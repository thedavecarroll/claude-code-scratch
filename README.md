# AWS SSO Configuration PowerShell Module

A PowerShell module to configure AWS SSO (SAML) profiles with minimal user interaction. Compatible with PowerShell 5.1 and 7+.

## Features

- **Device Authorization Flow**: Secure authentication using AWS SSO device authorization
- **Automatic Discovery**: Retrieves all available AWS accounts and roles
- **Interactive Selection**: Simple menu to select which profiles to configure
- **AWS Config Format**: Writes profiles directly to `~/.aws/config`
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

### Basic Usage

```powershell
Set-AwsSsoConfiguration -SsoStartUrl "https://my-sso-portal.awsapps.com/start"
```

### With Custom Options

```powershell
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://my-sso-portal.awsapps.com/start" `
    -SsoRegion "us-west-2" `
    -ProfilePrefix "mycompany" `
    -DefaultRegion "eu-west-1"
```

## Workflow

The function follows these steps:

1. **Register SSO Client**: Creates a temporary OIDC client with AWS
2. **Device Authorization**: Generates a device code and user code
3. **User Authentication**: Displays a URL for browser-based authentication
4. **Token Retrieval**: Polls for access token after user authorizes
5. **Account/Role Discovery**: Retrieves all available AWS accounts and roles
6. **Interactive Selection**: Presents a menu to select desired profiles
7. **Config Writing**: Writes selected profiles to `~/.aws/config`

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

The module writes profiles to `~/.aws/config` in this format:

```ini
[profile mycompany-production-account-administrator]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_account_id = 123456789012
sso_role_name = Administrator
region = us-east-1
output = json

[profile mycompany-development-account-developer]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_account_id = 987654321098
sso_role_name = Developer
region = us-east-1
output = json
```

## Using Configured Profiles

After configuration, use AWS CLI with your new profiles:

```bash
# Login to SSO
aws sso login --profile mycompany-production-account-administrator

# Use the profile
aws s3 ls --profile mycompany-production-account-administrator
aws ec2 describe-instances --profile mycompany-production-account-administrator
```

## Parameters

### `-SsoStartUrl` (Required)
Your AWS SSO portal start URL. Get this from your AWS administrator.

Example: `https://my-sso-portal.awsapps.com/start`

### `-SsoRegion` (Optional)
AWS region where SSO is configured. Default: `us-east-1`

### `-ProfilePrefix` (Optional)
Prefix to add to profile names for organization. Default: none

### `-DefaultRegion` (Optional)
Default AWS region for all profiles. Default: `us-east-1`

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

# Run configuration
Set-AwsSsoConfiguration -SsoStartUrl "https://d-1234567890.awsapps.com/start"

# Follow prompts to authorize and select roles
```

### Example 2: Multi-Region Organization

```powershell
# Configure with custom settings
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://mycompany.awsapps.com/start" `
    -SsoRegion "eu-west-1" `
    -ProfilePrefix "acme" `
    -DefaultRegion "eu-west-1"

# Results in profiles like: acme-production-administrator
```

### Example 3: Multiple Environments

```powershell
# Configure production profiles
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://prod.awsapps.com/start" `
    -ProfilePrefix "prod"

# Configure development profiles
Set-AwsSsoConfiguration `
    -SsoStartUrl "https://dev.awsapps.com/start" `
    -ProfilePrefix "dev"
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
- Profile names are auto-generated (manual editing of config supported)

## License

This module is provided as-is for AWS SSO configuration purposes.

## Contributing

Feel free to submit issues or improvements.

## Author

Created for simplified AWS SSO configuration workflows.
