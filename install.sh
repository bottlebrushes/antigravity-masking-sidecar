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

# Route google-antigravity through the local sidecar proxy.
# This goes in models.yml, not the models.db catalog cache: omp resolves a
# provider baseUrl from config before the cache, and any catalog refresh
# rewrites the cached rows.
MODELS_YML="$HOME/.omp/agent/models.yml"
ENTRY="  google-antigravity:\n    baseUrl: http://127.0.0.1:45123"

if grep -q "google-antigravity:" "$MODELS_YML" 2>/dev/null; then
  echo "--> $MODELS_YML already has a google-antigravity entry, leaving it alone."
  echo "    It needs 'baseUrl: http://127.0.0.1:45123' to route through the sidecar."
elif grep -q "^providers:" "$MODELS_YML" 2>/dev/null; then
  echo "--> Adding google-antigravity to providers in $MODELS_YML..."
  awk -v entry="$ENTRY" '{print} /^providers:[[:space:]]*$/ && !done {print entry; done=1}' \
    "$MODELS_YML" > "$MODELS_YML.tmp" && mv "$MODELS_YML.tmp" "$MODELS_YML"
else
  echo "--> Routing google-antigravity through the sidecar in $MODELS_YML..."
  printf 'providers:\n%b\n' "$ENTRY" >> "$MODELS_YML"
fi

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
