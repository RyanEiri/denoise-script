#!/usr/bin/env bash
#
# vhs_upscale.sh (resumable, Real-ESRGAN-x4plus default)
# Known stable on RX 7800 XT / RADV: tile=384, -j 4:4:1
#
# Chunked VHS upscaling with Real-ESRGAN-ncnn-vulkan.
#
# Workflow per segment:
#   1) Extract JPEG frames (video only) from the input
#   2) Real-ESRGAN model (default: realesrgan-x4plus) → PNG frames
#   3) Rebuild segment at model output resolution with H.264
#   4) Delete intermediate frames to keep disk usage low
#
# All segment videos live in a persistent workdir:
#   ./vhs_upscale_work/<input-basename>/segments/seg_XXX.mp4
#
# Resumable across runs:
#   - Existing seg_XXX.mp4 are kept
#   - Their durations are summed with ffprobe to find the resume timestamp
#   - You can safely change [segment_seconds] or model between runs
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 INPUT_FILE OUTPUT_FILE [segment_seconds] [crf]" >&2
  echo "  INPUT_FILE       : source video (with audio)" >&2
  echo "  OUTPUT_FILE      : final upscaled output video" >&2
  echo "  segment_seconds  : optional; default 120" >&2
  echo "  crf              : optional; default 21" >&2
  exit 1
fi

IN="$1"
OUT="$2"
SEG_SECONDS="${3:-120}"
CRF="${4:-21}"

if [ ! -f "$IN" ]; then
  echo "Error: input file not found: $IN" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found in PATH." >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe not found in PATH." >&2
  exit 1
fi

if ! command -v realesrgan-ncnn-vulkan >/dev/null 2>&1; then
  echo "Error: realesrgan-ncnn-vulkan not found in PATH." >&2
  echo "Make sure Real-ESRGAN is installed and in your PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Config (tweak as needed)
# ---------------------------------------------------------------------------

# JPEG quality for intermediate frames (2 = high quality, lower = better)
JPEG_QUALITY="${JPEG_QUALITY:-2}"

# Real-ESRGAN model & tuning
# Default: standard x4 model shipped with realesrgan-ncnn-vulkan
MODEL="${REALESRGAN_MODEL:-realesrgan-x4plus}"

# Tile size (384 for good quality / performance balance on 720x480)
tile_size="${REALESRGAN_TILE:-384}"

# THREADS:
# - PROC controls the first field of -j "<proc>:<load>:<tile>"
# - LOAD is CPU-side preprocessing
# - TILE is tile concurrency (1 = safest on AMD)
REALESRGAN_PROC_THREADS="${REALESRGAN_PROC_THREADS:-4}"
REALESRGAN_LOAD_THREADS="${REALESRGAN_LOAD_THREADS:-4}"
REALESRGAN_TILE_THREADS="${REALESRGAN_TILE_THREADS:-1}"

# FFmpeg encode threads (0 = auto)
FFMPEG_ENC_THREADS="${FFMPEG_ENC_THREADS:-8}"

# Optional override for scale; otherwise auto-detect from model name
REALESRGAN_SCALE="${REALESRGAN_SCALE:-}"

# Root work dir (can override via env)
WORK_ROOT="${WORK_ROOT:-./vhs_upscale_work}"

# ---------------------------------------------------------------------------
# Derive work dirs
# ---------------------------------------------------------------------------

in_basename="$(basename "$IN")"
in_stem="${in_basename%.*}"

WORK_DIR="$WORK_ROOT/$in_stem"
frames_dir="$WORK_DIR/frames"
frames_up_dir="$WORK_DIR/frames_up"
segments_dir="$WORK_DIR/segments"

mkdir -p "$frames_dir" "$frames_up_dir" "$segments_dir"

# ---------------------------------------------------------------------------
# Infer scale from model name if not explicitly set
# ---------------------------------------------------------------------------

if [ -z "$REALESRGAN_SCALE" ]; then
  case "$MODEL" in
    *1x*|*x1*) REALESRGAN_SCALE=1 ;;
    *2x*|*x2*) REALESRGAN_SCALE=2 ;;
    *3x*|*x3*) REALESRGAN_SCALE=3 ;;
    *4x*|*x4*|*x4plus*) REALESRGAN_SCALE=4 ;;
    *) REALESRGAN_SCALE=4 ;;  # conservative default for realesrgan-x4plus family
  esac
fi

echo "Input            : $IN"
echo "Output           : $OUT"
echo "Segment length   : ${SEG_SECONDS}s"
echo "CRF              : ${CRF}"
echo "Model            : $MODEL"
echo "Model scale      : ${REALESRGAN_SCALE}x"
echo "JPEG quality     : qscale=$JPEG_QUALITY"
echo "Tile size        : $tile_size"
echo "Real-ESRGAN -j   : ${REALESRGAN_PROC_THREADS}:${REALESRGAN_LOAD_THREADS}:${REALESRGAN_TILE_THREADS}"
if [ "$FFMPEG_ENC_THREADS" -gt 0 ]; then
  echo "FFmpeg enc thrds : $FFMPEG_ENC_THREADS"
else
  echo "FFmpeg enc thrds : auto (FFMPEG_ENC_THREADS=0)"
fi
echo "Work dir         : $WORK_DIR"
echo

# ---------------------------------------------------------------------------
# Probe input (duration, fps)
# ---------------------------------------------------------------------------

duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" || true)"
if [ -z "${duration:-}" ]; then
  echo "Error: could not determine input duration." >&2
  exit 1
fi

total_seconds="$(awk -v d="$duration" 'BEGIN{printf "%d", (d==int(d) ? d : int(d)+1)}')"

fps="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of csv=p=0 "$IN" || true)"
if [ -z "${fps:-}" ]; then
  echo "Error: could not determine input fps." >&2
  exit 1
fi

echo "Detected duration : ${duration}s (~${total_seconds}s)"
echo "Detected fps      : ${fps}"
echo

# ---------------------------------------------------------------------------
# Resume scan: figure out how much is already processed
# ---------------------------------------------------------------------------

start_sec=0
seg_index=0

shopt -s nullglob
existing_segments=( "$segments_dir"/seg_*.mp4 )
shopt -u nullglob

if [ "${#existing_segments[@]}" -gt 0 ]; then
  echo ">>> Found ${#existing_segments[@]} existing segment(s); calculating processed time..."
  for seg_path in "${existing_segments[@]}"; do
    seg_dur_raw="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$seg_path" || echo 0)"
    seg_dur_int="$(awk -v d="$seg_dur_raw" 'BEGIN{printf "%d", (d==int(d) ? d : int(d)+1)}')"
    start_sec=$(( start_sec + seg_dur_int ))
    seg_index=$(( seg_index + 1 ))
  done

  echo ">>> Resume point: ${seg_index} segment(s), ~${start_sec}s processed so far."
  echo ">>> New segments will use ${SEG_SECONDS}s chunk length."
else
  echo ">>> No existing segments detected; starting from 0s."
fi

echo
echo ">>> Processing in chunks with Real-ESRGAN"
echo ">>> Existing seg_XXX.mp4 files will be reused (resume support)"
echo

# ---------------------------------------------------------------------------
# Segment loop
# ---------------------------------------------------------------------------

while [ "$start_sec" -lt "$total_seconds" ]; do
  seg_index_str="$(printf "%03d" "$seg_index")"
  seg_out="$segments_dir/seg_${seg_index_str}.mp4"

  echo "=== Segment #$seg_index_str ==="
  echo "Start time: ${start_sec}s"

  if [ -s "$seg_out" ]; then
    echo "  -> Segment file exists ($seg_out), skipping reprocessing."
    start_sec=$(( start_sec + SEG_SECONDS ))
    seg_index=$(( seg_index + 1 ))
    echo "=== Finished segment #$seg_index_str (reused) ==="
    echo
    continue
  fi

  # Clean per-segment frame dirs
  rm -rf "$frames_dir" "$frames_up_dir"
  mkdir -p "$frames_dir" "$frames_up_dir"

  echo "  -> Extracting frames (JPG)..."
  ffmpeg -y \
    -ss "$start_sec" \
    -t "$SEG_SECONDS" \
    -i "$IN" \
    -an \
    -qscale:v "$JPEG_QUALITY" \
    "$frames_dir/frame_%08d.jpg"

  echo "  -> Real-ESRGAN upscaling (→ PNG)..."

  realesrgan-ncnn-vulkan \
    -i "$frames_dir" \
    -o "$frames_up_dir" \
    -n "$MODEL" \
    -s "$REALESRGAN_SCALE" \
    -t "$tile_size" \
    -j "${REALESRGAN_PROC_THREADS}:${REALESRGAN_LOAD_THREADS}:${REALESRGAN_TILE_THREADS}"

  echo "  -> Rebuilding segment video from PNG..."
  ffmpeg -y \
    -threads "$FFMPEG_ENC_THREADS" \
    -framerate "$fps" \
    -i "$frames_up_dir/frame_%08d.png" \
    -c:v libx264 -preset slow -crf "$CRF" \
    "$seg_out"

  echo "  -> Cleaning intermediate frames..."
  rm -rf "$frames_dir" "$frames_up_dir"

  start_sec=$(( start_sec + SEG_SECONDS ))
  seg_index=$(( seg_index + 1 ))

  echo "=== Finished segment #$seg_index_str ==="
  echo
done

# ---------------------------------------------------------------------------
# Concat all segments
# ---------------------------------------------------------------------------

echo ">>> Concatenating segments..."

shopt -s nullglob
all_segments=( "$segments_dir"/seg_*.mp4 )
shopt -u nullglob

if [ "${#all_segments[@]}" -eq 0 ]; then
  echo "Error: no segments found to concatenate." >&2
  exit 1
fi

concat_list="$segments_dir/concat_list.txt"
: > "$concat_list"

for seg_path in "${all_segments[@]}"; do
  printf "file '%s'\n" "$seg_path" >> "$concat_list"
done

concat_video="$WORK_DIR/video_concat.mp4"

ffmpeg -y \
  -f concat -safe 0 \
  -i "$concat_list" \
  -c copy \
  "$concat_video"

# ---------------------------------------------------------------------------
# Mux original audio with upscaled video
# ---------------------------------------------------------------------------

echo ">>> Muxing original audio with upscaled video..."

ffmpeg -y \
  -i "$concat_video" \
  -i "$IN" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a aac -b:a 160k \
  "$OUT"

echo
echo "All done."
echo "Final output file: $OUT"
echo "Work dir (for resume or inspection): $WORK_DIR"
echo "You may delete $WORK_DIR when you're satisfied with the result."

