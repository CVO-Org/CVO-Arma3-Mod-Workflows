@{
    Id = 'Validation.Config'
    ConfigKey = 'validation'
    Version = '0.1.0'
    Operations = @('Validate')
    Invoke = {
        param($Context, $Operation)

        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $validation = $Context.Configuration.validation
        $configSettings = $null

        if ($validation -is [System.Collections.IDictionary] -and $validation.Contains('config')) {
            $configSettings = $validation.config
        }

        if ($configSettings -is [System.Collections.IDictionary] -and $configSettings.Contains('enabled') -and $configSettings.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.Config' -Operation $Operation -Status Skipped -Summary 'Config contract validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $severity = 'error'
        if ($configSettings -is [System.Collections.IDictionary] -and $configSettings.severity) {
            $severity = ([string]$configSettings.severity).ToLowerInvariant()
        }

        $expectations = @()
        if ($configSettings -is [System.Collections.IDictionary] -and $configSettings.Contains('required_classes')) {
            $expectations = @($configSettings.required_classes)
        }

        if ($expectations.Count -eq 0) {
            $watch.Stop()
            $diagnostic = @{
                Message = 'No required config classes were configured; no config source files were inspected.'
                Remediation = 'Add path/name entries to validation.config.required_classes to check project config class declarations.'
            }
            return (New-A3WorkflowModuleResult -Module 'Validation.Config' -Operation $Operation -Status Skipped -Summary 'No required config classes are configured.' -Warnings @($diagnostic) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0 })
        }

        # Remove comments and quoted strings while preserving line breaks. This keeps
        # class-like text inside comments or string values from becoming declarations.
        $stripConfigNonCode = {
            param([string]$SourceText)
            $builder = New-Object System.Text.StringBuilder
            $state = 'Code'
            $index = 0
            while ($index -lt $SourceText.Length) {
                $character = $SourceText[$index]
                $next = [char]0
                if ($index + 1 -lt $SourceText.Length) { $next = $SourceText[$index + 1] }

                if ($state -eq 'LineComment') {
                    if ($character -eq "`n" -or $character -eq "`r") {
                        [void]$builder.Append($character)
                        $state = 'Code'
                    }
                    else { [void]$builder.Append(' ') }
                }
                elseif ($state -eq 'BlockComment') {
                    if ($character -eq '*' -and $next -eq '/') {
                        [void]$builder.Append(' ')
                        [void]$builder.Append(' ')
                        $index++
                        $state = 'Code'
                    }
                    elseif ($character -eq "`n" -or $character -eq "`r") { [void]$builder.Append($character) }
                    else { [void]$builder.Append(' ') }
                }
                elseif ($state -eq 'String') {
                    if ($character -eq '\') {
                        [void]$builder.Append(' ')
                        if ($index + 1 -lt $SourceText.Length) {
                            $index++
                            if ($SourceText[$index] -eq "`n" -or $SourceText[$index] -eq "`r") { [void]$builder.Append($SourceText[$index]) }
                            else { [void]$builder.Append(' ') }
                        }
                    }
                    elseif ($character -eq '"' -and $next -eq '"') {
                        [void]$builder.Append(' ')
                        [void]$builder.Append(' ')
                        $index++
                    }
                    elseif ($character -eq '"') {
                        [void]$builder.Append(' ')
                        $state = 'Code'
                    }
                    elseif ($character -eq "`n" -or $character -eq "`r") { [void]$builder.Append($character) }
                    else { [void]$builder.Append(' ') }
                }
                else {
                    if ($character -eq '/' -and $next -eq '/') {
                        [void]$builder.Append(' ')
                        [void]$builder.Append(' ')
                        $index++
                        $state = 'LineComment'
                    }
                    elseif ($character -eq '/' -and $next -eq '*') {
                        [void]$builder.Append(' ')
                        [void]$builder.Append(' ')
                        $index++
                        $state = 'BlockComment'
                    }
                    elseif ($character -eq '"') {
                        [void]$builder.Append(' ')
                        $state = 'String'
                    }
                    else { [void]$builder.Append($character) }
                }
                $index++
            }
            return $builder.ToString()
        }

        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

        foreach ($expectation in $expectations) {
            $relativePath = [string]$expectation.path
            $className = [string]$expectation.name
            $finding = $null

            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $finding = @{ Id = 'CONFIG_INVALID_PATH'; Severity = $severity; Message = 'Config source path is empty.'; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
            }
            elseif ([IO.Path]::IsPathRooted($relativePath)) {
                $finding = @{ Id = 'CONFIG_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'Config source paths must be relative to the project root.'; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
            }
            else {
                $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
                if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $projectRoot) {
                    $finding = @{ Id = 'CONFIG_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'Config source path resolves outside the project root.'; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
                }
                elseif (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $finding = @{ Id = 'CONFIG_FILE_NOT_FOUND'; Severity = $severity; Message = 'Config source file does not exist.'; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
                }
                else {
                    try {
                        $sourceText = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
                        $codeText = & $stripConfigNonCode $sourceText
                        $escapedName = [regex]::Escape($className)
                        $pattern = '(?im)^\s*class\s+' + $escapedName + '\s*(?::\s*[A-Za-z_][A-Za-z0-9_]*)?\s*\{'
                        if ($codeText -notmatch $pattern) {
                            $finding = @{ Id = 'CONFIG_CLASS_NOT_FOUND'; Severity = $severity; Message = "Required config class '$className' was not declared in the source file."; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
                        }
                    }
                    catch {
                        $finding = @{ Id = 'CONFIG_READ_FAILED'; Severity = $severity; Message = "Config source file could not be read: $($_.Exception.Message)"; Path = $relativePath; Class = $className; Tool = 'Arma3-Mod-Workflows' }
                    }
                }
            }

            if ($finding) {
                $findings.Add([pscustomobject]$finding)
                $checks.Add([pscustomobject]@{ Path = $relativePath; Class = $className; Status = 'Failed' })
            }
            else {
                $checks.Add([pscustomobject]@{ Path = $relativePath; Class = $className; Status = 'Passed' })
            }
        }

        $watch.Stop()
        $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
        $warnings = @($findings | Where-Object { $_.Severity -eq 'warning' })
        $status = 'Passed'
        $summary = "Validated $($checks.Count) required config class declaration(s); no issues found."
        if ($errors.Count -gt 0) {
            $status = 'Failed'
            $summary = "Found $($errors.Count) config error(s) across $($checks.Count) required class declaration(s)."
        }
        elseif ($warnings.Count -gt 0) {
            $status = 'Warning'
            $summary = "Found $($warnings.Count) config warning(s) across $($checks.Count) required class declaration(s)."
        }

        return (New-A3WorkflowModuleResult -Module 'Validation.Config' -Operation $Operation -Status $status -Summary $summary -Errors $errors -Warnings $warnings -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            ProjectRoot = $projectRoot
        })
    }
}
