#!/usr/bin/env bash
# Denoise with a measured SoX noise profile (streamed; no giant WAVs).
# Multithreaded ffmpeg; auto-matches channels/sample-rate to avoid mismatches.

set -euo pipefail

usage() {
  cat <<'USAGE'
USAGE:
  denoise.sh input.mp4 output.mp4
OR (override defaults):
  denoise.sh input.mp4 output.mp4 [noise_start] [noise_duration] [nr_amount] [norm_db] [threads]

DEFAULTS:
  noise_start      00:00:00
  noise_duration   00:00:00.3
  nr_amount        0.20
  norm_db          -1
  threads          $(nproc)
USAGE
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

INPUT=$1
OUTPUT=$2
SS=${3:-00:00:00}
T=${4:-00:00:00.3}
NR=${5:-0.20}
NORM=${6:--1}
THREADS=${7:-${FFMPEG_THREADS:-$(nproc)}}

# Requirements
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "ffprobe not found"; exit 1; }
command -v sox >/dev/null 2>&1 || { echo "sox not found"; exit 1; }

# Probe audio stream (a:0)
has_audio=$(ffprobe -v error -select_streams a:0 -show_entries stream=index -of default=nokey=1:nw=1 "$INPUT" || true)
if [[ -z "$has_audio" ]]; then
  echo "No audio stream (a:0) found in: $INPUT"
  exit 1
fi

AC=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nokey=1:nw=1 "$INPUT" || echo "")
AR=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nokey=1:nw=1 "$INPUT" || echo "")
AC=${AC:-2}
AR=${AR:-48000}
if ! [[ "$AC" =~ ^[0-9]+$ ]]; then AC=2; fi
if ! [[ "$AR" =~ ^[0-9]+$ ]]; then AR=48000; fi
if [[ "$AC" -lt 1 ]]; then AC=2; fi
if [[ "$AR" -lt 8000 ]]; then AR=48000; fi

workdir=$(mktemp -d -t denoise-XXXXXX)
trap 'rm -rf "$workdir"' EXIT
PROFILE="$workdir/noise.prof"

# 1) Build noise profile (match channels/rate)
ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
  -ss "$SS" -t "$T" -i "$INPUT" -map a:0 -vn -ac "$AC" -ar "$AR" -f s16le - \
| sox --buffer 131072 -t s16 -r "$AR" -c "$AC" - -n noiseprof "$PROFILE"

# 2) Stream full audio -> denoise -> remux with original video
ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
  -i "$INPUT" -map a:0 -vn -ac "$AC" -ar "$AR" -f s16le - \
| sox --buffer 131072 -t s16 -r "$AR" -c "$AC" - -t s16 - \
     noisered "$PROFILE" "$NR" norm "$NORM" \
| ffmpeg -hide_banner -loglevel error -nostdin -y \
  -thread_queue_size 1024 -i "$INPUT" \
  -thread_queue_size 1024 -f s16le -ar "$AR" -ac "$AC" -i - \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a aac -b:a 256k \
  -threads "$THREADS" \
  -movflags +faststart \
  "$OUTPUT"

echo "Denoised -> $OUTPUT (AC=$AC, AR=$AR, threads=$THREADS)"

