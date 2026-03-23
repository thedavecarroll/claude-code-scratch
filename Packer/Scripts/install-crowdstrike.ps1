#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the CrowdStrike Falcon sensor.

.DESCRIPTION
    Installs the CrowdStrike Falcon sensor with the specified Customer ID (CID).
    Verifies the installation by checking for the CSFalconService Windows service.

.PARAMETER InstallerPath
    Path to the CrowdStrike installer executable.

.PARAMETER CID
    The CrowdStrike Customer ID for sensor registration.

.NOTES
    File Name  : install-crowdstrike.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallerPath = 'C:\PackerInstallers\CrowdStrikeWindowsSensor.exe',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CID
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    if (-not (Test-Path -Path $InstallerPath)) {
        throw "CrowdStrike installer not found: $InstallerPath"
    }

    # Install CrowdStrike Falcon sensor
    Write-PackerLog -Message "Installing CrowdStrike Falcon sensor"
    $installArgs = "/install /quiet /norestart CID=$CID"
    Install-EXE -Path $InstallerPath -Arguments $installArgs

    # Verify the CrowdStrike service exists
    Write-PackerLog -Message "Verifying CrowdStrike Falcon service"
    $service = Get-Service -Name 'CSFalconService' -ErrorAction SilentlyContinue
    if ($service) {
        Write-PackerLog -Message "CrowdStrike Falcon service found (Status: $($service.Status))"
    }
    else {
        throw "CrowdStrike Falcon service (CSFalconService) not found after installation"
    }

    Write-PackerLog -Message "Completed $scriptName successfully"
}
catch {
    Write-PackerLog -Message "FAILED in ${scriptName}: $_" -Severity Error
    throw
}
finally {
    $transcriptFile = Stop-PackerTranscript
    if ($transcriptFile) {
        Add-LogToArchive -LogPath $transcriptFile
    }
}
