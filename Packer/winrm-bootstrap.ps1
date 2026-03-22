#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures WinRM for Packer communication.

.DESCRIPTION
    Sets up WinRM with an HTTPS listener using a self-signed certificate.
    Configures firewall rules and adjusts WinRM service settings for
    reliable Packer provisioner communication.

.NOTES
    File Name  : winrm-bootstrap.ps1
    Runs As    : Administrator (via Packer provisioner)
    Requires   : PowerShell 5.1+
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Import-Module -Name "$PSScriptRoot\Scripts\packer-logging.psm1" -Force
Import-Module -Name "$PSScriptRoot\Scripts\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    # Enable WinRM service
    Write-PackerLog -Message "Enabling WinRM service"
    Set-Service -Name 'WinRM' -StartupType Automatic
    Start-Service -Name 'WinRM'

    # Create a self-signed certificate for HTTPS
    Write-PackerLog -Message "Creating self-signed certificate for WinRM HTTPS"
    $hostname = $env:COMPUTERNAME
    $cert = New-SelfSignedCertificate -DnsName $hostname `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -KeyLength 2048 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(1)

    Write-PackerLog -Message "Certificate thumbprint: $($cert.Thumbprint)"

    # Remove existing HTTPS listeners
    $existingListeners = Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains 'Transport=HTTPS' }
    foreach ($listener in $existingListeners) {
        Remove-Item -Path "WSMan:\localhost\Listener\$($listener.Name)" -Recurse -Force
    }

    # Create HTTPS listener
    Write-PackerLog -Message "Creating WinRM HTTPS listener"
    New-Item -Path 'WSMan:\localhost\Listener' -Transport HTTPS `
        -Address '*' -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null

    # Configure WinRM settings
    Write-PackerLog -Message "Configuring WinRM settings"
    Set-Item -Path 'WSMan:\localhost\MaxTimeoutms' -Value 1800000
    Set-Item -Path 'WSMan:\localhost\Shell\MaxMemoryPerShellMB' -Value 2048
    Set-Item -Path 'WSMan:\localhost\Service\AllowUnencrypted' -Value $false
    Set-Item -Path 'WSMan:\localhost\Service\Auth\Basic' -Value $true

    # Configure firewall rule for WinRM HTTPS
    Write-PackerLog -Message "Configuring firewall rule for WinRM HTTPS (port 5986)"
    $existingRule = Get-NetFirewallRule -Name 'WinRM-HTTPS-In' -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -Name 'WinRM-HTTPS-In'
    }
    New-NetFirewallRule -Name 'WinRM-HTTPS-In' `
        -DisplayName 'WinRM HTTPS Inbound' `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 5986 `
        -Action Allow | Out-Null

    # Restart WinRM to apply changes
    Write-PackerLog -Message "Restarting WinRM service"
    Restart-Service -Name 'WinRM' -Force

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
