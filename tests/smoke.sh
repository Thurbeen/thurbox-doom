#!/usr/bin/env bash
# Exercise the pane in an isolated copy of the interface shipped with the
# installed thurbox. The bundled Pipelines pane owns F7 in current releases.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
TUI=${THURBOX_BIN:-thurbox}
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
BASE_UI=${THURBOX_BASE_UI:-$(THURBOX_DATA_DIR="$S/probe-data" "$CLI" plugin dir --text | head -1)}

export HOME="$S" XDG_CONFIG_HOME="$S/config" XDG_DATA_HOME="$S/data"
export XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state"
export THURBOX_CONFIG_DIR="$S/config/thurbox" THURBOX_DATA_DIR="$S/data/thurbox"
export THURBOX_UI_DIR="$S/ui" TMUX_TMPDIR="$SOCKET_ROOT" TERM=xterm-256color
export COLORTERM=truecolor
unset NO_COLOR
unset THURBOX_SOCKET THURBOX_SOCKET_FOR THURBOX_SESSION THURBOX_SESSION_ID
mkdir -p "$THURBOX_CONFIG_DIR" "$THURBOX_DATA_DIR" "$S/ui/plugins" "$S/ui/thurbox-doom/plugins" "$S/ui/thurbox-doom/engine/bin/linux-x86_64" "$S/ui/thurbox-doom/wad"
cp -a "$BASE_UI/lib" "$BASE_UI/layout.lua" "$BASE_UI/AGENTS.md" "$BASE_UI/README.md" "$S/ui/"
cp -a "$BASE_UI/plugins/." "$S/ui/plugins/"
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
if grep -Ei 'f7.*doom\.open|doom\.open.*f7' "$S/check.txt"; then
  echo 'DOOM conflicts with the bundled F7 binding' >&2
  exit 1
fi

# Match the Interface tab's capability record, scoped to this disposable copy.
python3 - "$S/ui/thurbox-doom/plugins/40_doom.lua" "$THURBOX_CONFIG_DIR/ui.json" <<'PY'
import json
import pathlib
import sys

pane, config = map(pathlib.Path, sys.argv[1:])
digest = 0xCBF29CE484222325
for byte in pane.read_bytes():
    digest = ((digest ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
config.write_text(json.dumps({"trusted": {str(pane): f"{digest:016x}"}}))
PY
sqlite3 "$THURBOX_DATA_DIR/thurbox.db" \
  "INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1') ON CONFLICT(key) DO UPDATE SET value = '1';"

if [ -n "${RECORD_CAST:-}" ]; then
  printf -v tui_command 'asciinema rec --overwrite --quiet --cols 112 --rows 32 --command %q %q' "$TUI" "$RECORD_CAST"
else
  tui_command="$TUI"
fi
tmux -S "$DRIVE_SOCKET" new-session -d -s smoke -x 112 -y 32 "$tui_command"
capture() { tmux -S "$DRIVE_SOCKET" capture-pane -p -t smoke; }
for _ in $(seq 1 80); do
  if capture | grep -qF 'No sessions yet'; then break; fi
  sleep 0.2
done
capture | grep -qF 'No sessions yet' || { capture >&2; echo 'thurbox did not reach the main interface' >&2; exit 1; }
tmux -S "$DRIVE_SOCKET" send-keys -t smoke F8
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
      key Enter 1
      key Enter 1
      key Enter 2
      key Up 1
      key Up 1
      key f 1
      key F8 2
      key F8 2
      key Right 1
      key C-q 1
      for _ in $(seq 1 30); do
        if [ -s "$RECORD_CAST" ]; then break; fi
        sleep 0.2
      done
      [ -s "$RECORD_CAST" ] || { echo 'recording was not written' >&2; exit 1; }
    fi
    echo 'DOOM focused through F8 in the current interface'
    exit 0
  fi
  sleep 0.2
done
capture >&2
echo 'F8 did not focus the DOOM pane' >&2
exit 1
