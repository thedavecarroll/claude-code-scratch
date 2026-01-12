@{
    # Module metadata
    ModuleVersion = '1.0.0'
    GUID = '7b3e4f2a-9c1d-4e8f-b5a7-6d3c2e1f0a9b'
    Author = 'AWS SSO Config Tool'
    Description = 'PowerShell module to configure AWS SSO profiles with minimal user interaction. Compatible with PowerShell 5.1 and 7+'
    PowerShellVersion = '5.1'

    # Module components
    RootModule = 'AwsSsoConfig.psm1'

    # Functions to export
    FunctionsToExport = @('Set-AwsSsoConfiguration')

    # Cmdlets to export
    CmdletsToExport = @()

    # Variables to export
    VariablesToExport = @()

    # Aliases to export
    AliasesToExport = @()

    # Private data
    PrivateData = @{
        PSData = @{
            Tags = @('AWS', 'SSO', 'SAML', 'Configuration', 'Authentication')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = 'Initial release - AWS SSO configuration with device authorization flow'
        }
    }
}
