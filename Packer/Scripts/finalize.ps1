<#
.SYNOPSIS
    Configures EC2Launch v2 and generalizes the instance using sysprep for AMI creation.
.DESCRIPTION
    This script performs the final steps to prepare a Windows instance for AMI creation.
    It combines the initial EC2Launch v2 agent configuration with the final sysprep and cleanup process.
    The script ensures the service is configured, validates settings, performs cleanup,
    and then executes sysprep via EC2Launch v2.
.NOTES
    This script is designed to be run as the final provisioning step in a Packer build process.
    It relies on a 'build-config.json' file being present at 'C:\Packer\Config\build-config.json'.
#>
[CmdletBinding()]
param()

#region Private helpers (sysprep / EC2Launch finalize only; formerly shared packer module)

function Set-EC2LaunchConfigFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [switch]$Backup
    )

    Write-Output "Setting configuration file from '$SourcePath' to '$DestinationPath'."

    if (-not (Test-Path -Path $SourcePath)) {
        throw "Source configuration file not found at '$SourcePath'."
    }

    $DestinationDir = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -Path $DestinationDir)) {
        if ($PSCmdlet.ShouldProcess($DestinationDir, "Create Directory")) {
            $null = New-Item -Path $DestinationDir -ItemType Directory -Force
        }
    }

    if ($Backup.IsPresent -and (Test-Path -Path $DestinationPath)) {
        $BackupPath = "$($DestinationPath).orig"
        if ($PSCmdlet.ShouldProcess($DestinationPath, "Backup to $BackupPath")) {
            try {
                Rename-Item -Path $DestinationPath -NewName $BackupPath -Force -ErrorAction Stop
                Write-Output "Backed up existing configuration to $BackupPath"
            }
            catch {
                Write-Warning "Failed to back up existing configuration file '$DestinationPath'. Error: $($_.Exception.Message)."
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($DestinationPath, "Copy from $SourcePath")) {
        try {
            Copy-Item -Path $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
            Write-Output "Successfully set configuration file '$DestinationPath' from '$SourcePath'."
        }
        catch {
            throw "Failed to copy configuration file from '$SourcePath' to '$DestinationPath'. Error: $($_.Exception.Message)"
        }
    }
}

function Get-PendingReboot {
    [CmdletBinding()]
    param()

    $RegistryChecks = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Cmdlet = 'Get-ItemProperty'; Reason = 'Windows Update (Auto Update)' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\RebootRequired'; Cmdlet = 'Get-ItemProperty'; Reason = 'Windows Update (RebootRequired)' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Cmdlet = 'Get-ChildItem'; Reason = 'Component Based Servicing' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'; Cmdlet = 'Get-ItemProperty'; Reason = 'CBS Packages Pending' }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Name = 'PendingFileRenameOperations'; Cmdlet = 'Get-ItemProperty'; Reason = 'Pending File Rename Operations' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\Reboot'; Cmdlet = 'Get-ItemProperty'; Reason = 'Windows Update Orchestrator' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'; Cmdlet = 'Get-ItemProperty'; Reason = 'CBS Reboot In Progress' }
    )

    $PendingRebootReasons = foreach ($Check in $RegistryChecks) {
        $params = @{ ErrorAction = 'SilentlyContinue' }
        if ($Check.Name) { $params['Name'] = $Check.Name }
        if (& $Check.Cmdlet $Check.Path @params) { $Check.Reason }
    }

    [PSCustomObject]@{
        IsPending = (@($PendingRebootReasons).Count -gt 0)
        Reasons   = @($PendingRebootReasons)
    }
}

function Invoke-SafeRemove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    foreach ($PathItem in $Path) {
        if (Test-Path $PathItem) {
            Write-Output "Removing: $PathItem"
            try {
                Remove-Item -Path $PathItem -Recurse -Force -ErrorAction Stop
                Write-Output "  - Successfully removed."
            }
            catch {
                Write-Warning "  - Could not remove '$PathItem': $($_.Exception.Message)"
            }
        } else {
            Write-Output "Path not found, skipping: $PathItem"
        }
    }
}

function Set-WindowsUpdateServices {
    [CmdletBinding()]
    param(
        [string[]]$ServiceNames
    )

    Write-Output "Stopping and disabling Windows Update services: $($ServiceNames -join ', ')"
    foreach ($Service in $ServiceNames) {
        try {
            $Svc = Get-Service -Name $Service -ErrorAction Stop
            if ($Svc.Status -ne 'Stopped') {
                $Svc | Stop-Service -Force -ErrorAction Stop
                Write-Output "  - Stopped $Service"
            }
            if ($Svc.StartupType -ne 'Disabled') {
                $Svc | Set-Service -StartupType Disabled -ErrorAction Stop
                Write-Output "  - Disabled $Service"
            }
        }
        catch {
            Write-Warning "  - Could not configure service '$Service': $($_.Exception.Message)"
        }
    }
}

#endregion

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
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName "finalize.ps1"

    #----------------------------------------------------------------------
    # STAGE 1: Initial EC2Launch Configuration
    #----------------------------------------------------------------------

    # Set the agent configuration without password reset for the build process
    $AgentConfigSource = Join-Path -Path $Config.ConfigPath -ChildPath 'agent-config.yml'
    $EC2LaunchInfo = Get-EC2LaunchInfo
    $AgentConfigDest = $EC2LaunchInfo.ConfigPath
    $AgentConfigBackup = "$($AgentConfigDest).orig"

    Set-EC2LaunchConfigFile -SourcePath $AgentConfigSource -DestinationPath $AgentConfigDest -Backup

    # Validate the new configuration
    $NewConfigIsValid = $false
    try {
        Write-Output "Validating new agent configuration at $AgentConfigDest..."
        & $EC2LaunchInfo.EC2LaunchExe validate
        if ($LASTEXITCODE -eq 0) {
            $NewConfigIsValid = $true
            Write-Output "SUCCESS: New agent-config.yml validation passed and applied."
        }
        else {
            throw "New agent-config.yml validation failed with exit code $LASTEXITCODE."
        }
    }
    catch {
        Write-Warning "New agent configuration is invalid. Error: $($_.Exception.Message)"
    }

    # If the new config is invalid, attempt a rollback and recovery
    if (-not $NewConfigIsValid) {
        Write-Warning "Attempting to roll back to the original configuration..."
        if (Test-Path -Path $AgentConfigBackup) {
            Set-EC2LaunchConfigFile -SourcePath $AgentConfigBackup -DestinationPath $AgentConfigDest
            Write-Output "Rolled back to original configuration from $AgentConfigBackup."

            try {
                Write-Output "Validating the restored original configuration..."
                & $EC2LaunchInfo.EC2LaunchExe validate
                if ($LASTEXITCODE -ne 0) {
                    throw "Restored original configuration validation failed with exit code $LASTEXITCODE."
                }
                Write-Warning "[RECOVERED] Validation of restored configuration passed. Proceeding with original AWS settings."
            }
            catch {
                Write-Error "ERROR: The new configuration failed AND the restored original configuration also failed validation. Error: $($_.Exception.Message)"
                Write-Error "The build cannot continue with a valid EC2Launch configuration."
                exit 1
            }
        }
        else {
            Write-Error "ERROR: New configuration failed validation and there was no original configuration to roll back to."
            exit 1
        }
    }

    Write-Output "Configuring EC2Launch v2 service..."
    $Ec2LaunchService = Get-Service 'Amazon EC2Launch' -ErrorAction Stop

    if ($Ec2LaunchService.Status -eq 'Running') {
        Write-Output "Stopping EC2Launch service for configuration..."
        $Ec2LaunchService | Stop-Service -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $Ec2LaunchService | Set-Service -StartupType Automatic -ErrorAction Stop
    Write-Output "SUCCESS: EC2Launch service set to Automatic startup"

    $retryCount = 0
    $maxRetries = 3
    do {
        try {
            $Ec2LaunchService | Start-Service -ErrorAction Stop
            Write-Output "SUCCESS: EC2Launch service started successfully"
            break
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Error "ERROR: Failed to start EC2Launch service after $maxRetries attempts: $($_.Exception.Message)"
                exit 1
            }
            Write-Warning "Failed to start service (attempt $retryCount/$maxRetries), retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    } while ($retryCount -lt $maxRetries)

    # if (Test-Path $EC2LaunchInfo.RunOnceFlagPath) {
    #     Write-Output "Clearing .run-once flag to ensure UserData is handled on reboot."
    #     Remove-Item $EC2LaunchInfo.RunOnceFlagPath -Force -Verbose
    # } else {
    #     Write-Output "The .run-once flag not found, no need to clear."
    # }

    #----------------------------------------------------------------------
    # STAGE 2: Sysprep and Finalization
    #----------------------------------------------------------------------

    Write-Output "Starting EC2Launch sysprep process..."

    if ([System.Convert]::ToBoolean($Config.SkipSysprep)) {
        Write-Output "SKIP_SYSPREP is set to true. Sysprep will be skipped."
        return
    }

    Write-Output "Checking for pending reboots before sysprep..."
    $RebootStatus = Get-PendingReboot
    if ($RebootStatus.IsPending) {
        Write-Warning "Pending reboot detected due to: $($RebootStatus.Reasons -join ', ')"
        Write-Warning "Sysprep may fail. A reboot is highly recommended before running sysprep."
        Write-Warning "Continuing at user's risk..."
    }
    else {
        Write-Output "No pending reboots detected. Proceeding with sysprep."
    }

    Write-Output "Attempting to stop and disable Windows Update services..."
    Set-WindowsUpdateServices -ServiceNames @('wuauserv', 'bits')

    Write-Output "Collecting EC2Launch logs..."
    $ZipFile = Join-Path -Path $Config.LogsPath -ChildPath 'ec2launch-logs.zip'
    try {
        Write-Output "Executing command: '$($EC2LaunchInfo.EC2LaunchExe) collect-logs --output $ZipFile'"
        & $EC2LaunchInfo.EC2LaunchExe collect-logs --output $ZipFile
        if ($LASTEXITCODE -ne 0) {
            throw "External process '$($EC2LaunchInfo.EC2LaunchExe)' failed with exit code $LASTEXITCODE."
        }
        Write-Output "SUCCESS: Process '$($EC2LaunchInfo.EC2LaunchExe)' completed successfully with exit code $LASTEXITCODE."
    }
    catch {
        Write-Warning "EC2Launch log collection failed, but continuing. Error: $($_.Exception.Message)"
    }

    Write-Output "Starting system cleanup process..."

    # Put CrowdStrike sensor in provisioning mode for sysprep (belt-and-suspenders with NO_START=1)
    $FalconCtlPath = 'C:\Program Files\CrowdStrike\falconctl.exe'
    if (Test-Path $FalconCtlPath) {
        Write-Output "Setting CrowdStrike sensor to provisioning mode..."
        & $FalconCtlPath -provisioning
        Write-Output "CrowdStrike sensor set to provisioning mode for sysprep."
    } else {
        Write-Output "CrowdStrike not installed; skipping falconctl -provisioning."
    }

    # Disable Chef scheduled tasks — they use C:\chef\validator.pem which is removed below
    $ChefScheduledTasks = @('Chef-Client', 'Chef-Client-Log-Rotation')
    foreach ($TaskName in $ChefScheduledTasks) {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) {
            Disable-ScheduledTask -TaskName $TaskName
            Write-Output "Disabled scheduled task: $TaskName"
        }
    }

    $PathsToRemove = @(
        "C:\chef\validator.pem",
        "C:\chef\client.pem",
        "C:\ProgramData\Amazon\SSM\InstanceData\Vault\Store\EC2RegistrationKey",
        "$($env:USERPROFILE)\AppData\Local\Temp\*"
    )
    Invoke-SafeRemove -Path $PathsToRemove

    Write-Output "Setting unattend.xml for sysprep..."
    $UnattendConfigSource = Join-Path -Path $Config.ConfigPath -ChildPath 'unattend.xml'
    $SysprepUnattendDest = 'C:\ProgramData\Amazon\EC2Launch\sysprep\unattend.xml'
    Copy-Item -Path $UnattendConfigSource -Destination $SysprepUnattendDest -Force -ErrorAction Stop

    Write-Output "Resetting EC2Launch agent state..."
    try {
        Write-Output "Executing command: '$($EC2LaunchInfo.EC2LaunchExe) reset -c'"
        & $EC2LaunchInfo.EC2LaunchExe reset -c
        if ($LASTEXITCODE -ne 0) {
            throw "External process '$($EC2LaunchInfo.EC2LaunchExe)' failed with exit code $LASTEXITCODE."
        }
        Write-Output "SUCCESS: Process '$($EC2LaunchInfo.EC2LaunchExe)' completed successfully with exit code $LASTEXITCODE."
    }
    catch {
        Write-Error "ERROR: EC2Launch reset failed with exception: $($_.Exception.Message)"
        exit 1
    }

    Write-Output "Executing EC2Launch sysprep..."
    try {
        # The '--shutdown=false' argument tells EC2Launch to perform sysprep and then quit,
        # allowing Packer to handle the shutdown and AMI creation.
        Write-Output "Executing command: '$($EC2LaunchInfo.EC2LaunchExe) sysprep --shutdown=false'"
        & $EC2LaunchInfo.EC2LaunchExe sysprep --shutdown=false --clean
        if ($LASTEXITCODE -ne 0) {
            throw "External process '$($EC2LaunchInfo.EC2LaunchExe)' failed with exit code $LASTEXITCODE."
        }
        Write-Output "SUCCESS: Process '$($EC2LaunchInfo.EC2LaunchExe)' completed successfully with exit code $LASTEXITCODE."
    }
    catch {
        Write-Error "ERROR: EC2Launch sysprep failed with exception: $($_.Exception.Message)"
        exit 1
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
