<#
.SYNOPSIS
    Installs packages from manifest using config-driven install arguments.
.DESCRIPTION
    Reads InstallFromManifestPackages and InstallerArguments from build-config.
    Resolves each package from manifest (same logic as download-installers).
    Runs installers with configured args. Supports EXE (run directly) and MSI (via msiexec).
    Does NOT handle service disable - use dedicated scripts (crowdstrike) for those.

    Idempotent: writes a receipt file per package after successful install. On re-run,
    packages with existing receipts are skipped.
.NOTES
    Package format: pkgId (latest) or pkgId@version (pinned).
    InstallerArguments key = pkgId only (no version).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TranscriptState = $null

try {
    # Load modules (install-helper imports packer-logging)
    $ConfigPath = Join-Path 'C:\Packer\Config' 'build-config.json'
    if (-not (Test-Path $ConfigPath)) {
        throw "Build configuration file not found at '$ConfigPath'. The build cannot continue."
    }
    $BootstrapConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $helperPath = $BootstrapConfig.InstallHelperModulePath
    if (-not (Test-Path $helperPath)) {
        throw "Packer install helper module not found at '$helperPath'. The build cannot continue."
    }
    Import-Module -Name $helperPath -Force
    $Config = Get-PackerBuildConfig
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'install-from-manifest.ps1'

    $InstallFilesPath = Get-InstallFilesPath -Config $Config
    $Packages = @()
    if ($Config.PSObject.Properties['InstallFromManifestPackages']) {
        $Packages = $Config.InstallFromManifestPackages
    }
    $InstallerArgs = @{}
    if ($Config.PSObject.Properties['InstallerArguments']) {
        $InstallerArgs = $Config.InstallerArguments
    }

    if (-not $Packages -or @($Packages).Count -eq 0) {
        Write-Output "InstallFromManifestPackages is empty; nothing to install."
    }
    else {

    $ManifestPath = Join-Path -Path $InstallFilesPath -ChildPath 'manifest.json'
    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found at '$ManifestPath'. Ensure download-installers.ps1 has run first."
    }
    $Manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    $ManifestSections = $Manifest.manifest_section
    $Packages = @($Packages)

    # Receipt directory for idempotency tracking
    $ReceiptPath = Join-Path -Path $InstallFilesPath -ChildPath '.receipts'
    if (-not (Test-Path $ReceiptPath)) {
        $null = New-Item -Path $ReceiptPath -ItemType Directory -Force
    }

    $idx = 0
    $installed = 0
    $skipped = 0
    foreach ($pkg in $Packages) {
        $pkg = $pkg.Trim()
        if ([string]::IsNullOrWhiteSpace($pkg)) { continue }

        # Parse pkgId from spec (strip @version if present) for config lookup
        $pkgId = if ($pkg -match '^(.+?)@') { $Matches[1].Trim() } else { $pkg }

        # Check for existing receipt (idempotency)
        $receiptFile = Join-Path -Path $ReceiptPath -ChildPath "$pkgId.installed"
        if (Test-Path $receiptFile) {
            Write-Output "Skipping ${pkg}: already installed (receipt exists)"
            $skipped++
            continue
        }

        # Get install args (keyed by pkgId only)
        $pkgConfig = $InstallerArgs.$pkgId
        if (-not $pkgConfig -or -not $pkgConfig.args) {
            throw "InstallerArguments for '$pkgId' not found in build-config. Add args for each package in InstallFromManifestPackages."
        }
        $installArgs = $pkgConfig.args
        $useMsiexec = ($pkgConfig.executable -eq 'msiexec')

        # Resolve S3 key from manifest via shared helper
        $resolvedKeys = Resolve-ManifestPackage -PackageSpec $pkg -ManifestSections $ManifestSections
        if (-not $resolvedKeys -or $resolvedKeys.Count -eq 0) {
            throw "Package '$pkg' not found in manifest."
        }
        $s3Key = $resolvedKeys[0]
        $fileName = Split-Path -Path $s3Key -Leaf
        $installerPath = Join-Path -Path $InstallFilesPath -ChildPath $fileName

        if (-not (Test-Path $installerPath)) {
            throw "Installer not found at '$installerPath'. Ensure download-installers.ps1 has run and ManifestPackages includes '$pkg'."
        }

        $idx++
        $logPrefix = "install_from_manifest_$idx"
        $isMsi = $fileName -match '\.msi$' -or $useMsiexec

        if ($isMsi) {
            $execArgs = $installArgs + @($installerPath)
            Write-Output "Installing ${pkg} via msiexec: $fileName"
            $null = Invoke-PackerInstaller -FilePath 'msiexec.exe' -ArgumentList $execArgs -InstallerName $pkgId -LogPrefix $logPrefix
        }
        else {
            Write-Output "Installing ${pkg}: $fileName"
            $null = Invoke-PackerInstaller -FilePath $installerPath -ArgumentList $installArgs -InstallerName $pkgId -LogPrefix $logPrefix
        }

        # Write receipt after successful install
        $receiptContent = @{
            PackageSpec = $pkg
            PackageId   = $pkgId
            FileName    = $fileName
            InstalledAt = (Get-Date -Format 'o')
        } | ConvertTo-Json
        $receiptContent | Set-Content -Path $receiptFile -Force
        $installed++
    }

    $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
    Write-Output "Install-from-manifest completed. Installed: $installed, Skipped: $skipped. Completed in $Elapsed"

    } # end else (packages to install)
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
