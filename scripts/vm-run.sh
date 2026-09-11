#!/usr/bin/env bash
# Boot the VM.
#
#   ./scripts/vm-run.sh              # a window on the Mac, Hyprland on DRM
#   ./scripts/vm-run.sh --headless   # no display; Hyprland headless + VNC
#   ./scripts/vm-run.sh --geometry 1080x2340
#   ./scripts/vm-run.sh --detach     # the same window, owned by no terminal
#
# From a terminal, QEMU stays in it: the serial console is that terminal, and
# closing it stops the VM. From anything else -- a Claude session's Bash tool --
# it detaches, as --detach asks for from a terminal too. QEMU gets a process
# session of its own, the serial console goes to vm/out/serial.log, the monitor
# to vm/out/monitor.sock, and this returns once ssh is up. A VM started as a
# session's background task died with that session, and whenever the Mac ran
# short of memory, and the window on the Mac went with it.
#
# If the VM is already up, this says so and leaves it alone. The window on the
# Mac is somebody's, and a restart closes it.
#
# Both modes serve VNC on the forwarded port, so `open vnc://127.0.0.1:PORT`
# works either way, and the GUEST IS IDENTICAL in both -- it always gets a
# virtio-gpu, always has a DRM device, and Hyprland always drives it the way it
# would on a phone. --headless only withholds the window on the Mac.
#
# It did originally mean what it says: no display device at all, so aquamarine
# would find no DRM node and fall back to its headless backend. That gives a
# guest with no /dev/dri and no tty1, and with no tty1 there is no autologin
# and therefore no session at all -- `systemctl status getty@tty1` reported
#
#   Active: failed (Result: start-limit-hit)
#
# because agetty exits immediately on a VT that does not exist. Keeping the GPU
# and hiding the window is one guest code path instead of two, and the panel
# geometry is still set here rather than in the guest's config.
#
# -cpu host with -accel hvf: the guest runs aarch64 instructions natively on
# the M-series core. Nothing here is emulated except the devices.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

HEADLESS=0
GEOMETRY=""
SNAPSHOT=0
DETACH=auto
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless)  HEADLESS=1; shift ;;
    --geometry)  GEOMETRY="$2"; shift 2 ;;
    --snapshot)  SNAPSHOT=1; shift ;;
    --detach)    DETACH=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    --)          shift; EXTRA+=("$@"); break ;;
    *)           die "unknown argument: $1" ;;
  esac
done
# The serial console on stdio is only any use with a terminal to show it.
if [ "$DETACH" = auto ]; then
  if [ -t 0 ]; then DETACH=0; else DETACH=1; fi
fi

VERSION=$(manifest_get omarchy-mobile version) || exit 1
IMG="vm/out/omarchy-mobile-$VERSION.img"
[ -f "$IMG" ] || die "no image at $IMG -- run ./scripts/vm-build.sh first"

W=$(manifest_get vm width)  || exit 1
H=$(manifest_get vm height) || exit 1
if [ -n "$GEOMETRY" ]; then
  W=${GEOMETRY%x*}; H=${GEOMETRY#*x}
  [ "$W" -gt 0 ] 2>/dev/null && [ "$H" -gt 0 ] 2>/dev/null || die "bad --geometry: $GEOMETRY"
fi
SMP=$(manifest_get vm smp)       || exit 1
MEM=$(manifest_get vm memory)    || exit 1
SSH_PORT=$(manifest_get vm ssh_port) || exit 1
VNC_PORT=$(manifest_get vm vnc_port) || exit 1

# Already up: say so rather than fail on the port forward, and never restart it.
holder=$(lsof -nP -t -iTCP:"$SSH_PORT" -sTCP:LISTEN 2>/dev/null | head -n1 || true)
if [ -n "$holder" ]; then
  cmd=$(ps -o command= -p "$holder" 2>/dev/null || true)
  case "$cmd" in
    *qemu-system-aarch64*)
      case "$cmd" in *"-display none"*) mode="headless, no window" ;; *) mode="in a window" ;; esac
      echo "==> already running: pid $holder, $mode -- left as it is"
      echo "    ssh  127.0.0.1:$SSH_PORT   (./scripts/vm-ssh.sh)"
      echo "    vnc  127.0.0.1:$VNC_PORT   (open vnc://127.0.0.1:$VNC_PORT)"
      exit 0 ;;
    *) die "127.0.0.1:$SSH_PORT is taken by pid $holder: ${cmd%% *}" ;;
  esac
fi

# A rebuild copies the new image over this one in place (build-disk.sh's
# cp --sparse=always), so a VM booted from it now would write into the new
# image while it lands.
if builder=$(pgrep -f 'scripts/vm-build\.sh' | head -n1) && [ -n "$builder" ]; then
  die "vm-build.sh is running (pid $builder) and rewrites $IMG -- start the VM once it has finished"
fi

QEMU=$(command -v qemu-system-aarch64) || die "qemu-system-aarch64 not found -- brew install qemu"
FW_DIR=$(dirname "$QEMU")/../share/qemu
CODE="$FW_DIR/edk2-aarch64-code.fd"
[ -f "$CODE" ] || die "no edk2 firmware at $CODE"

# UEFI variables persist across boots -- boot order and the firmware's own
# settings live here, not in the disk. One per image, kept beside it.
VARS="vm/out/edk2-vars-$VERSION.fd"
if [ ! -f "$VARS" ]; then
  # A blank 64 MiB pflash region; edk2 initialises it on first boot. It has to
  # be exactly the size of the code image or QEMU refuses the pflash pairing.
  mkdir -p vm/out && truncate -s 64m "$VARS"
fi

args=(
  -name "omarchy-mobile $VERSION"
  -machine virt,accel=hvf,gic-version=3
  -cpu host
  -smp "$SMP"
  -m "$MEM"
  -drive "if=pflash,format=raw,readonly=on,file=$CODE"
  -drive "if=pflash,format=raw,file=$VARS"
  -drive "if=virtio,format=raw,file=$IMG,cache=writeback,discard=unmap"
  -device virtio-rng-pci
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$VNC_PORT-:5900"
  -device virtio-net-pci,netdev=net0
)

# --snapshot throws away every write on exit. The image stays pristine, which
# is what you want when a change might wedge the guest and re-running the
# 130-package build to get back is twenty minutes you did not plan for.
[ "$SNAPSHOT" = 1 ] && args+=(-snapshot)

# The GPU and its input devices are unconditional; see the note at the top.
args+=(
  -device "virtio-gpu-pci,xres=$W,yres=$H"
  -device qemu-xhci
  -device usb-kbd
  -device usb-tablet
)

if [ "$HEADLESS" = 1 ]; then
  args+=(-display none)
  echo "==> headless: ${W}x${H}, no window -- watch it over VNC"
else
  args+=(-display cocoa,show-cursor=on)
  echo "==> window: ${W}x${H}, Hyprland on virtio-gpu DRM"
fi

SERIAL=vm/out/serial.log
MONITOR=vm/out/monitor.sock
PIDFILE=vm/out/qemu.pid
if [ "$DETACH" = 1 ]; then
  rm -f "$MONITOR" "$PIDFILE"
  args+=(-serial "file:$SERIAL" -monitor "unix:$MONITOR,server=on,wait=off" -pidfile "$PIDFILE")
else
  args+=(-serial mon:stdio)
fi

echo "    ssh  127.0.0.1:$SSH_PORT   (./scripts/vm-ssh.sh)"
echo "    vnc  127.0.0.1:$VNC_PORT   (open vnc://127.0.0.1:$VNC_PORT)"
if [ "$DETACH" = 0 ]; then
  echo "    the serial console is this terminal; C-a x quits qemu"
  echo
  exec "$QEMU" "${args[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
fi

echo "    serial $SERIAL; stop it with"
echo "      echo system_powerdown | nc -U $MONITOR"

# Fork, and setsid in the child before it becomes QEMU: it leaves the caller's
# process group and session, and launchd adopts it when the caller exits, so
# nothing that tears down the caller's process tree reaches it.
python3 - "$QEMU" "${args[@]}" ${EXTRA[@]+"${EXTRA[@]}"} <<'PY'
import os, sys
if os.fork():
    os._exit(0)
os.setsid()
null = os.open(os.devnull, os.O_RDWR)
log = os.open("vm/out/qemu.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(null, 0)
os.dup2(log, 1)
os.dup2(log, 2)
os.execv(sys.argv[1], sys.argv[1:])
PY

for _ in $(seq 50); do
  if lsof -nP -iTCP:"$SSH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "    up: pid $(cat "$PIDFILE" 2>/dev/null || echo '?'), detached"
    exit 0
  fi
  sleep 0.2
done
printf '\033[31m!! QEMU did not come up; vm/out/qemu.log says:\033[0m\n' >&2
tail -n 20 vm/out/qemu.log >&2
exit 1
