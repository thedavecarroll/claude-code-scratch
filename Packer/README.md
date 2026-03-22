# Packer Provisioner Scripts

PowerShell scripts for building hardened Windows machine images using [HashiCorp Packer](https://www.packer.io/).

## Overview

This folder contains provisioner scripts that Packer executes sequentially during a Windows image build. Each script handles a specific configuration step — from initial setup through software installation, security hardening, and final cleanup.

All scripts share a consistent logging pattern: transcript capture, structured log messages, and automatic archival to a combined zip file for post-build analysis.

## Folder Structure

```
Packer/
├── Logs/                          Transcript output (git-ignored)
├── Scripts/                       Additional utility scripts
├── packer-logging.psm1            Shared module: transcript and structured logging
├── packer-install-helper.psm1     Shared module: MSI/EXE install, download, registry checks
├── initialize.ps1                 System preparation and defaults
├── download-installers.ps1        Download installer packages to staging
├── install-from-manifest.ps1      Install software from a JSON manifest
├── install-chef-client.ps1        Install Chef Infra Client
├── run-chef-client.ps1            Execute Chef client with a run list
├── install-crowdstrike.ps1        Install CrowdStrike Falcon sensor
├── config-bginfo.ps1              Configure BGInfo desktop display
├── secure-iis.ps1                 Harden IIS (TLS, ciphers, defaults)
├── secure-ntlm.ps1               Restrict NTLM, enforce NTLMv2
├── winrm-bootstrap.ps1            Configure WinRM HTTPS for Packer
├── finalize.ps1                   Cleanup, DISM, and optional sysprep
└── .gitignore                     Excludes log artifacts
```

## Prerequisites

- **PowerShell 5.1** or later
- **Administrator privileges** (all provisioner scripts require elevation)
- **HashiCorp Packer** for orchestrating the build
- **Network access** for downloading installers (if using download-installers.ps1)

## Script Execution Order

The recommended provisioner order in your Packer template:

| Order | Script                    | Purpose                                      |
|-------|---------------------------|----------------------------------------------|
| 1     | initialize.ps1            | Disable updates, configure power, create dirs |
| 2     | winrm-bootstrap.ps1       | Set up WinRM HTTPS for Packer communication   |
| 3     | download-installers.ps1   | Stage installer packages locally               |
| 4     | install-from-manifest.ps1 | Install software from JSON manifest             |
| 5     | install-chef-client.ps1   | Install Chef Infra Client                       |
| 6     | run-chef-client.ps1       | Execute Chef convergence                        |
| 7     | install-crowdstrike.ps1   | Install endpoint protection                     |
| 8     | config-bginfo.ps1         | Configure desktop system info display            |
| 9     | secure-iis.ps1            | Harden IIS configuration                        |
| 10    | secure-ntlm.ps1           | Restrict NTLM authentication                    |
| 11    | finalize.ps1              | Cleanup temp files, DISM, optional sysprep       |

## Shared Modules

### packer-logging.psm1

Provides transcript management and structured logging for all provisioner scripts.

| Function               | Description                                         |
|------------------------|-----------------------------------------------------|
| Start-PackerTranscript | Starts a timestamped transcript in the Logs folder  |
| Stop-PackerTranscript  | Stops the active transcript, returns the log path   |
| Add-LogToArchive       | Appends a log file to packer-build-logs.zip         |
| Write-PackerLog        | Writes a `[timestamp] [Severity] Message` log entry |

### packer-install-helper.psm1

Provides reusable functions for software installation and validation.

| Function             | Description                                          |
|----------------------|------------------------------------------------------|
| Install-MSI          | Silent MSI install via msiexec with exit code checks |
| Install-EXE          | Silent EXE install with configurable valid exit codes|
| Test-InstalledSoftware | Checks Windows registry for installed software     |
| Get-InstallerFromUri | Downloads a file from a URI to a local path          |
| Wait-ForProcess      | Polls for a process to exit within a timeout         |

## Script Pattern

Every provisioner script follows this consistent structure:

```powershell
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\packer-logging.psm1" -Force
Import-Module "$PSScriptRoot\packer-install-helper.psm1" -Force

$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

try {
    $logPath = Start-PackerTranscript -ScriptName $scriptName
    Write-PackerLog -Message "Starting $scriptName"

    # === Provisioner logic here ===

    Write-PackerLog -Message "Completed $scriptName successfully"
}
catch {
    Write-PackerLog -Message "FAILED in ${scriptName}: $_" -Severity Error
    throw
}
finally {
    $transcriptFile = Stop-PackerTranscript
    if ($transcriptFile) { Add-LogToArchive -LogPath $transcriptFile }
}
```

The `try/catch/finally` pattern ensures that transcripts are always stopped and archived, even when a script fails.

## Logging

Each script generates a transcript file in `Logs/` named `<ScriptName>_<yyyyMMdd_HHmmss>.log`. When the script completes (success or failure), the transcript is appended to `Logs/packer-build-logs.zip` using `Compress-Archive -Update`.

After a full build, `packer-build-logs.zip` contains all provisioner transcripts as a single artifact.

## Adding a New Provisioner

1. Copy an existing script (e.g., `initialize.ps1`) as a template
2. Update the comment-based help (`.SYNOPSIS`, `.DESCRIPTION`)
3. Replace the provisioner logic section with your implementation
4. Add the script to your Packer template in the appropriate order
5. Update this README with the new script's purpose

## Example Packer Template Snippet (HCL)

```hcl
build {
  sources = ["source.amazon-ebs.windows"]

  provisioner "powershell" {
    scripts = [
      "Packer/initialize.ps1",
      "Packer/winrm-bootstrap.ps1",
      "Packer/download-installers.ps1",
      "Packer/install-from-manifest.ps1",
      "Packer/install-chef-client.ps1",
      "Packer/run-chef-client.ps1",
      "Packer/install-crowdstrike.ps1",
      "Packer/config-bginfo.ps1",
      "Packer/secure-iis.ps1",
      "Packer/secure-ntlm.ps1",
      "Packer/finalize.ps1",
    ]
  }
}
```
