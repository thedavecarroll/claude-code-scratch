<#
.SYNOPSIS
    Initializes the Packer build environment on the guest instance.
.DESCRIPTION
    Creates the Packer log directory, imports packer-logging, starts a transcript, prints
    build-config values, and calls Get-EC2LaunchInfo to verify EC2Launch v2. Must run first
    after guest files and build-config.json are uploaded.
.NOTES
    Config: Reads C:\Packer\Config\build-config.json for LoggingModulePath (packer-logging.psm1)
    and other keys. The JSON file is written by the Packer file provisioner.

    Get-Help: This script has no parameters.
.EXAMPLE
    PS C:\> & 'C:\Packer\Scripts\initialize.ps1'
#>
[CmdletBinding()]
param()

# Load build configuration from file
$ConfigPath = 'C:\Packer\Config\build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'. The build cannot continue."
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$TranscriptState = $null
try {
    $ErrorActionPreference = "Stop"
    Import-Module -Name $Config.LoggingModulePath -Force
    New-PackerLogDirectory

    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName "initialize.ps1"

    Write-Output "--- Packer Build Configuration ---"
    $Config.psobject.Properties | ForEach-Object {
        Write-Output "$($_.Name) = $($_.Value)"
    }
    Write-Output "------------------------------------"
    Write-Output ""

    Write-Output "Initialization complete. Gathering EC2 launch information..."
    Write-Output ""
    $EC2LaunchInfo = Get-EC2LaunchInfo -ShowInfo
    if ([version]$EC2LaunchInfo.AgentVersion -lt [version]'2.0.0') {
        Write-Error "This build pipeline exclusively supports EC2Launch v2, but detected version '$($EC2LaunchInfo.AgentVersion)'."
        exit 1
    }
    Write-Output ""
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
