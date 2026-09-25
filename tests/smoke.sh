#!/usr/bin/env bash
# Exercise the pane in a fresh copy of the interface bundled with the
# installed thurbox.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
TUI=${THURBOX_BIN:-thurbox}
TUI_COLS=${TUI_COLS:-112}
TUI_ROWS=${TUI_ROWS:-32}
ROOT="$REPO/engine/src/build-thurbox"
mkdir -p "$ROOT"
S=$(mktemp -d "$ROOT/smoke.XXXXXX")
SOCKET_ROOT=$(mktemp -d /tmp/doom-smoke.XXXXXX)
SOCKET="doom-smoke-$$"
DRIVE_SOCKET="$SOCKET_ROOT/$SOCKET"
GAME_SOCKET="$SOCKET_ROOT/tmux-$(id -u)/thurbox"
# Invoked through the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  tmux -S "$DRIVE_SOCKET" kill-server >/dev/null 2>&1 || true
  tmux -S "$GAME_SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$S"
  rm -rf "$SOCKET_ROOT"
}
trap cleanup EXIT
export HOME="$S" XDG_CONFIG_HOME="$S/config" XDG_DATA_HOME="$S/data"
export XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state"
export THURBOX_CONFIG_DIR="$S/config/thurbox" THURBOX_DATA_DIR="$S/data/thurbox"
export THURBOX_UI_DIR="$S/ui" TMUX_TMPDIR="$SOCKET_ROOT" TERM=xterm-256color
export COLORTERM=truecolor
unset NO_COLOR
unset THURBOX_SOCKET THURBOX_SOCKET_FOR THURBOX_SESSION THURBOX_SESSION_ID
mkdir -p "$THURBOX_CONFIG_DIR" "$THURBOX_DATA_DIR" "$S/ui" "$S/ui/thurbox-doom/plugins" "$S/ui/thurbox-doom/engine/bin/linux-x86_64" "$S/ui/thurbox-doom/wad"
# Installing this local source bootstraps the release's bundled interface.
# Move its flat copy aside; the fixture below loads the plugin as a clone.
"$CLI" plugin install "$REPO" --text > "$S/install.txt"
mv "$S/ui/plugins/40_doom.lua" "$S/bootstrapped-pane.lua"
mv "$S/ui/plugins.lock" "$S/bootstrapped-plugins.lock"
cp "$REPO/plugins/40_doom.lua" "$S/ui/thurbox-doom/plugins/40_doom.lua"
cp "$REPO/plugin.toml" "$S/ui/thurbox-doom/plugin.toml"
cp "$REPO/engine/bin/linux-x86_64/doom" "$S/ui/thurbox-doom/engine/bin/linux-x86_64/doom"
cp "$REPO/wad/doom1.wad" "$S/ui/thurbox-doom/wad/doom1.wad"
cat > "$S/ui/plugins.toml" <<'TOML'
[[plugin]]
src = "git+https://github.com/Thurbeen/thurbox-doom"
file = "thurbox-doom/plugins/40_doom.lua"
TOML

"$CLI" plugin check --text > "$S/check.txt"
if grep -Ei 'claimed by both.*doom\.open|doom\.open.*claimed by both' "$S/check.txt"; then
  echo 'DOOM conflicts with a bundled global binding' >&2
  exit 1
fi

# Match the Interface tab's capability record, scoped to this disposable copy.
python3 - "$S/ui/thurbox-doom/plugins/40_doom.lua" "$THURBOX_CONFIG_DIR/ui.json" <<'PY'
import json
import os
import pathlib
import sys

pane, config = map(pathlib.Path, sys.argv[1:])
digest = 0xCBF29CE484222325
for byte in pane.read_bytes():
    digest = ((digest ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
overrides = {"trusted": {str(pane): f"{digest:016x}"}}
if os.environ.get("RECORD_CAST"):
    overrides["settings"] = {"doom.args": "-warp 1 1 -iwad"}
config.write_text(json.dumps(overrides))
PY
sqlite3 "$THURBOX_DATA_DIR/thurbox.db" \
  "INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1') ON CONFLICT(key) DO UPDATE SET value = '1';"

if [ -n "${RECORD_CAST:-}" ]; then
  printf -v tui_command 'asciinema rec --overwrite --quiet --cols %q --rows %q --command %q %q' "$TUI_COLS" "$TUI_ROWS" "$TUI" "$RECORD_CAST"
else
  tui_command="$TUI"
fi
tmux -S "$DRIVE_SOCKET" new-session -d -s smoke -x "$TUI_COLS" -y "$TUI_ROWS" "$tui_command"
capture() { tmux -S "$DRIVE_SOCKET" capture-pane -p -t smoke; }
for _ in $(seq 1 80); do
  if capture | grep -qF 'No sessions yet'; then break; fi
  sleep 0.2
done
capture | grep -qF 'No sessions yet' || { capture >&2; echo 'thurbox did not reach the main interface' >&2; exit 1; }
tmux -S "$DRIVE_SOCKET" send-keys -t smoke F5
for _ in $(seq 1 80); do
  if capture | grep -q '▸ DOOM'; then
    sleep 3
    if ! tmux -S "$GAME_SOCKET" list-windows -a | grep -q 'doom'; then
      capture >&2
      echo 'the DOOM process did not start' >&2
      exit 1
    fi
    if [[ "$(capture)" != *"▀▀▀"* ]]; then
      capture >&2
      echo 'the DOOM program surface did not render game cells' >&2
      exit 1
    fi
    if [ -n "${SNAP:-}" ]; then
      capture > "$SNAP"
      tmux -S "$DRIVE_SOCKET" capture-pane -pe -t smoke > "$SNAP.ansi"
      tmux -S "$GAME_SOCKET" list-windows -a > "$SNAP.windows" 2>&1 || true
    fi
    if [ -n "${RECORD_CAST:-}" ]; then
      key() { tmux -S "$DRIVE_SOCKET" send-keys -t smoke "$1"; sleep "$2"; }
      key Up 1
      key Up 1
      key f 1
      key Right 1
      key Up 1
      key f 1
      key C-q 1
      for _ in $(seq 1 30); do
        if [ -s "$RECORD_CAST" ]; then break; fi
        sleep 0.2
      done
      [ -s "$RECORD_CAST" ] || { echo 'recording was not written' >&2; exit 1; }
    fi
    echo 'DOOM focused through F5 in the current interface'
    exit 0
  fi
  sleep 0.2
done
capture >&2
echo 'F5 did not focus the DOOM pane' >&2
exit 1
