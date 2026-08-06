#!/bin/bash
set -euo pipefail

# Installs Chatterbox outside the app bundle so My Man remains a normal small
# notarized Mac app. This server listens on 127.0.0.1 only; it receives text
# from My Man and returns a WAV reply, with no cloud/API key involved.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MYMAN_CHATTERBOX_ROOT="${MYMAN_CHATTERBOX_ROOT:-$HOME/Library/Application Support/MyMan/chatterbox}"
MYMAN_CHATTERBOX_VENV="$MYMAN_CHATTERBOX_ROOT/venv"

mkdir -p "$MYMAN_CHATTERBOX_ROOT"
if [[ ! -x "$MYMAN_CHATTERBOX_VENV/bin/python" ]]; then
  python3 -m venv "$MYMAN_CHATTERBOX_VENV"
fi
"$MYMAN_CHATTERBOX_VENV/bin/python" -m pip install --upgrade pip
"$MYMAN_CHATTERBOX_VENV/bin/python" -m pip install chatterbox-tts fastapi "uvicorn[standard]"

echo "Chatterbox is installed. Start it with:"
echo "  $SCRIPT_DIR/run-chatterbox.sh"
