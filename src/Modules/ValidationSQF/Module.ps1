@{
    Id = 'Validation.SQF'
    ConfigKey = 'validation'
    Version = '0.1.0'
    Operations = @('Validate')
    Invoke = {
        param($Context, $Operation)

        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $validation = $Context.Configuration.validation
        $settings = $null
        if ($validation -is [System.Collections.IDictionary] -and $validation.Contains('sqf')) { $settings = $validation.sqf }

        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('enabled') -and $settings.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQF-VM validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $severity = 'error'
        if ($settings -is [System.Collections.IDictionary] -and $settings.severity) { $severity = ([string]$settings.severity).ToLowerInvariant() }
        $files = @()
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('files')) { $files = @($settings.files) }
        if ($files.Count -eq 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'No SQF source files are configured.' -Warnings @(@{ Message = 'SQF-VM validation requires an explicit project-relative file manifest.'; Remediation = 'Add .sqf paths to validation.sqf.files and configure tools.sqfvm.path.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0; Tool = 'SQF-VM' })
        }

        $tool = $null
        if ($Context.Configuration.tools -is [System.Collections.IDictionary] -and $Context.Configuration.tools.Contains('sqfvm')) { $tool = $Context.Configuration.tools.sqfvm }
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('enabled') -and $tool.enabled -eq $false) {
            $watch.Stop()
            if ($tool.required -eq $true) {
                return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQF-VM is required but explicitly disabled.' -Errors @(@{ Id = 'SQFVM_TOOL_DISABLED'; Message = 'tools.sqfvm.enabled is false while tools.sqfvm.required is true.'; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQF-VM is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $toolPath = $null
        if ($tool -is [System.Collections.IDictionary] -and $tool.path) {
            $toolPath = [string]$tool.path
            if (-not [IO.Path]::IsPathRooted($toolPath)) { $toolPath = Join-Path $projectRoot $toolPath }
            $toolPath = [IO.Path]::GetFullPath($toolPath)
        }
        else {
            $commands = @(Get-Command -Name 'sqfvm.exe','sqfvm','sqfvm_x64.exe','sqfvm_x64' -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
            if ($commands.Count -gt 0) { $toolPath = $commands[0].Source }
        }

        $requiredTool = $false
        if ($tool -is [System.Collections.IDictionary] -and $tool.required -eq $true) { $requiredTool = $true }
        if (-not $toolPath -or -not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            $watch.Stop()
            if ($requiredTool) {
                return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'Required SQF-VM executable was not found.' -Errors @(@{ Id = 'SQFVM_TOOL_NOT_FOUND'; Message = 'Configure tools.sqfvm.path or add sqfvm to PATH.'; Path = $toolPath; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQF-VM is not installed or configured.' -Warnings @(@{ Message = 'SQF-VM was not found; SQF files were not checked.'; Remediation = 'Install SQF-VM and configure tools.sqfvm.path, or make it available on PATH.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        if ($tool -is [System.Collections.IDictionary] -and $tool.version) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQF-VM version pin cannot be verified.' -Errors @(@{ Id = 'SQFVM_VERSION_UNVERIFIABLE'; Message = 'The upstream SQF-VM CLI does not document a stable machine-readable version query; remove tools.sqfvm.version and pin the executable through your project dependency process.'; Path = $toolPath; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $timeoutSeconds = 600
        if ($tool -is [System.Collections.IDictionary] -and $tool.timeout_seconds) { $timeoutSeconds = [int]$tool.timeout_seconds }
        if ($timeoutSeconds -lt 1) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQF-VM timeout must be greater than zero.' -Errors @(@{ Id = 'SQFVM_INVALID_TIMEOUT'; Message = 'tools.sqfvm.timeout_seconds must be a positive integer.'; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $extraArguments = @()
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('arguments')) { $extraArguments = @($tool.arguments) }
        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $errors = New-Object System.Collections.Generic.List[object]
        $processes = New-Object System.Collections.Generic.List[object]
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

        $quoteArgument = {
            param([string]$Value)
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append('"')
            $slashes = 0
            foreach ($character in $Value.ToCharArray()) {
                if ($character -eq [char]92) { $slashes++ }
                elseif ($character -eq [char]34) {
                    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
                    [void]$builder.Append('\')
                    [void]$builder.Append('"')
                    $slashes = 0
                }
                else {
                    if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
                    [void]$builder.Append($character)
                    $slashes = 0
                }
            }
            if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
            [void]$builder.Append('"')
            return $builder.ToString()
        }

        foreach ($fileValue in $files) {
            $relativePath = [string]$fileValue
            $candidate = $null
            $fileFinding = $null
            if ([string]::IsNullOrWhiteSpace($relativePath)) { $fileFinding = @{ Id = 'SQFVM_INVALID_PATH'; Severity = $severity; Message = 'SQF source path is empty.'; Path = $relativePath; Tool = 'SQF-VM' } }
            elseif ([IO.Path]::IsPathRooted($relativePath)) { $fileFinding = @{ Id = 'SQFVM_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'SQF source paths must be relative to the project root.'; Path = $relativePath; Tool = 'SQF-VM' } }
            else {
                $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
                if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $fileFinding = @{ Id = 'SQFVM_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'SQF source path resolves outside the project root.'; Path = $relativePath; Tool = 'SQF-VM' } }
                elseif ([IO.Path]::GetExtension($candidate) -ine '.sqf') { $fileFinding = @{ Id = 'SQFVM_INVALID_EXTENSION'; Severity = $severity; Message = 'Only .sqf source files can be passed to SQF-VM.'; Path = $relativePath; Tool = 'SQF-VM' } }
                elseif (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $fileFinding = @{ Id = 'SQFVM_FILE_NOT_FOUND'; Severity = $severity; Message = 'SQF source file does not exist.'; Path = $relativePath; Tool = 'SQF-VM' } }
            }
            if ($fileFinding) {
                $findings.Add([pscustomobject]$fileFinding)
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                continue
            }

            $arguments = @('--automated', '--suppress-welcome', '--no-execute-print', '--parse-only', '--input-sqf', $candidate) + $extraArguments
            $quoted = @()
            foreach ($argument in $arguments) { $quoted += (& $quoteArgument ([string]$argument)) }
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $toolPath
            $startInfo.Arguments = $quoted -join ' '
            $startInfo.WorkingDirectory = $projectRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $processWatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                if (-not $process.Start()) { throw 'SQF-VM process did not start.' }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $timedOut = -not $process.WaitForExit($timeoutSeconds * 1000)
                if ($timedOut) {
                    try { if (-not $process.HasExited) { $process.Kill() }; $process.WaitForExit() } catch { }
                }
                $stdout = [string]$stdoutTask.Result
                $stderr = [string]$stderrTask.Result
                $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
                $processWatch.Stop()
                $processes.Add([pscustomobject]@{ Path = $relativePath; ExitCode = $exitCode; TimedOut = $timedOut; DurationMs = $processWatch.ElapsedMilliseconds; StandardOutput = $stdout; StandardError = $stderr })
                if ($timedOut) {
                    $errors.Add([pscustomobject]@{ Id = 'SQFVM_PROCESS_TIMEOUT'; Message = "SQF-VM exceeded its $timeoutSeconds second timeout."; Path = $relativePath; Tool = 'SQF-VM'; ExitCode = 124 })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                }
                elseif ($exitCode -ne 0) {
                    $errors.Add([pscustomobject]@{ Id = 'SQFVM_PROCESS_FAILED'; Message = "SQF-VM exited with code $exitCode."; Path = $relativePath; Tool = 'SQF-VM'; ExitCode = $exitCode; StandardError = $stderr })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                }
                else {
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Passed' })
                }
            }
            catch {
                $processWatch.Stop()
                $errors.Add([pscustomobject]@{ Id = 'SQFVM_PROCESS_START_FAILED'; Message = "SQF-VM could not be started: $($_.Exception.Message)"; Path = $relativePath; Tool = 'SQF-VM'; StandardError = $_.Exception.Message })
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
            }
            finally {
                try { if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
                if ($process) { $process.Dispose() }
            }
        }

        foreach ($finding in $findings) {
            if ($finding.Severity -eq 'error') { $errors.Add($finding) }
        }
        $watch.Stop()
        $status = 'Passed'
        $summary = "SQF-VM parsed $($checks.Count) SQF source file(s) successfully."
        if ($errors.Count -gt 0) { $status = 'Failed'; $summary = "SQF-VM reported $($errors.Count) validation/process error(s)." }
        elseif ($findings.Count -gt 0) { $status = 'Warning'; $summary = "SQF-VM reported $($findings.Count) source path finding(s)." }

        return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status $status -Summary $summary -Errors @($errors.ToArray()) -Warnings @($findings | Where-Object { $_.Severity -eq 'warning' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            Tool = @{ Name = 'SQF-VM'; Path = $toolPath; Version = $null; VersionDetection = 'The upstream CLI does not document a stable machine-readable version query.' }
            Processes = @($processes.ToArray())
            ProjectRoot = $projectRoot
            ValidationMode = 'ParseOnly'
        })
    }
}
