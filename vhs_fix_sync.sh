#!/usr/bin/env bash
#
# vhs_fix_sync.sh
#
# Correct *drift* between audio + video using ffmpeg.
#
# Usage:
#   ./vhs_fix_sync.sh "input-NR.mp4" "input-NR-sync.mp4"
#
# Example:
#   ./vhs_fix_sync.sh "2025-11-16 14-33-58-NR.mp4" \
#                     "2025-11-16 14-33-58-NR-sync.mp4"
#
# - Measures video vs audio duration with ffprobe.
# - Computes an atempo factor so audio duration matches video duration.
# - Uses aresample=async=1:first_pts=0 to clean up timestamp gaps.
# - Copies video as-is, re-encodes only audio.
#
# Requirements: ffmpeg, ffprobe, awk

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 input_file output_file" >&2
  exit 1
fi

IN="$1"
OUT="$2"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe not found in PATH." >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found in PATH." >&2
  exit 1
fi

echo ">>> Analyzing durations for:"
echo "    $IN"
echo

# Get durations in seconds (floating point) for video and audio streams.
v_dur=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=duration \
        -of csv=p=0 "$IN" || true)

a_dur=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=duration \
        -of csv=p=0 "$IN" || true)

# Fallback: use container-level duration if per-stream is missing.
if [ -z "${v_dur:-}" ] || [ -z "${a_dur:-}" ]; then
  echo "Per-stream duration missing; falling back to format duration..."
  fmt_dur=$(ffprobe -v error -show_entries format=duration \
             -of csv=p=0 "$IN" || true)
  if [ -z "${fmt_dur:-}" ]; then
    echo "Error: Could not determine durations via ffprobe." >&2
    exit 1
  fi
  v_dur="$fmt_dur"
  a_dur="$fmt_dur"
fi

echo "Video duration : $v_dur s"
echo "Audio duration : $a_dur s"

# Compute tempo factor so that audio duration matches video duration.
# atempo changes speed such that new_audio_dur = old_audio_dur / tempo.
# We want new_audio_dur = video_dur:
#     a_dur / tempo = v_dur  =>  tempo = a_dur / v_dur
tempo=$(awk -v vd="$v_dur" -v ad="$a_dur" 'BEGIN{
  if (vd == 0) {print 1.0; exit}
  printf "%.8f", ad / vd
}')

# Percentage difference from 1.0
diff_pct=$(awk -v t="$tempo" 'BEGIN{
  d = (t > 1.0) ? (t - 1.0) : (1.0 - t);
  printf "%.3f", d * 100.0
}')

echo "Computed audio tempo factor: $tempo (drift ≈ ${diff_pct}%)"

# If drift is tiny, just warn and exit.
if awk -v d="$diff_pct" 'BEGIN{exit (d < 0.05 ? 0 : 1)}'; then
  echo "Drift is less than 0.05% – probably not worth correcting."
  echo "No output written. If you still want to force correction,"
  echo "increase or remove the 0.05% threshold in this script."
  exit 0
fi

# Guard against wild values; atempo range is roughly 0.5–2.0 in one go.
if awk -v t="$tempo" 'BEGIN{exit (t < 0.5 || t > 2.0 ? 0 : 1)}'; then
  echo "Error: tempo factor $tempo is outside 0.5–2.0."
  echo "This suggests a bigger problem (e.g., wrong frame rate or bad capture)."
  exit 1
fi

echo
echo ">>> Writing drift-corrected file to:"
echo "    $OUT"
echo "    (video: copy, audio: atempo=$tempo + aresample=async=1:first_pts=0)"
echo

ffmpeg -y -i "$IN" \
  -map 0:v:0 -map 0:a:0 \
  -c:v copy \
  -af "atempo=$tempo,aresample=async=1:first_pts=0" \
  -c:a aac -b:a 192k \
  "$OUT"

echo
echo "Done."
echo "Original : $IN"
echo "Corrected: $OUT"

