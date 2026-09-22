<div align="center">

![Antigravity Masking Sidecar](assets/header.jpg)

# Antigravity Masking Sidecar

**Transparent, future-proof sidecar proxy for Oh My Pi (omp) & Google Antigravity.**  
*Bypasses fake `429 RESOURCE_EXHAUSTED` WAF filters by dynamically sanitizing harness-specific prompt tags and telemetry labels.*

[![License: MIT](https://img.shields.io/badge/License-MIT-cyan.svg)](LICENSE)
[![Runtime: Bun](https://img.shields.io/badge/Runtime-Bun-f472b6.svg)](https://bun.sh)
[![Platform: macOS%20|%20Linux](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-a855f7.svg)]()

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

1. **Omit `requestType`**: Automatically drops the top-level `"requestType": "agent"` field.
2. **Block Canonicalization**: Replaces the complete `<system-conventions>` or `<system_conventions>` block with stable neutral wording, including arbitrary new wording OMP may add inside that block. A bounded fallback covers standalone RFC 2119/8174 clauses.
3. **Harness Neutralization**: Strips textual harness markers (`"Oh My Pi coding harness"` → `"AI coding assistant"`).
4. **Telemetry Sanitization**: Removes fingerprinting labels like `used_claude_conservative` and `used_claude`.
5. **Header Normalization**: Emits official Antigravity client headers (`ideType=IDE_UNSPECIFIED`, clean `User-Agent`).
6. **Full SSE Streaming**: Forwards Server-Sent Events chunk-by-chunk in real time with zero latency overhead.

---

### Quick Start (1-Minute Setup)

#### Prerequisites
* [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`)
* Python 3 (standard on macOS & Linux)

#### 1. Clone & Install
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
* Persistently route `google-antigravity` through the sidecar using OMP's declarative `~/.omp/agent/models.yml` override. The refreshable `models.db` cache is not modified.

#### 2. Verify
Run an `omp` test command:
```bash
omp -p "say hello" --model "google-antigravity/gemini-3.8-flash-medium" </dev/null
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
