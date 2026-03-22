#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs software packages defined in a JSON manifest.

.DESCRIPTION
    Reads a JSON manifest file that defines software packages and their
    installation parameters. Supports both MSI and EXE installers.
    Each item in the manifest specifies the installer type, filename,
    and optional arguments.

.PARAMETER ManifestPath
    Path to the JSON manifest file. Defaults to install-manifest.json in the script directory.

.PARAMETER InstallerDirectory
    Directory containing the downloaded installer files. Defaults to C:\PackerInstallers.

.NOTES
    File Name  : install-from-manifest.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = "$PSScriptRoot\install-manifest.json",

    [Parameter()]
    [string]$InstallerDirectory = 'C:\PackerInstallers'
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    if (-not (Test-Path -Path $ManifestPath)) {
        Write-PackerLog -Message "Manifest file not found: $ManifestPath" -Severity Warning
        Write-PackerLog -Message "Create an install-manifest.json with a 'packages' array."
        Write-PackerLog -Message "Completed $scriptName (no manifest to process)"
        return
    }

    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    $totalPackages = @($manifest.packages).Count
    $currentPackage = 0

    Write-PackerLog -Message "Processing $totalPackages package(s) from manifest"

    foreach ($package in $manifest.packages) {
        $currentPackage++
        $installerPath = Join-Path -Path $InstallerDirectory -ChildPath $package.filename
        Write-PackerLog -Message "[$currentPackage/$totalPackages] Installing: $($package.name)"

        if (-not (Test-Path -Path $installerPath)) {
            Write-PackerLog -Message "Installer not found, skipping: $installerPath" -Severity Warning
            continue
        }

        switch ($package.type) {
            'msi' {
                $msiArgs = if ($package.arguments) { $package.arguments } else { '/qn /norestart' }
                Install-MSI -Path $installerPath -Arguments $msiArgs
            }
            'exe' {
                $exeArgs = if ($package.arguments) { $package.arguments } else { '/S' }
                Install-EXE -Path $installerPath -Arguments $exeArgs
            }
            default {
                Write-PackerLog -Message "Unknown installer type '$($package.type)' for $($package.name)" -Severity Warning
            }
        }

        # Verify installation if a verification name is provided
        if ($package.verifyName) {
            if (Test-InstalledSoftware -Name $package.verifyName) {
                Write-PackerLog -Message "Verified: $($package.verifyName) is installed"
            }
            else {
                Write-PackerLog -Message "Verification failed: $($package.verifyName) not found in registry" -Severity Warning
            }
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
