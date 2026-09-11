#!/usr/bin/env bash
# Drag a finger across the running VM's screen, for testing the gestures.
#
#   ./scripts/vm-drag.sh 180 712 -300          # swipe up from the bottom edge
#   ./scripts/vm-drag.sh 180 40 400            # pull the drawer's handle down
#   ./scripts/vm-drag.sh 52 218 0 1            # a tap
#   DX=-150 ./scripts/vm-drag.sh 180 712 0     # swipe sideways along the strip
#   HOLD=4 ./scripts/vm-drag.sh 180 712 -160   # hold, to screenshot mid-drag
#
# Coordinates are LOGICAL pixels -- 360x720 at the shipped scale, the same
# numbers `hyprctl cursorpos` prints. A negative dy is upward, a negative DX
# leftward.
#
# There is no other way to test a gesture from here: the guest's pointer is a
# usb-tablet QEMU forwards from the host, and the host cannot drive it either.
# scripts/vm-drag.py creates a second pointer in the guest through /dev/uinput
# for one gesture and destroys it afterwards.
#
# Pair it with the shell's own report, which says what it believes:
#
#   ./scripts/vm-ssh.sh 'OMARCHY_PATH=/usr/share/omarchy omarchy-shell drawer status'
#   closed progress=0 apps=13 query=""
#
# scripts/vm-selftest.sh is both together, once per acceptance criterion.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }
[ $# -ge 3 ] || die "usage: $0 <x> <y> <dy> [steps] [delay_ms]"

USER_NAME=$(manifest_get guest user) || exit 1
PORT=$(manifest_get vm ssh_port)     || exit 1
SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)

scp "${SSH_OPTS[@]}" -P "$PORT" scripts/vm-drag.py \
  "$USER_NAME@127.0.0.1:/tmp/vm-drag.py" >/dev/null

# accel_profile flat, so one relative unit is one logical pixel and the travel
# asked for is the travel delivered. `hyprctl keyword` is refused by 0.56's Lua
# parser ("keyword can't work with non-legacy parsers -- use eval"), so this is
# the config call rather than the keyword.
#
# It lasts until the session's next `hyprctl reload`, and it changes nothing
# about the image -- only how this synthetic pointer is interpreted.
ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@127.0.0.1" \
  "export HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t /run/user/1000/hypr | head -1)
   export XDG_RUNTIME_DIR=/run/user/1000
   hyprctl eval 'hl.config({ input = { accel_profile = \"flat\", sensitivity = 0 } })' >/dev/null
   sudo HYPRLAND_INSTANCE_SIGNATURE=\$HYPRLAND_INSTANCE_SIGNATURE \
        XDG_RUNTIME_DIR=/run/user/1000 HOLD=${HOLD:-0} DX=${DX:-0} \
        python3 /tmp/vm-drag.py $*"
