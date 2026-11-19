@{
    Id = 'Validation.Dependencies'
    ConfigKey = 'validation'
    Version = '0.1.0'
    Operations = @('Validate')
    Invoke = {
        param($Context, $Operation)
        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $settings = $null
        if ($Context.Configuration.validation -is [System.Collections.IDictionary] -and $Context.Configuration.validation.Contains('dependencies')) { $settings = $Context.Configuration.validation.dependencies }
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('enabled') -and $settings.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.Dependencies' -Operation $Operation -Status Skipped -Summary 'Addon dependency validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }
        $severity = 'warning'
        if ($settings -is [System.Collections.IDictionary] -and $settings.severity) { $severity = ([string]$settings.severity).ToLowerInvariant() }
        $configFiles = @()
        $internalAddons = @()
        if ($settings -is [System.Collections.IDictionary]) {
            if ($settings.Contains('config_files')) { $configFiles = @($settings.config_files) }
            if ($settings.Contains('internal_addons')) { $internalAddons = @($settings.internal_addons) }
        }
        if ($configFiles.Count -eq 0) {
            $watch.Stop()
            $diagnostic = @{ Message = 'No config source files were configured; addon dependency declarations were not inspected.'; Remediation = 'Add project-relative config.cpp paths to validation.dependencies.config_files. List project-owned addon class names in internal_addons to enable internal dependency checks.' }
            return (New-A3WorkflowModuleResult -Module 'Validation.Dependencies' -Operation $Operation -Status Skipped -Summary 'No config source files are configured.' -Warnings @($diagnostic) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0; DeclaredAddons = @(); ExternalDependenciesIgnored = $true })
        }

        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $declarations = @{}
        $requiredByAddon = @{}
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

        $removeComments = {
            param([string]$SourceText)
            $builder = New-Object System.Text.StringBuilder
            $state = 'Code'
            $index = 0
            while ($index -lt $SourceText.Length) {
                $character = $SourceText[$index]
                $next = [char]0
                if ($index + 1 -lt $SourceText.Length) { $next = $SourceText[$index + 1] }
                if ($state -eq 'LineComment') {
                    if ($character -eq "`n" -or $character -eq "`r") { [void]$builder.Append($character); $state = 'Code' } else { [void]$builder.Append(' ') }
                }
                elseif ($state -eq 'BlockComment') {
                    if ($character -eq '*' -and $next -eq '/') { [void]$builder.Append(' '); [void]$builder.Append(' '); $index++; $state = 'Code' }
                    elseif ($character -eq "`n" -or $character -eq "`r") { [void]$builder.Append($character) } else { [void]$builder.Append(' ') }
                }
                elseif ($state -eq 'String') {
                    [void]$builder.Append($character)
                    if ($character -eq '\' -and $index + 1 -lt $SourceText.Length) { $index++; [void]$builder.Append($SourceText[$index]) }
                    elseif ($character -eq '"' -and $next -eq '"') { $index++; [void]$builder.Append('"') }
                    elseif ($character -eq '"') { $state = 'Code' }
                }
                else {
                    if ($character -eq '/' -and $next -eq '/') { [void]$builder.Append(' '); [void]$builder.Append(' '); $index++; $state = 'LineComment' }
                    elseif ($character -eq '/' -and $next -eq '*') { [void]$builder.Append(' '); [void]$builder.Append(' '); $index++; $state = 'BlockComment' }
                    else { [void]$builder.Append($character); if ($character -eq '"') { $state = 'String' } }
                }
                $index++
            }
            return $builder.ToString()
        }
        $getBlockEnd = {
            param([string]$SourceText, [int]$OpeningBrace)
            $depth = 0
            $state = 'Code'
            $index = $OpeningBrace
            while ($index -lt $SourceText.Length) {
                $character = $SourceText[$index]
                $next = [char]0
                if ($index + 1 -lt $SourceText.Length) { $next = $SourceText[$index + 1] }
                if ($state -eq 'String') {
                    if ($character -eq '\') { $index++ }
                    elseif ($character -eq '"' -and $next -eq '"') { $index++ }
                    elseif ($character -eq '"') { $state = 'Code' }
                }
                else {
                    if ($character -eq '"') { $state = 'String' }
                    elseif ($character -eq '{') { $depth++ }
                    elseif ($character -eq '}') { $depth--; if ($depth -eq 0) { return $index } }
                }
                $index++
            }
            return -1
        }

        $seenFiles = @{}
        foreach ($configFile in $configFiles) {
            $relativePath = [string]$configFile
            $finding = $null
            if ([string]::IsNullOrWhiteSpace($relativePath)) { $finding = @{ Id = 'DEPENDENCY_INVALID_PATH'; Severity = $severity; Message = 'Config source path is empty.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
            elseif ([IO.Path]::IsPathRooted($relativePath)) { $finding = @{ Id = 'DEPENDENCY_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'Config source paths must be relative to the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
            else {
                $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
                if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $projectRoot) { $finding = @{ Id = 'DEPENDENCY_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'Config source path resolves outside the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                elseif (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $finding = @{ Id = 'DEPENDENCY_CONFIG_FILE_NOT_FOUND'; Severity = $severity; Message = 'Config source file does not exist.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                elseif ($seenFiles.ContainsKey($candidate)) { $finding = @{ Id = 'DEPENDENCY_CONFIG_FILE_DUPLICATE'; Severity = $severity; Message = 'Config source file is listed more than once.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                else {
                    $seenFiles[$candidate] = $true
                    try {
                        $codeText = & $removeComments (Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop)
                        $patchMatch = [regex]::Match($codeText, '(?im)^\s*class\s+CfgPatches\s*(?::\s*[A-Za-z_][A-Za-z0-9_]*)?\s*\{')
                        if (-not $patchMatch.Success) { $finding = @{ Id = 'DEPENDENCY_CFGPATCHES_NOT_FOUND'; Severity = $severity; Message = 'No CfgPatches class declaration was found in this config file.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                        else {
                            $patchOpen = $codeText.IndexOf('{', $patchMatch.Index)
                            $patchClose = & $getBlockEnd $codeText $patchOpen
                            if ($patchClose -lt 0) { $finding = @{ Id = 'DEPENDENCY_CFGPATCHES_UNCLOSED'; Severity = $severity; Message = 'CfgPatches has an unclosed class body.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                            else {
                                $patchBody = $codeText.Substring($patchOpen + 1, $patchClose - $patchOpen - 1)
                                $classMatches = [regex]::Matches($patchBody, '(?im)^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[A-Za-z_][A-Za-z0-9_]*)?\s*\{')
                                foreach ($classMatch in $classMatches) {
                                    $addonName = [string]$classMatch.Groups[1].Value
                                    $classOpen = $patchBody.IndexOf('{', $classMatch.Index)
                                    $classClose = & $getBlockEnd $patchBody $classOpen
                                    if ($classClose -lt 0) {
                                        $findings.Add([pscustomobject]@{ Id = 'DEPENDENCY_ADDON_CLASS_UNCLOSED'; Severity = $severity; Message = "Addon class '$addonName' has an unclosed class body."; Path = $relativePath; Addon = $addonName; Tool = 'Arma3-Mod-Workflows' })
                                        continue
                                    }
                                    if (-not $declarations.ContainsKey($addonName)) { $declarations[$addonName] = New-Object System.Collections.Generic.List[object] }
                                    $declarations[$addonName].Add([pscustomobject]@{ Path = $relativePath; Addon = $addonName })
                                    $addonBody = $patchBody.Substring($classOpen + 1, $classClose - $classOpen - 1)
                                    $requiredMatch = [regex]::Match($addonBody, '(?is)\brequiredAddons\s*\[\s*\]\s*=\s*\{(?<values>.*?)\}')
                                    if ($requiredMatch.Success) {
                                        $requiredNames = [regex]::Matches($requiredMatch.Groups['values'].Value, '"((?:\\.|[^"\\])*)"')
                                        foreach ($requiredName in $requiredNames) {
                                            $dependencyName = [string]$requiredName.Groups[1].Value
                                            if (-not $requiredByAddon.ContainsKey($dependencyName)) { $requiredByAddon[$dependencyName] = New-Object System.Collections.Generic.List[string] }
                                            $requiredByAddon[$dependencyName].Add($addonName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    catch { $finding = @{ Id = 'DEPENDENCY_CONFIG_READ_FAILED'; Severity = $severity; Message = "Config source file could not be read or inspected: $($_.Exception.Message)"; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' } }
                }
            }
            if ($finding) { $findings.Add([pscustomobject]$finding); $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' }) }
            else { $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Passed' }) }
        }

        foreach ($addonName in @($declarations.Keys)) {
            if ($declarations[$addonName].Count -gt 1) {
                $paths = @($declarations[$addonName] | ForEach-Object { $_.Path })
                $findings.Add([pscustomobject]@{ Id = 'DEPENDENCY_ADDON_DUPLICATE'; Severity = $severity; Message = "Addon '$addonName' is declared in more than one config source."; Addon = $addonName; Paths = $paths; Tool = 'Arma3-Mod-Workflows' })
            }
        }
        $internalSeen = @{}
        foreach ($internalValue in $internalAddons) {
            $internalName = [string]$internalValue
            if ([string]::IsNullOrWhiteSpace($internalName)) { $findings.Add([pscustomobject]@{ Id = 'DEPENDENCY_INTERNAL_ADDON_INVALID'; Severity = $severity; Message = 'An internal addon identifier is empty.'; Addon = $internalName; Tool = 'Arma3-Mod-Workflows' }); continue }
            if ($internalSeen.ContainsKey($internalName)) { $findings.Add([pscustomobject]@{ Id = 'DEPENDENCY_INTERNAL_ADDON_DUPLICATE'; Severity = $severity; Message = "Internal addon '$internalName' is listed more than once."; Addon = $internalName; Tool = 'Arma3-Mod-Workflows' }); continue }
            $internalSeen[$internalName] = $true
            if (-not $declarations.ContainsKey($internalName)) {
                $referencedBy = @()
                if ($requiredByAddon.ContainsKey($internalName)) { $referencedBy = @($requiredByAddon[$internalName] | Select-Object -Unique) }
                $findings.Add([pscustomobject]@{ Id = 'DEPENDENCY_INTERNAL_ADDON_MISSING'; Severity = $severity; Message = "Internal addon '$internalName' is required or expected but has no CfgPatches declaration in the configured files."; Addon = $internalName; ReferencedBy = $referencedBy; Tool = 'Arma3-Mod-Workflows' })
            }
        }

        $watch.Stop()
        $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
        $warnings = @($findings | Where-Object { $_.Severity -eq 'warning' })
        $status = 'Passed'
        $summary = "Inspected $($checks.Count) config source file(s) and $($declarations.Count) addon declaration(s); no dependency issues found."
        if ($errors.Count -gt 0) { $status = 'Failed'; $summary = "Found $($errors.Count) addon dependency error(s) across $($checks.Count) config source file(s)." }
        elseif ($warnings.Count -gt 0) { $status = 'Warning'; $summary = "Found $($warnings.Count) addon dependency warning(s) across $($checks.Count) config source file(s)." }
        return (New-A3WorkflowModuleResult -Module 'Validation.Dependencies' -Operation $Operation -Status $status -Summary $summary -Errors $errors -Warnings $warnings -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            ConfigFileCount = $checks.Count
            DeclaredAddons = @($declarations.Keys | Sort-Object)
            InternalAddons = @($internalSeen.Keys | Sort-Object)
            ExternalDependenciesIgnored = $true
            ProjectRoot = $projectRoot
        })
    }
}
