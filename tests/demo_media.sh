#!/usr/bin/env bash
# Check the committed recording at its delivered pixel size.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
GIF="$REPO/media/demo.gif"
read -r width height frames < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,nb_frames -of csv=s=x:p=0 "$GIF" | tr x ' ')
if (( width < 1000 || height < 650 || frames < 30 )); then
  echo "demo is ${width}x${height} with ${frames} frames; expected at least 1000x650 and 30 frames" >&2
  exit 1
fi
echo "demo is ${width}x${height} with ${frames} frames"
