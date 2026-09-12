#!/usr/bin/env bash
# Put Android on the phone: install Waydroid in the guest, and boot it.
#
#   ./scripts/vm-waydroid.sh install    # disk, packages, images, props, init
#   ./scripts/vm-waydroid.sh start      # boot the container, show the UI
#   ./scripts/vm-waydroid.sh stop
#   ./scripts/vm-waydroid.sh status
#   ./scripts/vm-waydroid.sh disk       # grow the guest's disk, live
#
# Waydroid runs a whole Android in an LXC container against the host's Wayland
# compositor, so an Android app becomes a window Hyprland manages like any
# other. On this image it needs four things the built image does not have, and
# each one is a decision worth writing down.
#
# 1. A KERNEL WITH BINDER. ALARM's linux-aarch64 7.2.4 already has it built in
#    -- CONFIG_ANDROID_BINDER_IPC=y and CONFIG_ANDROID_BINDERFS=y -- so the
#    binder_linux-dkms module every Waydroid-on-Arch guide starts with is not
#    needed here. This is the one hard prerequisite and it costs nothing.
#
# 2. ROOM. The images are 1.9 GB unpacked and the built image's root has about
#    3.6 GB free, which fits them with nothing left for Android's /data. So
#    `disk` grows the guest's disk, and it does it LIVE: the QEMU monitor's
#    block_resize enlarges the raw image, virtio-blk tells the guest its
#    capacity changed, sfdisk moves partition 2's end outward (its start and
#    therefore the filesystem are untouched, and -N keeps the PARTUUID that
#    fstab resolves), and resize2fs grows a mounted ext4. No reboot, so the
#    QEMU window on the Mac stays where it is.
#
#    A rebuilt image goes back to 14.7 GB. To build one with the room already
#    in it, raise the slack instead: ROOT_SLACK_MIB=12288 ./scripts/vm-build.sh
#
# 3. THE arm64_only IMAGES, not the arm64 ones. This matters more than it
#    looks. Apple Silicon has no AArch32, so every 32-bit Android binary exits
#    127 -- and `boringssl_self_test32_vendor` carries init's reboot_on_failure:
#
#      init: Service 'boringssl_self_test32_vendor' (pid 13) exited with status 127
#      init: Service boringssl_self_test32_vendor has 'reboot_on_failure' option
#            and failed, shutting down system.
#
#    Android shut itself down 3.2 seconds into every boot. Waydroid already
#    detects this CPU ("AArch64 CPU does not appear to support AArch32, assuming
#    arm64_only") and uses that string to pick its image channel -- so the fix
#    is to feed it the channel it asked for. The arm64_only images carry no
#    32-bit ABI at all, boot in about 60 seconds, and are smaller for it.
#
# 4. A GRALLOC THAT DOES NOT NEED A GPU. This VM's virtio-gpu has no 3D:
#
#      [drm] features: -virgl +edid -resource_blob -host_visible
#
#    and the QEMU that runs it has no virtio-gpu-gl device to offer instead, so
#    there is no way to give the guest one. Waydroid's default gralloc allocates
#    through GBM, and GBM cannot allocate here -- the render node refuses dumb
#    buffers outright, which is by design, render nodes only permit
#    DRM_RENDER_ALLOW ioctls:
#
#      /dev/dri/renderD128  KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
#      /dev/dri/card0       every allocation OK
#
#    Pointing Waydroid at card0 (its own `drm_device` knob) gets SurfaceFlinger
#    up, but then every app dies in gbm_mesa_bo_import: kms_swrast can allocate
#    a dumb buffer and cannot import one back, so the mapper null-derefs.
#
#    So this drops GBM entirely: ro.hardware.gralloc=default is the ashmem,
#    CPU-memory gralloc, with no dmabuf anywhere in it. Android's EGL then
#    resolves to ANGLE, and ANGLE enumerates the Vulkan ICDs the image ships
#    and finds SwiftShader's --
#
#      ANGLE: Renderer (Vulkan 1.2.0 (SwiftShader Device (LLVM 10.0.0)))
#
#    vulkan.pastel.so, which was in the image the whole time ("pastel" is what
#    AOSP calls SwiftShader's Vulkan driver). That is a complete software GPU,
#    so nothing in the path wants hardware. Do NOT also set ro.hardware.vulkan:
#    forcing it to lvp picks lavapipe instead, which SIGSEGVs in memcpy.
#
#    The catch is that this prop is hand-written into waydroid_base.prop, and
#    `waydroid init -f` regenerates that file from make_base_props() and puts
#    gralloc=gbm back. Re-run `install` (or `props`) after any re-init.
#
# The images are fetched on the MAC and pushed in, because SourceForge's mirror
# gives the guest 64 kB/s through slirp -- four hours for the system image --
# and the Mac 20 MB/s. Both are checked against the sha256 the OTA channel
# publishes before they are unpacked, and again end-to-end after the transfer.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

IMAGES_DIR=/etc/waydroid-extra/images   # waydroid's preinstalled-images path:
                                        # finding both images here makes `init`
                                        # set system_ota=None and skip the
                                        # download, and use them where they lie.
WORK=${WAYDROID_WORK:-vm/out/waydroid}  # where the Mac keeps the zips
DISK_TARGET=${WAYDROID_DISK:-32G}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

ssh_() { ./scripts/vm-ssh.sh "$@"; }

# ---------------------------------------------------------------------------
# The guest's disk, grown live through the QEMU monitor.
grow_disk() {
  local monitor=vm/out/monitor.sock
  [ -S "$monitor" ] || die "no QEMU monitor at $monitor -- is the VM detached and running?"

  local free_mib
  free_mib=$(ssh_ "df -m --output=avail / | tail -1" | tr -d ' ')
  if [ "$free_mib" -gt 6000 ]; then
    info "root has ${free_mib} MiB free, enough for the images -- leaving the disk alone"
    return 0
  fi
  say "growing the guest's disk to $DISK_TARGET (live, no reboot)"

  # HMP's size argument takes a suffix; a bare number is MEGABYTES, so
  # "34359738368" asks for 34 exabytes and fails with "File too large".
  python3 - "$monitor" "$DISK_TARGET" <<'PY'
import socket, sys, time
sock, target = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10)
s.connect(sock); time.sleep(0.4)
try: s.recv(65536)
except Exception: pass
s.sendall(f"block_resize virtio0 {target}\n".encode()); time.sleep(2.0)
buf = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        buf += d
except Exception: pass
txt = buf.decode(errors="replace")
if "Error" in txt:
    sys.exit("block_resize failed: " + " ".join(l for l in txt.splitlines() if "Error" in l))
s.close()
PY
  info "virtio0 resized; growing partition 2 and the filesystem"
  # -N 2 changes only partition 2, keeping its type, name and uuid -- fstab
  # resolves root by PARTUUID, so a regenerated uuid would leave it unbootable.
  ssh_ 'echo ", +" | sudo sfdisk --no-reread --force -N 2 /dev/vda >/dev/null 2>&1; sudo partx -u /dev/vda; sudo resize2fs /dev/vda2' >/dev/null 2>&1 || true
  info "$(ssh_ 'df -h / | tail -1')"
}

# ---------------------------------------------------------------------------
install_packages() {
  say "installing waydroid"
  # No -Sy: the image's sync db already knows waydroid 1.6.3, and refreshing it
  # here would risk a partial upgrade of a guest nobody asked to update.
  ssh_ 'sudo pacman -S --needed --noconfirm waydroid 2>&1 | tail -3'
  info "$(ssh_ 'pacman -Q waydroid lxc python-gbinder dnsmasq | tr "\n" " "')"
}

# ---------------------------------------------------------------------------
# Fetch one image from its OTA channel, check it, unpack it. The build is the
# one the manifest pins, not whatever is newest -- and the channel's own sha256
# for that build has to agree with the manifest's before anything is downloaded,
# so a rewritten channel is caught rather than trusted.
fetch_one() {
  local kind=$1 url_json=$2 want_fn=$3 want_sha=$4
  mkdir -p "$WORK"
  local meta="$WORK/$kind.meta"
  python3 - "$url_json" "$want_fn" "$want_sha" > "$meta" <<'PY'
import json, sys, urllib.request
url_json, want_fn, want_sha = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(urllib.request.urlopen(url_json))
for r in d["response"]:
    if r["filename"] == want_fn:
        if r["id"] != want_sha:
            sys.exit(f"channel publishes sha256 {r['id']} for {want_fn}, "
                     f"manifest pins {want_sha}")
        print(r["url"]); print(r["filename"]); print(r["id"])
        break
else:
    sys.exit(f"{want_fn} is no longer on the channel ({len(d['response'])} builds "
             f"listed) -- re-pin [waydroid] in manifest.toml")
PY
  local url fn want got
  url=$(sed -n 1p "$meta"); fn=$(sed -n 2p "$meta"); want=$(sed -n 3p "$meta")
  [ -n "$fn" ] || die "$kind: could not resolve the pinned build"
  info "$kind: $fn"
  if [ ! -f "$WORK/$fn" ]; then
    # -C - resumes: the mirror drops long transfers, and 86% of 759 MB is worth
    # keeping.
    for _ in 1 2 3 4 5; do
      curl -L --retry 5 --retry-all-errors -C - -o "$WORK/$fn.part" "$url" && break
      sleep 3
    done
    mv "$WORK/$fn.part" "$WORK/$fn"
  fi
  got=$(shasum -a 256 "$WORK/$fn" | cut -d' ' -f1)
  [ "$got" = "$want" ] || die "$kind sha256 mismatch: got $got, channel says $want"
  info "sha256 ok, unpacking"
  (cd "$WORK" && unzip -o -q "$fn")
}

fetch_images() {
  local ch dev sys_t ven_t sys_b sys_s ven_b ven_s
  ch=$(manifest_get waydroid channel)        || exit 1
  dev=$(manifest_get waydroid device)        || exit 1
  sys_t=$(manifest_get waydroid system_type) || exit 1
  ven_t=$(manifest_get waydroid vendor_type) || exit 1
  sys_b=$(manifest_get waydroid system_build)  || exit 1
  sys_s=$(manifest_get waydroid system_sha256) || exit 1
  ven_b=$(manifest_get waydroid vendor_build)  || exit 1
  ven_s=$(manifest_get waydroid vendor_sha256) || exit 1
  say "fetching the $dev images on the Mac"
  fetch_one system "https://ota.waydro.id/system/$ch/$dev/$sys_t.json" "$sys_b" "$sys_s"
  fetch_one vendor "https://ota.waydro.id/vendor/$dev/$ven_t.json"     "$ven_b" "$ven_s"
}

push_images() {
  say "pushing the images into the guest"
  ssh_ "sudo mkdir -p $IMAGES_DIR"
  local img host_sum guest_sum t0
  for img in system vendor; do
    [ -f "$WORK/$img.img" ] || die "no $WORK/$img.img -- fetch failed?"
    t0=$SECONDS
    info "$img.img ($(du -h "$WORK/$img.img" | cut -f1)) -- gzip -1 over ssh, slirp is the slow part"
    gzip -1 -c "$WORK/$img.img" | ssh_ "sudo sh -c 'gunzip -c > $IMAGES_DIR/$img.img.part'"
    host_sum=$(shasum -a 256 "$WORK/$img.img" | cut -d' ' -f1)
    guest_sum=$(ssh_ "sudo sha256sum $IMAGES_DIR/$img.img.part | cut -d' ' -f1")
    if [ "$host_sum" != "$guest_sum" ]; then
      ssh_ "sudo rm -f $IMAGES_DIR/$img.img.part"
      die "$img.img differs after transfer (host $host_sum, guest $guest_sum)"
    fi
    # Only now take the real name: waydroid crashes outright on a directory
    # that holds one image and not the other (it os.stat()s both), and a
    # half-written one is worse than a missing one.
    ssh_ "sudo mv $IMAGES_DIR/$img.img.part $IMAGES_DIR/$img.img"
    info "$img.img ok, $((SECONDS - t0))s"
  done
}

# ---------------------------------------------------------------------------
set_props() {
  say "gralloc: ashmem, not GBM"
  ssh_ 'sudo python3 - <<PY
p = "/var/lib/waydroid/waydroid_base.prop"
# Drop the GBM trio make_base_props() wrote. ro.hardware.vulkan is dropped too
# and deliberately not replaced: left unset, ANGLE finds SwiftShader; set to
# lvp it picks lavapipe, which crashes.
drop = {"ro.hardware.gralloc", "ro.hardware.egl", "ro.hardware.vulkan", "gralloc.gbm.device"}
out = [l.rstrip("\n") for l in open(p) if l.split("=")[0] not in drop]
out.append("ro.hardware.gralloc=default")
open(p, "w").write("\n".join(out) + "\n")
PY'
  info "$(ssh_ 'grep -E "gralloc|egl" /var/lib/waydroid/waydroid_base.prop | tr "\n" " "')"
}

do_init() {
  say "waydroid init"
  ssh_ 'sudo waydroid init 2>&1 | tail -3'
  info "$(ssh_ 'sudo grep -E "images_path|system_ota|arch " /var/lib/waydroid/waydroid.cfg | tr "\n" " "')"
}

# ---------------------------------------------------------------------------
do_start() {
  say "starting the container"
  ssh_ 'sudo systemctl start waydroid-container; sleep 2'
  # The session is the user's, and it needs the compositor an ssh login has no
  # idea about -- same reconstruction vm-screenshot.sh does.
  ssh_ 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
        export WAYLAND_DISPLAY=$(basename $(ls -t $XDG_RUNTIME_DIR/wayland-* 2>/dev/null | grep -v .lock | head -1))
        setsid env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
          waydroid session start >/tmp/wd-session.log 2>&1 </dev/null &
        sleep 5'
  info "waiting for Android to finish booting (about a minute in software)"
  ssh_ 'for i in $(seq 1 20); do
          bc=$(sudo waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d "\r")
          [ "$bc" = "1" ] && { echo "   boot_completed after $((i*10))s"; break; }
          sleep 10
        done'
  ssh_ 'waydroid status 2>&1 | head -5'
}

show_ui() {
  say "showing the full UI"
  ssh_ 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
        export WAYLAND_DISPLAY=$(basename $(ls -t $XDG_RUNTIME_DIR/wayland-* 2>/dev/null | grep -v .lock | head -1))
        setsid env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
          waydroid show-full-ui >/tmp/wd-ui.log 2>&1 </dev/null &
        sleep 20'
  info "$(ssh_ 'export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1); hyprctl clients | grep -c "class: Waydroid"') Waydroid window(s) mapped"
}

do_stop() {
  say "stopping"
  ssh_ 'export XDG_RUNTIME_DIR=/run/user/$(id -u); export WAYLAND_DISPLAY=wayland-1
        waydroid session stop >/dev/null 2>&1 || true
        sudo systemctl stop waydroid-container || true'
  info "stopped"
}

do_status() {
  ssh_ 'waydroid status 2>&1 | head -6
        echo
        echo "android:  $(sudo waydroid shell -- getprop ro.build.version.release 2>/dev/null | tr -d "\r")  $(sudo waydroid shell -- getprop ro.product.model 2>/dev/null | tr -d "\r")"
        echo "gralloc:  $(sudo waydroid shell -- getprop ro.hardware.gralloc 2>/dev/null | tr -d "\r")"
        echo "egl:      $(sudo waydroid shell -- getprop ro.hardware.egl 2>/dev/null | tr -d "\r")"
        echo "booted:   $(sudo waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d "\r")"'
}

# ---------------------------------------------------------------------------
case "${1:-install}" in
  install)
    . scripts/vm-lease.sh; lease_take "vm-waydroid.sh install" || exit 1
    grow_disk; install_packages; fetch_images; push_images; do_init; set_props
    say "installed"
    info "./scripts/vm-waydroid.sh start   boots it"
    ;;
  disk)   . scripts/vm-lease.sh; lease_take "vm-waydroid.sh disk" || exit 1; grow_disk ;;
  images) . scripts/vm-lease.sh; lease_take "vm-waydroid.sh images" || exit 1; fetch_images; push_images ;;
  props)  . scripts/vm-lease.sh; lease_take "vm-waydroid.sh props" || exit 1; set_props ;;
  start)  . scripts/vm-lease.sh; lease_take "vm-waydroid.sh start" || exit 1; do_start; show_ui ;;
  ui)     . scripts/vm-lease.sh; lease_take "vm-waydroid.sh ui" || exit 1; show_ui ;;
  stop)   . scripts/vm-lease.sh; lease_take "vm-waydroid.sh stop" || exit 1; do_stop ;;
  status) do_status ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
