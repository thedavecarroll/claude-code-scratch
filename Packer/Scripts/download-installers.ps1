#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Downloads installer packages to a local staging directory.

.DESCRIPTION
    Downloads software installers from specified URIs to a local staging
    directory for subsequent installation by other provisioner scripts.
    Supports an optional JSON manifest for batch downloads.

.PARAMETER StagingDirectory
    The local directory where installers are downloaded. Defaults to C:\PackerInstallers.

.PARAMETER ManifestPath
    Optional path to a JSON file listing download URIs and target filenames.

.NOTES
    File Name  : download-installers.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$StagingDirectory = 'C:\PackerInstallers',

    [Parameter()]
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    if (-not (Test-Path -Path $StagingDirectory)) {
        New-Item -Path $StagingDirectory -ItemType Directory -Force | Out-Null
    }

    if ($ManifestPath -and (Test-Path -Path $ManifestPath)) {
        Write-PackerLog -Message "Reading download manifest: $ManifestPath"
        $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

        foreach ($item in $manifest.downloads) {
            $destination = Join-Path -Path $StagingDirectory -ChildPath $item.filename
            Write-PackerLog -Message "Downloading: $($item.uri) -> $($item.filename)"

            try {
                Get-InstallerFromUri -Uri $item.uri -DestinationPath $destination
                Write-PackerLog -Message "Downloaded successfully: $($item.filename)"
            }
            catch {
                Write-PackerLog -Message "Failed to download $($item.filename): $_" -Severity Warning
            }
        }
    }
    else {
        Write-PackerLog -Message "No manifest provided or found. Add download URIs to a manifest JSON file." -Severity Warning
        # TODO: Add direct download URIs here if not using a manifest
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
