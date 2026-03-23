<#
.SYNOPSIS
    Copies required installers from S3 into the shared installer cache.
.DESCRIPTION
    - Reads C:\Packer\Config\build-config.json for inputs.
    - Downloads to C:\ProgramData\Installers (shared cache for Chef).
    - Uses Copy-S3Object with retry logic for resiliency.
    - Fails fast on error to stop the pipeline.
.NOTES
    The installer cache at C:\ProgramData\Installers is shared between Packer
    and Chef. Files downloaded here are used by Chef's plaisse_win_installer
    resource without re-downloading.

    Package format in ManifestPackages: "pkgId" (latest) or "pkgId@version" (pinned).
    Example: "mssql" uses latest; "mssql@17.10.6.1" pins to that version.
#>
[CmdletBinding()]
param()

# Load build configuration
$ConfigPath = 'C:\Packer\Config\build-config.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error "FATAL: Build configuration file not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$TranscriptState = $null
try {
    $ErrorActionPreference = 'Stop'

    Import-Module -Name $Config.LoggingModulePath -Force

    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'download-installers.ps1'

    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::Expect100Continue = $false

    # --- UPDATED: DISCOVER AWS MODULE VIA COMMAND ---
    $S3Command = Get-Command -Name Copy-S3Object -ErrorAction SilentlyContinue
    if ($null -eq $S3Command) {
        throw "Required command 'Copy-S3Object' not found. Ensure an AWS PowerShell module is installed."
    }

    $awsModule = $S3Command.Source
    Import-Module -Name $awsModule -ErrorAction Stop
    # -----------------------------------------------
    Write-Output "Using Copy-S3Object from module: $awsModule"

    $InstallFilesPath = $Config.InstallFilesPath
    $null = New-Item -Path $InstallFilesPath -ItemType Directory -Force

    $InstallerBucketName = $null
    if ($Config.PSObject.Properties['InstallerBucketName']) {
        $InstallerBucketName = $Config.InstallerBucketName
    }
    if ([string]::IsNullOrWhiteSpace($InstallerBucketName)) {
        throw "InstallerBucketName was not provided in build-config.json."
    }
    $InstallerBucketName = $InstallerBucketName.Trim()
    if ($InstallerBucketName -like 's3://*') {
        $InstallerBucketName = $InstallerBucketName.Substring(5)
    }
    $InstallerBucketName = $InstallerBucketName.Trim('/')

    $InstallerBucketRegion = $null
    if ($Config.PSObject.Properties['InstallerBucketRegion']) {
        $InstallerBucketRegion = $Config.InstallerBucketRegion
    }
    $S3Params = @{ Force = $true }
    if (-not [string]::IsNullOrWhiteSpace($InstallerBucketRegion)) {
        $S3Params["Region"] = $InstallerBucketRegion.Trim()
    }

    # --- MANIFEST: Download manifest.json first ---
    $ManifestS3Key = $null
    if ($Config.PSObject.Properties['ManifestS3Key']) {
        $ManifestS3Key = $Config.ManifestS3Key
    }
    if (-not [string]::IsNullOrWhiteSpace($ManifestS3Key)) {
        $ManifestS3Key = $ManifestS3Key.Trim()
        $ManifestTargetPath = Join-Path -Path $InstallFilesPath -ChildPath 'manifest.json'
        Write-Output "Downloading manifest: s3://$InstallerBucketName/$ManifestS3Key -> $ManifestTargetPath"
        try {
            Copy-S3Object -BucketName $InstallerBucketName -Key $ManifestS3Key -LocalFile $ManifestTargetPath @S3Params
            if (Test-Path $ManifestTargetPath) {
                Write-Output "Manifest downloaded successfully."
            }
        }
        catch {
            throw "Failed to download manifest from s3://$InstallerBucketName/$ManifestS3Key : $($_.Exception.Message)"
        }
    }

    # --- MANIFEST: Resolve package keys from manifest ---
    # Package format: "pkgId" (latest) or "pkgId@version" (pinned)
    $ManifestPackageKeys = @()
    $ManifestPackages = @()
    if ($Config.PSObject.Properties['ManifestPackages']) {
        $ManifestPackages = $Config.ManifestPackages
    }
    if ($ManifestPackages -and (Test-Path (Join-Path -Path $InstallFilesPath -ChildPath 'manifest.json'))) {
        $ManifestPath = Join-Path -Path $InstallFilesPath -ChildPath 'manifest.json'
        $Manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
        $ManifestSections = $Manifest.manifest_section
        $ManifestPackages = @($ManifestPackages)
        foreach ($pkg in $ManifestPackages) {
            $keys = Resolve-ManifestPackage -PackageSpec $pkg -ManifestSections $ManifestSections
            foreach ($key in $keys) {
                $ManifestPackageKeys += $key
                Write-Output "Resolved manifest package '$pkg' -> $key"
            }
        }
    }

    # --- Use manifest-resolved keys only ---
    $AllKeys = @($ManifestPackageKeys) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    if (-not $AllKeys) {
        throw "No packages resolved from manifest. Ensure ManifestPackages in build-config includes valid package IDs (e.g. chef_client, crowdstrike) and manifest.json contains those packages."
    }

    foreach ($key in $AllKeys) {
        if ([string]::IsNullOrWhiteSpace($key)) {
            Write-Warning 'Encountered blank installer key; skipping.'
            continue
        }

        $objectName = Split-Path -Path $key -Leaf
        if ([string]::IsNullOrWhiteSpace($objectName)) {
            $objectName = [Guid]::NewGuid().ToString()
        }

        $targetPath = Join-Path -Path $InstallFilesPath -ChildPath $objectName
        Write-Output "Starting S3 copy: s3://$InstallerBucketName/$key -> $targetPath"

        $maxRetries = 3
        $attempt = 0
        $copyComplete = $false
        $startTime = Get-Date

        while (-not $copyComplete -and $attempt -lt $maxRetries) {
            $attempt++
            try {
                # UPDATED: Added @S3Params splat
                Copy-S3Object -BucketName $InstallerBucketName -Key $key -LocalFile $targetPath @S3Params

                if (-not (Test-Path $targetPath)) {
                    throw "Expected file missing after Copy-S3Object: $targetPath"
                }
                $copyComplete = $true
            }
            catch {
                if ($attempt -ge $maxRetries) {
                    throw "Copy failed for s3://$InstallerBucketName/$key after $maxRetries attempts: $($_.Exception.Message)"
                }
                Write-Warning "Copy failed for s3://$InstallerBucketName/$key. Retrying in 10 seconds... ($attempt/$maxRetries). Error: $($_.Exception.Message)"
                Start-Sleep -Seconds 10
            }
        }

        if ($copyComplete) {
            $endTime = Get-Date
            $elapsed = $endTime - $startTime
            $fileSizeMB = 0
            if (Test-Path $targetPath) {
                $fileSizeMB = [math]::Round((Get-Item $targetPath).Length / 1MB, 2)
            }
            $timeTakenFormatted = '{0:D2}:{1:D2}' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds
            Write-Output ("Copy complete: {0}. Completed in {1} ({2} MB)" -f $objectName, $timeTakenFormatted, $fileSizeMB)
        }
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
