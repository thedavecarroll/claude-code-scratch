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

    .PARAMETER ProfilePrefix
        Optional prefix for profile names (default: none)

    .PARAMETER DefaultRegion
        Default AWS region for profiles (default: us-east-1)

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start"

    .EXAMPLE
        Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start" -ProfilePrefix "company" -DefaultRegion "us-west-2"
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SsoStartUrl,

        [Parameter(Mandatory = $false)]
        [string]$SsoRegion = "us-east-1",

        [Parameter(Mandatory = $false)]
        [string]$ProfilePrefix = "",

        [Parameter(Mandatory = $false)]
        [string]$DefaultRegion = "us-east-1"
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

        # Step 4: Get accounts and roles
        Write-Host "[3/5] Retrieving available accounts and roles..." -ForegroundColor Yellow
        $accountsAndRoles = Get-SsoAccountsAndRoles -AccessToken $accessToken -SsoRegion $SsoRegion

        if ($accountsAndRoles.Count -eq 0) {
            Write-Warning "No accounts or roles found."
            return
        }

        # Step 5: Let user select roles
        Write-Host "[4/5] Available accounts and roles:" -ForegroundColor Yellow
        $selectedRoles = Show-RoleSelectionMenu -AccountsAndRoles $accountsAndRoles

        if ($selectedRoles.Count -eq 0) {
            Write-Warning "No roles selected. Configuration cancelled."
            return
        }

        # Step 6: Write to AWS config
        Write-Host "[5/5] Writing configuration to AWS config file..." -ForegroundColor Yellow
        Write-AwsConfig -SelectedRoles $selectedRoles -SsoStartUrl $SsoStartUrl -SsoRegion $SsoRegion -ProfilePrefix $ProfilePrefix -DefaultRegion $DefaultRegion

        Write-Host ""
        Write-Host "Configuration complete! Created $($selectedRoles.Count) profile(s)." -ForegroundColor Green
        Write-Host ""
        Write-Host "To use a profile, run:" -ForegroundColor Cyan
        Write-Host "  aws sso login --profile <profile-name>" -ForegroundColor White
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

    # Generate new profiles
    $newProfiles = @()

    foreach ($role in $SelectedRoles) {
        $profileName = if ($ProfilePrefix) {
            "$ProfilePrefix-$($role.AccountName)-$($role.RoleName)".ToLower() -replace '\s+', '-'
        }
        else {
            "$($role.AccountName)-$($role.RoleName)".ToLower() -replace '\s+', '-'
        }

        $profileConfig = @"

[profile $profileName]
sso_start_url = $SsoStartUrl
sso_region = $SsoRegion
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

    # Append new profiles to config
    if ($newProfiles.Count -gt 0) {
        Add-Content -Path $awsConfigPath -Value ($newProfiles -join "`n") -NoNewline
        Write-Host ""
        Write-Host "Configuration written to: $awsConfigPath" -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "No new profiles to add." -ForegroundColor Yellow
    }
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
