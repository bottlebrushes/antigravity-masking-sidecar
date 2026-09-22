#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "  Antigravity Masking Sidecar Installer for Oh My Pi"
echo "=========================================================="

SIDECAR_DIR="$HOME/.omp/sidecar"
mkdir -p "$SIDECAR_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/src/antigravity-masking-proxy.ts" "$SIDECAR_DIR/antigravity-masking-proxy.ts"
cp "$SCRIPT_DIR/src/sanitizer.ts" "$SIDECAR_DIR/sanitizer.ts"
chmod +x "$SIDECAR_DIR/antigravity-masking-proxy.ts"

BUN_BIN="$(which bun 2>/dev/null || echo "/usr/local/bin/bun")"
if ! command -v "$BUN_BIN" &>/dev/null; then
  echo "Error: bun is required. Please install bun (https://bun.sh) first."
  exit 1
fi

OS="$(uname -s)"

if [ "$OS" = "Linux" ]; then
  echo "--> Installing systemd user service..."
  SYSTEMD_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_DIR"
  cp "$SCRIPT_DIR/service/omp-antigravity-sidecar.service" "$SYSTEMD_DIR/omp-antigravity-sidecar.service"
  # Replace bun path if needed
  sed -i "s|/usr/local/bin/bun|$BUN_BIN|g" "$SYSTEMD_DIR/omp-antigravity-sidecar.service"
  systemctl --user daemon-reload
  systemctl --user enable --now omp-antigravity-sidecar.service
  echo "--> systemd service started."

elif [ "$OS" = "Darwin" ]; then
  echo "--> Installing macOS LaunchAgent..."
  LAUNCH_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$LAUNCH_DIR"
  PLIST="$LAUNCH_DIR/com.antigravity.masking-sidecar.plist"
  cp "$SCRIPT_DIR/service/com.antigravity.masking-sidecar.plist" "$PLIST"
  sed -i "" "s|/usr/local/bin/bun|$BUN_BIN|g" "$PLIST"
  sed -i "" "s|/Users/SHARED_USER|$HOME|g" "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  echo "--> LaunchAgent loaded."
fi

# Route OMP through its durable, declarative models.yml override. Unlike
# models.db, this file is configuration rather than a refreshable cache.
MODELS_YML="$HOME/.omp/agent/models.yml"
mkdir -p "$(dirname "$MODELS_YML")"
[ -f "$MODELS_YML" ] || printf 'providers:\n' > "$MODELS_YML"
echo "--> Updating $MODELS_YML to route google-antigravity through the sidecar..."
cp "$MODELS_YML" "$MODELS_YML.pre-sidecar.bak"
python3 - "$MODELS_YML" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
if not any(line.rstrip() == "providers:" and not line.startswith((" ", "\t")) for line in lines):
    raise SystemExit(f"{path} has no top-level providers mapping")

provider_start = next((i for i, line in enumerate(lines) if line.rstrip() == "  google-antigravity:"), None)
if provider_start is None:
    providers_line = next(i for i, line in enumerate(lines) if line.rstrip() == "providers:")
    lines[providers_line + 1:providers_line + 1] = [
        "  google-antigravity:",
        "    baseUrl: http://127.0.0.1:45123",
    ]
else:
    provider_end = len(lines)
    for i in range(provider_start + 1, len(lines)):
        if lines[i] and not lines[i].startswith("    "):
            provider_end = i
            break
    base_url = next(
        (i for i in range(provider_start + 1, provider_end) if lines[i].lstrip().startswith("baseUrl:")),
        None,
    )
    if base_url is None:
        lines.insert(provider_start + 1, "    baseUrl: http://127.0.0.1:45123")
    else:
        lines[base_url] = "    baseUrl: http://127.0.0.1:45123"

temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text("\n".join(lines) + "\n")
temporary.replace(path)
PY

# Verification
sleep 1
if curl -s http://127.0.0.1:45123/health >/dev/null; then
  echo "=========================================================="
  echo "✓ Sidecar is active and healthy on http://127.0.0.1:45123"
  echo "✓ Google Antigravity fake 429 WAF error is now bypassed!"
  echo "=========================================================="
else
  echo "Warning: Sidecar health check failed. Check logs."
fi
