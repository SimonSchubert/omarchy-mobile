#!/usr/bin/env bash
# Take a screenshot of the running session, straight off the guest.
#
#   ./scripts/vm-screenshot.sh                  # -> docs/screenshots/<stamp>.png
#   ./scripts/vm-screenshot.sh docs/x.png
#
# grim runs inside the guest against the live Wayland session, so what lands is
# what the compositor actually composited -- not a photo of a QEMU window with
# its title bar in it. That matters once these start going in docs/.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

OUT=${1:-docs/screenshots/$(date +%Y%m%d-%H%M%S).png}
mkdir -p "$(dirname "$OUT")"

# grim needs WAYLAND_DISPLAY and XDG_RUNTIME_DIR, and an ssh session has
# neither -- so they are reconstructed from the uid and the socket Hyprland
# actually created.
./scripts/vm-ssh.sh 'export XDG_RUNTIME_DIR=/run/user/$(id -u); \
  export WAYLAND_DISPLAY=$(basename $(ls -t $XDG_RUNTIME_DIR/wayland-* 2>/dev/null | grep -v .lock | head -1)); \
  grim -t png -' > "$OUT"

if [ ! -s "$OUT" ]; then
  rm -f "$OUT"
  echo "!! grim produced nothing -- is the session up? try ./scripts/vm-ssh.sh hyprctl monitors" >&2
  exit 1
fi
echo "$OUT  ($(du -h "$OUT" | cut -f1))"
