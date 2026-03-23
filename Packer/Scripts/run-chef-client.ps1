<#
.SYNOPSIS
    Configures and executes the Chef Infra Client on a Windows instance.
.DESCRIPTION
    This script orchestrates the Chef Infra Client run by performing several key setup tasks.
    It dynamically generates the necessary 'first-boot.json' and 'client.rb' configuration
    files based on the contents of the 'build-config.json' file. The script sources
    credentials, such as the validator key and the encrypted data bag secret, from a
    secure S3 bucket. It also ensures the Chef binary path is included in the system's
    environment variables for the client to run successfully.
.NOTES
    Updated with explicit permission handling for validator.pem to prevent
    NoMethodError in Chef 18 (OpenSSL 3.0.x).
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
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName "run-chef-client.ps1"

    if (-not $Config.Environment) {
        throw "Environment is not set in the build configuration."
    }
    Write-Output "ENVIRONMENT: $($Config.Environment)"

    if (-not ($Config.PSObject.Properties['ChefEnvironmentConfig']) -or -not $Config.ChefEnvironmentConfig) {
        throw "ChefEnvironmentConfig is not provided in the build configuration."
    }

    $CurrentChefConfig = $Config.ChefEnvironmentConfig

    $ChefBinPath = 'C:\opscode\chef\bin'
    $ChefConfigDir = 'C:\chef'

    $ChefClientPath = Join-Path $ChefBinPath 'chef-client.bat'
    if (-not(Test-Path $ChefClientPath)) {
        throw "Chef Client is not installed at the expected path: $ChefClientPath"
    }
    Write-Output "Chef Client found at: $ChefClientPath"

    if (-not (Test-Path $ChefConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ChefConfigDir
    }

    $CurrentPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if (-not ($CurrentPath -match [regex]::Escape($ChefBinPath))) {
        [Environment]::SetEnvironmentVariable('PATH', "$CurrentPath;$ChefBinPath", 'Machine')
        Write-Output 'Chef Client bin directory added to PATH.'
        $env:Path = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    }

    # Prevent Chef 18 cert-store auth bug: retrieve_certificate_key crashes when
    # PowerShell Export-PfxCertificate fails (returns $false, then ps_blob["PSPath"] raises NoMethodError).
    # Removing chef-* certs forces check_certstore_for_key to return false so Chef uses PEM file.
    Write-Output "Listing ALL certs in LocalMachine\My and CurrentUser\My..."
    Get-ChildItem -Path cert:\LocalMachine\My -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Output "  LocalMachine\My: $($_.Subject) ($($_.Thumbprint)) NotAfter: $($_.NotAfter.ToString('yyyy-MM-dd'))"
    }
    Get-ChildItem -Path cert:\CurrentUser\My -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Output "  CurrentUser\My: $($_.Subject) ($($_.Thumbprint)) NotAfter: $($_.NotAfter.ToString('yyyy-MM-dd'))"
    }
    Write-Output "Removing chef-* certs..."
    Get-ChildItem -Path cert:\LocalMachine\My, cert:\CurrentUser\My -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'chef-' } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Output "Copying Chef credentials from S3..."
    Copy-S3Object -BucketName $CurrentChefConfig.BucketName -Key "$($CurrentChefConfig.S3Prefix)/$($CurrentChefConfig.ValidationClientName).pem" -LocalFile "$ChefConfigDir/validator.pem"
    Copy-S3Object -BucketName $CurrentChefConfig.BucketName -Key "$($CurrentChefConfig.S3Prefix)/$($CurrentChefConfig.EncryptedDataBagSecret)" -LocalFile "$ChefConfigDir/encrypted_data_bag_secret"

    # --- VALIDATION COMPONENT FIX ---
    # Chef 18 (OpenSSL 3.0) requires explicit read access to the PEM file or load_signing_key returns false
    Write-Output "Setting explicit read permissions on validator.pem..."
    $Acl = Get-Acl "$ChefConfigDir/validator.pem"
    $Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "Read", "Allow")
    $Acl.SetAccessRule($Ar)
    Set-Acl "$ChefConfigDir/validator.pem" $Acl

    # Remove stale client.pem to ensure validator attempts a fresh registration (prevents 403/409 errors)
    if (Test-Path "$ChefConfigDir\client.pem") {
        Write-Output "Removing existing client.pem to force re-registration..."
        Remove-Item "$ChefConfigDir\client.pem" -Force
    }
    # ---------------------------------

    $FirstBoot = @{
        'chef_environment' = $CurrentChefConfig.ChefEnvironment
    }

    $runList = @()
    if ($Config.PSObject.Properties['ChefRunList'] -and $Config.ChefRunList) {
        if ($Config.ChefRunList -is [System.Array]) {
            $runList += $Config.ChefRunList
        }
        else {
            $runList += @($Config.ChefRunList)
        }
    }

    if ($runList.Count -eq 0) {
        throw "ChefRunList must contain at least one entry."
    }

    $FirstBoot['run_list'] = @($runList)

    if ($Config.PSObject.Properties['ChefAttributes'] -and $Config.ChefAttributes) {
        foreach ($property in $Config.ChefAttributes.psobject.Properties) {
            $key = $property.Name
            if ($key -eq 'run_list' -and $FirstBoot.ContainsKey('run_list')) {
                continue
            }
            $FirstBoot[$key] = $property.Value
        }
    }

    $jsonContent = $FirstBoot | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText("$($ChefConfigDir)\first-boot.json", $jsonContent, $encoding)

    $allowedChefLogLevels = @('auto', 'debug', 'info', 'warn', 'error', 'fatal')
    $chefLogLevel = 'info'
    if ($Config.PSObject.Properties['ChefLogLevel'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ChefLogLevel)) {
        $chefLogLevel = [string]$Config.ChefLogLevel.Trim().ToLowerInvariant()
    }
    if ($allowedChefLogLevels -notcontains $chefLogLevel) {
        throw "ChefLogLevel must be one of: $($allowedChefLogLevels -join ', '). Got: '$chefLogLevel'."
    }
    Write-Output "Chef client.rb log_level: :$chefLogLevel"

    $ClientRbContent = @"
log_level               :$chefLogLevel
log_location            STDOUT
chef_server_url         '$($CurrentChefConfig.ChefServerUrl)/$($CurrentChefConfig.ChefOrg)'
validation_client_name  '$($CurrentChefConfig.ValidationClientName)'
validation_key          '$ChefConfigDir\validator.pem'
node_name               '$($Config.ChefNodeName)'
chef_license            'accept'
enable_reporting        false
data_collector.mode     :solo
cookbook_sync_threads   1
encrypted_data_bag_secret '$ChefConfigDir\encrypted_data_bag_secret'
"@

    Write-Output "$($ChefConfigDir)\client.rb:"
    Write-Output $ClientRbContent
    Write-Output ''
    [System.IO.File]::WriteAllText("$($ChefConfigDir)\client.rb", $ClientRbContent, $encoding)

    Write-Output "Running Chef Client for $($Config.ChefNodeName)..."
    $ChefArgs = @(
        "-j", "`"$ChefConfigDir\first-boot.json`"",
        "-L", "`"$ChefConfigDir\chef-first-run.log`""
    )
    & $ChefClientPath @ChefArgs
    $chefExitCode = $LASTEXITCODE

    if ($chefExitCode -eq 0) {
        Write-Output "Chef Client run completed successfully."
    }
    elseif ($chefExitCode -eq 3010) {
        Write-Output "Chef Client run successful: A reboot is required (Exit Code 3010)."
        # We exit with 0 so Packer doesn't mark this specific provisioner as "Failed"
        exit 0
    }
    else {
        throw "Chef Client run failed with exit code: $chefExitCode"
    }

}
catch {
    $StackTracePath = Join-Path $ChefConfigDir 'cache\chef-stacktrace.out'
    if (Test-Path $StackTracePath) {
        Write-Output "--- Chef client stacktrace ---"
        Get-Content -Path $StackTracePath | Write-Output
        Write-Output "--- End of chef client stacktrace ---"
    }

    $ChefLogPath = Join-Path $ChefConfigDir 'chef-first-run.log'
    if (Test-Path $ChefLogPath) {
        Write-Output "--- Chef client log (last 50 lines) ---"
        Get-Content -Path $ChefLogPath -Tail 50 | Write-Output
        Write-Output "--- End of chef client log ---"
    }
    Write-DetailedError -ErrorRecord $_
    exit 1
}
finally {
    if ($TranscriptState) {
        Stop-PackerTranscript -TranscriptState $TranscriptState
    }
}
