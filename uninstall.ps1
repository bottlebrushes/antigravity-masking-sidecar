<#
.SYNOPSIS
    Uninstalls the Antigravity Masking Sidecar on Windows.

.DESCRIPTION
    Reverses everything install.ps1 did:

      1. stops the sidecar process listening on the sidecar port
      2. removes the per-user Startup launcher
      3. restores omp's pre-sidecar model cache
      4. optionally deletes %USERPROFILE%\.omp\sidecar

.PARAMETER Purge
    Also delete the installed sidecar directory. Without it, the proxy scripts
    stay on disk so a later install.ps1 can reuse them.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>

[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$SidecarDir  = Join-Path $env:USERPROFILE '.omp\sidecar'
$StartupDir  = [Environment]::GetFolderPath('Startup')
$StartupVbs  = Join-Path $StartupDir 'omp-antigravity-sidecar.vbs'
$PatchScript = Join-Path $SidecarDir 'patch-models-db.ts'
$Port        = 45123
$RepoRoot    = $PSScriptRoot

function Resolve-Bun {
    foreach ($candidate in @(
        (Join-Path $env:USERPROFILE '.bun\bin\bun.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\bun\bun.exe'),
        (Join-Path $env:APPDATA 'npm\bun.exe')
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    $cmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

Write-Host '=========================================================='
Write-Host '  Antigravity Masking Sidecar Uninstaller (Windows)'
Write-Host '=========================================================='

# 1. Stop the listener, if any.
$owners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique
if ($owners) {
    foreach ($owner in $owners) {
        Write-Host "--> Stopping sidecar process $owner"
        Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '--> Sidecar was not running'
}

# 2. Remove the logon launcher.
if (Test-Path $StartupVbs) {
    Remove-Item $StartupVbs -Force
    Write-Host "--> Removed launcher: $StartupVbs"
} else {
    Write-Host '--> No logon launcher found'
}

# 3. Restore the pre-sidecar model cache.
#
# Always through the helper: models.db runs in WAL mode, so copying the backup
# file over it would leave the patched pages in models.db-wal and SQLite would
# replay them on the next open.
$bunExe = Resolve-Bun
$helper = $PatchScript
if (-not (Test-Path $helper)) {
    $repoHelper = Join-Path $RepoRoot 'src\patch-models-db.ts'
    if (Test-Path $repoHelper) { $helper = $repoHelper }
}

if ($bunExe -and (Test-Path $helper)) {
    & $bunExe $helper --restore
} else {
    Write-Warning 'Could not locate bun or patch-models-db.ts; models.db was left pointed at the sidecar.'
    Write-Warning 'Re-run install.ps1, then uninstall.ps1 from the repository directory to restore it.'
}

# 4. Optionally purge installed scripts.
if ($Purge -and (Test-Path $SidecarDir)) {
    Remove-Item $SidecarDir -Recurse -Force
    Write-Host "--> Removed $SidecarDir"
}

Write-Host ''
Write-Host 'Uninstall complete. Restart any running omp session to pick up the change.'
