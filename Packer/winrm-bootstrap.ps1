#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures WinRM for Packer communication.

.DESCRIPTION
    Sets up WinRM with an HTTPS listener using a self-signed certificate.
    Configures firewall rules and adjusts WinRM service settings for
    reliable Packer provisioner communication.

.NOTES
    Requires PowerShell 5.1+
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

    Write-PackerLog -Message "Enabling WinRM service"
    Set-Service -Name 'WinRM' -StartupType Automatic
    Start-Service -Name 'WinRM'

    Write-PackerLog -Message "Creating self-signed certificate for WinRM HTTPS"
    $hostname = $env:COMPUTERNAME
    $certParams = @{
        DnsName            = $hostname
        CertStoreLocation  = 'Cert:\LocalMachine\My'
        KeyLength          = 2048
        KeyAlgorithm       = 'RSA'
        HashAlgorithm      = 'SHA256'
        NotAfter           = (Get-Date).AddYears(1)
    }
    $cert = New-SelfSignedCertificate @certParams

    Write-PackerLog -Message "Certificate thumbprint: $($cert.Thumbprint)"

    $existingListeners = Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains 'Transport=HTTPS' }
    foreach ($listener in $existingListeners) {
        Remove-Item -Path "WSMan:\localhost\Listener\$($listener.Name)" -Recurse -Force
    }

    Write-PackerLog -Message "Creating WinRM HTTPS listener"
    $listenerParams = @{
        Path                 = 'WSMan:\localhost\Listener'
        Transport            = 'HTTPS'
        Address              = '*'
        CertificateThumbPrint = $cert.Thumbprint
        Force                = $true
    }
    $null = New-Item @listenerParams

    Write-PackerLog -Message "Configuring WinRM settings"
    Set-Item -Path 'WSMan:\localhost\MaxTimeoutms' -Value 1800000
    Set-Item -Path 'WSMan:\localhost\Shell\MaxMemoryPerShellMB' -Value 2048
    Set-Item -Path 'WSMan:\localhost\Service\AllowUnencrypted' -Value $false
    Set-Item -Path 'WSMan:\localhost\Service\Auth\Basic' -Value $true

    Write-PackerLog -Message "Configuring firewall rule for WinRM HTTPS (port 5986)"
    $existingRule = Get-NetFirewallRule -Name 'WinRM-HTTPS-In' -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -Name 'WinRM-HTTPS-In'
    }
    $firewallParams = @{
        Name        = 'WinRM-HTTPS-In'
        DisplayName = 'WinRM HTTPS Inbound'
        Direction   = 'Inbound'
        Protocol    = 'TCP'
        LocalPort   = 5986
        Action      = 'Allow'
    }
    $null = New-NetFirewallRule @firewallParams

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
