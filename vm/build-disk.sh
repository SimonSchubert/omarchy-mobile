#!/bin/bash
# Build vm/out/omarchy-mobile-<version>.img -- a GPT/UEFI disk for an aarch64
# QEMU guest.
#
# Runs inside vm/Dockerfile, natively on Apple Silicon, so every package is a
# real aarch64 binary and nothing is emulated.
#
# Layout -- a plain UEFI disk, because a VM boots through edk2 and has none of
# the SPL-at-byte-131072 constraints a PinePhone image has:
#
#   LBA 2048      ESP    FAT32 512M   Image, initramfs, systemd-boot, entries
#   LBA 1050624   root   ext4         sized to contents + slack
#
# No loop devices: mkfs.ext4 -d and mcopy populate a filesystem image from a
# directory without mounting it, which Docker Desktop's VM cannot do reliably.
# Only mkinitcpio needs a chroot, which is why the container wants --privileged.
set -euo pipefail

OUT=${OUT:-/out}
REPO=${REPO:-/repo}
SHARE=${SHARE:-/usr/local/share/omarchy-mobile}
PKGS=${PKGS:-/pkgs}

# /work is a Docker VOLUME, and /out is the host bind mount. The rootfs is
# built in the volume and only the finished image is copied out, because a
# rootfs cannot be built on Docker Desktop's VirtioFS at all:
#
#   $ systemd-sysusers --root=/out/t
#   Creating group 'wheel' with GID 999.
#   Failed to flush /out/t/etc/.#group5b567ce2a2a0917e: No such file or directory
#   $ cat /out/t/etc/group
#   root:x:0:root
#
# It reports success and writes nothing. The write-to-temp-then-rename pattern
# that every careful program uses -- systemd-sysusers, pacman's .part
# downloads, useradd -- silently loses the file. The same test against a
# container-internal path creates the groups correctly.
#
# This cost three separate failures that each looked like something else: a
# pacman "could not rename ... (No such file or directory)" on a file it had
# just written, a useradd that could not find any group, and a systemd-sysusers
# that printed "Creating group 'wheel'" and created nothing.
WORK=${WORK:-/work}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

. "$SHARE/manifest.sh"
VERSION=$(manifest_get omarchy-mobile version) || die "no version pin"
GUEST_USER=$(manifest_get guest user)          || die "no guest user"
GUEST_HOST=$(manifest_get guest hostname)      || die "no guest hostname"
OMARCHY_REF=$(manifest_get omarchy ref)        || die "no omarchy ref"
OMARCHY_VERSION=$(manifest_get omarchy version) || die "no omarchy version"
OMARCHY_URL=$(manifest_get omarchy url)        || die "no omarchy url"
VM_WIDTH=$(manifest_get vm width)              || die "no vm width"
VM_HEIGHT=$(manifest_get vm height)            || die "no vm height"
VM_SCALE=$(manifest_get vm scale)              || die "no vm scale"

SESSION_ONLY=${SESSION_ONLY:-0}

# Deterministic partition GUIDs. The loader entry and /etc/fstab both name the
# root filesystem by PARTUUID, and a PARTUUID that changes every build is a
# fstab that has to be rewritten every build -- so it is pinned here rather
# than discovered afterwards. "4f4d4152" is "OMAR".
ESP_UUID=4f4d4152-4348-0000-0000-000000000001
ROOT_UUID=4f4d4152-4348-0000-0000-000000000002

SECTOR=512
ESP_LBA=2048
ESP_MIB=512
ROOT_LBA=$(( ESP_LBA + ESP_MIB * 1024 * 1024 / SECTOR ))
ROOT_SLACK_MIB=${ROOT_SLACK_MIB:-6144}

NAME="omarchy-mobile-$VERSION"
IMG="$WORK/$NAME.img"
ROOTDIR="$WORK/rootfs"
BOOTSTAGE="$WORK/boot"

# The CONTENTS of $WORK, not $WORK itself: it is a volume mount point now, and
# `rm -rf /work` on one fails with "Device or resource busy".
mkdir -p "$WORK" "$OUT"
find "$WORK" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# --- provenance ------------------------------------------------------------
# A disk that corresponds to no commit cannot be rebuilt or bisected. /repo
# arrives as a bind mount whose inode metadata does not match the host's
# .git/index, so the host script passes both of these in rather than letting a
# stat-based check here call every tracked file modified.
COMMIT="${COMMIT:-$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)}"
info "commit ${COMMIT:0:12}${DIRTY:+ (DIRTY)}"

# ---------------------------------------------------------------------------
say "package set"
pkglist() {
  # Package names out of vm/packages/*: strip comments, inline trailing
  # comments and blank lines. An inline comment is why this is not `grep -v`.
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}
PKGLIST=$(pkglist "$REPO/vm/packages/session")
[ -n "$PKGLIST" ] || die "vm/packages/session is empty"
if [ "$SESSION_ONLY" = 1 ]; then
  info "session tier only ($(echo "$PKGLIST" | wc -l) packages) -- SESSION_ONLY=1"
else
  PKGLIST="$PKGLIST
$(pkglist "$REPO/vm/packages/apps")"
  info "session + apps ($(echo "$PKGLIST" | wc -l) packages)"
fi

# Packages this project built because Arch Linux ARM is behind on them. They go
# in a file:// repo listed AHEAD of core and extra, so pacman prefers ours only
# where the version is actually newer -- when ALARM catches up, its package wins
# on version and this repo quietly stops mattering.
LOCALREPO=""
if compgen -G "$PKGS/*.pkg.tar.*" >/dev/null; then
  say "local packages"
  mkdir -p "$WORK/repo"
  cp "$PKGS"/*.pkg.tar.* "$WORK/repo/"
  repo-add --quiet "$WORK/repo/omarchy-mobile.db.tar.gz" "$WORK/repo"/*.pkg.tar.* >/dev/null
  ls -1 "$WORK/repo"/*.pkg.tar.* | sed 's|.*/|    |'
  LOCALREPO=$'[omarchy-mobile]\nSigLevel = Never\nServer = file://'"$WORK/repo"
  # Our own builds are unsigned, which is why this repo says Never and the
  # upstream ones do not. It is a file:// path inside a container built from a
  # pinned commit, not something fetched over a network.
fi

cat >"$WORK/pacman.conf" <<EOF
[options]
Architecture = aarch64
CheckSpace
DisableSandbox
# pacman gives up on a stalled mirror with "Operation too slow. Less than 1
# bytes/sec". The retry loop below covers a mirror that drops the connection;
# this covers one that merely crawls, which on a 130-package transaction is the
# more common way to lose forty minutes.
DisableDownloadTimeout
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
$LOCALREPO
[core]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
[extra]
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
EOF

# ---------------------------------------------------------------------------
say "pacstrap"
mkdir -p "$ROOTDIR"
# -K gives the target its own keyring rather than copying the builder's.
attempt=0
until pacstrap -C "$WORK/pacman.conf" -K "$ROOTDIR" $PKGLIST; do
  attempt=$(( attempt + 1 ))
  [ "$attempt" -ge 3 ] && die "pacstrap failed $attempt times"
  info "pacstrap failed (attempt $attempt) -- retrying"
  sleep 5
done

# ---------------------------------------------------------------------------
say "omarchy $OMARCHY_REF"
# Upstream's configuration and theme layer, UNPATCHED. moarchy carries 264
# lines of patch here to turn Quickshell.Hyprland into Quickshell.I3; this
# project's entire premise is that on hardware that clears Hyprland's GLES 3.x
# floor, that patch is not needed.
curl -fsSL "$OMARCHY_URL/archive/$OMARCHY_REF.tar.gz" -o "$WORK/omarchy.tar.gz" \
  || die "could not fetch omarchy $OMARCHY_REF"
mkdir -p "$WORK/omarchy"
tar xzf "$WORK/omarchy.tar.gz" -C "$WORK/omarchy" --strip-components=1

# Patches, if any. The project's premise is that Omarchy's Hyprland coupling
# needs no porting -- these are MOBILE fixes, not architecture ones, and each
# is small enough to be a candidate for upstream rather than a fork.
#
# --fuzz=0 and no offset: a patch that no longer applies cleanly fails the
# build and names the hunk, rather than landing somewhere it was never aimed
# at. That is moarchy's rule for port-4x.patch and it is here for the same
# reason -- a silently mis-applied hunk is a shell that looks fine until the
# one screen the hunk was about.
if compgen -G "$REPO/patches/*.patch" >/dev/null; then
  for p in "$REPO"/patches/*.patch; do
    info "patch $(basename "$p")"
    patch -d "$WORK/omarchy" -p1 --fuzz=0 --no-backup-if-mismatch <"$p" \
      || die "$(basename "$p") does not apply to omarchy $OMARCHY_REF"
  done
fi

install -d "$ROOTDIR/usr/share/omarchy"
# /usr/share/omarchy is the path upstream hardcodes: three scripts and their
# acceptance test all say OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}".
#
# install/ is IN despite reading like upstream's x86_64 installer -- a dozen
# runtime omarchy-* scripts source things out of it, and leaving it out makes
# every omarchy-theme-set print a missing browser-policy.sh.
for d in shell config default themes applications migrations install; do
  [ -d "$WORK/omarchy/$d" ] && cp -a "$WORK/omarchy/$d" "$ROOTDIR/usr/share/omarchy/"
done
for f in version icon.png icon.txt logo.svg logo.txt LICENSE; do
  [ -f "$WORK/omarchy/$f" ] && install -Dm644 "$WORK/omarchy/$f" "$ROOTDIR/usr/share/omarchy/$f"
done
install -d "$ROOTDIR/usr/bin"
for f in "$WORK/omarchy"/bin/*; do
  [ -f "$f" ] && install -Dm755 "$f" "$ROOTDIR/usr/bin/$(basename "$f")"
done
install -Dm644 "$WORK/omarchy/etc/profile.d/omarchy.sh" "$ROOTDIR/etc/profile.d/omarchy.sh"
[ -f "$WORK/omarchy/etc/sudoers.d/omarchy-theme-browser" ] && \
  install -Dm440 "$WORK/omarchy/etc/sudoers.d/omarchy-theme-browser" \
    "$ROOTDIR/etc/sudoers.d/omarchy-theme-browser"
[ -f "$WORK/omarchy/default/fonts/omarchy/omarchy.ttf" ] && \
  install -Dm644 "$WORK/omarchy/default/fonts/omarchy/omarchy.ttf" \
    "$ROOTDIR/usr/share/fonts/omarchy/omarchy.ttf"
info "$(du -sh "$ROOTDIR/usr/share/omarchy" | cut -f1) in /usr/share/omarchy"

# This project's own overlay, on top of upstream and never instead of it.
if [ -d "$REPO/default" ] && [ -n "$(ls -A "$REPO/default" 2>/dev/null)" ]; then
  say "omarchy-mobile overlay"
  cp -a "$REPO/default/." "$ROOTDIR/"
  info "$(cd "$REPO/default" && find . -type f | wc -l) files"
fi

# What the session is made of, in the guest. The drawer's long-press card
# refuses to remove anything on it (gestures.md L12): this image pacstraps both
# tiers as explicit targets and has no meta package, so pacman has no
# dependency to object with and `pacman -Rs foot` would take the terminal every
# TUI opens in. Copied verbatim rather than stripped, so the file in the guest
# is the file in the repo and omarchy-mobile-app-remove does the one parse.
install -Dm644 "$REPO/vm/packages/session" "$ROOTDIR/etc/omarchy-mobile/session-packages"

# ---------------------------------------------------------------------------
say "configure"
# /root, not /tmp. arch-chroot mounts a FRESH TMPFS over the target's /tmp
# before it chroots, so a script staged there is hidden by the time it runs and
# the failure reads as though the file was never written:
#
#   chroot: failed to run command '/tmp/configure.sh': No such file or directory
#
# which is a confusing thing to be told about a file that is plainly sitting on
# disk one directory up.
install -Dm755 "$SHARE/configure.sh" "$ROOTDIR/root/configure.sh"
GUEST_USER="$GUEST_USER" GUEST_HOST="$GUEST_HOST" ROOT_UUID="$ROOT_UUID" \
ESP_UUID="$ESP_UUID" VERSION="$VERSION" COMMIT="$COMMIT" \
OMARCHY_VERSION="$OMARCHY_VERSION" OMARCHY_REF="$OMARCHY_REF" \
VM_WIDTH="$VM_WIDTH" VM_HEIGHT="$VM_HEIGHT" VM_SCALE="$VM_SCALE" \
SSH_PUBKEY="${SSH_PUBKEY:-}" \
  arch-chroot "$ROOTDIR" /root/configure.sh
rm -f "$ROOTDIR/root/configure.sh"

# ---------------------------------------------------------------------------
say "split /boot onto the ESP"
# /boot IS the ESP in the guest, so the kernel pacman installs and the
# initramfs mkinitcpio builds are already in the right place -- they just have
# to move out of the ext4 image and into the FAT one. Doing it this way (rather
# than a separate /boot inside root) is what makes an in-guest `pacman -Syu`
# that bumps the kernel land somewhere the firmware can actually read.
mv "$ROOTDIR/boot" "$BOOTSTAGE"
mkdir -p "$ROOTDIR/boot"
[ -f "$BOOTSTAGE/Image" ] || die "no kernel at /boot/Image -- linux-aarch64 did not install"
[ -f "$BOOTSTAGE/initramfs-linux.img" ] || die "no initramfs -- mkinitcpio did not run"
# dtbs are for real boards. A QEMU virt guest gets its device tree from the
# firmware, so 90 MB of Allwinner and Rockchip .dtb files would be 90 MB of a
# 512 MB ESP spent on hardware this image will never see.
rm -rf "$BOOTSTAGE/dtbs" "$BOOTSTAGE/Image.gz"

say "systemd-boot"
install -Dm644 "$ROOTDIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" \
  "$BOOTSTAGE/EFI/BOOT/BOOTAA64.EFI"
mkdir -p "$BOOTSTAGE/loader/entries"
cat >"$BOOTSTAGE/loader/loader.conf" <<EOF
default  omarchy-mobile.conf
timeout  0
console-mode keep
editor   yes
EOF
# console=ttyAMA0 as well as tty0: scripts/vm-run.sh --headless has no display
# at all, and a kernel that only talks to tty0 in that mode is a boot you can
# watch exactly nothing of.
cat >"$BOOTSTAGE/loader/entries/omarchy-mobile.conf" <<EOF
title    omarchy-mobile $VERSION
linux    /Image
initrd   /initramfs-linux.img
options  root=PARTUUID=$ROOT_UUID rw rootwait console=tty0 console=ttyAMA0,115200
EOF

# ---------------------------------------------------------------------------
say "manifest"
# What actually landed, beside the image. `pacman -Q` in the built rootfs, not
# the list we asked for: the answer to "what is in this image" has to come from
# the image.
#
# Before the filesystems, not after: the rootfs is deleted the moment its
# contents are inside the disk image, so anything that has to read it has to
# read it first. See the space note below.
arch-chroot "$ROOTDIR" pacman -Q >"$OUT/$NAME.packages" 2>/dev/null || true
info "$(wc -l <"$OUT/$NAME.packages") packages"

# ---------------------------------------------------------------------------
say "filesystems"
ESP_IMG="$WORK/esp.img"
rm -f "$ESP_IMG"
truncate -s "${ESP_MIB}M" "$ESP_IMG"
mkfs.fat -F32 -n OMARCHYESP "$ESP_IMG" >/dev/null
# mcopy writes into the FAT image without mounting it.
(cd "$BOOTSTAGE" && mcopy -s -i "$ESP_IMG" ./* ::)
info "ESP ${ESP_MIB}M, $(du -sh "$BOOTSTAGE" | cut -f1) used"
rm -rf "$BOOTSTAGE"

ROOT_USED_MIB=$(du -sm --apparent-size "$ROOTDIR" | cut -f1)
ROOT_MIB=$(( ROOT_USED_MIB + ROOT_SLACK_MIB ))

# ---------------------------------------------------------------------------
say "assemble"
TOTAL_SECTORS=$(( ROOT_LBA + ROOT_MIB * 1024 * 1024 / SECTOR + 2048 ))
rm -f "$IMG"
truncate -s $(( TOTAL_SECTORS * SECTOR )) "$IMG"
sgdisk -Z -o \
  -n "1:$ESP_LBA:+${ESP_MIB}M"  -t 1:ef00 -c 1:ESP  -u "1:$ESP_UUID" \
  -n "2:$ROOT_LBA:+${ROOT_MIB}M" -t 2:8304 -c 2:root -u "2:$ROOT_UUID" \
  "$IMG" >/dev/null

# mke2fs writes the root filesystem STRAIGHT INTO the disk image at the
# partition's byte offset. Building a separate root.img and dd-ing it in is the
# obvious way and it needs the rootfs, a full-size root.img and the disk image
# to exist at once -- 8.8 + 8.6 + 15 GB for the full package set, which filled
# Docker Desktop's 59 GB VM disk exactly here:
#
#   dd: error writing '/work/omarchy-mobile-0.1.0.img': No space left on device
#
# -E offset= removes one whole copy, and deleting the rootfs immediately
# afterwards removes the other, so the peak is one rootfs plus one sparse image
# rather than three copies of the same bytes.
#
# The size is given in explicit 4 KiB blocks rather than as a suffixed string,
# because without a size mke2fs takes the whole file and the offset stops
# meaning anything.
mkfs.ext4 -q -F -b 4096 -E offset=$(( ROOT_LBA * SECTOR )) \
  -L omarchy-root -d "$ROOTDIR" "$IMG" $(( ROOT_MIB * 1024 * 1024 / 4096 ))
info "root ${ROOT_MIB}M ($ROOT_USED_MIB MiB used + $ROOT_SLACK_MIB MiB slack)"
rm -rf "$ROOTDIR"

# conv=sparse keeps the holes: the image is mostly empty slack and writing it
# out solid would cost gigabytes for nothing.
dd if="$ESP_IMG" of="$IMG" bs=1M seek=$(( ESP_LBA * SECTOR / 1024 / 1024 )) \
   conv=notrunc,sparse status=none
rm -f "$ESP_IMG"

# ---------------------------------------------------------------------------
say "provenance"
{
  echo "version  $VERSION"
  echo "commit   $COMMIT${DIRTY:+ (dirty)}"
  echo "omarchy  $OMARCHY_REF"
  echo "built    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "packages $(wc -l <"$OUT/$NAME.packages")"
  echo "tier     $([ "$SESSION_ONLY" = 1 ] && echo session || echo session+apps)"
} >"$OUT/$NAME.provenance"

# cp --sparse=always, not mv: /work and /out are different filesystems, so this
# is a copy either way, and the image is mostly empty slack that would cost
# gigabytes on the host if the holes were filled in.
cp --sparse=always "$IMG" "$OUT/$NAME.img"
rm -f "$IMG"
rm -rf "$WORK/omarchy" "$WORK/omarchy.tar.gz" "$WORK/repo"

say "done"
info "$OUT/$NAME.img  ($(du -h "$OUT/$NAME.img" | cut -f1) on disk, $(( TOTAL_SECTORS * SECTOR / 1024 / 1024 )) MiB apparent)"
info "$(wc -l <"$OUT/$NAME.packages") packages"
