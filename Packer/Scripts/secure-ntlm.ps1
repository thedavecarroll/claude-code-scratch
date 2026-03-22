#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restricts NTLM authentication and enforces NTLMv2.

.DESCRIPTION
    Hardens NTLM settings by setting the LAN Manager authentication level
    to NTLMv2 only (refusing LM and NTLMv1), and configures NTLM audit
    logging for monitoring.

.NOTES
    File Name  : secure-ntlm.ps1
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

    $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $msv1Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'

    # Set LAN Manager authentication level to NTLMv2 only
    # Level 5: Send NTLMv2 response only, refuse LM & NTLM
    Write-PackerLog -Message "Setting LmCompatibilityLevel to 5 (NTLMv2 only, refuse LM and NTLMv1)"
    Set-ItemProperty -Path $lsaPath -Name 'LmCompatibilityLevel' -Value 5 -Type DWord

    # Restrict NTLM: Audit all NTLM authentication in this domain
    Write-PackerLog -Message "Enabling NTLM audit logging"
    if (-not (Test-Path -Path $msv1Path)) {
        New-Item -Path $msv1Path -Force | Out-Null
    }
    Set-ItemProperty -Path $msv1Path -Name 'AuditReceivingNTLMTraffic' -Value 2 -Type DWord
    Set-ItemProperty -Path $msv1Path -Name 'RestrictSendingNTLMTraffic' -Value 1 -Type DWord

    # Disable LM hash storage
    Write-PackerLog -Message "Disabling LM hash storage"
    Set-ItemProperty -Path $lsaPath -Name 'NoLMHash' -Value 1 -Type DWord

    # Configure minimum session security for NTLM SSP
    Write-PackerLog -Message "Setting minimum NTLM SSP session security (require NTLMv2 and 128-bit encryption)"
    Set-ItemProperty -Path $msv1Path -Name 'NtlmMinClientSec' -Value 0x20080000 -Type DWord
    Set-ItemProperty -Path $msv1Path -Name 'NtlmMinServerSec' -Value 0x20080000 -Type DWord

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
