#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Chef Infra Client.

.DESCRIPTION
    Installs the Chef Infra Client MSI package from a pre-staged location or
    downloads it from a specified URI. Verifies the installation via the
    Windows registry.

.PARAMETER InstallerPath
    Path to the Chef client MSI. Defaults to the staging directory.

.PARAMETER DownloadUri
    Optional URI to download the Chef client MSI if not pre-staged.

.NOTES
    File Name  : install-chef-client.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallerPath = 'C:\PackerInstallers\chef-client.msi',

    [Parameter()]
    [string]$DownloadUri
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    # Download if URI provided and installer not already staged
    if ($DownloadUri -and -not (Test-Path -Path $InstallerPath)) {
        Write-PackerLog -Message "Downloading Chef client from: $DownloadUri"
        Get-InstallerFromUri -Uri $DownloadUri -DestinationPath $InstallerPath
    }

    if (-not (Test-Path -Path $InstallerPath)) {
        throw "Chef client installer not found: $InstallerPath"
    }

    # Install Chef client
    Write-PackerLog -Message "Installing Chef Infra Client"
    $logFile = 'C:\PackerTemp\chef-client-install.log'
    Install-MSI -Path $InstallerPath -LogPath $logFile

    # Verify installation
    if (Test-InstalledSoftware -Name 'Chef Infra Client') {
        Write-PackerLog -Message "Chef Infra Client installed successfully"
    }
    else {
        throw "Chef Infra Client installation could not be verified in the registry"
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
