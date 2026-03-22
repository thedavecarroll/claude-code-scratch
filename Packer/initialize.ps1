#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Initializes the Windows environment for a Packer build.

.DESCRIPTION
    Prepares the system for image building by disabling Windows Update,
    configuring power settings to prevent sleep, setting the PowerShell
    execution policy, and creating temporary working directories.

    This script should run first in the Packer provisioner chain.

.NOTES
    File Name  : initialize.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    # Disable Windows Update service to prevent interference during build
    Write-PackerLog -Message "Disabling Windows Update service"
    Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
    Set-Service -Name 'wuauserv' -StartupType Disabled

    # Configure power settings to prevent sleep during long builds
    Write-PackerLog -Message "Configuring power settings"
    & powercfg.exe /change monitor-timeout-ac 0
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-ac 0

    # Disable screensaver
    Write-PackerLog -Message "Disabling screensaver"
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive' -Value '0' -Type String

    # Set execution policy for the build
    Write-PackerLog -Message "Setting PowerShell execution policy to RemoteSigned"
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

    # Create temporary working directories
    $stagingDirs = @(
        'C:\PackerInstallers'
        'C:\PackerTemp'
        'C:\PackerScripts'
    )

    foreach ($dir in $stagingDirs) {
        if (-not (Test-Path -Path $dir)) {
            Write-PackerLog -Message "Creating directory: $dir"
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
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
