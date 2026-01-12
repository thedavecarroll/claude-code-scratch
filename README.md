# AWS SSO Configuration PowerShell Module

A PowerShell module to configure AWS SSO (SAML) profiles with minimal user interaction. Compatible with PowerShell 5.1 and 7+.

## Features

- **SSO Session Management**: Creates reusable SSO sessions that multiple profiles reference
- **Configuration Retrieval**: View and query existing SSO configuration with multiple output formats
- **Automatic Session Naming**: Session named `sso-session-{username}` based on your SSO identity
- **Device Authorization Flow**: Secure authentication using AWS SSO device authorization
- **Automatic Discovery**: Retrieves all available AWS accounts and roles
- **Interactive Selection**: Simple menu to select which profiles to configure
- **Flexible Profile Naming**: Multiple naming schemes (AccountRole, AccountIdRole, RoleAccount, Custom)
- **AWS Config Format**: Writes profiles directly to `~/.aws/config` using modern SSO session format
- **Comprehensive Error Handling**: Detailed error messages for troubleshooting
- **Cross-Platform**: Works on Windows, Linux, and macOS
- **Dual Version Support**: Compatible with PowerShell 5.1 and 7+

## Requirements

- PowerShell 5.1 or higher
- Internet connection to AWS SSO endpoints
- AWS SSO portal URL (provided by your AWS administrator)

## Installation

### Option 1: Import from Local Path

```powershell
Import-Module ./AwsSsoConfig.psd1
```

### Option 2: Copy to Modules Directory

**Windows:**
```powershell
$modulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\AwsSsoConfig"
New-Item -ItemType Directory -Path $modulePath -Force
Copy-Item AwsSsoConfig.* $modulePath
Import-Module AwsSsoConfig
```

**Linux/macOS:**
```bash
mkdir -p ~/.local/share/powershell/Modules/AwsSsoConfig
cp AwsSsoConfig.* ~/.local/share/powershell/Modules/AwsSsoConfig/
pwsh -c "Import-Module AwsSsoConfig"
```

## Usage

### Setting Up SSO Configuration

```powershell
Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start"
```

### Viewing Existing Configuration

```powershell
# Display as formatted table
Get-AwsSsoConfiguration -Format Table

# Get as objects for scripting
$config = Get-AwsSsoConfiguration

# Get specific session
Get-AwsSsoConfiguration -SessionName "sso-session-jdoe" -Format Table

# Export as JSON
Get-AwsSsoConfiguration -Format Json | Out-File config-backup.json
```

### With Custom Options

```powershell
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -SsoRegion "us-west-2" `
    -ProfilePrefix "mycompany" `
    -DefaultRegion "eu-west-1"
```

### With Different Profile Naming Schemes

```powershell
# Use AccountId-RoleName format (e.g., 123456789012-administrator)
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -ProfileNamingScheme "AccountIdRole"

# Use RoleName-AccountName format (e.g., administrator-production)
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -ProfileNamingScheme "RoleAccount"

# Custom template
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -ProfileNamingScheme "Custom" `
    -ProfileNameTemplate "{Prefix}-{AccountId}-{RoleName}" `
    -ProfilePrefix "acme"
```

### With Custom Session Name

```powershell
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -SessionName "my-custom-session"
```

## Workflow

The function follows these steps:

1. **Register SSO Client**: Creates a temporary OIDC client with AWS
2. **Device Authorization**: Generates a device code and user code
3. **User Authentication**: Displays a URL for browser-based authentication
4. **Token Retrieval**: Polls for access token after user authorizes
5. **User Identity**: Retrieves your username for session naming
6. **Account/Role Discovery**: Retrieves all available AWS accounts and roles
7. **Interactive Selection**: Presents a menu to select desired profiles
8. **Config Writing**: Creates SSO session and writes profiles to `~/.aws/config`

## Interactive Selection

When prompted, you can:

- Enter specific numbers: `1,3,5`
- Select all roles: `all`
- Quit without saving: `q`

Example output:
```
Available Accounts and Roles:
=============================

  [1] Production-Account (123456789012) - Administrator
  [2] Production-Account (123456789012) - ReadOnly
  [3] Development-Account (987654321098) - Developer
  [4] Development-Account (987654321098) - ReadOnly

Enter selections (comma-separated numbers, 'all' for all, or 'q' to quit):
Example: 1,3,5 or all

Selection: 1,3
```

## Generated Config Format

The module writes an SSO session and profiles to `~/.aws/config` in modern AWS CLI format:

```ini
[sso-session sso-session-jdoe]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile mycompany-production-account-administrator]
sso_session = sso-session-jdoe
sso_account_id = 123456789012
sso_role_name = Administrator
region = us-east-1
output = json

[profile mycompany-development-account-developer]
sso_session = sso-session-jdoe
sso_account_id = 987654321098
sso_role_name = Developer
region = us-east-1
output = json
```

**Key Benefits:**
- Single SSO session shared by all profiles
- Login once with `aws sso login --sso-session sso-session-jdoe`
- All profiles using that session are authenticated
- No need to login separately for each profile

## Using Configured Profiles

After configuration, use AWS CLI with your new profiles:

```bash
# Login to SSO session (authenticates ALL profiles using this session)
aws sso login --sso-session sso-session-jdoe

# Use any profile - already authenticated!
aws s3 ls --profile mycompany-production-account-administrator
aws ec2 describe-instances --profile mycompany-development-account-developer

# You can also login using a specific profile
aws sso login --profile mycompany-production-account-administrator
```

## SSO Session Benefits

The module uses AWS CLI's modern SSO session feature, which provides several advantages:

1. **Single Authentication**: Login once to authenticate all profiles sharing the session
2. **Better Token Management**: AWS CLI handles token refresh automatically
3. **Simplified Workflow**: No need to remember which profile you're using
4. **Multiple SSO Portals**: Create different sessions for different organizations

### Working with Multiple SSO Portals

If you work with multiple AWS organizations:

```powershell
# Configure Company A profiles
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://companyA.awsapps.com/start" `
    -ProfilePrefix "companyA" `
    -SessionName "companya-session"

# Configure Company B profiles
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://companyB.awsapps.com/start" `
    -ProfilePrefix "companyB" `
    -SessionName "companyb-session"
```

Then login to each organization separately:
```bash
aws sso login --sso-session companya-session
aws sso login --sso-session companyb-session
```

## Profile Naming Schemes

Choose the naming scheme that works best for your workflow:

### AccountRole (Default)
Best for: Human-readable profile names
```
production-administrator
development-readonly
staging-developer
```

### AccountIdRole
Best for: When account names are ambiguous or change
```
123456789012-administrator
987654321098-readonly
555666777888-developer
```

### RoleAccount
Best for: When you primarily switch between roles
```
administrator-production
readonly-development
developer-staging
```

### Custom
Best for: Specific organizational standards
```powershell
# Example: Prefix-AccountId-Role format
-ProfileNamingScheme "Custom" `
-ProfileNameTemplate "{Prefix}-{AccountId}-{RoleName}" `
-ProfilePrefix "acme"

# Results in: acme-123456789012-administrator
```

## Parameters

### `-SsoStartUrl` (Required)
Your AWS SSO portal start URL. Get this from your AWS administrator.

Example: `https://my-sso-portal.awsapps.com/start`

### `-SsoRegion` (Optional)
AWS region where SSO is configured. Default: `us-east-1`

### `-ProfileNamingScheme` (Optional)
Profile naming format. Default: `AccountRole`

Options:
- **AccountRole**: `account-name-role-name` (e.g., `production-administrator`)
- **AccountIdRole**: `123456789012-role-name` (e.g., `123456789012-administrator`)
- **RoleAccount**: `role-name-account-name` (e.g., `administrator-production`)
- **Custom**: Use `-ProfileNameTemplate` to define your own format

### `-ProfileNameTemplate` (Optional)
Custom template for profile names (use with `-ProfileNamingScheme Custom`)

Available placeholders:
- `{AccountName}`: AWS account name
- `{AccountId}`: AWS account ID (12 digits)
- `{RoleName}`: IAM role name
- `{Prefix}`: Value from `-ProfilePrefix`

Example: `"{Prefix}-{AccountId}-{RoleName}"` → `acme-123456789012-administrator`

### `-ProfilePrefix` (Optional)
Prefix to add to profile names. Default: none

Example: `mycompany` → `mycompany-production-administrator`

### `-DefaultRegion` (Optional)
Default AWS region for all profiles. Default: `us-east-1`

### `-SessionName` (Optional)
Custom SSO session name. Default: `sso-session-{username}`

Example: `my-team-session`

## Get-AwsSsoConfiguration Function

The `Get-AwsSsoConfiguration` function retrieves and displays your existing AWS SSO configuration.

### Features

- **Parse AWS Config**: Reads and parses `~/.aws/config` file
- **Multiple Output Formats**: Object, Table, or JSON
- **Session Filtering**: Filter profiles by SSO session name
- **Error Handling**: Comprehensive error handling for missing/invalid config
- **Legacy Support**: Detects both modern (sso_session) and legacy profiles

### Parameters

#### `-SessionName` (Optional)
Filter to show only profiles for a specific SSO session.

Example: `Get-AwsSsoConfiguration -SessionName "sso-session-jdoe"`

#### `-Format` (Optional)
Output format. Default: `Object`

Options:
- **Object**: Returns PowerShell objects (default) - best for scripting
- **Table**: Displays formatted console output - best for viewing
- **Json**: Returns JSON string - best for export/integration

### Output Structure

When using `-Format Object`, returns a hashtable with:

```powershell
@{
    ConfigPath = "~/.aws/config"        # Path to config file
    Sessions = @(...)                    # Array of SSO session objects
    Profiles = @(...)                    # Array of SSO profile objects
    TotalSessions = 2                    # Count of sessions
    TotalProfiles = 15                   # Count of profiles
}
```

Each **Session** object contains:
- `Name`: Session name
- `SsoStartUrl`: SSO portal URL
- `SsoRegion`: AWS region
- `SsoRegistrationScopes`: OAuth scopes

Each **Profile** object contains:
- `ProfileName`: Profile name
- `SsoSession`: Referenced session name
- `SsoAccountId`: AWS account ID
- `SsoRoleName`: IAM role name
- `Region`: Default AWS region
- `Output`: Output format
- `Type`: "Modern" (uses sso_session) or "Legacy" (uses sso_start_url)

### Examples

#### Display as Table
```powershell
Get-AwsSsoConfiguration -Format Table
```

Output:
```
AWS SSO Configuration
=====================
Config File: /home/user/.aws/config

SSO Sessions (2):

  Session: sso-session-jdoe
    Start URL: https://mycompany.awsapps.com/start
    Region: us-east-1
    Scopes: sso:account:access
    Profiles: 8

  Session: sso-session-admin
    Start URL: https://admin.awsapps.com/start
    Region: us-west-2
    Scopes: sso:account:access
    Profiles: 4

SSO Profiles (12):

  Session: sso-session-jdoe
    Profile: production-administrator
      Account: 123456789012
      Role: Administrator
      Region: us-east-1
      Type: Modern
    ...
```

#### Get as Objects for Scripting
```powershell
$config = Get-AwsSsoConfiguration

# List all profile names
$config.Profiles | ForEach-Object { $_.ProfileName }

# Find profiles for specific account
$config.Profiles | Where-Object { $_.SsoAccountId -eq "123456789012" }

# Count profiles per session
$config.Profiles | Group-Object SsoSession | Select-Object Name, Count
```

#### Filter by Session
```powershell
Get-AwsSsoConfiguration -SessionName "sso-session-jdoe" -Format Table
```

#### Export to JSON
```powershell
# Backup configuration
Get-AwsSsoConfiguration -Format Json | Out-File aws-sso-backup.json

# Pretty print with native PowerShell
$config = Get-AwsSsoConfiguration
$config | ConvertTo-Json -Depth 10 | Out-File aws-sso-config.json
```

#### Check if Config Exists
```powershell
$config = Get-AwsSsoConfiguration
if ($config) {
    Write-Host "Found $($config.TotalProfiles) profiles in $($config.TotalSessions) sessions"
} else {
    Write-Host "No SSO configuration found. Run Set-AwsSsoConfiguration to set up."
}
```

### Error Handling

The function handles various error scenarios:

- **Config file not found**: Returns `$null` with warning message
- **Permission denied**: Returns `$null` with error explaining permissions issue
- **Empty config**: Returns `$null` with warning
- **Invalid format**: Skips invalid sections, continues parsing valid ones
- **No SSO profiles**: Returns `$null` with informative message
- **Session not found**: Returns `$null` when filtering for non-existent session

## Compatibility Notes

### PowerShell 5.1 vs 7+

The module handles differences automatically:

- **TLS 1.2**: Automatically enabled for PowerShell 5.1
- **Platform Detection**: Uses appropriate methods for each version
- **File Paths**: Correctly resolves `~/.aws/config` on all platforms
- **REST API Calls**: Compatible error handling for both versions

### Cross-Platform Paths

- **Windows**: `%USERPROFILE%\.aws\config`
- **Linux/macOS**: `~/.aws/config`

## Troubleshooting

### "No accounts or roles found"

- Verify your SSO start URL is correct
- Ensure you have assigned roles in AWS SSO
- Check that you completed the browser authorization

### "Device authorization timed out"

- The authorization must be completed within 5 minutes
- Run the command again and complete authorization faster

### "Invalid SSO region"

- Verify the region where your AWS SSO is configured
- Common regions: `us-east-1`, `us-west-2`, `eu-west-1`

### Profile Already Exists

The module skips profiles that already exist in your config. To recreate a profile, manually remove it from `~/.aws/config` first.

## Examples

### Example 1: Quick Setup

```powershell
# Import module
Import-Module ./AwsSsoConfig.psd1

# Run configuration with defaults
Set-AwsSsoConfiguration -SsoStartUrl "https://d-1234567890.awsapps.com/start"

# Follow prompts to authorize and select roles
# Creates: sso-session-{your-username}
# Profiles: account-name-role-name format
```

### Example 2: Organization with Account ID Naming

```powershell
# Use account IDs in profile names for clarity
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://mycompany.awsapps.com/start" `
    -ProfileNamingScheme "AccountIdRole" `
    -ProfilePrefix "acme"

# Results in: acme-123456789012-administrator
```

### Example 3: Multiple Organizations

```powershell
# Configure Company A (production)
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://companyA.awsapps.com/start" `
    -SessionName "companya-session" `
    -ProfilePrefix "companyA"

# Configure Company B (consulting client)
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://companyB.awsapps.com/start" `
    -SessionName "companyb-session" `
    -ProfilePrefix "companyB"

# Login to each separately
aws sso login --sso-session companya-session
aws sso login --sso-session companyb-session
```

### Example 4: Custom Profile Naming

```powershell
# Custom format: environment-accountid-role
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://mycompany.awsapps.com/start" `
    -ProfileNamingScheme "Custom" `
    -ProfileNameTemplate "prod-{AccountId}-{RoleName}"

# Results in: prod-123456789012-administrator
```

### Example 5: Multi-Region Setup

```powershell
# Configure EU organization with custom defaults
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://eu.awsapps.com/start" `
    -SsoRegion "eu-west-1" `
    -DefaultRegion "eu-west-1" `
    -ProfilePrefix "eu"
```

## Security Considerations

- **Device Flow**: Uses OAuth 2.0 device authorization flow (secure)
- **No Password Storage**: Credentials are never stored in the module
- **Browser Authentication**: Authentication happens in your browser with AWS
- **Temporary Tokens**: OIDC client credentials expire after use
- **Config File**: AWS config file contains no sensitive credentials

## Limitations

- Cannot be fully tested without AWS SSO access
- Requires browser access for authentication (no headless support)
- AWS SSO portal APIs may vary by AWS version
- Requires AWS CLI v2.9.0+ for full SSO session support

## License

This module is provided as-is for AWS SSO configuration purposes.

## Contributing

Feel free to submit issues or improvements.

## Author

Created for simplified AWS SSO configuration workflows.
