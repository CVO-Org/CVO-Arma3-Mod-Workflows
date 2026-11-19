@{
    Id = 'Validation.Package'
    ConfigKey = 'validation'
    Version = '0.1.0'
    Operations = @('Validate')
    Invoke = {
        param($Context, $Operation)

        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $settings = $null
        if ($Context.Configuration.validation -is [System.Collections.IDictionary] -and $Context.Configuration.validation.Contains('package')) {
            $settings = $Context.Configuration.validation.package
        }

        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('enabled') -and $settings.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.Package' -Operation $Operation -Status Skipped -Summary 'Package validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $severity = 'error'
        if ($settings -is [System.Collections.IDictionary] -and $settings.severity) {
            $severity = ([string]$settings.severity).ToLowerInvariant()
        }
        $artifacts = @()
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('artifacts')) {
            $artifacts = @($settings.artifacts)
        }
        if ($artifacts.Count -eq 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.Package' -Operation $Operation -Status Skipped -Summary 'No package artifacts are configured.' -Warnings @(@{ Message = 'No PBO files were inspected.'; Remediation = 'Add explicit project-relative PBO paths to validation.package.artifacts.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0; Packages = @() })
        }

        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $packages = New-Object System.Collections.Generic.List[object]
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $readAsciiZ = {
            param([System.IO.BinaryReader]$Reader)
            $builder = New-Object System.Text.StringBuilder
            $terminated = $false
            for ($index = 0; $index -lt 4096; $index++) {
                if ($Reader.BaseStream.Position -ge $Reader.BaseStream.Length) { break }
                $byte = $Reader.ReadByte()
                if ($byte -eq 0) { $terminated = $true; break }
                [void]$builder.Append([char]$byte)
            }
            if (-not $terminated) { throw 'PBO header contains an unterminated or excessively long string.' }
            return $builder.ToString()
        }

        foreach ($artifact in $artifacts) {
            $relativePath = ''
            $requiredEntries = @()
            if ($artifact -is [System.Collections.IDictionary]) {
                if ($artifact.Contains('path')) { $relativePath = [string]$artifact.path }
                if ($artifact.Contains('required_entries')) { $requiredEntries = @($artifact.required_entries) }
            }
            else {
                $relativePath = [string]$artifact
            }

            $findingStart = $findings.Count
            $candidate = $null
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $findings.Add([pscustomobject]@{ Id = 'PACKAGE_INVALID_PATH'; Severity = $severity; Message = 'Package artifact path is empty.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
            }
            elseif ([IO.Path]::IsPathRooted($relativePath)) {
                $findings.Add([pscustomobject]@{ Id = 'PACKAGE_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'Package artifact paths must be relative to the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
            }
            else {
                try { $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath)) }
                catch { $findings.Add([pscustomobject]@{ Id = 'PACKAGE_INVALID_PATH'; Severity = $severity; Message = "Package path could not be resolved: $($_.Exception.Message)"; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' }) }
                if ($candidate -and -not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $projectRoot) {
                    $findings.Add([pscustomobject]@{ Id = 'PACKAGE_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'Package path resolves outside the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
                    $candidate = $null
                }
                elseif ($candidate -and [IO.Path]::GetExtension($candidate) -ine '.pbo') {
                    $findings.Add([pscustomobject]@{ Id = 'PACKAGE_INVALID_EXTENSION'; Severity = $severity; Message = 'Package artifact must use the .pbo extension; encrypted or other container formats are not inspected.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
                    $candidate = $null
                }
                elseif ($candidate -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $findings.Add([pscustomobject]@{ Id = 'PACKAGE_NOT_FOUND'; Severity = $severity; Message = 'Configured PBO artifact does not exist.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
                    $candidate = $null
                }
            }

            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $entryNames = New-Object System.Collections.Generic.List[string]
                $packageInfo = $null
                try {
                    $stream = New-Object System.IO.FileStream($candidate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    try {
                        if ($stream.Length -lt 21) { throw 'PBO is too small to contain a complete header.' }
                        $reader = New-Object System.IO.BinaryReader($stream, [Text.Encoding]::ASCII, $true)
                        try {
                            $headerEnded = $false
                            $firstEntry = $true
                            $dataBytes = [UInt64]0
                            $entryCount = 0
                            while ($stream.Position -lt $stream.Length) {
                                $entryName = & $readAsciiZ $reader
                                $metadata = $reader.ReadBytes(20)
                                if ($metadata.Length -ne 20) { throw 'PBO header entry is truncated.' }
                                $mime = [Text.Encoding]::ASCII.GetString($metadata, 0, 4)
                                $originalSize = [BitConverter]::ToUInt32($metadata, 4)
                                $timestamp = [BitConverter]::ToUInt32($metadata, 12)
                                $dataSize = [BitConverter]::ToUInt32($metadata, 16)

                                if ([string]::IsNullOrEmpty($entryName)) {
                                    if ($firstEntry -and $mime -eq 'Vers') {
                                        if ($originalSize -ne 0 -or $timestamp -ne 0 -or $dataSize -ne 0) { throw 'PBO properties entry has unexpected nonzero metadata.' }
                                        while ($true) {
                                            $propertyName = & $readAsciiZ $reader
                                            if ([string]::IsNullOrEmpty($propertyName)) { break }
                                            $propertyValue = & $readAsciiZ $reader
                                            if ([string]::IsNullOrEmpty($propertyValue)) { throw 'PBO properties entry contains an incomplete key/value pair.' }
                                        }
                                        $firstEntry = $false
                                        continue
                                    }
                                    if ($mime -eq [string]::new([char]0, 4) -and $originalSize -eq 0 -and $timestamp -eq 0 -and $dataSize -eq 0) {
                                        $headerEnded = $true
                                        break
                                    }
                                    throw 'PBO header contains an invalid empty-name entry.'
                                }

                                if ($entryName -match '[\x00-\x1F]' -or $entryName.StartsWith('/') -or $entryName -match '^[A-Za-z]:') {
                                    throw "PBO contains an invalid entry path '$entryName'."
                                }
                                if ($entryName -match '(^|[\\/])\.\.([\\/]|$)') {
                                    throw "PBO entry path escapes its package root: '$entryName'."
                                }
                                if ($mime -ne [string]::new([char]0, 4) -and $mime -ne 'Cprs' -and $mime -ne 'Encr') {
                                    throw "PBO entry '$entryName' uses an unrecognized packing marker '$mime'."
                                }
                                $entryNames.Add($entryName)
                                $entryCount++
                                $dataBytes += [UInt64]$dataSize
                                $firstEntry = $false
                            }
                            if (-not $headerEnded) { throw 'PBO header terminator was not found.' }
                            $dataStart = $stream.Position
                            $dataEnd = [UInt64]$dataStart + $dataBytes
                            if ($dataEnd -gt [UInt64]$stream.Length) { throw 'PBO file data extends beyond the end of the artifact.' }
                            $trailingBytes = [UInt64]$stream.Length - $dataEnd
                            if ($trailingBytes -notin @([UInt64]0, [UInt64]20)) {
                                throw "PBO has an unexpected $trailingBytes trailing byte(s) after its data section; only an optional 20-byte SHA-1 checksum is accepted."
                            }
                            if ($entryCount -eq 0) { throw 'PBO contains no file entries.' }
                            $packageInfo = [pscustomobject]@{ Path = $relativePath; EntryCount = $entryCount; Entries = @($entryNames.ToArray()); DataBytes = $dataBytes; TrailingBytes = $trailingBytes; Status = 'Passed' }
                        }
                        finally { $reader.Dispose() }
                    }
                    finally { $stream.Dispose() }
                }
                catch {
                    $findings.Add([pscustomobject]@{ Id = 'PACKAGE_INVALID_PBO'; Severity = $severity; Message = $_.Exception.Message; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' })
                }

                if ($packageInfo) {
                    foreach ($requiredEntry in $requiredEntries) {
                        $normalizedRequired = ([string]$requiredEntry).Replace('/', '\')
                        $found = $false
                        foreach ($entryName in $entryNames) {
                            if ($entryName.Replace('/', '\') -ieq $normalizedRequired) { $found = $true; break }
                        }
                        if (-not $found) {
                            $findings.Add([pscustomobject]@{ Id = 'PACKAGE_REQUIRED_ENTRY_MISSING'; Severity = $severity; Message = "Required package entry '$requiredEntry' was not found."; Path = $relativePath; Entry = [string]$requiredEntry; Tool = 'Arma3-Mod-Workflows' })
                        }
                    }
                    $packages.Add($packageInfo)
                }
            }

            $newFindings = @($findings | Select-Object -Skip $findingStart)
            $checkStatus = 'Passed'
            if (@($newFindings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { $checkStatus = 'Failed' }
            elseif (@($newFindings | Where-Object { $_.Severity -eq 'warning' }).Count -gt 0) { $checkStatus = 'Warning' }
            $checks.Add([pscustomobject]@{ Path = $relativePath; Status = $checkStatus })
        }

        $watch.Stop()
        $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
        $warnings = @($findings | Where-Object { $_.Severity -eq 'warning' })
        $status = 'Passed'
        $summary = "Inspected $($checks.Count) configured PBO artifact(s); no issues found."
        if ($errors.Count -gt 0) {
            $status = 'Failed'
            $summary = "Found $($errors.Count) package error(s) across $($checks.Count) configured artifact(s)."
        }
        elseif ($warnings.Count -gt 0) {
            $status = 'Warning'
            $summary = "Found $($warnings.Count) package warning(s) across $($checks.Count) configured artifact(s)."
        }

        return (New-A3WorkflowModuleResult -Module 'Validation.Package' -Operation $Operation -Status $status -Summary $summary -Errors $errors -Warnings $warnings -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            Packages = @($packages.ToArray())
            ProjectRoot = $projectRoot
            ValidationMode = 'PboStructure'
        })
    }
}