<#
.SYNOPSIS
    Installs packages from manifest using config-driven install arguments.
.DESCRIPTION
    Reads InstallFromManifestPackages and InstallerArguments from build-config.
    Resolves each package from manifest (same logic as download-installers).
    Runs installers with configured args. Supports EXE (run directly) and MSI (via msiexec).
    Does NOT handle service disable - use dedicated scripts (crowdstrike) for those.
.NOTES
    Package format: pkgId (latest) or pkgId@version (pinned).
    InstallerArguments key = pkgId only (no version).
#>
[CmdletBinding()]
param()

# Load modules (install-helper imports packer-logging)
$ConfigPath = Join-Path 'C:\Packer\Config' 'build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'. The build cannot continue."
    exit 1
}
$bootstrap = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$helperPath = $bootstrap.InstallHelperModulePath
if (-not (Test-Path $helperPath)) {
    Write-Error "FATAL: Packer install helper module not found at '$helperPath'. The build cannot continue."
    exit 1
}
Import-Module -Name $helperPath -Force
$Config = Get-PackerBuildConfig

$TranscriptState = $null
try {
    $ErrorActionPreference = 'Stop'
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

    if (-not $Packages -or $Packages.Count -eq 0) {
        Write-Output "InstallFromManifestPackages is empty; nothing to install."
        exit 0
    }

    $ManifestPath = Join-Path -Path $InstallFilesPath -ChildPath 'manifest.json'
    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found at '$ManifestPath'. Ensure download-installers.ps1 has run first."
    }
    $Manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    $sections = $Manifest.manifest_section

    if ($Packages -isnot [System.Array]) {
        $Packages = @($Packages)
    }

    $idx = 0
    foreach ($pkg in $Packages) {
        $pkg = $pkg.Trim()
        if ([string]::IsNullOrWhiteSpace($pkg)) { continue }

        $pkgId = $pkg
        $requestedVersion = $null
        if ($pkg -match '^(.+?)@(.+)$') {
            $pkgId = $Matches[1].Trim()
            $requestedVersion = $Matches[2].Trim()
        }

        # Get install args (keyed by pkgId only)
        $pkgConfig = $InstallerArgs.$pkgId
        if (-not $pkgConfig -or -not $pkgConfig.args) {
            throw "InstallerArguments for '$pkgId' not found in build-config. Add args for each package in InstallFromManifestPackages."
        }
        $installArgs = $pkgConfig.args
        $useMsiexec = ($pkgConfig.executable -eq 'msiexec')

        # Resolve file from manifest (same logic as download-installers)
        $s3Key = $null
        $resolved = $false

        if ($requestedVersion) {
            foreach ($section in $sections) {
                $sectionFiles = $section.files
                if (-not $sectionFiles) { continue }
                $productPath = "/$pkgId/"
                $entry = $sectionFiles | Where-Object {
                    $_.s3_key -and $_.s3_key -like "*$productPath*" -and
                    $_.version -and $_.version.ToString() -eq $requestedVersion -and
                    (($_.arch -eq '64') -or [string]::IsNullOrWhiteSpace($_.arch))
                } | Select-Object -First 1
                if (-not $entry) {
                    $entry = $sectionFiles | Where-Object {
                        $_.s3_key -and $_.s3_key -like "*$productPath*" -and
                        $_.version -and $_.version.ToString() -eq $requestedVersion
                    } | Select-Object -First 1
                }
                if ($entry -and $entry.s3_key) {
                    $s3Key = $entry.s3_key
                    $resolved = $true
                    break
                }
            }
            if (-not $resolved) {
                throw "Package '$pkgId' version '$requestedVersion' not found in manifest."
            }
        }
        else {
            foreach ($section in $sections) {
                $latest = $section.latest
                if (-not $latest -or -not $latest.PSObject.Properties[$pkgId]) { continue }
                $product = $latest.$pkgId
                $files = $product.files
                if ($files) {
                    $entry = $files | Where-Object { ($_.arch -eq '64') -or ([string]::IsNullOrWhiteSpace($_.arch)) } | Select-Object -First 1
                    if ($entry -and $entry.s3_key) {
                        $s3Key = $entry.s3_key
                        $resolved = $true
                        break
                    }
                }
            }
            if (-not $resolved) {
                throw "Package '$pkgId' (latest) not found in manifest."
            }
        }

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
    }

    $Elapsed = Get-ElapsedTimeString -StartTime $TranscriptState.StartTime
    Write-Output "Install-from-manifest completed successfully. Installed $($Packages.Count) package(s). Completed in $Elapsed"
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
