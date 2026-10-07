#!/usr/bin/env bash
# Record media/demo.gif: the real thurbox TUI, in its built-in Doom theme, with
# this plugin installed from the repository's COMMITTED state and F5 pressed.
#
# asciinema records the pty and agg rasterises the cast. tmux presses the keys,
# so what lands in the cast is the interface reacting to real chords; VHS
# cannot send an F-key.
#
#   demo/record.sh [output.gif]
#
# Needs thurbox + thurbox-cli (THURBOX_BIN / THURBOX_CLI to pick others),
# asciinema 3, agg, ffmpeg, ffprobe, tmux, git, sqlite3 and python3 >= 3.11.
#
# Nothing here touches a real interface, database or tmux server: HOME, every
# XDG root and TMUX_TMPDIR point into a throwaway directory. That directory is
# not /tmp, which is RAM on plenty of machines.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/media/demo.gif}
TUI=${THURBOX_BIN:-thurbox}
CLI=${THURBOX_CLI:-thurbox-cli}
COLS=${COLS:-200}
ROWS=${ROWS:-56}
CLIP_SECS=${CLIP_SECS:-10}
for tool in "$TUI" "$CLI" tmux git sqlite3 python3 asciinema agg ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
case $(asciinema --version) in
  "asciinema 3."*) ;;
  *) echo "asciinema 3 is required (--window-size, --output-format)" >&2; exit 2 ;;
esac

# Kept short: thurbox binds a control socket at
# <data dir>/ui-control/<uuid>.sock, and a socket path has ~107 bytes.
ROOT=${DEMO_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/tdoom}
mkdir -p "$ROOT"
S=$(mktemp -d "$ROOT/s.XXXXXX")
if (( ${#S} + 63 > 107 )); then
  echo "sandbox path $S is too long for thurbox's control socket; set DEMO_ROOT" >&2
  rm -rf "$S"
  exit 2
fi
TM=(tmux -L doom-demo)
# Invoked through the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  TMUX_TMPDIR="$S/tmux" "${TM[@]}" kill-server 2>/dev/null || true
  TMUX_TMPDIR="$S/tmux" tmux -L thurbox kill-server 2>/dev/null || true
  rm -rf "$S"
}
trap cleanup EXIT INT TERM

export HOME="$S/h"
export XDG_CONFIG_HOME="$S/c" XDG_DATA_HOME="$S/d"
export XDG_STATE_HOME="$S/s" XDG_CACHE_HOME="$S/x"
export TMUX_TMPDIR="$S/tmux" THURBOX_SOCKET=thurbox
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR THURBOX_SOCKET_FOR
unset THURBOX_SESSION THURBOX_SESSION_ID NO_COLOR TMUX TMUX_PANE
mkdir -p "$XDG_CONFIG_HOME/thurbox" "$XDG_DATA_HOME/thurbox" "$TMUX_TMPDIR"

# Both features reach the network: one puts an upgrade notice in the top band,
# the other replaces the binaries being recorded.
cat >"$XDG_CONFIG_HOME/thurbox/settings.toml" <<'SETTINGS'
[features]
version_check = false
auto_update = false
SETTINGS

# A stub agent, so the session list has a row without an agent CLI or account.
cat >"$XDG_CONFIG_HOME/thurbox/agents.toml" <<'AGENTS'
default = "agent"

[[agents]]
name = "agent"
command = "sh"
args = ["-c", "exec cat >/dev/null"]
AGENTS
P="$HOME/demo-app"
git init -q -b main "$P"
printf '# demo-app\n' >"$P/README.md"
git -C "$P" add -A
git -C "$P" -c user.email=demo@example.com -c user.name=demo -c commit.gpgsign=false \
  commit -qm init
"$CLI" session create --name lunch-break --repo-path "$P" --json >/dev/null

# Installed the way the README says, from a clone of the committed state.
git clone -q "$REPO" "$S/src/thurbox-doom"
"$CLI" plugin install "git+file://$S/src/thurbox-doom" --text >"$S/install.txt"

paths=$("$CLI" config show --json | python3 -c '
import json, sys
paths = json.load(sys.stdin)["paths"]
print(paths["ui_dir"]); print(paths["ui_json"]); print(paths["database"])')
{ IFS= read -r UI_DIR; IFS= read -r UI_JSON; IFS= read -r DB; } <<<"$paths"

# The program grant is made in the settings modal and nowhere else, so write
# what that modal writes: {pin, digest} from plugins.lock, keyed by the
# installed file. The setting warps straight into E1M1 rather than recording
# the title screen.
python3 - "$UI_DIR" "$UI_JSON" <<'PY'
import json, pathlib, sys, tomllib

ui_dir, out = map(pathlib.Path, sys.argv[1:])
entry, = tomllib.loads((ui_dir / "plugins.lock").read_text())["plugin"]
pane = entry["file"]
grant = {"pin": f"{entry['src']}@{entry['version']}", "digest": entry["files"][pane]}
out.write_text(json.dumps({
    "trusted": {str(ui_dir / pane): grant},
    "settings": {"doom.args": "-warp 1 1 -iwad"},
}, indent=2))
PY

# The Doom theme is the persisted `active_theme` the Ctrl+Y picker writes, and
# the v2 notice is answered so the first frame is the interface.
sqlite3 "$DB" "
INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO metadata (key, value) VALUES ('active_theme', 'doom')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value;"

cat >"$S/run.sh" <<RUN
#!/usr/bin/env bash
export TERM=xterm-256color COLORTERM=truecolor SHELL=/bin/sh PS1='\$ '
cd "$P"
exec $(command -v "$TUI")
RUN
chmod +x "$S/run.sh"

CAST="$S/demo.cast"
"${TM[@]}" new-session -d -x "$COLS" -y "$ROWS" \
  "asciinema rec --overwrite --quiet --output-format asciicast-v2 \
   --window-size ${COLS}x$ROWS --command '$S/run.sh' '$CAST'"
capture() { "${TM[@]}" capture-pane -p -t 0; }
key() { "${TM[@]}" send-keys -t 0 "$1"; sleep "$2"; }

for _ in $(seq 1 80); do
  capture | grep -qF 'lunch-break' && break
  sleep 0.25
done
capture | grep -qF 'lunch-break' || { capture >&2; echo 'thurbox did not start' >&2; exit 1; }
sleep 2
key F5 1
for _ in $(seq 1 80); do
  [[ "$(capture)" == *"▀▀▀"* ]] && break
  sleep 0.25
done
[[ "$(capture)" == *"▀▀▀"* ]] || { capture >&2; echo 'Doom did not render' >&2; exit 1; }
# Walk into E1M1's first room, shoot, glance at the automap, and turn back.
# The engine reads a lone press as a hold of ~0.7 s, so one key per step.
sleep 1
key Up 0.8
key f 0.6
key Up 0.8
key Right 0.6
key f 0.6
key Tab 1.4
key Tab 0.4
key Left 0.6
key Up 0.8
key f 1
key C-q 2
for _ in $(seq 1 30); do [ -s "$CAST" ] && break; sleep 0.5; done
[ -s "$CAST" ] || { echo 'recording was not written' >&2; exit 1; }

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
start_diag = next((i for i, event in enumerate(events[:first_frame])
                   if event[1] == "o" and "W_Init" in event[2]), first_frame)
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
python3 - "$CAST" "$REPO" "$ROOT" "$(id -un)" "$(uname -n)" <<'PY'
import json
import pathlib
import sys

cast, *needles = sys.argv[1:]
events = pathlib.Path(cast).read_text().splitlines()[1:]
payload = "".join(event[2] for line in events if (event := json.loads(line))[1] == "o")
found = [name for name, needle in zip(("repository path", "sandbox path", "username", "hostname"), needles)
         if needle and needle in payload]
if found:
    raise SystemExit("recording contains " + ", ".join(found))
PY

mkdir -p "$(dirname "$OUT")"
agg --font-size 15 --idle-time-limit 2 --last-frame-duration 1 "$CAST" "$S/full.gif" >"$S/agg.log" 2>&1 || {
  cat "$S/agg.log" >&2
  exit 1
}
# Find the first fully painted gameplay frame in agg's rendered timeline.
# Startup timing varies, so a fixed seek can leave an empty viewport at the
# beginning of the delivered GIF.
START=$(python3 - "$S/full.gif" <<'PY'
from collections import Counter
import subprocess
import sys

gif = sys.argv[1]
times = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", gif],
    check=True, capture_output=True, text=True,
).stdout.splitlines()
video = subprocess.run(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", gif,
     "-vf", "crop=iw*0.63:ih*0.16:iw*0.29:ih*0.77,scale=32:8:flags=neighbor",
     "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
    check=True, capture_output=True,
).stdout
frame_bytes = 32 * 8 * 3
if len(video) != len(times) * frame_bytes:
    raise SystemExit("could not inspect every rendered demo frame")
for frame_number, offset in enumerate(range(0, len(video), frame_bytes)):
    frame = video[offset:offset + frame_bytes]
    pixels = (frame[i:i + 3] for i in range(0, frame_bytes, 3))
    if Counter(pixels).most_common(1)[0][1] < 32 * 8 * 0.3:
        # Give the terminal's remaining cell runs time to finish the HUD.
        print(f"{float(times[frame_number]) + 0.5:.3f}")
        break
else:
    raise SystemExit("recording never displayed a full gameplay frame")
PY
)
ffmpeg -hide_banner -loglevel error -y -i "$S/full.gif" -ss "$START" -t "$CLIP_SECS" \
  -filter_complex 'fps=6,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' \
  "$OUT"
ls -lh "$OUT"
