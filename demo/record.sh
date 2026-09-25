#!/usr/bin/env bash
# Record the real pane and engine in the same isolated interface as the smoke
# test. asciinema captures thurbox's terminal output; agg renders the cast.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/media/demo.gif}
for tool in thurbox thurbox-cli tmux sqlite3 python3 asciinema agg ffmpeg; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
mkdir -p "$REPO/engine/src/build-thurbox"
S=$(mktemp -d "$REPO/engine/src/build-thurbox/demo.XXXXXX")
trap 'rm -rf "$S"' EXIT
CAST="$S/demo.cast"

RECORD_CAST="$CAST" TUI_COLS=116 TUI_ROWS=34 bash "$REPO/tests/smoke.sh"

# The engine prints its WAD's absolute sandbox path while starting. Blank the
# startup diagnostic's visible text while retaining ANSI control sequences:
# later frames reuse that terminal state. Stop before leaving the alternate
# screen so the GIF ends on the pane.
python3 - "$CAST" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
events = [json.loads(line) for line in lines[1:]]
first_frame = next(i for i, event in enumerate(events)
                   if event[1] == "o" and event[2].count("▀") >= 100)
start_diag = next(i for i, event in enumerate(events[:first_frame])
                  if event[1] == "o" and "W_Init" in event[2])
controls = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
for event in events[start_diag:first_frame]:
    if event[1] != "o":
        continue
    parts = controls.split(event[2])
    escapes = controls.findall(event[2])
    blanked = ["".join(" " if char.isprintable() else char for char in part) for part in parts]
    event[2] = "".join(part + (escapes[i] if i < len(escapes) else "")
                       for i, part in enumerate(blanked))
end = next((i for i in range(first_frame, len(events))
            if events[i][1] == "o" and "\x1b[?1049l" in events[i][2]), len(events))
path.write_text("\n".join([lines[0]] + [json.dumps(event, ensure_ascii=False)
                                         for event in events[:end]]) + "\n")
PY

# Neither the cast nor the image may carry identifying paths or host details.
python3 - "$CAST" "$REPO" "$(id -un)" "$(uname -n)" <<'PY'
import json
import pathlib
import sys

cast, *needles = sys.argv[1:]
events = pathlib.Path(cast).read_text().splitlines()[1:]
payload = "".join(event[2] for line in events if (event := json.loads(line))[1] == "o")
found = [name for name, needle in zip(("repository path", "username", "hostname"), needles)
         if needle and needle in payload]
if found:
    raise SystemExit("recording contains " + ", ".join(found))
PY

mkdir -p "$(dirname "$OUT")"
agg --font-size 15 --idle-time-limit 2 --last-frame-duration 3 "$CAST" "$S/full.gif" 2>"$S/agg.log" || {
  cat "$S/agg.log" >&2
  exit 1
}
ffmpeg -hide_banner -loglevel error -y -ss 1 -i "$S/full.gif" -t 32 \
  -filter_complex 'fps=6,scale=1024:-1:flags=neighbor,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' \
  "$OUT"
echo "$OUT"
