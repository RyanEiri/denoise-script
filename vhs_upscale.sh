#!/usr/bin/env bash
#
# vhs_upscale.sh (resumable, speed-optimized)
#
# Chunked VHS upscaling with Real-ESRGAN-ncnn-vulkan.
#
# Workflow per segment:
#   1) Extract JPEG frames (video only) from the input
#   2) Real-ESRGAN x4plus (4x internal upscaling, tiled, GPU)
#   3) Rebuild segment at 2x resolution (downscale from 4x) with H.264
#   4) Delete intermediate frames to keep disk usage low
#
# All segment videos live in a persistent workdir:
#   ./vhs_upscale_work/<input-basename>/segments/seg_XXX.mp4
#
# Resumable:
#   - If you rerun the script with the same input and output,
#     existing seg_XXX.mp4 files are detected and skipped.
#   - The script then reconcats all segments and remuxes audio.
#
# Usage:
#   ./vhs_upscale.sh input_sync.mp4 output_upscaled.mp4 [segment_seconds] [crf]
#
# Defaults:
#   segment_seconds = 120   (2 minutes per chunk)
#   crf             = 21    (speed/size/quality balance)
#
# Requirements:
#   - ffmpeg, ffprobe
#   - realesrgan-ncnn-vulkan in PATH
#   - MODELS_DIR pointing to Real-ESRGAN NCNN models (x4plus .param/.bin)

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 input_sync.mp4 output_upscaled.mp4 [segment_seconds] [crf]" >&2
  exit 1
fi

IN="$1"
OUT="$2"
SEG_SECONDS="${3:-120}"  # default 2-minute chunks
CRF="${4:-21}"           # H.264 CRF (lower = bigger/better, higher = smaller/softer)

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

for cmd in ffprobe ffmpeg realesrgan-ncnn-vulkan; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd not found in PATH." >&2
    exit 1
  fi
done

if [ ! -f "$IN" ]; then
  echo "Error: input file '$IN' not found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Real-ESRGAN model location
# ---------------------------------------------------------------------------

# Default models directory (adjust if you keep models elsewhere)
MODELS_DIR="${MODELS_DIR:-$HOME/opt/realesrgan-ncnn/models}"

if [ ! -d "$MODELS_DIR" ]; then
  echo "Error: MODELS_DIR '$MODELS_DIR' not found." >&2
  echo "Set MODELS_DIR to your Real-ESRGAN models directory or edit this script." >&2
  exit 1
fi

MODEL="realesrgan-x4plus"
INTERNAL_SCALE=4   # must match x4plus model

# JPEG frame settings
FRAME_EXT="jpg"
JPEG_QUALITY=2     # ffmpeg qscale=2 ~ very high quality JPEG

# Real-ESRGAN tiling / threading / GPU
tile_size=400      # increase for speed; drop to 300 if you ever see tile artefacts
threads="3:3:2"    # gpu_threads:gpu_streams:cpu_threads
vk_device="0"      # Vulkan device index (0 = primary GPU)

# ---------------------------------------------------------------------------
# Derive a persistent workdir per input
# ---------------------------------------------------------------------------

BASE_NAME="$(basename "$IN")"
BASE_STEM="${BASE_NAME%.*}"

WORK_ROOT="${WORK_ROOT:-$PWD/vhs_upscale_work}"
WORK_DIR="$WORK_ROOT/$BASE_STEM"

frames_dir="$WORK_DIR/frames"
upscaled_dir="$WORK_DIR/frames_up"
segments_dir="$WORK_DIR/segments"

mkdir -p "$frames_dir" "$upscaled_dir" "$segments_dir"

echo ">>> VHS upscale (resumable, speed-optimized)"
echo "Input file      : $IN"
echo "Output file     : $OUT"
echo "Chunk length    : ${SEG_SECONDS}s"
echo "CRF             : ${CRF}"
echo "Model           : $MODEL (internal 4x, final 2x)"
echo "Models dir      : $MODELS_DIR"
echo "JPEG quality    : qscale=$JPEG_QUALITY"
echo "Tile size       : $tile_size"
echo "Threads         : $threads"
echo "Work dir        : $WORK_DIR"
echo

# ---------------------------------------------------------------------------
# Probe input (duration, fps)
# ---------------------------------------------------------------------------

duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" || true)
if [ -z "${duration:-}" ]; then
  echo "Error: could not determine input duration." >&2
  exit 1
fi

total_seconds=$(awk -v d="$duration" 'BEGIN{printf "%d", (d==int(d) ? d : int(d)+1)}')

fps=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of csv=p=0 "$IN" || true)
if [ -z "${fps:-}" ]; then
  echo "Warning: could not determine r_frame_rate; defaulting to 30000/1001" >&2
  fps="30000/1001"
fi

echo "Detected duration : ${duration}s (~${total_seconds}s)"
echo "Detected fps      : ${fps}"
echo

# ---------------------------------------------------------------------------
# Process in chunks (resume-aware)
# ---------------------------------------------------------------------------

start_sec=0
seg_index=0

echo ">>> Processing in chunks with Real-ESRGAN (x4plus → final 2x)"
echo ">>> Existing seg_XXX.mp4 files will be reused (resume support)"
echo

while [ "$start_sec" -lt "$total_seconds" ]; do
  seg_index_str=$(printf "%03d" "$seg_index")
  seg_out="$segments_dir/seg_${seg_index_str}.mp4"

  echo "=== Segment #$seg_index_str ==="
  echo "Start time: ${start_sec}s"

  # If this segment already exists and is non-empty, skip (resume)
  if [ -s "$seg_out" ]; then
    echo "  -> Segment file exists ($seg_out), skipping reprocessing."
    start_sec=$(( start_sec + SEG_SECONDS ))
    seg_index=$(( seg_index + 1 ))
    echo "=== Finished segment #$seg_index_str (reused) ==="
    echo
    continue
  fi

  # Clean per-segment frame dirs
  rm -rf "$frames_dir" "$upscaled_dir"
  mkdir -p "$frames_dir" "$upscaled_dir"

  # 1) Extract JPEG frames for this segment (video only)
  ffmpeg -y \
    -ss "$start_sec" \
    -t "$SEG_SECONDS" \
    -i "$IN" \
    -an \
    -qscale:v "$JPEG_QUALITY" \
    "$frames_dir/frame_%08d.$FRAME_EXT"

  if ! ls "$frames_dir"/*."$FRAME_EXT" >/dev/null 2>&1; then
    echo "  -> No frames extracted for this segment; stopping."
    break
  fi

  # 2) Real-ESRGAN upscale (x4 internal)
  echo "  -> Real-ESRGAN upscaling..."
  realesrgan-ncnn-vulkan \
    -i "$frames_dir" \
    -o "$upscaled_dir" \
    -s "$INTERNAL_SCALE" \
    -m "$MODELS_DIR" \
    -n "$MODEL" \
    -t "$tile_size" \
    -j "$threads" \
    -g "$vk_device" \
    -f jpg

  # 3) Rebuild segment video at 2x resolution (downscale from 4x)
  echo "  -> Rebuilding segment video at 2x resolution..."
  ffmpeg -y \
    -framerate "$fps" \
    -i "$upscaled_dir/frame_%08d.$FRAME_EXT" \
    -vf "scale=iw/2:ih/2" \
    -c:v libx264 -preset medium -crf "$CRF" \
    -an \
    "$seg_out"

  # 4) Free intermediate frames to save disk
  rm -rf "$frames_dir" "$upscaled_dir"

  start_sec=$(( start_sec + SEG_SECONDS ))
  seg_index=$(( seg_index + 1 ))

  echo "=== Finished segment #$seg_index_str (processed) ==="
  echo
done

# ---------------------------------------------------------------------------
# Collect all segment videos
# ---------------------------------------------------------------------------

shopt -s nullglob
segment_files=( "$segments_dir"/seg_*.mp4 )
shopt -u nullglob

if [ "${#segment_files[@]}" -eq 0 ]; then
  echo "Error: no segment files found in $segments_dir." >&2
  exit 1
fi

# Sort segments lexicographically to ensure correct order
IFS=$'\n' segment_files_sorted=($(printf '%s\n' "${segment_files[@]}" | sort))
unset IFS

echo ">>> Found ${#segment_files_sorted[@]} segment(s) for concatenation."
for f in "${segment_files_sorted[@]}"; do
  echo "  - $f"
done
echo

# ---------------------------------------------------------------------------
# Concatenate segment videos (video only)
# ---------------------------------------------------------------------------

concat_list="$WORK_DIR/segments.txt"
: > "$concat_list"

for f in "${segment_files_sorted[@]}"; do
  echo "file '$f'" >> "$concat_list"
done

concat_video="$WORK_DIR/video_concat.mp4"

echo ">>> Concatenating segments into: $concat_video"

ffmpeg -y \
  -f concat -safe 0 \
  -i "$concat_list" \
  -c copy \
  "$concat_video"

# ---------------------------------------------------------------------------
# Mux original audio with upscaled video
# ---------------------------------------------------------------------------

echo ">>> Muxing original audio into final upscaled video: $OUT"

ffmpeg -y \
  -i "$concat_video" \
  -i "$IN" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a aac -b:a 160k \
  "$OUT"

echo
echo "All done."
echo "Final upscaled file: $OUT"
echo "Work dir (for resume or inspection): $WORK_DIR"
echo "You may delete $WORK_DIR when you're satisfied with the result."

