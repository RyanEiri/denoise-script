#!/usr/bin/env bash
#
# vhs_process.sh
#
# Usage:
#   ./vhs_process.sh "2025-11-16 14-33-58.mp4"
#
# Produces:
#   2025-11-16 14-33-58-NR.mp4          (denoised)
#   2025-11-16 14-33-58-NR-sync.mp4     (denoised + synced)
#   2025-11-16 14-33-58-NR-sync-x2.mp4  (denoised + synced + upscaled)

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 input_obs_file.mp4" >&2
  exit 1
fi

IN="$1"
BASE="${IN%.*}"

NR="${BASE}-NR.mp4"
SYNC="${BASE}-NR-sync.mp4"
UPSCALED="${BASE}-NR-sync-x2.mp4"

./denoise.sh "$IN" "$NR"
./vhs_fix_sync.sh "$NR" "$SYNC"
./vhs_upscale.sh "$SYNC" "$UPSCALED" 2

echo
echo "Pipeline complete:"
echo "  Denoised : $NR"
echo "  Synced   : $SYNC"
echo "  Upscaled : $UPSCALED"

