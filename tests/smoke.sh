#!/usr/bin/env bash
# The Doom package installs as a settings and payload provider without claiming F5.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
ROOT="$REPO/engine/src/build-thurbox"
mkdir -p "$ROOT"
S=$(mktemp -d "$ROOT/smoke.XXXXXX")
trap 'rm -rf "$S"' EXIT
export XDG_CONFIG_HOME="$S/config" XDG_DATA_HOME="$S/data"
export XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state"
export THURBOX_CONFIG_DIR="$S/config/thurbox" THURBOX_DATA_DIR="$S/data/thurbox"
export THURBOX_UI_DIR="$S/ui"
mkdir -p "$THURBOX_CONFIG_DIR" "$THURBOX_DATA_DIR" "$THURBOX_UI_DIR"
"$CLI" plugin install "$REPO" --text > "$S/install.txt"
"$CLI" plugin check --text > "$S/check.txt"
rg -q 'doom' "$S/check.txt"
if rg -qi 'doom.open|claimed by both|failed' "$S/check.txt"; then
  cat "$S/check.txt" >&2
  exit 1
fi
printf 'Doom package loads without a separate F5 pane\n'
