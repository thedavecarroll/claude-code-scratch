<#
.SYNOPSIS
    Installs CrowdStrike Falcon sensor during Packer AMI build.
.DESCRIPTION
    Installs CrowdStrike Falcon sensor from a pre-staged EXE (downloaded by
    download-installers.ps1 via manifest). Uses NO_START=1 for sysprep compatibility (per CrowdStrike aws-ec2-image-builder).
    CID is passed via CROWDSTRIKE_CID environment variable (GitLab CI variables).
.NOTES
    Runs just before finalize.ps1. Requires CROWDSTRIKE_CID env var.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TranscriptState = $null

try {
    $ConfigPath = Join-Path 'C:\Packer\Config' 'build-config.json'
    if (-not (Test-Path $ConfigPath)) {
        throw "Build configuration file not found at '$ConfigPath'. The build cannot continue."
    }
    $BootstrapConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $helperPath = $BootstrapConfig.InstallHelperModulePath
    if (-not (Test-Path $helperPath)) {
        throw "Packer install helper module not found at '$helperPath'. The build cannot continue."
    }
    Import-Module -Name $helperPath -Force
    $Config = Get-PackerBuildConfig
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'install-crowdstrike.ps1'

    $crowdCid = [Environment]::GetEnvironmentVariable('CROWDSTRIKE_CID', 'Process')
    if ([string]::IsNullOrWhiteSpace($crowdCid)) {
        throw "CROWDSTRIKE_CID environment variable is not set. CROWDSTRIKE_CID must be set in GitLab CI variables."
    }
    $InstallFilesPath = Get-InstallFilesPath -Config $Config
    $FalconExe = Find-PackerInstaller -Path $InstallFilesPath -Filter 'FalconSensor_Windows_*_x64.exe' -NotFoundMessage "CrowdStrike Falcon installer not found in '$InstallFilesPath'. Ensure manifest includes crowdstrike package."

    Write-Output "Installing CrowdStrike Falcon sensor: $($FalconExe.Name)"
    Invoke-WaitForMsiexec -TimeoutMinutes 5 -PollIntervalSeconds 15

    $InstallArgs = @('/install', '/quiet', '/norestart', "CID=$($env:CROWDSTRIKE_CID)", 'NO_START=1')
    $null = Invoke-PackerInstaller -FilePath $FalconExe.FullName -ArgumentList $InstallArgs -InstallerName 'CrowdStrike Falcon' -LogPrefix 'crowdstrike'

    $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
    Write-Output "CrowdStrike Falcon sensor installed successfully (NO_START=1 for sysprep). Completed in $Elapsed"
}
catch {
    Write-DetailedError -ErrorRecord $_
    exit 1
}
finally {
    if ($TranscriptState) {
        Stop-PackerTranscript -TranscriptState $TranscriptState
    }
}
