<#
.SYNOPSIS
    Installs the Antigravity Masking Sidecar on Windows.

.DESCRIPTION
    Windows counterpart of install.sh. It:

      1. copies the proxy (and the models.db helper) to %USERPROFILE%\.omp\sidecar
      2. installs a hidden, health-checked launcher in the per-user Startup folder
      3. routes every `google-antigravity` model in omp's model cache to the sidecar
      4. starts the sidecar and reports its health

    No administrator rights are required and no Python 3 is needed: the model
    cache is rewritten with Bun's built-in `bun:sqlite`.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$SidecarDir   = Join-Path $env:USERPROFILE '.omp\sidecar'
$StartupDir   = [Environment]::GetFolderPath('Startup')
$StartupVbs   = Join-Path $StartupDir 'omp-antigravity-sidecar.vbs'
$ProxyScript  = Join-Path $SidecarDir 'antigravity-masking-proxy.ts'
$PatchScript  = Join-Path $SidecarDir 'patch-models-db.ts'
$ControlCmd   = Join-Path $SidecarDir 'sidecar.cmd'
$HealthUrl    = 'http://127.0.0.1:45123/health'
$RepoRoot     = $PSScriptRoot

function Write-Step([string]$Message) {
    Write-Host "--> $Message"
}

function Resolve-Bun {
    # Prefer a real bun.exe: launching the npm `bun.cmd` shim from a hidden
    # launcher spawns a visible console window.
    $candidates = @(
        (Join-Path $env:USERPROFILE '.bun\bin\bun.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\bun\bun.exe'),
        (Join-Path $env:APPDATA 'npm\bun.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    $cmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw 'bun was not found on PATH. Install it first: https://bun.sh'
}

function Test-SidecarHealth {
    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 3 -UseBasicParsing
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

Write-Host '=========================================================='
Write-Host '  Antigravity Masking Sidecar Installer for Oh My Pi'
Write-Host '  (Windows)'
Write-Host '=========================================================='

if (-not (Test-Path (Join-Path $RepoRoot 'src\antigravity-masking-proxy.ts'))) {
    throw "Run this script from the repository root; src\antigravity-masking-proxy.ts was not found."
}

$bunExe = Resolve-Bun
Write-Step "Using Bun: $bunExe"

New-Item -ItemType Directory -Force -Path $SidecarDir | Out-Null

Copy-Item (Join-Path $RepoRoot 'src\antigravity-masking-proxy.ts') $ProxyScript -Force
Copy-Item (Join-Path $RepoRoot 'src\patch-models-db.ts')        $PatchScript -Force
Write-Step "Installed sidecar scripts to $SidecarDir"

# The launcher and control script ship with placeholders, matching the sed
# substitution install.sh performs on the systemd/launchd definitions.
$vbsTemplate = Get-Content (Join-Path $RepoRoot 'service\omp-antigravity-sidecar.vbs') -Raw
$vbsTemplate = $vbsTemplate.Replace('__BUN__', $bunExe).Replace('__SCRIPT__', $ProxyScript)
Set-Content -Path $StartupVbs -Value $vbsTemplate -Encoding ASCII
Write-Step "Installed logon launcher: $StartupVbs"

$cmdTemplate = Get-Content (Join-Path $RepoRoot 'service\sidecar.cmd') -Raw
$cmdTemplate = $cmdTemplate.Replace('__BUN__', $bunExe).Replace('__SCRIPT__', $ProxyScript)
Set-Content -Path $ControlCmd -Value $cmdTemplate -Encoding ASCII
Write-Step "Installed control script: $ControlCmd"

# Start now. The launcher exits immediately when the sidecar is already healthy,
# so this is safe to re-run.
if (Test-SidecarHealth) {
    Write-Step 'Sidecar already running.'
} else {
    Write-Step 'Starting sidecar...'
    & wscript.exe $StartupVbs
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-SidecarHealth) { break }
    }
}

# Route omp's cached google-antigravity models through the sidecar.
Write-Step 'Routing google-antigravity models through the sidecar...'
& $bunExe $PatchScript

Write-Host ''
if (Test-SidecarHealth) {
    Write-Host '=========================================================='
    Write-Host '  Sidecar is active and healthy on http://127.0.0.1:45123'
    Write-Host '  Google Antigravity fake 429 WAF error is now bypassed!'
    Write-Host ''
    Write-Host '  Verify with:'
    Write-Host '    omp -p "say hello" --model "google-antigravity/gemini-3.8-flash"'
    Write-Host ''
    Write-Host "  Manage with: $ControlCmd start|stop|status"
    Write-Host '=========================================================='
} else {
    Write-Warning "Sidecar health check failed. Inspect the log with: `"$ControlCmd`" status"
    exit 1
}
