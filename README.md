<div align="center">

![Antigravity Masking Sidecar](assets/header.jpg)

# Antigravity Masking Sidecar

**Transparent, future-proof sidecar proxy for Oh My Pi (omp) & Google Antigravity.**  
*Bypasses fake `429 RESOURCE_EXHAUSTED` WAF filters by dynamically sanitizing harness-specific prompt tags and telemetry labels.*

[![License: MIT](https://img.shields.io/badge/License-MIT-cyan.svg)](LICENSE)
[![Runtime: Bun](https://img.shields.io/badge/Runtime-Bun-f472b6.svg)](https://bun.sh)
[![Platform: macOS%20|%20Linux%20|%20Windows](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-a855f7.svg)]()

</div>

---

### The Problem

When using Google Antigravity (`gemini-3.8-flash`, `gemini-3.8-pro`, `claude-*`) through `omp`, requests randomly or deterministically fail with:

```json
Cloud Code Assist API error (429): {
  "error": {
    "code": 429,
    "message": "Resource has been exhausted (e.g. check quota).",
    "status": "RESOURCE_EXHAUSTED"
  }
}
```

#### Root Cause
This is **not** a quota exhaustion. Google’s front-end API gateway (`daily-cloudcode-pa.googleapis.com`) has a pattern-matching WAF inspection rule that triggers whenever **`"requestType": "agent"`** is sent alongside `omp`'s default system prompt tags:

```xml
<system-conventions>
RFC 2119: MUST, REQUIRED, SHOULD, RECOMMENDED, MAY, OPTIONAL.
</system-conventions>
```

Binary-patching strings in `omp` binaries is brittle because:
1. Upstream updates or rebuilds overwrite the binary patch.
2. Google can add filters for subsequent tags (`<system-directive>`, `used_claude_conservative`, etc.).
3. You have to re-patch binaries separately on every machine (macOS, Linux).

---

### The Solution: Dynamic Sidecar Proxy

The **Antigravity Masking Sidecar** runs as a lightweight local proxy (`http://127.0.0.1:45123`) between `omp` and Google's backend:

1. **Omit `requestType`**: Automatically drops top-level `"requestType": "agent"` from JSON payloads, exactly mirroring the official Antigravity IDE contract.
2. **Tag Normalization**: Automatically converts all variants of `<system-conventions>`, `<system_conventions>`, `<system-directive>`, and `<critical>` into neutral equivalents (`<conventions>`, `<instructions>`, `<important>`).
3. **Harness Neutralization**: Strips textual harness markers (`"Oh My Pi coding harness"` → `"AI coding assistant"`).
4. **Telemetry Sanitization**: Removes fingerprinting labels like `used_claude_conservative` and `used_claude`.
5. **Header Normalization**: Emits official Antigravity client headers (`ideType=IDE_UNSPECIFIED`, clean `User-Agent`).
6. **Full SSE Streaming**: Forwards Server-Sent Events chunk-by-chunk in real time with zero latency overhead.

---

### Quick Start (1-Minute Setup)

#### Prerequisites
* **macOS & Linux**: [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`) and Python 3
* **Windows**: PowerShell 5.1+ and Git — the installer bootstraps Bun for you

#### 1. Clone & Install — macOS & Linux
```bash
git clone https://github.com/bottlebrushes/antigravity-masking-sidecar.git
cd antigravity-masking-sidecar
./install.sh
```

The installer will:
* Install the proxy script to `~/.omp/sidecar/antigravity-masking-proxy.ts`
* Configure and start the background daemon:
  * **Linux**: `systemd` user service (`omp-antigravity-sidecar.service`)
  * **macOS**: `launchd` user agent (`com.antigravity.masking-sidecar.plist`)
* Route all `google-antigravity` models in `~/.omp/agent/models.db` to the local sidecar.

#### 1. Clone & Install — Windows
```powershell
git clone https://github.com/bottlebrushes/antigravity-masking-sidecar.git
cd antigravity-masking-sidecar
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The Windows installer additionally:
* Installs [Bun](https://bun.sh) automatically if missing
* Writes a windowless `wscript` launcher (`%USERPROFILE%\.omp\sidecar\sidecar.vbs`) so no console window is left open
* Registers a hidden **at-logon Scheduled Task** (`AntigravitySidecar`) whose launcher supervises the proxy and restarts it 3s after any exit, mirroring the systemd unit's `Restart=always` — no admin rights required
* Adds the `google-antigravity` provider override to `%USERPROFILE%\.omp\agent\models.yml`, preserving its encoding, indentation and line endings. Before modifying an existing file for the first time it writes `models.yml.pre-sidecar.bak`; that snapshot is never overwritten by later runs
* Logs proxy output to `%USERPROFILE%\.omp\sidecar\sidecar.log`, truncated at 5 MB when the proxy restarts — the Windows counterpart to `journalctl` / launchd's log file

> Note: the Windows installer routes traffic via the documented `models.yml` provider override instead of rewriting the `models.db` cache — the override survives cache refreshes and is trivially reversible.

<details>
<summary><b>models.yml shapes the Windows installer will not edit</b></summary>

The installer edits `models.yml` textually so it can preserve your formatting, which means it only touches shapes it can reason about safely. It refuses **before** stopping a running sidecar and tells you what to add by hand:

| Shape | Why |
|---|---|
| A YAML document marker (`---` / `...`, with or without a comment) | It cannot tell which document to edit |
| An inline `providers: { ... }` mapping | Rewriting flow style would reformat your file |
| A flow collection spanning lines (`models: {` … `}` across several lines) | Its inner lines look unindented, so a `providers:` member could be mistaken for a top-level key. Single-line flow values (`models: {a: 1}`) are fine |
| A root that is not a plain block mapping — the whole file is `{}` / `[...]`, a bare scalar, a sequence, or carries a node property (`!!map {...}`, `&anchor`, `*alias`, `%YAML 1.2`, `? complex key`) | Appending a `providers:` key would create a second root node. A block mapping whose *values* are flow style (`models: {}`) is fine |
| Any top-level line it cannot classify as a block mapping key — a stray flow closer (`}`), a root sequence entry, or a node property | The check is deliberately conservative: it refuses rather than guess. Unusual but valid key spellings (`a!b: 1`, `'a,b': 1`) are fine |
| An escaped double-quoted key anywhere in the file (`"pro\u0076iders":`) | It compares keys literally and will not risk inserting a duplicate |

It also leaves your file untouched — without failing — when `google-antigravity` already exists but points somewhere else, or when its value is an inline mapping whose route cannot be verified. In that case the sidecar still starts and the installer exits **2**, meaning *routing needs your attention or could not be verified*. Point that provider's `baseUrl` at `http://127.0.0.1:45123` and re-run.

Normalise the unsupported shape before re-running: simply adding the override while leaving, say, a document marker in place will still be refused.

Exit codes: **0** installed and routed · **1** the sidecar is unhealthy, something else already owns port 45123, or the install failed outright · **2** the sidecar is (or was left) running but its `models.yml` routing needs attention or could not be verified — if a failure interrupted the install, the message says whether the sidecar came back up.

</details>

#### 2. Verify (all platforms)
Run an `omp` test command:
```bash
# macOS / Linux
omp -p "say hello" --model "google-antigravity/gemini-3.8-flash-medium" </dev/null
```
```powershell
# Windows PowerShell
omp -p "say hello" --model "google-antigravity/gemini-3.8-flash-medium"
```

You should see an immediate `HTTP 200` response:
```
Working...
Hello. How can I help you today?
```

---

### Service Management

#### Linux (systemd)
```bash
# Check status
systemctl --user status omp-antigravity-sidecar.service

# View live logs
journalctl --user -u omp-antigravity-sidecar.service -f

# Restart service
systemctl --user restart omp-antigravity-sidecar.service
```

#### macOS (launchd)
```bash
# View logs
tail -f /tmp/antigravity-sidecar.log

# Restart agent
launchctl unload ~/Library/LaunchAgents/com.antigravity.masking-sidecar.plist
launchctl load -w ~/Library/LaunchAgents/com.antigravity.masking-sidecar.plist
```
#### Windows (Task Scheduler)
```powershell
# Check status
Get-ScheduledTask -TaskName AntigravitySidecar | Select-Object TaskName, State
Invoke-RestMethod http://127.0.0.1:45123/health   # service should read omp-antigravity-sidecar

# View logs
Get-Content "$env:USERPROFILE\.omp\sidecar\sidecar.log" -Tail 40 -Wait

# Start
Start-ScheduledTask -TaskName AntigravitySidecar

# Stop. The launcher supervises the proxy and restarts it 3s after any exit,
# so ALWAYS stop the task first - killing the proxy alone just respawns it.
$dir = "$env:USERPROFILE\.omp\sidecar"
Stop-ScheduledTask -TaskName AntigravitySidecar
Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='cmd.exe' OR Name='bun.exe'" |
  Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($dir.ToLower()) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Uninstall - same ordering: unregistering a task does NOT stop it if running
$dir = "$env:USERPROFILE\.omp\sidecar"
Stop-ScheduledTask -TaskName AntigravitySidecar
Unregister-ScheduledTask -TaskName AntigravitySidecar -Confirm:$false
Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='cmd.exe' OR Name='bun.exe'" |
  Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($dir.ToLower()) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Restore the pre-install config. The .bak is a snapshot of models.yml as it was
# the FIRST time an install modified it - not the most recent run - so restoring
# it discards every edit made since. It exists only if the installer actually
# modified a pre-existing models.yml.
$yml = "$env:USERPROFILE\.omp\agent\models.yml"
if (Test-Path "$yml.pre-sidecar.bak") { Copy-Item "$yml.pre-sidecar.bak" $yml -Force }
else { Write-Host "No backup: remove the 'google-antigravity' block from $yml by hand" }
Remove-Item "$env:USERPROFILE\.omp\sidecar" -Recurse -Force
```

---

### Integration with `omp` Wrappers

If you use a custom wrapper around `omp` (such as `omp-wrapper.ts`), you can add a lightweight health-check hook to guarantee the sidecar is always live before executing:

```typescript
export async function ensureAntigravitySidecar(): Promise<void> {
  const sidecarHealth = "http://127.0.0.1:45123/health";
  try {
    const res = await fetch(sidecarHealth, { signal: AbortSignal.timeout(200) });
    if (res.ok) return;
  } catch {}

  try {
    const proc = Bun.spawn(["systemctl", "--user", "start", "omp-antigravity-sidecar.service"]);
    await proc.exited;
  } catch {
    const scriptPath = `${process.env.HOME}/.omp/sidecar/antigravity-masking-proxy.ts`;
    Bun.spawn(["bun", scriptPath], {
      detached: true,
      stdio: ["ignore", "ignore", "ignore"],
    }).unref();
  }
}
```

---

### License
[MIT](LICENSE) © [bottlebrushes](https://github.com/bottlebrushes)
