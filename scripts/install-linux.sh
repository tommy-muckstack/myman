#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Linux ]]; then
  echo 'This installer is for Linux. The macOS app and CLI are unchanged.' >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo 'Install Node.js 22 or newer, then rerun this script.' >&2
  exit 1
fi
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' || {
  echo 'Node.js 22 or newer is required.' >&2
  exit 1
}
installer_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
node "$installer_root/integrations/linux/install.mjs" "$installer_root"
cat <<'MESSAGE'
Optional Ubuntu packages (the installer never runs sudo):
  sudo apt-get install imagemagick scrot x11-utils x11-xserver-utils git fonts-dejavu-core
  sudo apt-get install tesseract-ocr xvfb
Optional Omarchy / Arch packages (Hyprland supplies hyprctl):
  sudo pacman -S --needed nodejs-lts-jod git imagemagick librsvg grim ttf-dejavu
  sudo pacman -S --needed tesseract tesseract-data-eng
Run inside the Hyprland session, preserving WAYLAND_DISPLAY, XDG_RUNTIME_DIR,
and HYPRLAND_INSTANCE_SIGNATURE for remote agents. X11 uses DISPLAY/XAUTHORITY.
For a virtual X11 desktop, use xvfb-run.
Edit the printed agents.json as the owner to enable only the required grants.
MESSAGE
