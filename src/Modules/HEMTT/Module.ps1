@{
    Id = 'Build.HEMTT'
    ConfigKey = 'build'
    Version = '0.1.0'
    Operations = @('Run', 'Detect', 'Check', 'Dev', 'Build', 'Release')
    Invoke = {
        param($Context, $Operation)

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
                return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary "Configured HEMTT executable was not found: $configuredPath" -Errors @(@{ Message = 'Configured HEMTT executable does not exist.'; Path = $configuredPath }) -StartedAt $started)
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
            return (New-A3WorkflowModuleResult -Module 'Build.HEMTT' -Operation $Operation -Status Failed -Summary 'HEMTT executable was not found. Configure tools.hemtt.path or add HEMTT to PATH.' -Errors @(@{ Message = 'HEMTT executable not found.'; Remediation = 'Set tools.hemtt.path or add hemtt.exe to PATH.' }) -StartedAt $started)
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

        $previousLocation = Get-Location
        $outputLines = @()
        $exitCode = 1
        try {
            Set-Location -LiteralPath $projectRoot
            $outputLines = @(& $executable @commandArguments 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
            if ($null -eq $exitCode) { $exitCode = 0 }
        }
        catch {
            $outputLines += $_.Exception.Message
            $exitCode = 1
        }
        finally {
            Set-Location -LiteralPath $previousLocation
        }

        $outputText = $outputLines -join [Environment]::NewLine
        $version = $null
        if ($Operation -eq 'Detect' -or $outputText -match '(?i)HEMTT\s+v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)') {
            if ($outputText -match '(?i)HEMTT\s+v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)') {
                $version = $Matches[1]
            }
        }

        $artifactDirectory = $null
        switch ($Operation) {
            'Dev' { $artifactDirectory = Join-Path $projectRoot '.hemttout/dev' }
            'Build' { $artifactDirectory = Join-Path $projectRoot '.hemttout/build' }
            'Release' { $artifactDirectory = Join-Path $projectRoot '.hemttout/release' }
            'Run' { $artifactDirectory = Join-Path $projectRoot '.hemttout/build' }
        }
        $artifacts = @()
        if ($artifactDirectory -and (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
            $artifacts = @(Get-ChildItem -LiteralPath $artifactDirectory -Force | ForEach-Object { $_.FullName })
        }

        $elapsed = [long]([DateTime]::UtcNow - $started).TotalMilliseconds
        $data = @{
            Executable = $executable
            Version = $version
            Arguments = $commandArguments
            ExitCode = [int]$exitCode
            Output = $outputText
            ArtifactDirectory = $artifactDirectory
            Artifacts = $artifacts
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
