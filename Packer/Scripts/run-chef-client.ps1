#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs the Chef Infra Client with a specified run list.

.DESCRIPTION
    Executes chef-client with the provided run list and environment.
    Waits for the Chef run to complete and validates the exit code.

.PARAMETER RunList
    The Chef run list to execute (e.g., 'recipe[base::default]').

.PARAMETER Environment
    The Chef environment name. Defaults to '_default'.

.PARAMETER ConfigPath
    Path to the Chef client configuration file.

.NOTES
    File Name  : run-chef-client.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+, Chef Infra Client installed
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RunList,

    [Parameter()]
    [string]$Environment = '_default',

    [Parameter()]
    [string]$ConfigPath = 'C:\chef\client.rb'
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    $chefPath = 'C:\opscode\chef\bin\chef-client.bat'
    if (-not (Test-Path -Path $chefPath)) {
        throw "Chef client not found at: $chefPath"
    }

    # Build chef-client arguments
    $chefArgs = @('--no-color')

    if ($ConfigPath -and (Test-Path -Path $ConfigPath)) {
        $chefArgs += '--config', $ConfigPath
    }

    if ($Environment) {
        $chefArgs += '--environment', $Environment
    }

    if ($RunList) {
        $chefArgs += '--runlist', $RunList
    }

    Write-PackerLog -Message "Running Chef client with args: $($chefArgs -join ' ')"
    $process = Start-Process -FilePath $chefPath -ArgumentList $chefArgs -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "Chef client run failed with exit code $($process.ExitCode)"
    }

    Write-PackerLog -Message "Chef client run completed successfully"
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
