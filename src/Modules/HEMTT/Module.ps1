@{
    Id = 'Build.HEMTT'
    ConfigKey = 'build'
    Version = '0.1.0'
    Operations = @('Run', 'Detect', 'Check', 'Dev', 'Build', 'Release')
    Invoke = {
        param($Context, $Operation)

function Invoke-A3WorkflowExternalProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 600,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    $processFile = $FilePath
    $processArguments = @($Arguments)
    if ([IO.Path]::GetExtension($FilePath) -ieq '.ps1') {
        $hostExecutable = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $hostExecutable)) { $hostExecutable = Join-Path $PSHOME 'powershell.exe' }
        $processFile = $hostExecutable
        $processArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $processArguments
    }

    $quotedArguments = @()
    foreach ($argument in $processArguments) {
        $value = [string]$argument
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq [char]92) {
                $slashes++
            }
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
        $quotedArguments += $builder.ToString()
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $processFile
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $stdout = ''
    $stderr = ''
    $timedOut = $false
    $exitCode = 1
    try {
        if (-not $process.Start()) { throw "Failed to start process: $processFile" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # taskkill /T is available on Windows and also terminates descendants
            # that would otherwise survive after the direct process is stopped.
            if ($env:OS -eq 'Windows_NT') {
                try {
                    $taskkill = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                    if (Test-Path -LiteralPath $taskkill) {
                        $killInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $killInfo.FileName = $taskkill
                        $killInfo.Arguments = "/PID $($process.Id) /T /F"
                        $killInfo.UseShellExecute = $false
                        $killInfo.CreateNoWindow = $true
                        $killer = [System.Diagnostics.Process]::Start($killInfo)
                        if ($killer) { $killer.WaitForExit(5000); $killer.Dispose() }
                    }
                }
                catch { }
            }
            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
            try { $process.WaitForExit() } catch { }
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    }
    finally {
        $watch.Stop()
        try { if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch { }
        if ($process) { $process.Dispose() }
    }

    return @{
        ExitCode = [int]$exitCode
        StdOut = [string]$stdout
        StdErr = [string]$stderr
        TimedOut = [bool]$timedOut
        DurationMs = [long]$watch.ElapsedMilliseconds
    }
}


        $started = [DateTime]::UtcNow
        $projectRoot = [string]$Context.ProjectRoot
        $toolConfiguration = $null
        if ($Context.Configuration.tools -is [System.Collections.IDictionary] -and $Context.Configuration.tools.Contains('hemtt')) {
            $toolConfiguration = $Context.Configuration.tools.hemtt
        }

        if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.Contains('enabled') -and $toolConfiguration.enabled -eq $false) {
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Skipped -Summary 'HEMTT is disabled in tool configuration.' -StartedAt $started)
        }

        $executable = $null
        if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.path) {
            $configuredPath = [string]$toolConfiguration.path
            if (-not [IO.Path]::IsPathRooted($configuredPath)) {
                $configuredPath = Join-Path $projectRoot $configuredPath
            }
            if (Test-Path -LiteralPath $configuredPath -PathType Container) {
                $configuredPath = Join-Path $configuredPath 'hemtt.exe'
            }
            if (Test-Path -LiteralPath $configuredPath -PathType Leaf) {
                $executable = (Resolve-Path -LiteralPath $configuredPath).Path
            }
            else {
                $diagnostic = @{ Message = 'Configured HEMTT executable does not exist.'; Path = $configuredPath }
                if ($toolConfiguration.required -eq $true) {
                    return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary "Configured HEMTT executable was not found: $configuredPath" -Errors @($diagnostic) -StartedAt $started)
                }
                return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Skipped -Summary "Configured HEMTT executable was not found: $configuredPath" -Warnings @($diagnostic) -StartedAt $started)
            }
        }
        else {
            foreach ($commandName in @('hemtt.exe', 'hemtt')) {
                $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($command -and $command.Source) {
                    $executable = $command.Source
                    break
                }
            }
        }

        if (-not $executable) {
            $diagnostic = @{ Message = 'HEMTT executable not found.'; Remediation = 'Set tools.hemtt.path or add hemtt.exe to PATH. Set tools.hemtt.required to true to make this a failure.' }
            if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.required -eq $true) {
                return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary 'HEMTT executable was not found. Configure tools.hemtt.path or add HEMTT to PATH.' -Errors @($diagnostic) -StartedAt $started)

            }
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Skipped -Summary 'HEMTT executable was not found. Configure tools.hemtt.path or add HEMTT to PATH.' -Warnings @($diagnostic) -StartedAt $started)
        }

        if ($Operation -ne 'Detect') {
            $hemttConfig = '.hemtt/project.toml'
            if ($Context.Configuration.paths -is [System.Collections.IDictionary] -and $Context.Configuration.paths.Contains('hemtt_config')) {
                $hemttConfig = $Context.Configuration.paths.hemtt_config
            }
            if ([string]::IsNullOrWhiteSpace([string]$hemttConfig)) {
                return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary 'HEMTT project configuration path is not configured.' -Errors @(@{ Message = 'paths.hemtt_config must identify the HEMTT project.toml file.' }) -StartedAt $started)
            }
            if (-not [IO.Path]::IsPathRooted([string]$hemttConfig)) {
                $hemttConfig = Join-Path $projectRoot ([string]$hemttConfig)
            }
            if (-not (Test-Path -LiteralPath $hemttConfig -PathType Leaf)) {
                return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary "HEMTT project configuration was not found: $hemttConfig" -Errors @(@{ Message = 'Required HEMTT project.toml file does not exist.'; Path = $hemttConfig; Remediation = 'Create .hemtt/project.toml or configure paths.hemtt_config.' }) -StartedAt $started)
            }
        }

        $commandArguments = @()
        switch ($Operation) {
            'Detect' { $commandArguments = @('--version') }
            'Check' { $commandArguments = @('check') }
            'Dev' { $commandArguments = @('dev') }
            'Build' { $commandArguments = @('build') }
            'Release' { $commandArguments = @('release') }
            default { $commandArguments = @('build') }
        }

        if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.arguments) {
            $commandArguments += @($toolConfiguration.arguments)
        }

        $artifactDirectories = @()
        switch ($Operation) {
            'Dev' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/dev') }
            'Build' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/build') }
            'Release' {
                $artifactDirectories += (Join-Path $projectRoot '.hemttout/releases')
                $artifactDirectories += (Join-Path $projectRoot 'releases')
            }
            'Run' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/build') }
        }
        $artifactSnapshot = @{}
        foreach ($directory in $artifactDirectories) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Get-ChildItem -LiteralPath $directory -File -Recurse -Force | ForEach-Object {
                    $artifactSnapshot[$_.FullName] = "$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
                }
            }
        }

        $exitCode = 1
        $versionExitCode = 0
        $version = $null
        $versionOutputText = ''
        $versionStandardOutput = ''
        $versionStandardError = ''
        $outputText = ''
        $versionMismatch = $false
        $versionParseFailed = $false
        $timedOut = $false
        $timeoutSeconds = 600
        $processDurationMs = 0
        $standardOutput = ''
        $standardError = ''
        $processStartError = $null
        if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.Contains('timeout_seconds') -and $null -ne $toolConfiguration.timeout_seconds) {
            $timeoutSeconds = [int]$toolConfiguration.timeout_seconds
        }
        if ($timeoutSeconds -lt 1) {
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary 'HEMTT timeout_seconds must be at least 1.' -Errors @(@{ Message = 'Invalid process timeout.'; Value = $timeoutSeconds }) -StartedAt $started)
        }

        try {
            if ($Operation -ne 'Detect') {
                $versionArguments = @('--version')
                if ($toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.arguments) {
                    $versionArguments += @($toolConfiguration.arguments)
                }
                $versionProcess = Invoke-A3WorkflowExternalProcess -FilePath $executable -Arguments $versionArguments -TimeoutSeconds $timeoutSeconds -WorkingDirectory $projectRoot
                $versionExitCode = $versionProcess.ExitCode
                $processDurationMs += $versionProcess.DurationMs
                $versionStandardOutput = $versionProcess.StdOut
                $versionStandardError = $versionProcess.StdErr
                $versionOutputText = ($versionStandardOutput + [Environment]::NewLine + $versionStandardError).Trim()
                if ($versionProcess.TimedOut) {
                    $timedOut = $true
                    $exitCode = 124
                    $outputText = 'HEMTT version query timed out.'
                }
                if ($versionOutputText -match '(?i)(?:HEMTT\s+)?v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)') {
                    $version = $Matches[1]
                }

                if (-not $timedOut -and $versionExitCode -ne 0) {
                    $exitCode = $versionExitCode
                    $outputText = 'HEMTT version query failed.' + [Environment]::NewLine + $versionOutputText
                }
                elseif (-not $timedOut -and $toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.version) {
                    $expectedVersion = ([string]$toolConfiguration.version).TrimStart('v')
                    if (-not $version) {
                        $exitCode = 1
                        $versionMismatch = $true
                        $outputText = "Unable to determine HEMTT version; configured version requirement is $expectedVersion."
                    }
                    elseif ($version -ne $expectedVersion) {
                        $exitCode = 1
                        $versionMismatch = $true
                        $outputText = "HEMTT version mismatch. Expected $expectedVersion but found $version."
                    }
                }
            }

            if ($Operation -eq 'Detect' -or ($versionExitCode -eq 0 -and -not $versionMismatch -and -not $timedOut)) {
                $processResult = Invoke-A3WorkflowExternalProcess -FilePath $executable -Arguments $commandArguments -TimeoutSeconds $timeoutSeconds -WorkingDirectory $projectRoot
                $exitCode = $processResult.ExitCode
                $standardOutput = $processResult.StdOut
                $standardError = $processResult.StdErr
                $timedOut = $processResult.TimedOut
                $processDurationMs += $processResult.DurationMs
                $outputText = ($standardOutput + [Environment]::NewLine + $standardError).Trim()
                if ($Operation -eq 'Detect') {
                    $versionExitCode = $processResult.ExitCode
                }
                if ($Operation -eq 'Detect' -and $outputText -match '(?i)(?:HEMTT\s+)?v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)') {
                    $version = $Matches[1]
                }
                if ($Operation -eq 'Detect' -and -not $timedOut -and $exitCode -eq 0 -and -not $version) {
                    $versionParseFailed = $true
                    $exitCode = 1
                    $outputText = 'Unable to parse HEMTT version output.' + [Environment]::NewLine + $outputText
                }
                if ($Operation -eq 'Detect' -and -not $timedOut -and $exitCode -eq 0 -and $toolConfiguration -is [System.Collections.IDictionary] -and $toolConfiguration.version) {
                    $expectedVersion = ([string]$toolConfiguration.version).TrimStart('v')
                    if (-not $version -or $version -ne $expectedVersion) {
                        $versionMismatch = $true
                        $exitCode = 1
                        $outputText = "HEMTT version mismatch. Expected $expectedVersion but found $version." + [Environment]::NewLine + $outputText
                    }
                }
            }
        }
        catch {
            $processStartError = $_.Exception.Message
            $standardError = $processStartError
            $outputText = $standardError
            $exitCode = 1
        }

        $artifactDirectory = $null
        if ($artifactDirectories.Count -gt 0) { $artifactDirectory = $artifactDirectories[0] }
        $artifacts = @()
        foreach ($directory in $artifactDirectories) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Get-ChildItem -LiteralPath $directory -File -Force -Recurse | ForEach-Object {
                    $signature = "$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
                    if (-not $artifactSnapshot.ContainsKey($_.FullName) -or $artifactSnapshot[$_.FullName] -ne $signature) {
                        $artifacts += $_.FullName
                    }
                }
            }
        }

        $elapsed = [long]([DateTime]::UtcNow - $started).TotalMilliseconds
        $data = @{
            Executable = $executable
            Version = $version
            ExpectedVersion = if ($toolConfiguration -is [System.Collections.IDictionary]) { $toolConfiguration.version } else { $null }
            VersionOutput = $versionOutputText
            VersionStandardOutput = $versionStandardOutput
            VersionStandardError = $versionStandardError
            VersionExitCode = [int]$versionExitCode
            VersionMismatch = $versionMismatch
            VersionParseFailed = $versionParseFailed
            Arguments = $commandArguments
            ExitCode = [int]$exitCode
            Output = $outputText
            StandardOutput = $standardOutput
            StandardError = $standardError
            ProcessStartError = $processStartError
            TimedOut = $timedOut
            TimeoutSeconds = $timeoutSeconds
            ProcessDurationMs = $processDurationMs
            ArtifactDirectory = $artifactDirectory
            ArtifactDirectories = $artifactDirectories
            Artifacts = $artifacts
        }

        if ($timedOut) {
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary "HEMTT command timed out after $timeoutSeconds seconds." -Errors @(@{ Message = 'HEMTT process exceeded its configured timeout.'; Output = $outputText }) -StartedAt $started -DurationMs $elapsed -Data $data)
        }

        if ($exitCode -ne 0) {
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary "HEMTT command failed with exit code $exitCode." -Errors @(@{ Message = "HEMTT exited with code $exitCode."; Output = $outputText }) -StartedAt $started -DurationMs $elapsed -Data $data)
        }

        $summary = "HEMTT $($commandArguments -join ' ') completed successfully."
        if ($Operation -eq 'Detect') {
            if ($version) { $summary = "Detected HEMTT version $version." }
            else { $summary = 'HEMTT responded to the version query; version output could not be parsed.' }
        }
        return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Passed -Summary $summary -StartedAt $started -DurationMs $elapsed -Data $data)
    }
}
