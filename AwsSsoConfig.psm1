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

    # Read existing config if it exists
    $existingConfig = ""
    if (Test-Path $awsConfigPath) {
        $existingConfig = Get-Content $awsConfigPath -Raw
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
            Write-Host "  Skipped (already exists): $profileName" -ForegroundColor Yellow
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

Export-ModuleMember -Function Set-AwsSsoConfiguration
