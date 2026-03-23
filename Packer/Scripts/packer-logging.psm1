<#
.SYNOPSIS
    Packer Windows build: config load, transcripts, EC2Launch info, and log helpers.
.DESCRIPTION
    Used by Packer provisioning scripts for build-config.json, transcript logging,
    zip updates, detailed errors, and optional EC2Launch / Windows Update diagnostics.
#>

$Script:PackerLogsPath = if ($env:LOGS_PATH) { $env:LOGS_PATH } else { 'C:\Packer\Logs' }

#region Config Functions

function Get-PackerBuildConfig {
    <#
    .SYNOPSIS
        Loads and returns the Packer build configuration from build-config.json.
    .DESCRIPTION
        Reads C:\Packer\Config\build-config.json (written by the Packer file provisioner)
        and returns the configuration as a PSCustomObject.
    #>
    [CmdletBinding()]
    param()

    $ConfigPath = Join-Path 'C:\Packer\Config' 'build-config.json'
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "FATAL: Build configuration file not found at '$ConfigPath'. The build cannot continue."
        exit 1
    }
    return Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
}

#endregion

#region Logging Functions

function Get-PackerLogsPath {
    [CmdletBinding()]
    param()
    return $Script:PackerLogsPath
}

function Start-PackerTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.InvocationInfo]$Invocation,

        [Parameter()]
        [string]$OriginalScriptName,

        [Parameter()]
        [switch]$FailOnError
    )

    if ($OriginalScriptName) {
        $ScriptName = $OriginalScriptName
        $LogFileName = $OriginalScriptName
    } else {
        $ScriptName = $Invocation.MyCommand.Name
        $LogFileName = $ScriptName
    }

    Write-Output ('Starting {0}' -f $ScriptName)

    New-PackerLogDirectory
    $LogDir = Get-PackerLogsPath

    $TimingLogPath = Join-Path $LogDir 'script-timing.log'
    $ZipPath = Join-Path (Split-Path $LogDir -Parent) 'packer-guest-logs.zip'

    if (-not (Test-Path $ZipPath)) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create').Dispose()
    }

    $TranscriptPath = Join-Path $LogDir -ChildPath "$($LogFileName)-$(Get-Date -Format 'yyyyMMddHHmmss').log"
    try {
        Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop
    } catch {
        $ErrorMsg = "Failed to start transcript: $($_.Exception.Message)"
        Write-Warning $ErrorMsg
        if ($FailOnError) {
            Write-Error "Transcript logging is required for this script. Exiting."
            exit 1
        }
    }

    try {
        $StartTime = (Get-Date).ToUniversalTime()
        "START: $ScriptName at $($StartTime.ToString('u'))" | Out-File -FilePath $TimingLogPath -Append -Encoding utf8 -ErrorAction Stop
    } catch {
        $ErrorMsg = "Failed to write timing log: $($_.Exception.Message)"
        Write-Warning $ErrorMsg
        $StartTime = (Get-Date).ToUniversalTime()
        if ($FailOnError) {
            Write-Error "Timing log is required for this script. Exiting."
            exit 1
        }
    }

    return [PSCustomObject]@{
        StartTime      = $StartTime
        ScriptName     = $ScriptName
        TimingLogPath  = $TimingLogPath
        TranscriptPath = $TranscriptPath
        ZipPath        = $ZipPath
        FailOnError    = $FailOnError.IsPresent
    }
}

function Get-ElapsedTimeString {
    <#
    .SYNOPSIS
        Returns a formatted elapsed time string (HH:MM:SS) from a start time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [DateTime]$StartTime
    )

    $Duration = (Get-Date).ToUniversalTime() - $StartTime
    return '{0:D2}:{1:D2}:{2:D2}' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
}

function Stop-PackerTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TranscriptState
    )

    try {
        try {
            $EndTime = (Get-Date).ToUniversalTime()
            $Duration = New-TimeSpan -Start $TranscriptState.StartTime -End $EndTime
            "END:   $($TranscriptState.ScriptName) at $($EndTime.ToString('u')). Duration: $($Duration.TotalSeconds) seconds" | Out-File -FilePath $TranscriptState.TimingLogPath -Append -Encoding utf8 -ErrorAction Stop
        } catch {
            $ErrorMsg = "Failed to write timing log: $($_.Exception.Message)"
            Write-Warning $ErrorMsg
            if ($TranscriptState.FailOnError) {
                Write-Error "Timing log is required for this script. Exiting."
                exit 1
            }
        }

        Write-Output "Script execution completed - $($TranscriptState.ScriptName)"
        try {
            Stop-Transcript -ErrorAction Stop
        } catch {
            $ErrorMsg = "Failed to stop transcript: $($_.Exception.Message)"
            Write-Warning $ErrorMsg
            if ($TranscriptState.FailOnError) {
                Write-Error "Transcript logging is required for this script. Exiting."
                exit 1
            }
        }

        if ($TranscriptState.ZipPath) {
            $FilesToAdd = @()
            if ($TranscriptState.TranscriptPath -and (Test-Path $TranscriptState.TranscriptPath)) {
                $FilesToAdd += $TranscriptState.TranscriptPath
            }
            if ($TranscriptState.TimingLogPath -and (Test-Path $TranscriptState.TimingLogPath)) {
                $FilesToAdd += $TranscriptState.TimingLogPath
            }
            if ($FilesToAdd.Count -gt 0) {
                try {
                    Compress-Archive -Path $FilesToAdd -DestinationPath $TranscriptState.ZipPath -Update
                } catch {
                    Write-Warning "Failed to update log zip: $($_.Exception.Message)"
                }
            }
        }
    }
}

function Write-DetailedError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Invocation = $ErrorRecord.InvocationInfo
    $Exception = $ErrorRecord.Exception

    $ErrorMessage = @"
---------------------------------------------------------------------
A fatal error occurred.

Error Type:    $($Exception.GetType().FullName)
Error Message: $($Exception.Message)

Failing Command:  $($Invocation.MyCommand)
Script:           $($Invocation.ScriptName)
Line Number:      $($Invocation.ScriptLineNumber)
Source Line:      $($Invocation.Line)

Stack Trace:
$($ErrorRecord.ScriptStackTrace)
---------------------------------------------------------------------
"@

    Write-Error $ErrorMessage
}

#endregion

#region EC2Launch Functions

function Get-EC2LaunchInfo {
    <#
    .SYNOPSIS
        Detects the installed version of EC2Launch and returns configuration paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$ShowInfo
    )

    $EC2LaunchInfo = [PSCustomObject]@{
        OSEdition       = $null
        OSVersion       = $null
        OSBuild         = $null
        AgentVersion    = '0.0.0'
        EC2LaunchExe    = 'C:\Program Files\Amazon\EC2Launch\ec2launch.exe'
        ConfigPath      = 'C:\ProgramData\Amazon\EC2Launch\config\agent-config.yml'
        RunOnceFlagPath = 'C:\ProgramData\Amazon\EC2Launch\state\.run-once'
        UnattendPath    = 'C:\ProgramData\Amazon\EC2Launch\unattend.xml'
    }

    try {
        $WinCurrentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $EC2LaunchInfo.OSEdition = $WinCurrentVersion.ProductName
        $EC2LaunchInfo.OSVersion = $WinCurrentVersion.ReleaseId
        $EC2LaunchInfo.OSBuild = '{0}.{1}' -f $WinCurrentVersion.CurrentBuild,$WinCurrentVersion.UBR

        if (Test-Path -Path $EC2LaunchInfo.EC2LaunchExe) {
            $EC2LaunchExe = Get-Item $EC2LaunchInfo.EC2LaunchExe
            $EC2LaunchInfo.AgentVersion = $EC2LaunchExe.VersionInfo.ProductVersion
            if ($ShowInfo) {
                Write-Host "Operating System        : $($EC2LaunchInfo.OSEdition)"
                Write-Host "OS Version              : $($EC2LaunchInfo.OSVersion)"
                Write-Host "OS Build                : $($EC2LaunchInfo.OSBuild)"
                Write-Host "EC2Launch Agent Version : $($EC2LaunchInfo.AgentVersion)"
            }
        }
        return $EC2LaunchInfo
    }
    catch {
        Write-Error "Failed to get EC2Launch info: $($_.Exception.Message)"
        exit 1
    }
}

#endregion

#region System Utilities

function New-PackerLogDirectory {
    <#
    .SYNOPSIS
        Creates the Packer logs directory with error handling and validation.
    #>
    [CmdletBinding()]
    param()

    $LogPath = Get-PackerLogsPath
    Write-Output "Creating Packer log directory: $LogPath"

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $ErrorMsg = "CRITICAL: Log path is null or empty"
        Write-Error $ErrorMsg
        Write-Error "Log directory creation failed. Exiting."
        exit 1
    }

    try {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is for testing purposes.')]
        $TestPath = [System.IO.Path]::GetFullPath($LogPath)
    } catch {
        $ErrorMsg = "CRITICAL: Invalid log path '$LogPath': $($_.Exception.Message)"
        Write-Error $ErrorMsg
        Write-Error "Log directory creation failed. Exiting."
        exit 1
    }

    if (Test-Path -Path $LogPath -PathType Container) {
        Write-Output "Log directory already exists: $LogPath"

        try {
            $TestFile = Join-Path -Path $LogPath -ChildPath "test-write-$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
            "test" | Out-File -FilePath $TestFile -Encoding utf8 -ErrorAction Stop
            Remove-Item -Path $TestFile -Force -ErrorAction Stop
            Write-Output "Write permissions validated for existing directory"
        } catch {
            $ErrorMsg = "CRITICAL: Cannot write to existing log directory '$LogPath': $($_.Exception.Message)"
            Write-Error $ErrorMsg
            Write-Error "Log directory validation failed. Exiting."
            exit 1
        }

        return
    }

    try {
        $CreatedDir = New-Item -Path $LogPath -ItemType Directory -Force -ErrorAction Stop
        Write-Output "Successfully created log directory: $($CreatedDir.FullName)"

        if (-not (Test-Path -Path $LogPath -PathType Container)) {
            throw "Directory creation appeared successful but directory does not exist"
        }

        $TestFile = Join-Path -Path $LogPath -ChildPath "test-write-$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
        "test" | Out-File -FilePath $TestFile -Encoding utf8 -ErrorAction Stop
        Remove-Item -Path $TestFile -Force -ErrorAction Stop
        Write-Output "Write permissions validated for new directory"

    } catch {
        $ErrorMsg = "CRITICAL: Failed to create log directory '$LogPath': $($_.Exception.Message)"
        Write-Error $ErrorMsg
        Write-Error "Log directory creation failed. Exiting."
        exit 1
    }
}

function Get-WindowsUpdateClientEvents {
    <#
    .SYNOPSIS
        Displays Windows Update Client events from the operational log.
    #>
    [CmdletBinding()]
    param()

    Write-Output "=== Windows Update Client Event Log Summary ==="

    try {
        $Events = Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 50 -ErrorAction Stop |
                 Where-Object { $_.TimeCreated.Date -eq (Get-Date).Date } |
                 Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                 Sort-Object TimeCreated

        if ($Events.Count -gt 0) {
            Write-Output "Found $($Events.Count) events:"
            $Events | Format-Table -AutoSize
        } else {
            Write-Output "No events found for today."
        }
    }
    catch {
        Write-Output "Windows Update Client log not available: $($_.Exception.Message)"
    }

    Write-Output "=== End Windows Update Client Event Summary ==="
}

#endregion

Export-ModuleMember -Function Get-PackerBuildConfig, Start-PackerTranscript, Stop-PackerTranscript, Get-ElapsedTimeString, Get-PackerLogsPath, New-PackerLogDirectory, Get-EC2LaunchInfo, Get-WindowsUpdateClientEvents, Write-DetailedError
