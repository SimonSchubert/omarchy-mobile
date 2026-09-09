#!/usr/bin/env bash
# Boot the VM.
#
#   ./scripts/vm-run.sh              # a window on the Mac, Hyprland on DRM
#   ./scripts/vm-run.sh --headless   # no display; Hyprland headless + VNC
#   ./scripts/vm-run.sh --geometry 1080x2340
#
# Both modes serve VNC on the forwarded port, so `open vnc://127.0.0.1:PORT`
# works either way. The difference is what the guest sees: with a display it
# gets a virtio-gpu and Hyprland drives a real DRM device the way it would on a
# phone; headless it gets no GPU at all, aquamarine finds no DRM node and falls
# back to its headless backend.
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
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless)  HEADLESS=1; shift ;;
    --geometry)  GEOMETRY="$2"; shift 2 ;;
    --snapshot)  SNAPSHOT=1; shift ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    --)          shift; EXTRA+=("$@"); break ;;
    *)           die "unknown argument: $1" ;;
  esac
done

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
  -serial mon:stdio
)

# --snapshot throws away every write on exit. The image stays pristine, which
# is what you want when a change might wedge the guest and re-running the
# 130-package build to get back is twenty minutes you did not plan for.
[ "$SNAPSHOT" = 1 ] && args+=(-snapshot)

if [ "$HEADLESS" = 1 ]; then
  # No GPU device at all. Giving the guest a virtio-gpu and then hiding the
  # window would leave Hyprland driving a DRM device nobody can see, and
  # wayvnc would mirror a display at the QEMU window's geometry rather than
  # the one asked for here.
  args+=(-display none)
  echo "==> headless: Hyprland on its headless backend"
else
  args+=(
    -device "virtio-gpu-pci,xres=$W,yres=$H"
    -device qemu-xhci
    -device usb-kbd
    -device usb-tablet
    -display cocoa,show-cursor=on
  )
  echo "==> window: ${W}x${H}, Hyprland on virtio-gpu DRM"
fi

echo "    ssh  127.0.0.1:$SSH_PORT   (./scripts/vm-ssh.sh)"
echo "    vnc  127.0.0.1:$VNC_PORT   (open vnc://127.0.0.1:$VNC_PORT)"
echo "    the serial console is this terminal; C-a x quits qemu"
echo
exec "$QEMU" "${args[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
