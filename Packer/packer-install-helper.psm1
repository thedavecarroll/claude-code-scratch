<#
.SYNOPSIS
    Shared installation helper module for Packer provisioner scripts.

.DESCRIPTION
    Provides reusable functions for installing MSI and EXE packages, verifying
    installed software, downloading installers, and waiting for processes to complete.

.NOTES
    File Name  : packer-install-helper.psm1
    Requires   : PowerShell 5.1+
#>

function Install-MSI {
    <#
    .SYNOPSIS
        Installs an MSI package silently.

    .DESCRIPTION
        Runs msiexec.exe with the specified MSI file and arguments. Validates the
        exit code and optionally writes an installation log.

    .PARAMETER Path
        The full path to the MSI file.

    .PARAMETER Arguments
        Additional msiexec arguments. Defaults to '/qn /norestart'.

    .PARAMETER LogPath
        Optional path for the MSI installation log. Uses msiexec /l*v logging.

    .EXAMPLE
        Install-MSI -Path 'C:\Installers\chef-client.msi'

    .EXAMPLE
        Install-MSI -Path 'C:\Installers\agent.msi' -LogPath 'C:\Logs\agent-install.log'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string]$Arguments = '/qn /norestart',

        [Parameter()]
        [string]$LogPath
    )

    if (-not (Test-Path -Path $Path)) {
        throw "MSI file not found: $Path"
    }

    $msiArgs = @("/i", "`"$Path`"")
    $msiArgs += $Arguments -split ' '

    if ($LogPath) {
        $msiArgs += "/l*v", "`"$LogPath`""
    }

    Write-Verbose "Running: msiexec.exe $($msiArgs -join ' ')"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "MSI installation failed with exit code $($process.ExitCode): $Path"
    }

    if ($process.ExitCode -eq 3010) {
        Write-Warning "MSI installation succeeded but requires a reboot (exit code 3010): $Path"
    }

    Write-Verbose "MSI installation completed with exit code $($process.ExitCode)"
    return $process.ExitCode
}

function Install-EXE {
    <#
    .SYNOPSIS
        Installs an EXE package silently.

    .DESCRIPTION
        Runs an executable installer with the specified arguments and validates
        the exit code against a list of acceptable codes.

    .PARAMETER Path
        The full path to the EXE installer.

    .PARAMETER Arguments
        Installer arguments. Defaults to '/S' (common silent flag).

    .PARAMETER ValidExitCodes
        Array of acceptable exit codes. Defaults to 0 and 3010.

    .EXAMPLE
        Install-EXE -Path 'C:\Installers\crowdstrike.exe' -Arguments '/install /quiet /norestart CID=XXXXX'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string]$Arguments = '/S',

        [Parameter()]
        [int[]]$ValidExitCodes = @(0, 3010)
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Installer not found: $Path"
    }

    Write-Verbose "Running: $Path $Arguments"
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru

    if ($process.ExitCode -notin $ValidExitCodes) {
        throw "EXE installation failed with exit code $($process.ExitCode): $Path"
    }

    if ($process.ExitCode -eq 3010) {
        Write-Warning "Installation succeeded but requires a reboot (exit code 3010): $Path"
    }

    Write-Verbose "EXE installation completed with exit code $($process.ExitCode)"
    return $process.ExitCode
}

function Test-InstalledSoftware {
    <#
    .SYNOPSIS
        Checks whether software is installed by searching the registry.

    .DESCRIPTION
        Queries the Windows uninstall registry keys (both 64-bit and 32-bit paths)
        for a matching DisplayName.

    .PARAMETER Name
        The software name to search for (supports wildcards via -like).

    .EXAMPLE
        if (Test-InstalledSoftware -Name 'Chef Infra Client') { Write-Host 'Chef is installed' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installed = Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*$Name*" }

    return [bool]$installed
}

function Get-InstallerFromUri {
    <#
    .SYNOPSIS
        Downloads a file from a URI to a local path.

    .DESCRIPTION
        Downloads an installer or artifact from the specified URI. Creates the
        destination directory if it does not exist.

    .PARAMETER Uri
        The download URI.

    .PARAMETER DestinationPath
        The full local path where the file will be saved.

    .EXAMPLE
        Get-InstallerFromUri -Uri 'https://example.com/installer.msi' -DestinationPath 'C:\Installers\installer.msi'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    $parentDir = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -Path $parentDir)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }

    Write-Verbose "Downloading: $Uri -> $DestinationPath"

    # Use TLS 1.2 for PowerShell 5.1 compatibility
    if ($PSVersionTable.PSVersion.Major -le 5) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing

    if (-not (Test-Path -Path $DestinationPath)) {
        throw "Download failed, file not found: $DestinationPath"
    }

    Write-Verbose "Download complete: $DestinationPath"
    return $DestinationPath
}

function Wait-ForProcess {
    <#
    .SYNOPSIS
        Waits for a process to exit within a timeout period.

    .DESCRIPTION
        Polls for the specified process and waits until it exits or the timeout
        is reached. Useful for installers that spawn child processes.

    .PARAMETER ProcessName
        The process name to wait for (without .exe extension).

    .PARAMETER TimeoutSeconds
        Maximum time to wait in seconds. Defaults to 300 (5 minutes).

    .EXAMPLE
        $completed = Wait-ForProcess -ProcessName 'msiexec' -TimeoutSeconds 600
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProcessName,

        [Parameter()]
        [int]$TimeoutSeconds = 300
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Verbose "Process '$ProcessName' has exited."
            return $true
        }
        Write-Verbose "Waiting for process '$ProcessName' ($([int]$stopwatch.Elapsed.TotalSeconds)s / ${TimeoutSeconds}s)..."
        Start-Sleep -Seconds 5
    }

    Write-Warning "Timed out waiting for process '$ProcessName' after ${TimeoutSeconds} seconds."
    return $false
}

Export-ModuleMember -Function Install-MSI, Install-EXE, Test-InstalledSoftware, Get-InstallerFromUri, Wait-ForProcess
