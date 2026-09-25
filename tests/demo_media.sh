#!/usr/bin/env bash
# Check the committed recording at its delivered pixel size.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
GIF="$REPO/media/demo.gif"
read -r width height frames < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,nb_frames -of csv=s=x:p=0 "$GIF" | tr x ' ')
if (( width < 1600 || height < 1100 )); then
  echo "demo is ${width}x${height}; expected at least 1600x1100 delivered pixels" >&2
  exit 1
fi
if (( frames < 30 )); then
  echo "demo has ${frames} frames; expected at least 30" >&2
  exit 1
fi
echo "demo is ${width}x${height} with ${frames} frames"

# Decode the delivered GIF, not the recording script. An unfocused DOOM pane
# leaves the center of the right-hand viewport nearly one solid color.
python3 - "$GIF" <<'PY'
from collections import Counter
import subprocess
import sys

sample_width, sample_height = 32, 24
frame_bytes = sample_width * sample_height * 3
video = subprocess.run(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", sys.argv[1],
     "-vf", "crop=iw*0.63:ih*0.75:iw*0.29:ih*0.08,scale=32:24:flags=neighbor",
     "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
    check=True, capture_output=True,
).stdout
if not video or len(video) % frame_bytes:
    raise SystemExit("could not decode complete demo frames")
for frame_number, offset in enumerate(range(0, len(video), frame_bytes), 1):
    frame = video[offset:offset + frame_bytes]
    pixels = (frame[i:i + 3] for i in range(0, frame_bytes, 3))
    dominant_count = Counter(pixels).most_common(1)[0][1]
    if dominant_count > sample_width * sample_height * 0.9:
        raise SystemExit(
            f"demo frame {frame_number} loses gameplay: "
            f"{dominant_count} of {sample_width * sample_height} viewport samples "
            "are one color"
        )
print("gameplay remains visible in every decoded demo frame")
PY
