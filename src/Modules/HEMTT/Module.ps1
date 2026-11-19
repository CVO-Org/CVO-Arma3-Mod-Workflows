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

        $artifactDirectories = @()
        switch ($Operation) {
            'Dev' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/dev') }
            'Build' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/build') }
            'Release' {
                $artifactDirectories += (Join-Path $projectRoot '.hemttout/release')
                $artifactDirectories += (Join-Path $projectRoot 'releases')
            }
            'Run' { $artifactDirectories += (Join-Path $projectRoot '.hemttout/build') }
        }
        $artifactDirectory = $null
        if ($artifactDirectories.Count -gt 0) { $artifactDirectory = $artifactDirectories[0] }
        $artifacts = @()
        foreach ($directory in $artifactDirectories) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                $artifacts += @(Get-ChildItem -LiteralPath $directory -Force -Recurse | ForEach-Object { $_.FullName })
            }
        }

        $elapsed = [long]([DateTime]::UtcNow - $started).TotalMilliseconds
        $data = @{
            Executable = $executable
            Version = $version
            Arguments = $commandArguments
            ExitCode = [int]$exitCode
            Output = $outputText
            ArtifactDirectory = $artifactDirectory
            ArtifactDirectories = $artifactDirectories
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
