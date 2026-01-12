function Set-AwsSsoConfiguration {
    <#
    .SYNOPSIS
        Configure AWS SSO profiles with minimal user interaction.

    .DESCRIPTION
        This function helps configure AWS SSO by:
        1. Authenticating to AWS SSO using device authorization flow
        2. Retrieving available accounts and roles
        3. Allowing user to select which profiles to configure
        4. Writing selected profiles to ~/.aws/config

        Compatible with PowerShell 5.1 and 7+

    .PARAMETER SsoStartUrl
        The AWS SSO start URL (e.g., https://my-sso-portal.awsapps.com/start)

    .PARAMETER SsoRegion
        The AWS region where SSO is configured (default: us-east-1)

    .PARAMETER ProfileNamingScheme
        Profile naming scheme. Options:
        - "AccountRole" (default): account-name-role-name
        - "AccountIdRole": 123456789012-role-name
        - "RoleAccount": role-name-account-name
        - "Custom": Use ProfileNameTemplate parameter

    .PARAMETER ProfileNameTemplate
        Custom template for profile names. Use placeholders:
        {AccountName}, {AccountId}, {RoleName}, {Prefix}
        Example: "{Prefix}-{AccountId}-{RoleName}"

    .PARAMETER ProfilePrefix
        Optional prefix for profile names (default: none)

    .PARAMETER DefaultRegion
        Default AWS region for profiles (default: us-east-1)

    .PARAMETER SessionName
        Optional custom SSO session name. Default: sso-session-{username}

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start"

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start" -ProfilePrefix "company" -DefaultRegion "us-west-2"

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start" -ProfileNamingScheme "AccountIdRole"

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start" -ProfileNamingScheme "Custom" -ProfileNameTemplate "{AccountId}-{RoleName}"
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SsoStartUrl,

        [Parameter(Mandatory = $false)]
        [string]$SsoRegion = "us-east-1",

        [Parameter(Mandatory = $false)]
        [ValidateSet("AccountRole", "AccountIdRole", "RoleAccount", "Custom")]
        [string]$ProfileNamingScheme = "AccountRole",

        [Parameter(Mandatory = $false)]
        [string]$ProfileNameTemplate = "",

        [Parameter(Mandatory = $false)]
        [string]$ProfilePrefix = "",

        [Parameter(Mandatory = $false)]
        [string]$DefaultRegion = "us-east-1",

        [Parameter(Mandatory = $false)]
        [string]$SessionName = ""
    )

    # Ensure cross-version compatibility
    $script:IsWindows = $PSVersionTable.Platform -eq 'Win32NT' -or $PSVersionTable.PSVersion.Major -le 5
    $script:IsLinux = $PSVersionTable.Platform -eq 'Unix' -and $PSVersionTable.OS -match 'Linux'
    $script:IsMacOS = $PSVersionTable.Platform -eq 'Unix' -and $PSVersionTable.OS -match 'Darwin'

    if ($PSVersionTable.PSVersion.Major -le 5) {
        $script:IsWindows = $true
    }

    try {
        Write-Host "AWS SSO Configuration Tool" -ForegroundColor Cyan
        Write-Host "=========================" -ForegroundColor Cyan
        Write-Host ""

        # Step 1: Register client
        Write-Host "[1/5] Registering SSO client..." -ForegroundColor Yellow
        $clientInfo = Register-SsoClient -SsoRegion $SsoRegion

        # Step 2: Start device authorization
        Write-Host "[2/5] Starting device authorization..." -ForegroundColor Yellow
        $deviceAuth = Start-DeviceAuthorization -ClientId $clientInfo.ClientId -ClientSecret $clientInfo.ClientSecret -SsoStartUrl $SsoStartUrl -SsoRegion $SsoRegion

        # Step 3: Wait for user authorization
        Write-Host ""
        Write-Host "Please authorize this application:" -ForegroundColor Green
        Write-Host "  1. Open this URL in your browser: $($deviceAuth.VerificationUriComplete)" -ForegroundColor White
        Write-Host "  2. Or go to: $($deviceAuth.VerificationUri)" -ForegroundColor White
        Write-Host "     And enter code: $($deviceAuth.UserCode)" -ForegroundColor White
        Write-Host ""
        Write-Host "Waiting for authorization..." -ForegroundColor Yellow

        $accessToken = Wait-ForDeviceAuthorization -ClientId $clientInfo.ClientId -ClientSecret $clientInfo.ClientSecret -DeviceCode $deviceAuth.DeviceCode -SsoRegion $SsoRegion

        Write-Host "Authorization successful!" -ForegroundColor Green
        Write-Host ""

        # Step 4: Get user identity for session naming
        Write-Host "[3/6] Retrieving user identity..." -ForegroundColor Yellow
        $userIdentity = Get-SsoUserIdentity -AccessToken $accessToken -SsoRegion $SsoRegion

        # Step 5: Get accounts and roles
        Write-Host "[4/6] Retrieving available accounts and roles..." -ForegroundColor Yellow
        $accountsAndRoles = Get-SsoAccountsAndRoles -AccessToken $accessToken -SsoRegion $SsoRegion

        if ($accountsAndRoles.Count -eq 0) {
            Write-Warning "No accounts or roles found."
            return
        }

        # Step 6: Let user select roles
        Write-Host "[5/6] Available accounts and roles:" -ForegroundColor Yellow
        $selectedRoles = Show-RoleSelectionMenu -AccountsAndRoles $accountsAndRoles

        if ($selectedRoles.Count -eq 0) {
            Write-Warning "No roles selected. Configuration cancelled."
            return
        }

        # Determine session name
        $finalSessionName = if ($SessionName) {
            $SessionName
        } else {
            "sso-session-$($userIdentity.Username)"
        }

        # Step 7: Write to AWS config
        Write-Host "[6/6] Writing configuration to AWS config file..." -ForegroundColor Yellow
        Write-AwsConfig -SelectedRoles $selectedRoles `
                       -SsoStartUrl $SsoStartUrl `
                       -SsoRegion $SsoRegion `
                       -SessionName $finalSessionName `
                       -ProfileNamingScheme $ProfileNamingScheme `
                       -ProfileNameTemplate $ProfileNameTemplate `
                       -ProfilePrefix $ProfilePrefix `
                       -DefaultRegion $DefaultRegion

        Write-Host ""
        Write-Host "Configuration complete!" -ForegroundColor Green
        Write-Host "  SSO Session: $finalSessionName" -ForegroundColor Cyan
        Write-Host "  Profiles Created: $($selectedRoles.Count)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "To use your profiles:" -ForegroundColor Yellow
        Write-Host "  aws sso login --sso-session $finalSessionName" -ForegroundColor White
        Write-Host "  aws s3 ls --profile <profile-name>" -ForegroundColor White

    }
    catch {
        Write-Error "Failed to configure AWS SSO: $_"
        Write-Error $_.Exception.Message
        if ($_.Exception.InnerException) {
            Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
        }
    }
}

function Register-SsoClient {
    param(
        [string]$SsoRegion
    )

    $endpoint = "https://oidc.$SsoRegion.amazonaws.com/client/register"

    $body = @{
        clientName = "PowerShell-AWS-SSO-Config"
        clientType = "public"
        scopes = @("sso:account:access")
    } | ConvertTo-Json

    $headers = @{
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethodCompat -Uri $endpoint -Method Post -Body $body -Headers $headers

    return @{
        ClientId = $response.clientId
        ClientSecret = $response.clientSecret
        ExpiresAt = $response.clientSecretExpiresAt
    }
}

function Start-DeviceAuthorization {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$SsoStartUrl,
        [string]$SsoRegion
    )

    $endpoint = "https://oidc.$SsoRegion.amazonaws.com/device_authorization"

    $body = @{
        clientId = $ClientId
        clientSecret = $ClientSecret
        startUrl = $SsoStartUrl
    } | ConvertTo-Json

    $headers = @{
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethodCompat -Uri $endpoint -Method Post -Body $body -Headers $headers

    return @{
        DeviceCode = $response.deviceCode
        UserCode = $response.userCode
        VerificationUri = $response.verificationUri
        VerificationUriComplete = $response.verificationUriComplete
        ExpiresIn = $response.expiresIn
        Interval = $response.interval
    }
}

function Wait-ForDeviceAuthorization {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$DeviceCode,
        [string]$SsoRegion
    )

    $endpoint = "https://oidc.$SsoRegion.amazonaws.com/token"

    $headers = @{
        "Content-Type" = "application/json"
    }

    $maxAttempts = 60
    $attempt = 0
    $interval = 5

    while ($attempt -lt $maxAttempts) {
        Start-Sleep -Seconds $interval
        $attempt++

        $body = @{
            clientId = $ClientId
            clientSecret = $ClientSecret
            deviceCode = $DeviceCode
            grantType = "urn:ietf:params:oauth:grant-type:device_code"
        } | ConvertTo-Json

        try {
            $response = Invoke-RestMethodCompat -Uri $endpoint -Method Post -Body $body -Headers $headers
            return $response.accessToken
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 400) {
                # Still waiting for authorization
                Write-Host "." -NoNewline
                continue
            }
            else {
                throw
            }
        }
    }

    throw "Device authorization timed out after $maxAttempts attempts"
}

function Get-SsoAccountsAndRoles {
    param(
        [string]$AccessToken,
        [string]$SsoRegion
    )

    $endpoint = "https://portal.sso.$SsoRegion.amazonaws.com/instance/appinstances"

    $headers = @{
        "x-amz-sso_bearer_token" = $AccessToken
    }

    $response = Invoke-RestMethodCompat -Uri $endpoint -Method Get -Headers $headers

    $allRoles = @()

    foreach ($appInstance in $response.result) {
        $accountEndpoint = "https://portal.sso.$SsoRegion.amazonaws.com/instance/appinstance/$($appInstance.id)/accounts"

        try {
            $accounts = Invoke-RestMethodCompat -Uri $accountEndpoint -Method Get -Headers $headers

            foreach ($account in $accounts.result) {
                $rolesEndpoint = "https://portal.sso.$SsoRegion.amazonaws.com/instance/appinstance/$($appInstance.id)/account/$($account.accountId)/roles"

                $roles = Invoke-RestMethodCompat -Uri $rolesEndpoint -Method Get -Headers $headers

                foreach ($role in $roles.result) {
                    $allRoles += @{
                        AccountId = $account.accountId
                        AccountName = $account.accountName
                        RoleName = $role.roleName
                        AppInstanceId = $appInstance.id
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not retrieve accounts for app instance: $($appInstance.id)"
        }
    }

    # Alternative approach using SSO API
    if ($allRoles.Count -eq 0) {
        $listAccountsEndpoint = "https://portal.sso.$SsoRegion.amazonaws.com/assignment/accounts"

        $accounts = Invoke-RestMethodCompat -Uri $listAccountsEndpoint -Method Get -Headers $headers

        foreach ($account in $accounts.accountList) {
            $rolesEndpoint = "https://portal.sso.$SsoRegion.amazonaws.com/assignment/roles?account_id=$($account.accountId)"

            $roles = Invoke-RestMethodCompat -Uri $rolesEndpoint -Method Get -Headers $headers

            foreach ($role in $roles.roleList) {
                $allRoles += @{
                    AccountId = $account.accountId
                    AccountName = $account.accountName
                    RoleName = $role.roleName
                }
            }
        }
    }

    return $allRoles
}

function Get-SsoUserIdentity {
    param(
        [string]$AccessToken,
        [string]$SsoRegion
    )

    $endpoint = "https://portal.sso.$SsoRegion.amazonaws.com/user"

    $headers = @{
        "x-amz-sso_bearer_token" = $AccessToken
    }

    try {
        $response = Invoke-RestMethodCompat -Uri $endpoint -Method Get -Headers $headers

        $username = if ($response.userName) {
            $response.userName
        } elseif ($response.emailAddress) {
            ($response.emailAddress -split '@')[0]
        } else {
            "user"
        }

        # Sanitize username for use in config
        $username = $username.ToLower() -replace '[^a-z0-9-]', '-'

        return @{
            Username = $username
            Email = $response.emailAddress
            DisplayName = $response.displayName
        }
    }
    catch {
        Write-Verbose "Could not retrieve user identity, using default session name"
        return @{
            Username = "default"
            Email = ""
            DisplayName = ""
        }
    }
}

function Show-RoleSelectionMenu {
    param(
        [array]$AccountsAndRoles
    )

    Write-Host ""
    Write-Host "Available Accounts and Roles:" -ForegroundColor Cyan
    Write-Host "=============================" -ForegroundColor Cyan
    Write-Host ""

    $index = 1
    $menuItems = @()

    foreach ($item in $AccountsAndRoles) {
        $displayName = "$($item.AccountName) ($($item.AccountId)) - $($item.RoleName)"
        Write-Host "  [$index] $displayName" -ForegroundColor White
        $menuItems += @{
            Index = $index
            Item = $item
            DisplayName = $displayName
        }
        $index++
    }

    Write-Host ""
    Write-Host "Enter selections (comma-separated numbers, 'all' for all, or 'q' to quit):" -ForegroundColor Yellow
    Write-Host "Example: 1,3,5 or all" -ForegroundColor Gray
    Write-Host ""

    $selection = Read-Host "Selection"

    if ($selection -eq 'q') {
        return @()
    }

    $selectedRoles = @()

    if ($selection -eq 'all') {
        $selectedRoles = $AccountsAndRoles
    }
    else {
        $selections = $selection -split ',' | ForEach-Object { $_.Trim() }

        foreach ($sel in $selections) {
            if ($sel -match '^\d+$') {
                $idx = [int]$sel
                $menuItem = $menuItems | Where-Object { $_.Index -eq $idx }
                if ($menuItem) {
                    $selectedRoles += $menuItem.Item
                }
                else {
                    Write-Warning "Invalid selection: $sel"
                }
            }
            else {
                Write-Warning "Invalid input: $sel"
            }
        }
    }

    return $selectedRoles
}

function Write-AwsConfig {
    param(
        [array]$SelectedRoles,
        [string]$SsoStartUrl,
        [string]$SsoRegion,
        [string]$SessionName,
        [string]$ProfileNamingScheme,
        [string]$ProfileNameTemplate,
        [string]$ProfilePrefix,
        [string]$DefaultRegion
    )

    # Determine AWS config path
    if ($script:IsWindows) {
        $awsConfigDir = Join-Path $env:USERPROFILE ".aws"
    }
    else {
        $awsConfigDir = Join-Path $env:HOME ".aws"
    }

    $awsConfigPath = Join-Path $awsConfigDir "config"

    # Create .aws directory if it doesn't exist
    if (-not (Test-Path $awsConfigDir)) {
        New-Item -ItemType Directory -Path $awsConfigDir -Force | Out-Null
    }

    # Read existing config if it exists and warn user
    $existingConfig = ""
    $configFileExists = Test-Path $awsConfigPath

    if ($configFileExists) {
        $existingConfig = Get-Content $awsConfigPath -Raw
        Write-Host ""
        Write-Host "WARNING: AWS config file already exists at: $awsConfigPath" -ForegroundColor Yellow
        Write-Host "Existing profiles may be overwritten if you confirm." -ForegroundColor Yellow
        Write-Host ""
    }

    # Create SSO session if it doesn't exist
    $sessionConfig = ""
    if ($existingConfig -notmatch "\[sso-session $SessionName\]") {
        $sessionConfig = @"

[sso-session $SessionName]
sso_start_url = $SsoStartUrl
sso_region = $SsoRegion
sso_registration_scopes = sso:account:access
"@
        Write-Host "  Added SSO session: $SessionName" -ForegroundColor Green
    }
    else {
        Write-Host "  SSO session already exists: $SessionName" -ForegroundColor Yellow
    }

    # Generate new profiles
    $newProfiles = @()
    $profilesToOverwrite = @()
    $overwriteAll = $false
    $skipAll = $false

    foreach ($role in $SelectedRoles) {
        $profileName = Get-ProfileName -Role $role `
                                       -Scheme $ProfileNamingScheme `
                                       -Template $ProfileNameTemplate `
                                       -Prefix $ProfilePrefix

        $profileConfig = @"

[profile $profileName]
sso_session = $SessionName
sso_account_id = $($role.AccountId)
sso_role_name = $($role.RoleName)
region = $DefaultRegion
output = json
"@

        # Check if profile already exists in config
        if ($existingConfig -notmatch "\[profile $profileName\]") {
            $newProfiles += $profileConfig
            Write-Host "  Added profile: $profileName" -ForegroundColor Green
        }
        else {
            # Profile exists - ask for confirmation
            $shouldOverwrite = $false

            if ($overwriteAll) {
                $shouldOverwrite = $true
                Write-Host "  Overwriting profile: $profileName" -ForegroundColor Cyan
            }
            elseif ($skipAll) {
                Write-Host "  Skipped (already exists): $profileName" -ForegroundColor Yellow
            }
            else {
                Write-Host ""
                Write-Host "  Profile '$profileName' already exists." -ForegroundColor Yellow
                Write-Host "    Account: $($role.AccountId)" -ForegroundColor Gray
                Write-Host "    Role: $($role.RoleName)" -ForegroundColor Gray
                Write-Host ""

                $response = ""
                while ($response -notin @('y', 'n', 'a', 's')) {
                    $response = (Read-Host "  Overwrite? (Y)es, (N)o, (A)ll, (S)kip all [default: N]").ToLower()
                    if ([string]::IsNullOrWhiteSpace($response)) {
                        $response = 'n'
                    }
                }

                switch ($response) {
                    'y' {
                        $shouldOverwrite = $true
                        Write-Host "  Overwriting profile: $profileName" -ForegroundColor Cyan
                    }
                    'a' {
                        $overwriteAll = $true
                        $shouldOverwrite = $true
                        Write-Host "  Overwriting profile: $profileName (and all subsequent)" -ForegroundColor Cyan
                    }
                    's' {
                        $skipAll = $true
                        Write-Host "  Skipped (and skipping all subsequent): $profileName" -ForegroundColor Yellow
                    }
                    'n' {
                        Write-Host "  Skipped: $profileName" -ForegroundColor Yellow
                    }
                }
            }

            if ($shouldOverwrite) {
                $profilesToOverwrite += @{
                    ProfileName = $profileName
                    Config = $profileConfig
                }
            }
        }
    }

    # Handle profiles to overwrite
    if ($profilesToOverwrite.Count -gt 0) {
        Write-Host ""
        Write-Host "Processing overwrite operations..." -ForegroundColor Cyan

        foreach ($item in $profilesToOverwrite) {
            # Remove old profile section from config
            $profilePattern = "(?ms)\[profile $($item.ProfileName)\].*?(?=\n\[|\z)"
            $existingConfig = $existingConfig -replace $profilePattern, ""
        }

        # Write updated config back (without old profiles)
        Set-Content -Path $awsConfigPath -Value $existingConfig.TrimEnd() -NoNewline

        # Add overwritten profiles to new profiles list
        foreach ($item in $profilesToOverwrite) {
            $newProfiles += $item.Config
        }
    }

    # Append session and profiles to config
    $configToAdd = @()
    if ($sessionConfig) {
        $configToAdd += $sessionConfig
    }
    if ($newProfiles.Count -gt 0) {
        $configToAdd += $newProfiles
    }

    if ($configToAdd.Count -gt 0) {
        Add-Content -Path $awsConfigPath -Value ($configToAdd -join "`n") -NoNewline
        Write-Host ""
        Write-Host "Configuration written to: $awsConfigPath" -ForegroundColor Green

        # Summary
        $addedCount = $newProfiles.Count - $profilesToOverwrite.Count
        $overwrittenCount = $profilesToOverwrite.Count

        if ($addedCount -gt 0) {
            Write-Host "  New profiles added: $addedCount" -ForegroundColor Green
        }
        if ($overwrittenCount -gt 0) {
            Write-Host "  Profiles overwritten: $overwrittenCount" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host ""
        Write-Host "No new configuration to add." -ForegroundColor Yellow
    }
}

function Get-ProfileName {
    param(
        [hashtable]$Role,
        [string]$Scheme,
        [string]$Template,
        [string]$Prefix
    )

    # Sanitize components
    $accountName = $Role.AccountName.ToLower() -replace '\s+', '-' -replace '[^a-z0-9-]', ''
    $accountId = $Role.AccountId
    $roleName = $Role.RoleName.ToLower() -replace '\s+', '-' -replace '[^a-z0-9-]', ''

    $profileName = switch ($Scheme) {
        "AccountRole" {
            if ($Prefix) {
                "$Prefix-$accountName-$roleName"
            } else {
                "$accountName-$roleName"
            }
        }
        "AccountIdRole" {
            if ($Prefix) {
                "$Prefix-$accountId-$roleName"
            } else {
                "$accountId-$roleName"
            }
        }
        "RoleAccount" {
            if ($Prefix) {
                "$Prefix-$roleName-$accountName"
            } else {
                "$roleName-$accountName"
            }
        }
        "Custom" {
            if (-not $Template) {
                throw "ProfileNameTemplate is required when using Custom naming scheme"
            }
            $name = $Template
            $name = $name -replace '\{AccountName\}', $accountName
            $name = $name -replace '\{AccountId\}', $accountId
            $name = $name -replace '\{RoleName\}', $roleName
            $name = $name -replace '\{Prefix\}', $Prefix
            $name.ToLower()
        }
        default {
            if ($Prefix) {
                "$Prefix-$accountName-$roleName"
            } else {
                "$accountName-$roleName"
            }
        }
    }

    return $profileName
}

function Invoke-RestMethodCompat {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$Body
    )

    # PowerShell 5.1 compatibility
    if ($PSVersionTable.PSVersion.Major -le 5) {
        # Force TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    $params = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ContentType = "application/json"
    }

    if ($Body) {
        $params['Body'] = $Body
    }

    # Add error handling for both PS versions
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params['SkipHttpErrorCheck'] = $false
        }

        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        if ($_.ErrorDetails.Message) {
            $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errorDetail.error -eq 'authorization_pending') {
                # Re-throw for device auth polling
                throw $_
            }
        }
        throw
    }
}

function Get-AwsSsoConfiguration {
    <#
    .SYNOPSIS
        Retrieves and displays AWS SSO configuration from ~/.aws/config

    .DESCRIPTION
        Reads the AWS CLI config file and parses SSO sessions and SSO-enabled profiles.
        Returns structured information about configured SSO sessions and their associated profiles.

        Compatible with PowerShell 5.1 and 7+

    .PARAMETER SessionName
        Optional filter to show only profiles for a specific SSO session

    .PARAMETER Format
        Output format: Object (default), Table, or Json
        - Object: Returns PowerShell objects for programmatic use
        - Table: Displays formatted table to console
        - Json: Returns JSON string

    .EXAMPLE
        Get-AwsSsoConfiguration

        Returns all SSO sessions and profiles as objects

    .EXAMPLE
        Get-AwsSsoConfiguration -Format Table

        Displays all SSO sessions and profiles in a formatted table

    .EXAMPLE
        Get-AwsSsoConfiguration -SessionName "sso-session-jdoe"

        Returns only profiles using the specified SSO session

    .EXAMPLE
        Get-AwsSsoConfiguration -Format Json

        Returns configuration as JSON for export or integration
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SessionName = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet("Object", "Table", "Json")]
        [string]$Format = "Object"
    )

    # Ensure cross-version compatibility
    $isWindows = $PSVersionTable.Platform -eq 'Win32NT' -or $PSVersionTable.PSVersion.Major -le 5
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $isWindows = $true
    }

    try {
        # Determine AWS config path
        if ($isWindows) {
            $awsConfigDir = Join-Path $env:USERPROFILE ".aws"
        }
        else {
            $awsConfigDir = Join-Path $env:HOME ".aws"
        }

        $awsConfigPath = Join-Path $awsConfigDir "config"

        # Check if config file exists
        if (-not (Test-Path $awsConfigPath)) {
            Write-Warning "AWS config file not found at: $awsConfigPath"
            Write-Host "Run Set-AwsSsoConfiguration to create your first configuration." -ForegroundColor Yellow
            return $null
        }

        # Check if file is readable
        try {
            $configContent = Get-Content $awsConfigPath -Raw -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-Error "Permission denied: Cannot read $awsConfigPath"
            Write-Error "Check file permissions and try again."
            return $null
        }
        catch {
            Write-Error "Failed to read config file: $_"
            return $null
        }

        # Check if file is empty
        if ([string]::IsNullOrWhiteSpace($configContent)) {
            Write-Warning "AWS config file is empty: $awsConfigPath"
            return $null
        }

        # Parse the config file
        $parsedConfig = Parse-AwsConfig -ConfigContent $configContent

        if (-not $parsedConfig) {
            Write-Warning "No valid configuration found in $awsConfigPath"
            return $null
        }

        # Filter by session name if specified
        if ($SessionName) {
            $parsedConfig.Profiles = $parsedConfig.Profiles | Where-Object {
                $_.SsoSession -eq $SessionName
            }

            $parsedConfig.Sessions = $parsedConfig.Sessions | Where-Object {
                $_.Name -eq $SessionName
            }

            if ($parsedConfig.Sessions.Count -eq 0) {
                Write-Warning "SSO session not found: $SessionName"
                return $null
            }
        }

        # Return based on format
        switch ($Format) {
            "Table" {
                Show-SsoConfigTable -Config $parsedConfig
                return
            }
            "Json" {
                return ($parsedConfig | ConvertTo-Json -Depth 10)
            }
            default {
                return $parsedConfig
            }
        }
    }
    catch {
        Write-Error "Failed to retrieve AWS SSO configuration: $_"
        Write-Error $_.Exception.Message
        if ($_.Exception.InnerException) {
            Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
        }
        return $null
    }
}

function Parse-AwsConfig {
    param(
        [string]$ConfigContent
    )

    try {
        $sessions = @()
        $profiles = @()

        # Split content into lines
        $lines = $ConfigContent -split "`r?`n"

        $currentSection = $null
        $currentSectionData = @{}

        foreach ($line in $lines) {
            # Trim whitespace
            $line = $line.Trim()

            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
                continue
            }

            # Check for section header
            if ($line -match '^\[(.+)\]$') {
                # Save previous section if exists
                if ($currentSection) {
                    Save-ConfigSection -SectionName $currentSection -SectionData $currentSectionData -Sessions ([ref]$sessions) -Profiles ([ref]$profiles)
                }

                # Start new section
                $currentSection = $matches[1]
                $currentSectionData = @{}
            }
            # Parse key-value pair
            elseif ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $currentSectionData[$key] = $value
            }
        }

        # Save last section
        if ($currentSection) {
            Save-ConfigSection -SectionName $currentSection -SectionData $currentSectionData -Sessions ([ref]$sessions) -Profiles ([ref]$profiles)
        }

        return @{
            ConfigPath = (Get-AwsConfigPath)
            Sessions = $sessions
            Profiles = $profiles
            TotalSessions = $sessions.Count
            TotalProfiles = $profiles.Count
        }
    }
    catch {
        Write-Error "Failed to parse AWS config: $_"
        return $null
    }
}

function Save-ConfigSection {
    param(
        [string]$SectionName,
        [hashtable]$SectionData,
        [ref]$Sessions,
        [ref]$Profiles
    )

    try {
        # SSO Session
        if ($SectionName -match '^sso-session\s+(.+)$') {
            $sessionName = $matches[1].Trim()

            $session = [PSCustomObject]@{
                Name = $sessionName
                SsoStartUrl = $SectionData['sso_start_url']
                SsoRegion = $SectionData['sso_region']
                SsoRegistrationScopes = $SectionData['sso_registration_scopes']
            }

            $Sessions.Value += $session
        }
        # Profile (with or without SSO)
        elseif ($SectionName -match '^profile\s+(.+)$') {
            $profileName = $matches[1].Trim()

            # Check if it's an SSO profile
            $isSsoProfile = $SectionData.ContainsKey('sso_session') -or
                           $SectionData.ContainsKey('sso_start_url') -or
                           $SectionData.ContainsKey('sso_account_id')

            if ($isSsoProfile) {
                $profile = [PSCustomObject]@{
                    ProfileName = $profileName
                    SsoSession = $SectionData['sso_session']
                    SsoStartUrl = $SectionData['sso_start_url']
                    SsoRegion = $SectionData['sso_region']
                    SsoAccountId = $SectionData['sso_account_id']
                    SsoRoleName = $SectionData['sso_role_name']
                    Region = $SectionData['region']
                    Output = $SectionData['output']
                    Type = if ($SectionData['sso_session']) { "Modern" } else { "Legacy" }
                }

                $Profiles.Value += $profile
            }
        }
        # Default profile (no "profile" prefix)
        elseif ($SectionName -eq 'default') {
            $isSsoProfile = $SectionData.ContainsKey('sso_session') -or
                           $SectionData.ContainsKey('sso_start_url') -or
                           $SectionData.ContainsKey('sso_account_id')

            if ($isSsoProfile) {
                $profile = [PSCustomObject]@{
                    ProfileName = 'default'
                    SsoSession = $SectionData['sso_session']
                    SsoStartUrl = $SectionData['sso_start_url']
                    SsoRegion = $SectionData['sso_region']
                    SsoAccountId = $SectionData['sso_account_id']
                    SsoRoleName = $SectionData['sso_role_name']
                    Region = $SectionData['region']
                    Output = $SectionData['output']
                    Type = if ($SectionData['sso_session']) { "Modern" } else { "Legacy" }
                }

                $Profiles.Value += $profile
            }
        }
    }
    catch {
        Write-Verbose "Error saving section $SectionName: $_"
    }
}

function Show-SsoConfigTable {
    param(
        [hashtable]$Config
    )

    Write-Host ""
    Write-Host "AWS SSO Configuration" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    Write-Host "Config File: $($Config.ConfigPath)" -ForegroundColor Gray
    Write-Host ""

    # Display SSO Sessions
    if ($Config.Sessions.Count -gt 0) {
        Write-Host "SSO Sessions ($($Config.Sessions.Count)):" -ForegroundColor Yellow
        Write-Host ""

        foreach ($session in $Config.Sessions) {
            Write-Host "  Session: $($session.Name)" -ForegroundColor White
            Write-Host "    Start URL: $($session.SsoStartUrl)" -ForegroundColor Gray
            Write-Host "    Region: $($session.SsoRegion)" -ForegroundColor Gray
            if ($session.SsoRegistrationScopes) {
                Write-Host "    Scopes: $($session.SsoRegistrationScopes)" -ForegroundColor Gray
            }

            # Count profiles using this session
            $profileCount = ($Config.Profiles | Where-Object { $_.SsoSession -eq $session.Name }).Count
            Write-Host "    Profiles: $profileCount" -ForegroundColor Gray
            Write-Host ""
        }
    }
    else {
        Write-Host "No SSO sessions found." -ForegroundColor Yellow
        Write-Host ""
    }

    # Display SSO Profiles
    if ($Config.Profiles.Count -gt 0) {
        Write-Host "SSO Profiles ($($Config.Profiles.Count)):" -ForegroundColor Yellow
        Write-Host ""

        # Group by session for better readability
        $groupedProfiles = $Config.Profiles | Group-Object -Property SsoSession

        foreach ($group in $groupedProfiles) {
            $sessionName = if ($group.Name) { $group.Name } else { "Legacy (no session)" }
            Write-Host "  Session: $sessionName" -ForegroundColor Cyan

            foreach ($profile in $group.Group) {
                Write-Host "    Profile: $($profile.ProfileName)" -ForegroundColor White
                Write-Host "      Account: $($profile.SsoAccountId)" -ForegroundColor Gray
                Write-Host "      Role: $($profile.SsoRoleName)" -ForegroundColor Gray
                Write-Host "      Region: $($profile.Region)" -ForegroundColor Gray
                Write-Host "      Type: $($profile.Type)" -ForegroundColor Gray
                Write-Host ""
            }
        }
    }
    else {
        Write-Host "No SSO profiles found." -ForegroundColor Yellow
        Write-Host ""
    }

    # Usage instructions
    Write-Host "Usage:" -ForegroundColor Green
    if ($Config.Sessions.Count -gt 0) {
        $firstSession = $Config.Sessions[0].Name
        Write-Host "  aws sso login --sso-session $firstSession" -ForegroundColor White
    }
    if ($Config.Profiles.Count -gt 0) {
        $firstProfile = $Config.Profiles[0].ProfileName
        Write-Host "  aws s3 ls --profile $firstProfile" -ForegroundColor White
    }
    Write-Host ""
}

function Get-AwsConfigPath {
    $isWindows = $PSVersionTable.Platform -eq 'Win32NT' -or $PSVersionTable.PSVersion.Major -le 5
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $isWindows = $true
    }

    if ($isWindows) {
        $awsConfigDir = Join-Path $env:USERPROFILE ".aws"
    }
    else {
        $awsConfigDir = Join-Path $env:HOME ".aws"
    }

    return (Join-Path $awsConfigDir "config")
}

Export-ModuleMember -Function Set-AwsSsoConfiguration, Get-AwsSsoConfiguration
