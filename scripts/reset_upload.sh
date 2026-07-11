#!/bin/bash
set -euo pipefail

WORKSPACE=$(cd "$(dirname "$0")" && pwd)
IMG_DIR=/tmp/upload
mkdir -p "$IMG_DIR"
exec env IMG_DIR="$IMG_DIR" "$WORKSPACE/reset_offline.sh"
