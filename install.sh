#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "  Antigravity Masking Sidecar Installer for Oh My Pi"
echo "=========================================================="

SIDECAR_DIR="$HOME/.omp/sidecar"
mkdir -p "$SIDECAR_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/src/antigravity-masking-proxy.ts" "$SIDECAR_DIR/antigravity-masking-proxy.ts"
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

# Route models.db through the local sidecar proxy
MODELS_DB="$HOME/.omp/agent/models.db"
if [ -f "$MODELS_DB" ]; then
  echo "--> Updating $MODELS_DB to route through sidecar (http://127.0.0.1:45123)..."
  python3 -c "
import sqlite3, json, shutil

db_path = '$MODELS_DB'
shutil.copyfile(db_path, db_path + '.pre-sidecar.bak')

conn = sqlite3.connect(db_path)
c = conn.cursor()
c.execute('SELECT models FROM model_cache WHERE provider_id = \"google-antigravity\"')
row = c.fetchone()
if row:
    models = json.loads(row[0])
    for m in models:
        m['baseUrl'] = 'http://127.0.0.1:45123'
    c.execute('UPDATE model_cache SET models = ? WHERE provider_id = \"google-antigravity\"', (json.dumps(models),))
    conn.commit()
    print(f'Successfully redirected {len(models)} models to sidecar.')
conn.close()
"
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
