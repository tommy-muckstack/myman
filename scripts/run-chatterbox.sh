#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MYMAN_CHATTERBOX_ROOT="${MYMAN_CHATTERBOX_ROOT:-$HOME/Library/Application Support/MyMan/chatterbox}"
MYMAN_CHATTERBOX_PYTHON="$MYMAN_CHATTERBOX_ROOT/venv/bin/python"

if [[ ! -x "$MYMAN_CHATTERBOX_PYTHON" ]]; then
  echo "Chatterbox is not installed. Run $SCRIPT_DIR/scripts/install-chatterbox.sh first." >&2
  exit 1
fi
exec "$MYMAN_CHATTERBOX_PYTHON" -m uvicorn chatterbox_server:app \
  --app-dir "$SCRIPT_DIR/scripts" --host 127.0.0.1 --port 8000
