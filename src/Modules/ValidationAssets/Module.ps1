@{
    Id = 'Validation.Assets'
    ConfigKey = 'validation'
    Version = '0.1.0'
    Operations = @('Validate')
    Invoke = {
        param($Context, $Operation)

        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $validation = $Context.Configuration.validation
        $assetConfiguration = $null

        if ($validation -is [System.Collections.IDictionary] -and $validation.Contains('assets')) {
            $assetConfiguration = $validation.assets
        }

        if ($assetConfiguration -is [System.Collections.IDictionary] -and $assetConfiguration.Contains('enabled') -and $assetConfiguration.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.Assets' -Operation $Operation -Status Skipped -Summary 'Asset reference validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $severity = 'error'
        if ($assetConfiguration -is [System.Collections.IDictionary] -and $assetConfiguration.severity) {
            $severity = ([string]$assetConfiguration.severity).ToLowerInvariant()
        }

        $references = @()
        if ($assetConfiguration -is [System.Collections.IDictionary] -and $assetConfiguration.Contains('references')) {
            $references = @($assetConfiguration.references)
        }

        if ($references.Count -eq 0) {
            $watch.Stop()
            $diagnostic = @{ Message = 'No asset references were configured; no project files were inspected.'; Remediation = 'Add project-relative paths to validation.assets.references to enable manifest-based asset checks.' }
            return (New-A3WorkflowModuleResult -Module 'Validation.Assets' -Operation $Operation -Status Skipped -Summary 'No asset references are configured.' -Warnings @($diagnostic) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0 })
        }

        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

        foreach ($reference in $references) {
            $relativePath = [string]$reference
            $finding = $null
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $finding = @{ Id = 'ASSET_INVALID_PATH'; Severity = $severity; Message = 'Asset reference is empty.'; Path = $null; Tool = 'Arma3-Mod-Workflows' }
            }
            elseif ([IO.Path]::IsPathRooted($relativePath)) {
                $finding = @{ Id = 'ASSET_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'Asset references must be relative to the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' }
            }
            else {
                $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
                if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $projectRoot) {
                    $finding = @{ Id = 'ASSET_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'Asset reference resolves outside the project root.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' }
                }
                elseif (-not (Test-Path -LiteralPath $candidate)) {
                    $finding = @{ Id = 'ASSET_NOT_FOUND'; Severity = $severity; Message = 'Referenced asset does not exist.'; Path = $relativePath; Tool = 'Arma3-Mod-Workflows' }
                }
            }

            if ($finding) {
                $findings.Add([pscustomobject]$finding)
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
            }
            else {
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Passed' })
            }
        }

        $watch.Stop()
        $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
        $warnings = @($findings | Where-Object { $_.Severity -eq 'warning' })
        $status = 'Passed'
        $summary = "Validated $($checks.Count) configured asset reference(s); no issues found."
        if ($errors.Count -gt 0) {
            $status = 'Failed'
            $summary = "Found $($errors.Count) asset error(s) across $($checks.Count) configured reference(s)."
        }
        elseif ($warnings.Count -gt 0) {
            $status = 'Warning'
            $summary = "Found $($warnings.Count) asset warning(s) across $($checks.Count) configured reference(s)."
        }

        return (New-A3WorkflowModuleResult -Module 'Validation.Assets' -Operation $Operation -Status $status -Summary $summary -Errors $errors -Warnings $warnings -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            ProjectRoot = $projectRoot
        })
    }
}
