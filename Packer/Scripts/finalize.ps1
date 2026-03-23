#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Performs final cleanup and preparation before image capture.

.DESCRIPTION
    Cleans up temporary files and directories created during the build,
    runs Windows image cleanup, collects final logs, and optionally
    prepares the system for sysprep.

.PARAMETER RunSysprep
    If specified, runs sysprep with /oobe /generalize /shutdown after cleanup.
    Defaults to false; Packer typically handles sysprep separately.

.PARAMETER CleanupDirs
    Array of directories to remove during cleanup.

.NOTES
    File Name  : finalize.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$RunSysprep,

    [Parameter()]
    [string[]]$CleanupDirs = @('C:\PackerInstallers', 'C:\PackerTemp')
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    # Clean up staging directories
    foreach ($dir in $CleanupDirs) {
        if (Test-Path -Path $dir) {
            Write-PackerLog -Message "Removing staging directory: $dir"
            Remove-Item -Path $dir -Recurse -Force
        }
    }

    # Clear Windows temp files
    Write-PackerLog -Message "Clearing Windows temp directories"
    $tempPaths = @(
        "$env:TEMP\*"
        "$env:SystemRoot\Temp\*"
    )
    foreach ($tempPath in $tempPaths) {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Run DISM component cleanup
    Write-PackerLog -Message "Running DISM component cleanup"
    $dismParams = @{
        FilePath     = 'dism.exe'
        ArgumentList = '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'
        Wait         = $true
        PassThru     = $true
        NoNewWindow  = $true
    }
    $dismResult = Start-Process @dismParams
    Write-PackerLog -Message "DISM cleanup completed with exit code: $($dismResult.ExitCode)"

    # Clear event logs
    Write-PackerLog -Message "Clearing Windows event logs"
    Get-EventLog -LogName * -ErrorAction SilentlyContinue |
        ForEach-Object { Clear-EventLog -LogName $_.Log -ErrorAction SilentlyContinue }

    # Re-enable Windows Update for the final image
    Write-PackerLog -Message "Re-enabling Windows Update service"
    Set-Service -Name 'wuauserv' -StartupType Manual

    Write-PackerLog -Message "Completed $scriptName successfully"

    # Sysprep must run after transcript stops
    if ($RunSysprep) {
        Write-PackerLog -Message "Sysprep requested; will execute after transcript cleanup"
    }
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

    # Run sysprep after transcript/archive are complete
    if ($RunSysprep) {
        $sysprepPath = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
        & $sysprepPath /oobe /generalize /shutdown /quiet
    }
}
