#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

for tool in luac stylua shellcheck make cc thurbox thurbox-cli tmux sqlite3 python3; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done

luac -p plugins/40_doom.lua
stylua --check plugins/40_doom.lua
shellcheck scripts/check.sh tests/smoke.sh demo/record.sh

# The engine test writes this executable in the source directory. Keep any
# executable that was already there, and remove only the one this gate created.
had_release_test=false
[ -e engine/src/release_test ] && had_release_test=true
# Invoked through the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  if [ "$had_release_test" = false ]; then rm -f engine/src/release_test; fi
}
trap cleanup EXIT
make -C engine/src test
bash tests/smoke.sh
