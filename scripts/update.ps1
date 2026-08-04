param(
    [switch] $VoiceNim,
    [switch] $VoiceLocal,
    [switch] $VoiceAll,
    [string] $TorchBackend = "",
    [switch] $DryRun,
    [switch] $Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]] $RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoArchiveUrl = "https://github.com/Alishahryar1/free-claude-code/archive/refs/heads/main.zip"
# Windows on ARM emulates x64, whose Python package ecosystem has broader wheel support.
$PythonRequest = "cpython-3.14.0-windows-x86_64-none"
$MinUvVersion = "0.11.16"
$UvInstallUrl = "https://astral.sh/uv/install.ps1"
$FccCommands = @(
    # Include retired entry points so updates reject older FCC processes before replacement.
    "fcc-desktop",
    "fcc-server",
    "fcc-claude",
    "fcc-codex",
    "fcc-pi",
    "fcc-init",
    "free-claude-code"
)

function Show-Usage {
    @"
Usage: update.ps1 [options]

Updates an existing Free Claude Code installation to the latest version from the main branch.
This script is faster than the full installer since it skips coding agent verification.

Options:
  -VoiceNim              Install NVIDIA NIM voice transcription support.
  -VoiceLocal            Install local Whisper voice transcription support.
  -VoiceAll              Install all voice transcription backends.
  -TorchBackend VALUE    Use a uv PyTorch backend, such as cu130. Requires local voice.
  -DryRun                Print commands without running them.
  -Help                  Show this help text.
"@
}

function Write-Step {
    param([string] $Message)

    Write-Host ""
    Write-Host "==> $Message"
}

function Format-Argument {
    param([string] $Value)

    if ($Value -match '^[A-Za-z0-9_./:@%+=,\[\]\\-]+$') {
        return $Value
    }
    return "'$($Value.Replace("'", "''"))'"
}

function Invoke-PrintCommand {
    param([object[]] $Args)

    $formattedArgs = $Args | ForEach-Object { Format-Argument -Value $_ }
    Write-Host "+ $([string]::Join(" ", $formattedArgs))"
}

function Invoke-Run {
    param([object[]] $Command)

    Invoke-PrintCommand -Args $Command

    if ($DryRun) {
        return
    }

    & $Command[0] ($Command[1..($Command.Length - 1)]) 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            throw $_.Exception
        }
        Write-Output $_
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE : $([string]::Join(' ', $Command))"
    }
}

function Test-FccProcessesRunning {
    $running = @()
    foreach ($commandName in $FccCommands) {
        $processes = Get-Process -Name $commandName -ErrorAction SilentlyContinue
        if ($null -ne $processes) {
            foreach ($process in $processes) {
                $running += "$commandName (PID $($process.Id))"
            }
        }
    }
    return $running
}

function Assert-FccIsInstalled {
    $fccFound = $false
    
    # Check if fcc-server is available
    try {
        $fccPath = Get-Command fcc-server -ErrorAction SilentlyContinue
        if ($null -ne $fccPath) {
            $fccFound = $true
        }
    } catch {
        # Command not found
    }

    if (-not $fccFound) {
        # Check common uv tool locations
        $uvToolBin = $null
        try {
            $uvToolBin = uv tool dir --bin 2>$null
        } catch {
            # uv not available
        }

        if ($null -ne $uvToolBin -and (Test-Path "$uvToolBin\fcc-server.exe")) {
            $fccFound = $true
        }
    }

    if (-not $fccFound) {
        throw "Free Claude Code is not installed. Please run install.ps1 first."
    }
}

function Assert-NoFccProcessesRunning {
    $running = Test-FccProcessesRunning
    if ($running.Count -gt 0) {
        $runningStr = $running -join ", "
        throw "Free Claude Code is still running ($runningStr). Stop those processes, then rerun the updater."
    }
}

function Get-UvVersion {
    try {
        $output = uv --version 2>&1 | Out-String
        if ($output -match 'uv\s+([\d\.]+)') {
            return $matches[1]
        }
    } catch {
        # uv not available
    }
    return $null
}

function Test-UvVersionIsSupported {
    param([string] $Version, [string] $Minimum)

    if ($Version -match '-') {
        return $false
    }

    $currentParts = $Version.Split('.') | ForEach-Object { [int]$_ }
    $minimumParts = $Minimum.Split('.') | ForEach-Object { [int]$_ }

    for ($i = 0; $i -lt 3; $i++) {
        $current = if ($i -lt $currentParts.Count) { $currentParts[$i] } else { 0 }
        $minimum = if ($i -lt $minimumParts.Count) { $minimumParts[$i] } else { 0 }

        if ($current -gt $minimum) { return $true }
        if ($current -lt $minimum) { return $false }
    }
    return $true
}

function Verify-Uv {
    if ($DryRun) {
        Invoke-PrintCommand -Args @("uv", "--version")
        return
    }

    $uvPath = Get-Command uv -ErrorAction SilentlyContinue
    if ($null -eq $uvPath) {
        throw "uv is required but not found on PATH."
    }

    $version = Get-UvVersion
    if ($null -eq $version) {
        throw "uv is present, but 'uv --version' did not return a valid version."
    }

    if (-not (Test-UvVersionIsSupported -Version $version -Minimum $MinUvVersion)) {
        throw "Stable uv $MinUvVersion or newer is required; found uv $version."
    }

    Write-Host "Verified uv $version."
}

function Get-PackageSpec {
    $includeNim = $VoiceNim.IsPresent
    $includeLocal = $VoiceLocal.IsPresent

    if ($VoiceAll.IsPresent) {
        $includeNim = $true
        $includeLocal = $true
    }

    if ($includeNim -and $includeLocal) {
        return "free-claude-code[voice,voice_local] @ $RepoArchiveUrl"
    } elseif ($includeNim) {
        return "free-claude-code[voice] @ $RepoArchiveUrl"
    } elseif ($includeLocal) {
        return "free-claude-code[voice_local] @ $RepoArchiveUrl"
    } else {
        return "free-claude-code @ $RepoArchiveUrl"
    }
}

function Update-FreeClaudeCode {
    Assert-NoFccProcessesRunning
    $spec = Get-PackageSpec

    Write-Step "Updating Free Claude Code to latest version"
    Write-Host "This will replace your current installation with the latest version from main branch."

    $baseArgs = @(
        "tool", "install",
        "--force",
        "--refresh-package", "free-claude-code",
        "--python", $PythonRequest
    )

    if ($TorchBackend -ne "") {
        $baseArgs += @("--torch-backend", $TorchBackend)
    }

    $baseArgs += $spec

    Invoke-Run -Command ("uv", $baseArgs)
}

function Configure-And-Verify-FreeClaudeCode {
    Invoke-Run -Command @("uv", "tool", "update-shell")

    if ($DryRun) {
        Invoke-PrintCommand -Args @("uv", "tool", "dir", "--bin")
        Write-Host "+ verify fcc-desktop, fcc-server, fcc-claude, fcc-codex, and fcc-pi in the uv tool bin directory"
        Invoke-PrintCommand -Args @("fcc-server", "--version")
        return
    }

    Invoke-PrintCommand -Args @("uv", "tool", "dir", "--bin")
    $toolBin = uv tool dir --bin 2>&1 | Out-String | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($toolBin)) {
        throw "Could not determine the uv tool bin directory."
    }
    $toolBin = $toolBin.Trim()

    $env:Path = "$toolBin;$env:Path"
    [Environment]::SetEnvironmentVariable("PATH", $env:Path, [EnvironmentVariableTarget]::Process)

    foreach ($commandName in @("fcc-desktop", "fcc-server", "fcc-claude", "fcc-codex", "fcc-pi")) {
        $commandPath = Join-Path $toolBin "$commandName.exe"
        if (-not (Test-Path $commandPath)) {
            throw "Free Claude Code installation did not create $commandPath."
        }
    }

    Invoke-Run -Command @("$toolBin\fcc-server.exe", "--version")
}

# Parse arguments
if ($Help) {
    Show-Usage
    exit 0
}

# Validate arguments
$includeLocal = $VoiceLocal.IsPresent
if ($VoiceAll.IsPresent) {
    $includeLocal = $true
}

if ($TorchBackend -ne "" -and -not $includeLocal) {
    throw "-TorchBackend requires -VoiceLocal or -VoiceAll."
}

Write-Step "Checking Free Claude Code installation"
Assert-FccIsInstalled

Write-Step "Checking uv"
Verify-Uv

Update-FreeClaudeCode

Write-Step "Configuring PATH and verifying Free Claude Code"
Configure-And-Verify-FreeClaudeCode

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. No changes were made."
} else {
    Write-Host ""
    Write-Host "✅ Free Claude Code has been updated to the latest version!"
    Write-Host ""
    Write-Host "Start the proxy with: fcc-server"
    Write-Host "Run Claude Code with: fcc-claude"
    Write-Host "Run Codex with: fcc-codex"
    Write-Host "Run Pi with: fcc-pi"
}
