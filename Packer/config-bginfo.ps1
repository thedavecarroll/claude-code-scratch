#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures BGInfo to display system information on the desktop.

.DESCRIPTION
    Copies a BGInfo configuration file to a standard location and registers
    BGInfo to run at user logon via the registry Run key.

.PARAMETER BgiConfigPath
    Path to the BGInfo configuration file (.bgi). Defaults to the staging directory.

.PARAMETER BgInfoExePath
    Path to the BGInfo executable. Defaults to the staging directory.

.NOTES
    File Name  : config-bginfo.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$BgiConfigPath = 'C:\PackerInstallers\bginfo.bgi',

    [Parameter()]
    [string]$BgInfoExePath = 'C:\PackerInstallers\Bginfo64.exe'
)

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    $bgInfoDir = 'C:\BGInfo'

    # Create BGInfo directory
    if (-not (Test-Path -Path $bgInfoDir)) {
        Write-PackerLog -Message "Creating BGInfo directory: $bgInfoDir"
        New-Item -Path $bgInfoDir -ItemType Directory -Force | Out-Null
    }

    # Copy BGInfo executable
    if (Test-Path -Path $BgInfoExePath) {
        $destExe = Join-Path -Path $bgInfoDir -ChildPath (Split-Path -Path $BgInfoExePath -Leaf)
        Copy-Item -Path $BgInfoExePath -Destination $destExe -Force
        Write-PackerLog -Message "Copied BGInfo executable to: $destExe"
    }
    else {
        throw "BGInfo executable not found: $BgInfoExePath"
    }

    # Copy BGInfo configuration
    if (Test-Path -Path $BgiConfigPath) {
        $destConfig = Join-Path -Path $bgInfoDir -ChildPath 'bginfo.bgi'
        Copy-Item -Path $BgiConfigPath -Destination $destConfig -Force
        Write-PackerLog -Message "Copied BGInfo config to: $destConfig"
    }
    else {
        throw "BGInfo configuration file not found: $BgiConfigPath"
    }

    # Register BGInfo to run at logon
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $bgInfoCommand = "`"$destExe`" `"$destConfig`" /timer:0 /nolicprompt /silent"
    Set-ItemProperty -Path $runKey -Name 'BGInfo' -Value $bgInfoCommand -Type String
    Write-PackerLog -Message "Registered BGInfo at logon: $bgInfoCommand"

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
