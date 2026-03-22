<#
.SYNOPSIS
    Shared logging and transcript management module for Packer provisioner scripts.

.DESCRIPTION
    Provides standardized transcript management and structured logging for Packer
    provisioner scripts. Each provisioner imports this module to start/stop transcripts
    and archive log files into a combined zip for post-build analysis.

.NOTES
    File Name  : packer-logging.psm1
    Requires   : PowerShell 5.1+
#>

# Script-scoped state for tracking active transcript
$script:TranscriptPath = $null

function Start-PackerTranscript {
    <#
    .SYNOPSIS
        Starts a PowerShell transcript for a provisioner script.

    .DESCRIPTION
        Creates a timestamped transcript log file in the Logs directory.
        The transcript captures all console output for the duration of the provisioner run.

    .PARAMETER ScriptName
        The name of the calling provisioner script (without extension).

    .PARAMETER LogDirectory
        The directory where transcript files are written. Defaults to Logs under the module root.

    .EXAMPLE
        $logPath = Start-PackerTranscript -ScriptName 'initialize'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptName,

        [Parameter()]
        [string]$LogDirectory = "$PSScriptRoot\..\Logs"
    )

    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFileName = "${ScriptName}_${timestamp}.log"
    $script:TranscriptPath = Join-Path -Path $LogDirectory -ChildPath $logFileName

    Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
    Write-Verbose "Transcript started: $($script:TranscriptPath)"

    return $script:TranscriptPath
}

function Stop-PackerTranscript {
    <#
    .SYNOPSIS
        Stops the active PowerShell transcript.

    .DESCRIPTION
        Safely stops the current transcript and returns the path to the log file.
        Handles the case where no transcript is running without throwing an error.

    .EXAMPLE
        $logFile = Stop-PackerTranscript
    #>
    [CmdletBinding()]
    param()

    $logFile = $script:TranscriptPath
    $script:TranscriptPath = $null

    try {
        Stop-Transcript | Out-Null
        Write-Verbose "Transcript stopped: $logFile"
    }
    catch {
        Write-Verbose "No active transcript to stop."
    }

    return $logFile
}

function Add-LogToArchive {
    <#
    .SYNOPSIS
        Appends a transcript log file to the combined build log archive.

    .DESCRIPTION
        Uses Compress-Archive with -Update to append the specified log file to a
        cumulative zip archive. Each provisioner's transcript is added to the same
        archive, producing a single artifact for the entire Packer build.

    .PARAMETER LogPath
        The full path to the transcript log file to archive.

    .PARAMETER ArchivePath
        The path to the zip archive. Defaults to packer-build-logs.zip in the Logs directory.

    .EXAMPLE
        Add-LogToArchive -LogPath 'C:\Packer\Logs\initialize_20260322_120000.log'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [string]$ArchivePath = "$PSScriptRoot\..\Logs\packer-build-logs.zip"
    )

    if (-not (Test-Path -Path $LogPath)) {
        Write-Warning "Log file not found, skipping archive: $LogPath"
        return
    }

    try {
        Compress-Archive -Path $LogPath -DestinationPath $ArchivePath -Update
        Write-Verbose "Archived log to: $ArchivePath"
    }
    catch {
        Write-Warning "Failed to archive log file: $_"
    }
}

function Write-PackerLog {
    <#
    .SYNOPSIS
        Writes a structured, timestamped log message.

    .DESCRIPTION
        Outputs a formatted log message with timestamp and severity level.
        Messages are captured by the active transcript and displayed in the Packer
        build output. Routes to Write-Warning or Write-Error for non-Info severities.

    .PARAMETER Message
        The log message text.

    .PARAMETER Severity
        The severity level: Info, Warning, or Error. Defaults to Info.

    .EXAMPLE
        Write-PackerLog -Message 'Installing software' -Severity Info

    .EXAMPLE
        Write-PackerLog -Message 'Disk space low' -Severity Warning
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Severity = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$timestamp] [$Severity] $Message"

    switch ($Severity) {
        'Info'    { Write-Host $formatted -ForegroundColor Cyan }
        'Warning' { Write-Warning $formatted }
        'Error'   { Write-Error $formatted }
    }
}

Export-ModuleMember -Function Start-PackerTranscript, Stop-PackerTranscript, Add-LogToArchive, Write-PackerLog
