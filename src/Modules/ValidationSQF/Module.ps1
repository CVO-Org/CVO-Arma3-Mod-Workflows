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
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQF validation is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $severity = 'error'
        if ($settings -is [System.Collections.IDictionary] -and $settings.severity) { $severity = ([string]$settings.severity).ToLowerInvariant() }
        $files = @()
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('files')) { $files = @($settings.files) }
        if ($files.Count -eq 0) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'No SQF source files are configured.' -Warnings @(@{ Message = 'SQF validation requires an explicit project-relative file manifest.'; Remediation = 'Add .sqf paths to validation.sqf.files and configure tools.sqflint.path.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{ Checks = @(); Findings = @(); CheckedCount = 0; Tool = 'SQFLint' })
        }

        $tool = $null
        if ($Context.Configuration.tools -is [System.Collections.IDictionary] -and $Context.Configuration.tools.Contains('sqflint')) { $tool = $Context.Configuration.tools.sqflint }
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('enabled') -and $tool.enabled -eq $false) {
            $watch.Stop()
            if ($tool.required -eq $true) {
                return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQFLint is required but explicitly disabled.' -Errors @(@{ Id = 'SQF_TOOL_DISABLED'; Message = 'tools.sqflint.enabled is false while tools.sqflint.required is true.'; Tool = 'SQFLint' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQFLint is disabled.' -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $toolPath = $null
        $processPrefix = @()
        if ($tool -is [System.Collections.IDictionary] -and $tool.path) {
            $toolPath = [string]$tool.path
            if (-not [IO.Path]::IsPathRooted($toolPath)) { $toolPath = Join-Path $projectRoot $toolPath }
            $toolPath = [IO.Path]::GetFullPath($toolPath)
        }
        else {
            $commands = @(Get-Command -Name 'sqflint.exe','sqflint' -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
            if ($commands.Count -gt 0) { $toolPath = $commands[0].Source }
        }

        $requiredTool = $false
        if ($tool -is [System.Collections.IDictionary] -and $tool.required -eq $true) { $requiredTool = $true }
        if (-not $toolPath -or -not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            $watch.Stop()
            if ($requiredTool) {
                return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'Required SQFLint executable or JAR was not found.' -Errors @(@{ Id = 'SQF_TOOL_NOT_FOUND'; Message = 'Configure tools.sqflint.path or add sqflint to PATH.'; Path = $toolPath; Tool = 'SQFLint' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Skipped -Summary 'SQFLint is not installed or configured.' -Warnings @(@{ Message = 'SQFLint was not found; SQF files were not checked.'; Remediation = 'Install SQFLint and configure tools.sqflint.path, or make it available on PATH.' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        if ([IO.Path]::GetExtension($toolPath) -ieq '.jar') {
            $javaCommands = @(Get-Command -Name 'java.exe','java' -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' })
            if ($javaCommands.Count -eq 0) {
                $watch.Stop()
                $status = if ($requiredTool) { 'Failed' } else { 'Skipped' }
                $message = 'Java was not found on PATH; SQFLint JAR cannot be launched.'
                $diagnostic = @{ Id = 'SQF_JAVA_NOT_FOUND'; Message = $message; Path = $toolPath; Tool = 'SQFLint' }
                if ($requiredTool) { return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status $status -Summary $message -Errors @($diagnostic) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds))) }
                return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status $status -Summary $message -Warnings @($diagnostic) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
            }
            $processPath = $javaCommands[0].Source
            $processPrefix = @('-jar', $toolPath)
        }
        else {
            $processPath = $toolPath
        }

        if ($tool -is [System.Collections.IDictionary] -and $tool.version) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQFLint version pin cannot be verified.' -Errors @(@{ Id = 'SQF_VERSION_UNVERIFIABLE'; Message = 'The SQFLint CLI does not expose a documented version query; remove tools.sqflint.version or use a wrapper that reports and enforces its version.'; Path = $toolPath; Tool = 'SQFLint' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }

        $timeoutSeconds = 600
        if ($tool -is [System.Collections.IDictionary] -and $tool.timeout_seconds) { $timeoutSeconds = [int]$tool.timeout_seconds }
        if ($timeoutSeconds -lt 1) {
            $watch.Stop()
            return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status Failed -Summary 'SQFLint timeout must be greater than zero.' -Errors @(@{ Id = 'SQF_INVALID_TIMEOUT'; Message = 'tools.sqflint.timeout_seconds must be a positive integer.'; Tool = 'SQFLint' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)))
        }
        $extraArguments = @()
        if ($tool -is [System.Collections.IDictionary] -and $tool.Contains('arguments')) { $extraArguments = @($tool.arguments) }

        $findings = New-Object System.Collections.Generic.List[object]
        $checks = New-Object System.Collections.Generic.List[object]
        $errors = New-Object System.Collections.Generic.List[object]
        $toolOutputs = New-Object System.Collections.Generic.List[object]
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
            $fileFinding = $null
            if ([string]::IsNullOrWhiteSpace($relativePath)) { $fileFinding = @{ Id = 'SQF_INVALID_PATH'; Severity = $severity; Message = 'SQF source path is empty.'; Path = $relativePath; Tool = 'SQFLint' } }
            elseif ([IO.Path]::IsPathRooted($relativePath)) { $fileFinding = @{ Id = 'SQF_PATH_NOT_RELATIVE'; Severity = $severity; Message = 'SQF source paths must be relative to the project root.'; Path = $relativePath; Tool = 'SQFLint' } }
            else {
                $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $relativePath))
                if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $fileFinding = @{ Id = 'SQF_PATH_OUTSIDE_PROJECT'; Severity = $severity; Message = 'SQF source path resolves outside the project root.'; Path = $relativePath; Tool = 'SQFLint' } }
                elseif ([IO.Path]::GetExtension($candidate) -ine '.sqf') { $fileFinding = @{ Id = 'SQF_INVALID_EXTENSION'; Severity = $severity; Message = 'Only .sqf source files can be passed to SQFLint.'; Path = $relativePath; Tool = 'SQFLint' } }
                elseif (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $fileFinding = @{ Id = 'SQF_FILE_NOT_FOUND'; Severity = $severity; Message = 'SQF source file does not exist.'; Path = $relativePath; Tool = 'SQFLint' } }
            }
            if ($fileFinding) {
                $findings.Add([pscustomobject]$fileFinding)
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                continue
            }

            $arguments = @('-j', '-oc')
            if ($severity -eq 'error') { $arguments += '-we' }
            $arguments += $extraArguments
            $arguments += $candidate
            $quoted = @()
            foreach ($argument in $processPrefix + $arguments) { $quoted += (& $quoteArgument ([string]$argument)) }
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
            try {
                if (-not $process.Start()) { throw 'SQFLint process did not start.' }
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
                $toolOutputs.Add([pscustomobject]@{ Path = $relativePath; ExitCode = $exitCode; TimedOut = $timedOut; DurationMs = $processWatch.ElapsedMilliseconds; StandardOutput = $stdout; StandardError = $stderr })
                if ($timedOut) {
                    $errors.Add([pscustomobject]@{ Id = 'SQF_PROCESS_TIMEOUT'; Message = "SQFLint exceeded its $timeoutSeconds second timeout."; Path = $relativePath; Tool = 'SQFLint'; ExitCode = 124 })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                    continue
                }
                $parsedCount = 0
                foreach ($line in ($stdout -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $diagnostic = $line | ConvertFrom-Json -ErrorAction Stop }
                    catch {
                        $errors.Add([pscustomobject]@{ Id = 'SQF_OUTPUT_INVALID'; Message = "SQFLint returned non-JSON output: $line"; Path = $relativePath; Tool = 'SQFLint'; StandardError = $stderr })
                        continue
                    }
                    if ($diagnostic.type -eq 'error' -or $diagnostic.type -eq 'warning') {
                        $parsedCount++
                        $findingSeverity = $severity
                        $lineStart = $null
                        $columnStart = $null
                        if ($diagnostic.line -and $diagnostic.line.Count -gt 0) { $lineStart = [int]$diagnostic.line[0] }
                        if ($diagnostic.column -and $diagnostic.column.Count -gt 0) { $columnStart = [int]$diagnostic.column[0] }
                        $findings.Add([pscustomobject]@{ Id = 'SQF_LINT_FINDING'; Severity = $findingSeverity; Message = [string]$diagnostic.message; Path = $relativePath; Line = $lineStart; Column = $columnStart; Tool = 'SQFLint'; ToolSeverity = [string]$diagnostic.type })
                    }
                }
                if ($exitCode -ne 0 -and $exitCode -ne 1) {
                    $errors.Add([pscustomobject]@{ Id = 'SQF_PROCESS_FAILED'; Message = "SQFLint exited with code $exitCode."; Path = $relativePath; Tool = 'SQFLint'; ExitCode = $exitCode; StandardError = $stderr })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                }
                elseif ($exitCode -eq 1 -and $parsedCount -eq 0 -and $errors.Count -eq 0) {
                    $errors.Add([pscustomobject]@{ Id = 'SQF_PROCESS_FAILED'; Message = 'SQFLint exited with code 1 but returned no parseable diagnostics.'; Path = $relativePath; Tool = 'SQFLint'; ExitCode = $exitCode; StandardError = $stderr })
                    $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
                }
                else { $checks.Add([pscustomobject]@{ Path = $relativePath; Status = if ($parsedCount -gt 0) { 'Findings' } else { 'Passed' } }) }
            }
            catch {
                $processWatch.Stop()
                $errors.Add([pscustomobject]@{ Id = 'SQF_PROCESS_START_FAILED'; Message = "SQFLint could not be started: $($_.Exception.Message)"; Path = $relativePath; Tool = 'SQFLint'; StandardError = $_.Exception.Message })
                $checks.Add([pscustomobject]@{ Path = $relativePath; Status = 'Failed' })
            }
            finally {
                try { if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
                if ($process) { $process.Dispose() }
            }
        }

        $watch.Stop()
        $status = 'Passed'
        $summary = "SQFLint inspected $($checks.Count) SQF source file(s); no findings."
        if ($errors.Count -gt 0) { $status = 'Failed'; $summary = "SQFLint failed to inspect $($errors.Count) file/process condition(s)." }
        elseif ($findings.Count -gt 0) {
            if ($severity -eq 'error') { $status = 'Failed'; $summary = "SQFLint reported $($findings.Count) SQF finding(s)." }
            else { $status = 'Warning'; $summary = "SQFLint reported $($findings.Count) SQF finding(s)." }
        }
        return (New-A3WorkflowModuleResult -Module 'Validation.SQF' -Operation $Operation -Status $status -Summary $summary -Errors @($errors.ToArray()) -Warnings @($findings | Where-Object { $_.Severity -eq 'warning' }) -StartedAt $started -DurationMs ([Math]::Max(1, $watch.ElapsedMilliseconds)) -Data @{
            Checks = @($checks.ToArray())
            Findings = @($findings.ToArray())
            CheckedCount = $checks.Count
            Tool = @{ Name = 'SQFLint'; Path = $toolPath; Version = $null; VersionDetection = 'The upstream CLI does not document a version query.' }
            Processes = @($toolOutputs.ToArray())
            ProjectRoot = $projectRoot
        })
    }
}
