#!/usr/bin/env bash
set -euo pipefail

# This script is intended for bb's script automation runtime. The cheap poll
# runs frequently, but an LLM thread is created only when the installed OMP
# version on the selected machine changes.
BB_CMD="${BB_CLI:-bb}"
OMP_HOST="${OMP_HOST_ID:?OMP_HOST_ID is required}"
PROJECT_ID="${BB_PROJECT_ID:?BB_PROJECT_ID is required}"
STATE_FILE="${PWD}/last-omp-version"

terminal_json="$($BB_CMD terminal create --machine "$OMP_HOST" \
  --title "OMP version probe" \
  --command 'omp --version 2>&1; sleep 8' --json)"
terminal_id="$(printf '%s\n' "$terminal_json" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$terminal_id" ] || { echo "Unable to create OMP version probe terminal" >&2; exit 1; }

sleep 2
output="$($BB_CMD terminal output "$terminal_id" --tail-bytes 4096 2>/dev/null || true)"
$BB_CMD terminal close "$terminal_id" --force >/dev/null 2>&1 || true
version="$(printf '%s\n' "$output" | sed -n 's/.*omp\/\([0-9][0-9.]*\).*/\1/p' | tail -n 1)"
[ -n "$version" ] || { echo "Unable to determine installed OMP version" >&2; exit 1; }

previous=""
[ -f "$STATE_FILE" ] && previous="$(tr -d '\r\n' < "$STATE_FILE")"
if [ -z "$previous" ]; then
  printf '%s\n' "$version" > "$STATE_FILE"
  printf '%s\n' '{"wakeAgent": false}'
  exit 0
fi
if [ "$version" = "$previous" ]; then
  printf '%s\n' '{"wakeAgent": false}'
  exit 0
fi

prompt="OMP changed from ${previous} to ${version} on the monitored Mac. Review the installed OMP configuration and request-building behavior against https://github.com/bottlebrushes/antigravity-masking-sidecar. Inspect the actual local OMP binary/configuration and the repository at its current main branch. Test whether models.yml still provides the google-antigravity baseUrl override, whether OMP's conventions/system prompt shape is covered by the sidecar canonicalizer, and whether installation/service configuration remains valid. Do not expose credentials or prompt contents. Do not mutate the installation or push changes; produce an evidence-backed compatibility report with exact recommended changes if needed."

$BB_CMD thread spawn \
  --project "$PROJECT_ID" \
  --machine "$OMP_HOST" \
  --new-environment personal \
  --provider codex \
  --model gpt-5.6-sol \
  --reasoning-level high \
  --permission-mode auto \
  --title "Review OMP ${version} sidecar" \
  --prompt "$prompt" >/dev/null

printf '%s\n' "$version" > "$STATE_FILE"
echo "OMP ${version} detected; compatibility review thread created."
