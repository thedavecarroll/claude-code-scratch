<#
.SYNOPSIS
    Configures BgInfo from Sysinternals (manifest) and sets up logon startup.
.DESCRIPTION
    Extracts Sysinternals zip to C:\Sysinternals. Copies BgInfo64.exe to C:\ProgramData\BgInfo.
    Renames {ChefOrganization}.bgi to bginfo.bgi. BgInfo scripts are provisioned to C:\ProgramData\BgInfo
    by the BGInfo file provisioner. Creates startup shortcut to run at logon. Sets EulaAccepted registry key.
.NOTES
    Runs after download-installers.ps1. Requires sysinternals in manifest.
#>
[CmdletBinding()]
param()

# Load build configuration
$ConfigPath = 'C:\Packer\Config\build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$TranscriptState = $null
try {
    $ErrorActionPreference = 'Stop'
    Import-Module -Name $Config.LoggingModulePath -Force
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'config-bginfo.ps1'

    $InstallFilesPath = $Config.InstallFilesPath
    $BgInfoDir = $Config.BgInfoPath
    $SysinternalsDir = $Config.SysinternalsPath

    if ([string]::IsNullOrWhiteSpace($BgInfoDir)) {
        throw "BgInfoPath was not supplied in build-config.json."
    }
    if ([string]::IsNullOrWhiteSpace($SysinternalsDir)) {
        throw "SysinternalsPath was not supplied in build-config.json."
    }

    $null = New-Item -Path $BgInfoDir -ItemType Directory -Force

    # Find Sysinternals zip (from manifest download)
    $SysinternalsZip = Get-ChildItem -Path $InstallFilesPath -Filter '*Sysinternals*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $SysinternalsZip) {
        $SysinternalsZip = Get-ChildItem -Path $InstallFilesPath -Filter '*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'sysinternals|Sysinternals' } | Select-Object -First 1
    }
    if (-not $SysinternalsZip) {
        throw "Sysinternals zip not found in '$InstallFilesPath'. Ensure manifest includes sysinternals package."
    }

    Write-Output "Extracting Sysinternals: $($SysinternalsZip.Name)"
    $null = New-Item -Path $SysinternalsDir -ItemType Directory -Force
    Expand-Archive -Path $SysinternalsZip.FullName -DestinationPath $SysinternalsDir -Force

    # Find BgInfo64.exe (or BgInfo.exe) and optional default .bgi in zip
    $BgInfoExe = Get-ChildItem -Path $SysinternalsDir -Filter 'BgInfo64.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $BgInfoExe) {
        $BgInfoExe = Get-ChildItem -Path $SysinternalsDir -Filter 'BgInfo.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $BgInfoExe) {
        throw "BgInfo64.exe or BgInfo.exe not found in Sysinternals zip."
    }

    Copy-Item -Path $BgInfoExe.FullName -Destination (Join-Path -Path $BgInfoDir -ChildPath 'BgInfo64.exe') -Force

    # Rename {ChefOrganization}.bgi to bginfo.bgi in C:\ProgramData\BgInfo
    $ChefOrg = $Config.ChefOrganization
    if ([string]::IsNullOrWhiteSpace($ChefOrg)) {
        throw "ChefOrganization was not supplied in build-config.json. Required for BgInfo config lookup."
    }
    $BgiConfig = Join-Path -Path $BgInfoDir -ChildPath "${ChefOrg}.bgi"
    if (-not (Test-Path $BgiConfig)) {
        throw "BgInfo config not found at '$BgiConfig'. Add scripts/BGInfo/${ChefOrg}.bgi for this organization."
    }
    Rename-Item -Path $BgiConfig -NewName 'bginfo.bgi' -Force
    Write-Output "Using BgInfo config: $BgiConfig"

    $BgiDest = Join-Path -Path $BgInfoDir -ChildPath 'bginfo.bgi'

    # EulaAccepted for all Sysinternals tools (HKU\.DEFAULT for new users and System)
    $SysinternalsEulaPath = 'Registry::HKEY_USERS\.DEFAULT\Software\Sysinternals'
    $null = New-Item -Path $SysinternalsEulaPath -Force
    Set-ItemProperty -Path $SysinternalsEulaPath -Name 'EulaAccepted' -Value 1 -Type DWord -Force

    # All Users Startup: run at logon for every user (updates desktop)
    if (Test-Path $BgiDest) {
        $StartupScriptPath = Join-Path -Path $BgInfoDir -ChildPath 'Set-BgInfoStartup.ps1'
        & $StartupScriptPath -BgInfoPath $BgInfoDir -BgiConfig $BgiDest
        $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
        Write-Output "BgInfo installed to $BgInfoDir. Startup shortcut created for all users at logon. Completed in $Elapsed"
    }
    else {
        $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
        Write-Output "BgInfo installed to $BgInfoDir. Startup shortcut skipped (no bginfo.bgi). Add config and shortcut manually. Completed in $Elapsed"
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
