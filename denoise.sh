#!/usr/bin/env bash
# Parallel per-channel SoX noisered (streamed; no giant WAVs)
# Uses measured profiles; ffmpeg multi-threaded; SoX runs one worker per channel.

set -euo pipefail

usage() {
  cat <<'USAGE'
USAGE:
  denoise.sh input.mp4 output.mp4
OR:
  denoise.sh input.mp4 output.mp4 [noise_start] [noise_duration] [nr_amount] [norm_db] [threads]

Defaults:
  noise_start    00:00:00
  noise_duration 00:00:00.3
  nr_amount      0.20
  norm_db        -1
  threads        $(nproc)   # for ffmpeg; SoX parallelism = channel count
USAGE
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi

INPUT=$1
OUTPUT=$2
SS=${3:-00:00:00}
T=${4:-00:00:00.3}
NR=${5:-0.20}
NORM=${6:--1}
THREADS=${7:-${FFMPEG_THREADS:-$(nproc)}}

command -v ffmpeg >/dev/null || { echo "ffmpeg not found"; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found"; exit 1; }
command -v sox >/dev/null || { echo "sox not found"; exit 1; }

# Probe audio stream
if ! ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$INPUT" >/dev/null 2>&1; then
  echo "No audio stream (a:0) found in: $INPUT"; exit 1
fi

AC=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$INPUT" || echo "")
AR=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$INPUT" || echo "")
AC=${AC:-2}; AR=${AR:-48000}
[[ "$AC" =~ ^[0-9]+$ ]] || AC=2
[[ "$AR" =~ ^[0-9]+$ ]] || AR=48000
(( AC >= 1 )) || AC=2
(( AR >= 8000 )) || AR=48000

workdir=$(mktemp -d -t denoise-XXXXXX)
trap 'rm -rf "$workdir"' EXIT

# If mono, use simple (single-worker) path
if (( AC == 1 )); then
  PROFILE="$workdir/noise.prof"
  ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
    -ss "$SS" -t "$T" -i "$INPUT" -map a:0 -vn -ac 1 -ar "$AR" -f s16le - \
  | sox --buffer 131072 -t s16 -r "$AR" -c 1 - -n noiseprof "$PROFILE"

  ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
    -i "$INPUT" -map a:0 -vn -ac 1 -ar "$AR" -f s16le - \
  | sox --buffer 131072 -t s16 -r "$AR" -c 1 - -t s16 - noisered "$PROFILE" "$NR" norm "$NORM" \
  | ffmpeg -hide_banner -loglevel error -nostdin -y \
      -thread_queue_size 1024 -i "$INPUT" \
      -thread_queue_size 1024 -f s16le -ar "$AR" -ac 1 -i - \
      -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 256k -threads "$THREADS" -movflags +faststart \
      "$OUTPUT"
  echo "Denoised -> $OUTPUT (mono, AR=$AR, threads=$THREADS)"
  exit 0
fi

# === Parallel per-channel path ===
# Create per-channel profiles and FIFOs for cleaned audio
declare -a PROFILES CLEAN_FIFOS
for ((i=0; i<AC; i++)); do
  PROFILES[$i]="$workdir/noise.$i.prof"
  CLEAN_FIFOS[$i]="$workdir/clean.$i.pcm"
  mkfifo "${CLEAN_FIFOS[$i]}"

  # Build per-channel noise profile from sample window
  ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
    -ss "$SS" -t "$T" -i "$INPUT" -map a:0 -vn \
    -af "pan=mono|c0=c${i}" -ac 1 -ar "$AR" -f s16le - \
  | sox --buffer 131072 -t s16 -r "$AR" -c 1 - -n noiseprof "${PROFILES[$i]}"
done

# Launch per-channel cleaners in background (one SoX per channel)
pids=()
for ((i=0; i<AC; i++)); do
  (
    ffmpeg -hide_banner -loglevel error -nostdin -y -threads "$THREADS" \
      -i "$INPUT" -map a:0 -vn \
      -af "pan=mono|c0=c${i}" -ac 1 -ar "$AR" -f s16le - \
    | sox --buffer 131072 -t s16 -r "$AR" -c 1 - -t s16 - \
         noisered "${PROFILES[$i]}" "$NR" norm "$NORM" \
    > "${CLEAN_FIFOS[$i]}"
  ) &
  pids+=($!)
done

# Build inputs list for ffmpeg and amerge filter
ff_inputs=()
ff_maps=()
for ((i=0; i<AC; i++)); do
  ff_inputs+=( -thread_queue_size 1024 -f s16le -ar "$AR" -ac 1 -i "${CLEAN_FIFOS[$i]}" )
  ff_maps+=( "[$((i+1)):a:0]" )
done

# shellcheck disable=SC2207
inputs_joined=("${ff_inputs[@]}")

# Merge cleaned mono channels -> multichannel, then mux with original video
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -thread_queue_size 1024 -i "$INPUT" \
  "${inputs_joined[@]}" \
  -filter_complex "amerge=inputs=${AC}[am]" \
  -map 0:v:0 -map "[am]" \
  -c:v copy \
  -c:a aac -b:a 256k -ac "${AC}" \
  -threads "$THREADS" \
  -movflags +faststart \
  "$OUTPUT"

# Wait for workers to finish (and release FIFOs)
for pid in "${pids[@]}"; do wait "$pid"; done

echo "Denoised -> $OUTPUT (channels=$AC, AR=$AR, ffmpeg threads=$THREADS, SoX workers=$AC)"

