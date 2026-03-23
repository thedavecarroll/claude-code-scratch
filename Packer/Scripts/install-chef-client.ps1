<#
.SYNOPSIS
    Installs the Chef Infra Client on a Windows instance.
.DESCRIPTION
    Installs the Chef Infra Client from a pre-staged MSI in C:\ProgramData\Installers
    (downloaded by download-installers.ps1). Waits for any other MSI installations
    to complete before starting. Installer is not deleted after use.
.NOTES
    Runs after download-installers.ps1. Requires build-config.json at C:\Packer\Config\build-config.json.
#>
[CmdletBinding()]
param()

$ConfigPath = Join-Path 'C:\Packer\Config' 'build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'. The build cannot continue."
    exit 1
}
$bootstrap = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$helperPath = $bootstrap.InstallHelperModulePath
if (-not (Test-Path $helperPath)) {
    Write-Error "FATAL: Packer install helper module not found at '$helperPath'. The build cannot continue."
    exit 1
}
Import-Module -Name $helperPath -Force
$Config = Get-PackerBuildConfig

$TranscriptState = $null
try {
    $ErrorActionPreference = 'Stop'
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'install-chef-client.ps1'

    $InstallFilesPath = Get-InstallFilesPath -Config $Config
    $NotFoundMsg = "Chef installer not found in '{0}'. Ensure download-installers.ps1 downloaded chef_client from the manifest." -f $InstallFilesPath
    $ChefMsi = Find-PackerInstaller -Path $InstallFilesPath -Filter 'chef-client-*.msi' -NotFoundMessage $NotFoundMsg

    Write-Output "Installing Chef Client from $($ChefMsi.FullName)..."
    Invoke-WaitForMsiexec -TimeoutMinutes 5 -PollIntervalSeconds 15

    $ClientInstallLogPath = Join-Path -Path $Config.LogsPath -ChildPath 'install-chef-client.msi.log'
    $LogArg = '/L*v "' + $ClientInstallLogPath + '"'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/qn', '/i', $ChefMsi.FullName, $LogArg -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "Chef Client installation failed with exit code $($proc.ExitCode)."
    }

    # Output last 30 lines of MSI log for visibility in transcript and Packer console
    if (Test-Path -LiteralPath $ClientInstallLogPath) {
        $logLines = Get-Content -Path $ClientInstallLogPath -Tail 30 -ErrorAction SilentlyContinue
        if ($logLines) {
            Write-Output '--- Chef Client MSI log (last 30 lines) ---'
            $logLines | ForEach-Object { Write-Output $_ }
            Write-Output '--- end MSI log ---'
        }
    }

    $ChefClientPath = 'C:\opscode\chef\bin\chef-client.bat'
    if (-not (Test-Path -LiteralPath $ChefClientPath)) {
        throw ('Chef Client installation verification failed. Path not found: {0}' -f $ChefClientPath)
    }
    $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
    Write-Output "Chef Client installed successfully. Completed in $Elapsed"
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
