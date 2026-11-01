#!/usr/bin/env bash
# Beside a code-review agent pane without a Doom tab, standalone Doom draws its
# pane and binds F5; beside one with the tab, it defers to the tab.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
ROOT="$REPO/engine/src/build-thurbox"
mkdir -p "$ROOT"
TMP=$(mktemp -d "$ROOT/standalone.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

check() {
  local sha=$1 S="$TMP/$1"
  mkdir -p "$S"
  export XDG_CONFIG_HOME="$S/config" XDG_DATA_HOME="$S/data"
  export XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state"
  export THURBOX_CONFIG_DIR="$S/config/thurbox" THURBOX_DATA_DIR="$S/data/thurbox"
  export THURBOX_UI_DIR="$S/ui"
  mkdir -p "$THURBOX_CONFIG_DIR" "$THURBOX_DATA_DIR" "$THURBOX_UI_DIR"

  # Installing seeds the interface's own lib/. The copies below replace the
  # pane, and code-review's agent pane replaces the bundled one.
  "$CLI" plugin install "$REPO" --text > "$S/install.txt"
  rm "$S/ui/plugins/40_doom.lua" "$S/ui/plugins/20_agent.lua" "$S/ui/plugins.lock"
  git init -q "$S/ui/thurbox-code-review"
  git -C "$S/ui/thurbox-code-review" fetch -q --depth 1 \
    https://github.com/Thurbeen/thurbox-code-review "$sha"
  git -C "$S/ui/thurbox-code-review" checkout -q FETCH_HEAD
  mkdir -p "$S/ui/thurbox-doom/plugins" "$S/ui/thurbox-doom/lib"
  cp "$REPO/plugins/40_doom.lua" "$S/ui/thurbox-doom/plugins/40_doom.lua"
  cp "$REPO/lib/doom.lua" "$S/ui/thurbox-doom/lib/doom.lua"
  cat > "$S/ui/plugins.toml" <<'TOML'
[[plugin]]
src = "git+https://github.com/Thurbeen/thurbox-code-review"
file = "thurbox-code-review/plugins/20_agent.lua"

[[plugin]]
src = "git+https://github.com/Thurbeen/thurbox-doom"
file = "thurbox-doom/plugins/40_doom.lua"
TOML

  if ! "$CLI" plugin check --text > "$S/check.txt" 2>&1 ||
    grep -Eqi 'doom\.open|claimed by both|failed' "$S/check.txt"; then
    cat "$S/check.txt" >&2
    echo "FAIL: Doom is unreachable beside code-review ${sha:0:7}" >&2
    exit 1
  fi
  printf 'Doom is reachable beside code-review %s\n' "${sha:0:7}"
}

# code-review main: ships lib/review.lua but has no Doom tab.
check 435dd3b4ce19fab6ddb16e33a8ac541318f840a2
# code-review feat/doom-agent-tab: its agent pane has the Doom tab.
check 7fba08929b7f5c5234da440bed047efb467250c0
