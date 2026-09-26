#!/usr/bin/env bash
set -euo pipefail
# Do not reuse a caller's live compositor while the synthetic one starts.
unset WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
wayland_test_dir="$(mktemp -d)"
export XDG_RUNTIME_DIR="$wayland_test_dir/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
cat > "$wayland_test_dir/sway.conf" <<'CONFIG'
output HEADLESS-1 mode 1280x800 bg #336699 solid_color
seat seat0 fallback true
CONFIG
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway --unsupported-gpu -c "$wayland_test_dir/sway.conf" > "$wayland_test_dir/sway.log" 2>&1 &
wayland_test_pid=$!
trap 'kill "$wayland_test_pid" 2>/dev/null || true; rm -rf "$wayland_test_dir"' EXIT
for attempt in {1..100}; do
  for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [[ -S "$socket" ]]; then export WAYLAND_DISPLAY="${socket##*/}"; break; fi
  done
  for socket in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do
    if [[ -S "$socket" ]]; then export SWAYSOCK="$socket"; break; fi
  done
  if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${SWAYSOCK:-}" ]] && swaymsg -t get_outputs >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if [[ -z "${SWAYSOCK:-}" ]]; then cat "$wayland_test_dir/sway.log"; exit 1; fi
export MYMAN_TEST_WAYLAND=1
export XDG_SESSION_TYPE=wayland
unset HYPRLAND_INSTANCE_SIGNATURE
node --test integrations/linux/test/wayland.test.mjs
