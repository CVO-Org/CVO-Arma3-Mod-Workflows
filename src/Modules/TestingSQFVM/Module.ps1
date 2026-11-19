@{
    Id = 'Testing.SQFVM'
    ConfigKey = 'testing'
    Version = '0.1.0'
    Operations = @('Test')
    Invoke = {
        param($Context, $Operation)

        $started = [DateTime]::UtcNow
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $projectRoot = [IO.Path]::GetFullPath([string]$Context.ProjectRoot)
        $testing = $Context.Configuration.testing
        $settings = $null
        if ($testing -is [System.Collections.IDictionary] -and $testing.Contains('sqfvm')) { $settings = $testing.sqfvm }

        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('enabled') -and $settings.enabled -eq $false) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Skipped -Summary 'SQF-VM test execution is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $files = @()
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('files')) { $files = @($settings.files) }
        if ($files.Count -eq 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Skipped -Summary 'No SQF-VM test scripts are configured.' -Warnings @(@{ Message = 'No test scripts were executed.'; Remediation = 'Add explicit project-relative test script paths to testing.sqfvm.files.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); TestCount = 0; Processes = @() })
        }

        $tool = $null
        if ($Context.Configuration.tools -is [System.Collections.IDictionary] -and $Context.Configuration.tools.Contains('sqfvm')) { $tool = $Context.Configuration.tools.sqfvm }
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('enabled') -and $tool.enabled -eq $false) {
            $watch.Stop()
            if ($tool.required -eq $true) {
                return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM is required but explicitly disabled.' -Errors @(@{ Id = 'SQFVM_TOOL_DISABLED'; Message = 'tools.sqfvm.enabled is false while tools.sqfvm.required is true.'; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Skipped -Summary 'SQF-VM is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
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
                return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'Required SQF-VM executable was not found.' -Errors @(@{ Id = 'SQFVM_TOOL_NOT_FOUND'; Message = 'Configure tools.sqfvm.path or add sqfvm to PATH.'; Path = $toolPath; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Skipped -Summary 'SQF-VM is not installed or configured.' -Warnings @(@{ Message = 'No test scripts were run because SQF-VM was not found.'; Remediation = 'Install SQF-VM and configure tools.sqfvm.path, or make it available on PATH.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $timeoutSeconds = 600
        if ($tool -is [System.Collections.IDictionary] -and $tool.timeout_seconds) { $timeoutSeconds = [int]$tool.timeout_seconds }
        if ($timeoutSeconds -lt 1) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM timeout must be greater than zero.' -Errors @(@{ Id = 'SQFVM_INVALID_TIMEOUT'; Message = 'tools.sqfvm.timeout_seconds must be a positive integer.'; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $maxRuntimeMs = 0
        if ($settings -is [System.Collections.IDictionary] -and $settings.max_runtime_ms) { $maxRuntimeMs = [int]$settings.max_runtime_ms }
        if ($maxRuntimeMs -lt 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM maximum runtime cannot be negative.' -Errors @(@{ Id = 'SQFVM_INVALID_MAX_RUNTIME'; Message = 'testing.sqfvm.max_runtime_ms must be zero or a positive integer.'; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $configFiles = @()
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('config_files')) { $configFiles = @($settings.config_files) }
        $extraArguments = @()
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('arguments')) { $extraArguments = @($tool.arguments) }
        $reservedArguments = @('--automated', '--suppress-welcome', '--no-execute-print', '--parse-only', '--input-sqf', '--input-config', '--max-runtime')
        $conflictingArguments = @()
        foreach ($argument in $extraArguments) {
            $argumentName = ([string]$argument -split '=', 2)[0]
            if ($reservedArguments -contains $argumentName) { $conflictingArguments += [string]$argument }
        }
        if ($conflictingArguments.Count -gt 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM extra arguments conflict with runner-controlled execution options.' -Errors @(@{ Id = 'SQFVM_RESERVED_ARGUMENT'; Message = 'Remove runner-controlled arguments from tools.sqfvm.arguments.'; Arguments = $conflictingArguments; Tool = 'SQF-VM' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); TestCount = 0; Processes = @(); Tool = @{ Name = 'SQF-VM'; Path = $toolPath }; ProjectRoot = $projectRoot; ExecutionMode = 'ExplicitTestScripts' })
        }
        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $errors = New-Object System.Collections.Generic.List[object]
        $processes = New-Object System.Collections.Generic.List[object]
        $rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

        $resolveProjectFile = {
            param([string]$RelativePath, [string]$Kind, [string]$ExpectedExtension)
            if ([string]::IsNullOrWhiteSpace($RelativePath)) { return @{ Error = @{ Id = 'SQFVM_INVALID_PATH'; Message = "$Kind path is empty."; Path = $RelativePath } } }
            if ([IO.Path]::IsPathRooted($RelativePath)) { return @{ Error = @{ Id = 'SQFVM_PATH_NOT_RELATIVE'; Message = "$Kind paths must be relative to the project root."; Path = $RelativePath } } }
            $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $RelativePath))
            if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return @{ Error = @{ Id = 'SQFVM_PATH_OUTSIDE_PROJECT'; Message = "$Kind path resolves outside the project root."; Path = $RelativePath } } }
            if ($ExpectedExtension -and [IO.Path]::GetExtension($candidate) -ine $ExpectedExtension) { return @{ Error = @{ Id = 'SQFVM_INVALID_EXTENSION'; Message = "$Kind files must use the $ExpectedExtension extension."; Path = $RelativePath } } }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return @{ Error = @{ Id = 'SQFVM_FILE_NOT_FOUND'; Message = "$Kind file does not exist."; Path = $RelativePath } } }
            return @{ Path = $candidate }
        }

        $validatedConfigs = @()
        foreach ($configValue in $configFiles) {
            $resolved = & $resolveProjectFile ([string]$configValue) 'SQF-VM config input' '.cpp'
            if ($resolved.Error) {
                $finding = [pscustomobject]@{ Id = $resolved.Error.Id; Severity = 'error'; Message = $resolved.Error.Message; Path = $resolved.Error.Path; Tool = 'SQF-VM' }
                $findings.Add($finding)
                $errors.Add($finding)
            }
            else { $validatedConfigs += $resolved.Path }
        }

        if ($errors.Count -gt 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM test configuration inputs are invalid; no test scripts were executed.' -Errors @($errors.ToArray()) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); TestCount = 0; Processes = @(); Tool = @{ Name = 'SQF-VM'; Path = $toolPath }; ProjectRoot = $projectRoot; ExecutionMode = 'ExplicitTestScripts' })
        }

        $processPath = $toolPath
        $processPrefix = @()
        if ([IO.Path]::GetExtension($toolPath) -ieq '.ps1') {
            $hostExecutable = Join-Path $PSHOME 'pwsh.exe'
            if (-not (Test-Path -LiteralPath $hostExecutable)) { $hostExecutable = Join-Path $PSHOME 'powershell.exe' }
            $processPath = $hostExecutable
            $processPrefix = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $toolPath)
        }

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

        $validatedTestFiles = New-Object System.Collections.Generic.List[object]
        foreach ($fileValue in $files) {
            $relativePath = [string]$fileValue
            $resolved = & $resolveProjectFile $relativePath 'SQF-VM test script' '.sqf'
            if ($resolved.Error) {
                $finding = [pscustomobject]@{ Id = $resolved.Error.Id; Severity = 'error'; Message = $resolved.Error.Message; Path = $resolved.Error.Path; Tool = 'SQF-VM' }
                $findings.Add($finding)
                $errors.Add($finding)
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed'; ExitCode = $null; TimedOut = $false })
            }
            else {
                $validatedTestFiles.Add([pscustomobject]@{ RelativePath = $relativePath; Path = $resolved.Path })
            }
        }

        if ($errors.Count -gt 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status Failed -Summary 'SQF-VM test manifest is invalid; no test scripts were executed.' -Errors @($errors.ToArray()) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
                Checks = @($checks.ToArray())
                TestCount = 0
                PassedCount = 0
                FailedCount = @($checks | Where-Object { $_.Status -eq 'Failed' }).Count
                Processes = @()
                Tool = @{ Name = 'SQF-VM'; Path = $toolPath; Version = $null }
                ProjectRoot = $projectRoot
                ExecutionMode = 'ExplicitTestScripts'
                MaxRuntimeMs = $maxRuntimeMs
            })
        }

        foreach ($validatedFile in $validatedTestFiles) {
            $relativePath = $validatedFile.RelativePath
            $resolvedPath = $validatedFile.Path
            $arguments = $processPrefix + @('--automated', '--suppress-welcome', '--no-execute-print')
            if ($maxRuntimeMs -gt 0) { $arguments += @('--max-runtime', [string]$maxRuntimeMs) }
            foreach ($configPath in $validatedConfigs) { $arguments += @('--input-config', $configPath) }
            $arguments += @('--input-sqf', $resolvedPath)
            $arguments += $extraArguments
            $quoted = @()
            foreach ($argument in $arguments) { $quoted += (& $quoteArgument ([string]$argument)) }

            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $processPath
            $startInfo.Arguments = $quoted -join ' '
            $startInfo.WorkingDirectory = $projectRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $processWatch = [Diagnostics.Stopwatch]::StartNew()
            $stdout = ''
            $stderr = ''
            try {
                if (-not $process.Start()) { throw 'SQF-VM process did not start.' }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $timedOut = -not $process.WaitForExit($timeoutSeconds * 1000)
                if ($timedOut) {
                    if ($env:OS -eq 'Windows_NT') {
                        try {
                            $taskkill = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                            if (Test-Path -LiteralPath $taskkill) {
                                $killInfo = New-Object System.Diagnostics.ProcessStartInfo
                                $killInfo.FileName = $taskkill
                                $killInfo.Arguments = "/PID $($process.Id) /T /F"
                                $killInfo.UseShellExecute = $false
                                $killProcess = [Diagnostics.Process]::Start($killInfo)
                                if ($killProcess) { $killProcess.WaitForExit(); $killProcess.Dispose() }
                            }
                        } catch { }
                    }
                    try { if (-not $process.HasExited) { $process.Kill() }; $process.WaitForExit() } catch { }
                }
                $stdout = [string]$stdoutTask.Result
                $stderr = [string]$stderrTask.Result
                $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
                $processWatch.Stop()
                $processResult = [pscustomobject]@{ Path = $relativePath; ExitCode = $exitCode; TimedOut = $timedOut; DurationMs = $processWatch.ElapsedMilliseconds; StandardOutput = $stdout; StandardError = $stderr }
                $processes.Add($processResult)
                if ($timedOut) {
                    $errors.Add([pscustomobject]@{ Id = 'SQFVM_TEST_TIMEOUT'; Message = "SQF-VM test script exceeded the $timeoutSeconds second process timeout."; Path = $relativePath; Tool = 'SQF-VM'; ExitCode = 124 })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed'; ExitCode = 124; TimedOut = $true })
                }
                elseif ($exitCode -ne 0) {
                    $errors.Add([pscustomobject]@{ Id = 'SQFVM_TEST_FAILED'; Message = "SQF-VM test script exited with code $exitCode."; Path = $relativePath; Tool = 'SQF-VM'; ExitCode = $exitCode; StandardError = $stderr })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed'; ExitCode = $exitCode; TimedOut = $false })
                }
                else {
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Passed'; ExitCode = 0; TimedOut = $false })
                }
            }
            catch {
                $processWatch.Stop()
                $errors.Add([pscustomobject]@{ Id = 'SQFVM_TEST_START_FAILED'; Message = "SQF-VM test process could not be started: $($_.Exception.Message)"; Path = $relativePath; Tool = 'SQF-VM'; StandardError = $_.Exception.Message })
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed'; ExitCode = $null; TimedOut = $false })
            }
            finally {
                try { if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
                if ($process) { $process.Dispose() }
            }
        }

        $watch.Stop()
        $status = 'Passed'
        $summary = "SQF-VM executed $($checks.Count) test script(s) successfully."
        if ($errors.Count -gt 0) { $status = 'Failed'; $summary = "SQF-VM test run failed with $($errors.Count) error(s)." }
        return (New-A3WorkflowModuleResult -Module 'Testing.SQFVM' -Operation $Operation -Status $status -Summary $summary -Errors @($errors.ToArray()) -Warnings @() -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            TestCount = $checks.Count
            PassedCount = @($checks | Where-Object { $_.Status -eq 'Passed' }).Count
            FailedCount = @($checks | Where-Object { $_.Status -eq 'Failed' }).Count
            Processes = @($processes.ToArray())
            Tool = @{ Name = 'SQF-VM'; Path = $toolPath; Version = $null }
            ProjectRoot = $projectRoot
            ExecutionMode = 'ExplicitTestScripts'
            MaxRuntimeMs = $maxRuntimeMs
        })
    }
}
