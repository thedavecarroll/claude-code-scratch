<#
.SYNOPSIS
    Applies IIS security hardening during AMI build.
.DESCRIPTION
    This script runs after Chef installs IIS features and applies security hardening:
    - Removes the Default Web Site (prevents port 80 conflicts)
    - Removes X-Powered-By header (security)
    - Sets error mode to DetailedLocalOnly (prevents info disclosure)
    - Disables directory browsing (security)

    The script is idempotent: it checks current config values and skips changes that are already applied.
.NOTES
    Must run AFTER IIS features are installed (after run-chef-client.ps1).
    Only executes if IIS is installed on the system.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# Load packer-logging
$configPath = 'C:\Packer\Config\build-config.json'
if (-not (Test-Path $configPath)) {
    Write-Output "ERROR: Build config not found at $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$loggingModule = $config.LoggingModulePath
if (Test-Path $loggingModule) {
    Import-Module $loggingModule -Force
}

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'TranscriptState', Justification = 'Used in finally block')]
$TranscriptState = $null
try {
    $TranscriptState = Start-PackerTranscript -Invocation $MyInvocation -OriginalScriptName 'secure-iis.ps1'

    Write-Output "========================================"
    Write-Output "Secure IIS"
    Write-Output "========================================"

    # Check if IIS is installed
    $iisInstalled = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue | Where-Object { $_.Installed }
    if (-not $iisInstalled) {
        Write-Output "IIS is not installed. Skipping IIS configuration."
        return
    }

    Write-Output "IIS detected. Applying security hardening..."

    # Resolve inetsrv path - Sysnative for 32-bit PowerShell on 64-bit Windows
    $sys32Inetsrv = Join-Path $env:SystemRoot "system32\inetsrv"
    $sysNativeInetsrv = Join-Path $env:SystemRoot "Sysnative\system32\inetsrv"
    $inetsrvPath = if (Test-Path $sysNativeInetsrv) { $sysNativeInetsrv } else { $sys32Inetsrv }
    $appcmd = Join-Path $inetsrvPath "appcmd.exe"

    if (-not (Test-Path -LiteralPath $appcmd)) {
        Write-Output "IIS Management Scripts and Tools not installed. Installing Web-Scripting-Tools..."
        $null = Install-WindowsFeature Web-Scripting-Tools -IncludeManagementTools
        $appcmd = Join-Path $inetsrvPath "appcmd.exe"
        if (-not (Test-Path -LiteralPath $appcmd)) {
            throw "appcmd.exe not found after installing Web-Scripting-Tools. Path: $appcmd"
        }
    }

    # -------------------------------------------------------------------------
    # Remove Default Web Site
    # -------------------------------------------------------------------------
    Write-Output ""
    Write-Output "--- Removing Default Web Site ---"

    try {
        # Load ServerManager assembly (use resolved inetsrv path for 32-bit PowerShell on 64-bit Windows)
        $mwaPath = Join-Path $inetsrvPath "Microsoft.Web.Administration.dll"
        $null = [System.Reflection.Assembly]::LoadFrom($mwaPath)

        $serverManager = New-Object Microsoft.Web.Administration.ServerManager
        $defaultSite = $serverManager.Sites["Default Web Site"]

        if ($null -ne $defaultSite) {
            Write-Output "Default Web Site found, removing..."
            if ($defaultSite.State -eq "Started") {
                $defaultSite.Stop()
            }
            $serverManager.Sites.Remove($defaultSite)
            $serverManager.CommitChanges()
            Write-Output "Default Web Site removed successfully"
        } else {
            Write-Output "Default Web Site not found (already removed)"
        }

        $serverManager.Dispose()
    }
    catch {
        Write-Output "Warning: Failed to remove Default Web Site: $_"
        Write-Output "This is not critical - continuing..."
    }

    # Single list config call - system.webServer contains httpProtocol, httpErrors, directoryBrowse
    $webServerConfig = & $appcmd list config -section:system.webServer 2>&1

    # -------------------------------------------------------------------------
    # Remove X-Powered-By Header
    # -------------------------------------------------------------------------
    Write-Output ""
    Write-Output "--- Removing X-Powered-By Header ---"

    if ($webServerConfig -match "name='X-Powered-By'") {
        $removeHeaderResult = & $appcmd set config -section:system.webServer/httpProtocol /-"customHeaders.[name='X-Powered-By']" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "X-Powered-By header removed successfully"
        } else {
            Write-Output "Warning: Failed to remove X-Powered-By header: $removeHeaderResult"
        }
    } else {
        Write-Output "X-Powered-By header not present (already removed)"
    }

    # -------------------------------------------------------------------------
    # Disable Detailed Error Messages for Remote Clients
    # -------------------------------------------------------------------------
    Write-Output ""
    Write-Output "--- Configuring Error Mode ---"

    if ($webServerConfig -notmatch "DetailedLocalOnly") {
        $errorModeResult = & $appcmd set config -section:system.webServer/httpErrors /errorMode:DetailedLocalOnly 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Error mode set to DetailedLocalOnly"
        } else {
            Write-Output "Warning: Failed to set error mode: $errorModeResult"
        }
    } else {
        Write-Output "Error mode already DetailedLocalOnly"
    }

    # -------------------------------------------------------------------------
    # Disable Directory Browsing
    # -------------------------------------------------------------------------
    Write-Output ""
    Write-Output "--- Disabling Directory Browsing ---"

    $dirBrowseEnabled = $webServerConfig -match 'enabled\s*=\s*"true"' -or $webServerConfig -match "enabled\s*=\s*'true'"
    if ($dirBrowseEnabled) {
        $dirBrowseResult = & $appcmd set config -section:system.webServer/directoryBrowse /enabled:false 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Directory browsing disabled"
        } else {
            Write-Output "Warning: Failed to disable directory browsing: $dirBrowseResult"
        }
    } else {
        Write-Output "Directory browsing already disabled"
    }

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    Write-Output ""
    Write-Output "========================================"
    Write-Output "IIS security hardening completed"
    Write-Output "========================================"
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
