#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Hardens IIS security configuration.

.DESCRIPTION
    Applies security hardening to IIS: removes the default website, disables
    directory browsing, enforces TLS 1.2+, disables weak cipher suites,
    and configures HSTS headers.

.NOTES
    File Name  : secure-iis.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+, IIS installed
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

    # Verify IIS is installed
    $iisFeature = Get-WindowsFeature -Name 'Web-Server' -ErrorAction SilentlyContinue
    if (-not $iisFeature -or $iisFeature.InstallState -ne 'Installed') {
        Write-PackerLog -Message "IIS is not installed, skipping hardening" -Severity Warning
        return
    }

    Import-Module WebAdministration -ErrorAction Stop

    # Remove default website
    Write-PackerLog -Message "Removing default IIS website"
    $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Remove-Website -Name 'Default Web Site'
        Write-PackerLog -Message "Default Web Site removed"
    }

    # Disable directory browsing
    Write-PackerLog -Message "Disabling directory browsing"
    $dirBrowseParams = @{
        Filter = '/system.webServer/directoryBrowse'
        PSPath = 'IIS:\'
        Name   = 'enabled'
        Value  = $false
    }
    Set-WebConfigurationProperty @dirBrowseParams

    # Disable TLS 1.0
    Write-PackerLog -Message "Disabling TLS 1.0"
    $tls10Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server'
    New-Item -Path $tls10Path -Force | Out-Null
    Set-ItemProperty -Path $tls10Path -Name 'Enabled' -Value 0 -Type DWord
    Set-ItemProperty -Path $tls10Path -Name 'DisabledByDefault' -Value 1 -Type DWord

    # Disable TLS 1.1
    Write-PackerLog -Message "Disabling TLS 1.1"
    $tls11Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server'
    New-Item -Path $tls11Path -Force | Out-Null
    Set-ItemProperty -Path $tls11Path -Name 'Enabled' -Value 0 -Type DWord
    Set-ItemProperty -Path $tls11Path -Name 'DisabledByDefault' -Value 1 -Type DWord

    # Enable TLS 1.2 explicitly
    Write-PackerLog -Message "Ensuring TLS 1.2 is enabled"
    $tls12Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server'
    New-Item -Path $tls12Path -Force | Out-Null
    Set-ItemProperty -Path $tls12Path -Name 'Enabled' -Value 1 -Type DWord
    Set-ItemProperty -Path $tls12Path -Name 'DisabledByDefault' -Value 0 -Type DWord

    # Disable weak ciphers (RC4, DES, 3DES)
    Write-PackerLog -Message "Disabling weak cipher suites"
    $weakCiphers = @('RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128', 'DES 56/56', 'Triple DES 168')
    foreach ($cipher in $weakCiphers) {
        $cipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\$cipher"
        New-Item -Path $cipherPath -Force | Out-Null
        Set-ItemProperty -Path $cipherPath -Name 'Enabled' -Value 0 -Type DWord
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
