<#
.SYNOPSIS
    Hardens the security settings for the NTLM authentication protocol on a Windows instance.
.DESCRIPTION
    Sets registry values under HKLM for LSA and Netlogon: LmCompatibilityLevel, NoLMHash,
    NtlmMinClientSec, NtlmMinServerSec, and RestrictSendingNTLMTraffic (DWORDs). Intended for
    Packer AMI builds running as Administrator.
.NOTES
    Packer: The secure-ntlm provisioner always runs after download-installers and before install-chef-client.

    Config: Reads C:\Packer\Config\build-config.json for LoggingModulePath (path to
    packer-logging.psm1). That file is deployed by the Packer file provisioner before this script.

    Get-Help: This script has no parameters; configuration is supplied via build-config.json.
.EXAMPLE
    PS C:\> & 'C:\Packer\Scripts\secure-ntlm.ps1'
#>
[CmdletBinding()]
param()

# Load build configuration from file
$ConfigPath = 'C:\Packer\Config\build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'. The build cannot continue."
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$TranscriptState = $null
try {
    $ErrorActionPreference = "Stop"
    Import-Module -Name $Config.LoggingModulePath -Force
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName "secure-ntlm.ps1"

    Write-Output "Applying NTLM hardening security settings..."

    $RegistrySettings = @(
        @{
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            Name = 'LmCompatibilityLevel'
            Value = 5  # Level 5: Send NTLMv2 only; refuse LM and NTLM
        }
        @{
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            Name = 'NoLMHash'
            Value = 1  # Prevent storage of LAN Manager hash
        }
        @{
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
            Name = 'NtlmMinClientSec'
            Value = 537395248  # 0x20080030: NTLMv2 session security (signing + sealing + 128-bit encryption)
        }
        @{
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
            Name = 'NtlmMinServerSec'
            Value = 537395248  # 0x20080030: NTLMv2 session security (signing + sealing + 128-bit encryption)
        }
        @{
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
            Name = 'RestrictSendingNTLMTraffic'
            Value = 2  # Deny all NTLM traffic to remote servers
        }
    )

    foreach ($RegistrySetting in $RegistrySettings) {
        $null = New-Item -Path $RegistrySetting.Path -Force
        Set-ItemProperty -LiteralPath $RegistrySetting.Path -Name $RegistrySetting.Name -Value $RegistrySetting.Value -Type DWord -Force
        Write-Output "  - Set $($RegistrySetting.Name) to $($RegistrySetting.Value) in $($RegistrySetting.Path)"
    }
}
catch {
    Write-DetailedError -ErrorRecord $_
    exit 1
}
finally {
    if ($TranscriptState) {
        Stop-PackerTranscript -TranscriptState $TranscriptState
    }
}
