<#
.SYNOPSIS
    Packer Windows build: installer discovery, msiexec wait, and captured installer runs.
.DESCRIPTION
    Imports packer-logging.psm1 from the same directory for Get-PackerLogsPath and related
    helpers. Used by install scripts and install-from-manifest.
#>

# -Global: nested module exports are not visible to the caller script unless logging is imported into the session scope.
Import-Module -Name (Join-Path $PSScriptRoot 'packer-logging.psm1') -Force -Global

function Get-InstallFilesPath {
    <#
    .SYNOPSIS
        Returns validated InstallFilesPath from build config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $path = $Config.InstallFilesPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "InstallFilesPath was not supplied in build-config.json."
    }
    return $path
}

function Find-PackerInstaller {
    <#
    .SYNOPSIS
        Locates an installer by filter in the given path. Throws if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Filter,

        [Parameter(Mandatory)]
        [string]$NotFoundMessage
    )

    $installer = Get-ChildItem -Path $Path -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $installer) {
        throw $NotFoundMessage
    }
    return $installer
}

function Invoke-WaitForMsiexec {
    <#
    .SYNOPSIS
        Waits for msiexec processes to exit before proceeding.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [Alias('TimeoutMinutes')]
        [int]$TimeoutMins = 5,

        [Parameter()]
        [int]$PollIntervalSeconds = 15
    )

    Write-Output "Checking for existing msiexec processes..."
    $Timeout = New-TimeSpan -Minutes $TimeoutMins
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $WaitCount = 0
    $LastDisplayedInstalling = $null
    $StepSeconds = @(60, 45, 30, 15)
    while (Get-Process -Name msiexec -ErrorAction SilentlyContinue) {
        if ($Stopwatch.Elapsed -gt $Timeout) {
            throw "Timeout waiting for other msiexec processes to exit."
        }
        $msiexecProcs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msiexec.exe'" -ErrorAction SilentlyContinue
        $installing = $msiexecProcs | ForEach-Object {
            $cmd = $_.CommandLine
            if ($cmd -match '(?:/I|/i)\s+"([^"]+)"') {
                [System.IO.Path]::GetFileName($Matches[1])
            } elseif ($cmd -match '(?:/I|/i)\s+\{([^}]+)\}') {
                "Product {$($Matches[1])}"
            } elseif ($cmd -match '(?:/I|/i)\s+(\S+)') {
                $m = $Matches[1]
                if ($m -match '\.msi$') { [System.IO.Path]::GetFileName($m) } else { $m }
            } else {
                "PID $($_.ProcessId)"
            }
        } | Sort-Object -Unique
        $installingStr = if ($installing) { $installing -join ', ' } else { $null }
        if ($installingStr -and $installingStr -ne $LastDisplayedInstalling) {
            Write-Output "  - Waiting on: $installingStr"
            $LastDisplayedInstalling = $installingStr
        }
        $WaitCount++
        $SleepSeconds = $StepSeconds[[Math]::Min($WaitCount - 1, $StepSeconds.Count - 1)]
        Write-Output "  - Waited for $([int]$Stopwatch.Elapsed.TotalSeconds) seconds, retrying in ${SleepSeconds} seconds..."
        Start-Sleep -Seconds $SleepSeconds
    }
    if ($WaitCount -gt 0) {
        Write-Output "  - msiexec cleared after $WaitCount wait(s), $([int]$Stopwatch.Elapsed.TotalSeconds)s total."
    }
}

function Invoke-PackerInstaller {
    <#
    .SYNOPSIS
        Runs an installer with stdout/stderr capture and outputs captured content for visibility.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [array]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$InstallerName,

        [Parameter(Mandatory)]
        [string]$LogPrefix
    )

    $LogDir = Get-PackerLogsPath
    $StdoutPath = Join-Path -Path $LogDir -ChildPath "${LogPrefix}-installer-stdout.log"
    $StderrPath = Join-Path -Path $LogDir -ChildPath "${LogPrefix}-installer-stderr.log"

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "$InstallerName installation failed with exit code $($proc.ExitCode)."
    }

    if (Test-Path $StdoutPath) {
        $stdout = Get-Content -Path $StdoutPath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Output "--- $InstallerName installer stdout ---"
            Write-Output $stdout.Trim()
            Write-Output "--- end stdout ---"
        }
    }
    if (Test-Path $StderrPath) {
        $stderr = Get-Content -Path $StderrPath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Output "--- $InstallerName installer stderr ---"
            Write-Output $stderr.Trim()
            Write-Output "--- end stderr ---"
        }
    }

    return $proc
}

Export-ModuleMember -Function Get-InstallFilesPath, Find-PackerInstaller, Invoke-WaitForMsiexec, Invoke-PackerInstaller
