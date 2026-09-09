#!/usr/bin/env bash
# Build the VM disk image, in an aarch64 container, on the host.
#
#   ./scripts/vm-build.sh                 # session + apps
#   ./scripts/vm-build.sh --session-only  # just enough to start Hyprland
#   ./scripts/vm-build.sh --no-ssh-key    # do not authorise a key in the guest
#
# The image lands in vm/out/. It is a development VM and is not published, so
# unlike moarchy's phone images this one DOES bake in an ssh key by default --
# the guest account is locked and password auth is off, so without a key
# scripts/vm-ssh.sh has no way in at all. --no-ssh-key opts out.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

SESSION_ONLY=0
SSH_KEY=""
USE_SSH_KEY=1
for arg in "$@"; do
  case "$arg" in
    --session-only) SESSION_ONLY=1 ;;
    --no-ssh-key)   USE_SSH_KEY=0 ;;
    --ssh-key=*)    SSH_KEY="${arg#--ssh-key=}" ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found -- Docker Desktop must be running"
docker info >/dev/null 2>&1 || die "the docker daemon is not responding -- start Docker Desktop"

# The pacman download cache is a NAMED VOLUME, not a bind mount into the repo.
# A bind mount is the obvious choice and it does not work: Docker Desktop's
# VirtioFS fails pacman's download-to-.part-then-rename with
#
#   error: could not rename /var/cache/pacman/pkg/libxau-1.0.12-1-aarch64.pkg.tar.xz.part
#          to .../libxau-1.0.12-1-aarch64.pkg.tar.xz (No such file or directory)
#
# on a file it had just written. A named volume lives inside Docker's own VM
# with ordinary Linux semantics, caches just as well between runs, and is
# thrown away with `docker volume rm omarchy-mobile-pkgcache`.
docker volume create omarchy-mobile-pkgcache >/dev/null

if [ "$USE_SSH_KEY" = 1 ] && [ -z "$SSH_KEY" ]; then
  for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [ -f "$k" ] && { SSH_KEY="$k"; break; }
  done
fi
PUBKEY=""
if [ "$USE_SSH_KEY" = 1 ]; then
  [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ] || die "no ssh public key found -- pass --ssh-key=PATH or --no-ssh-key"
  PUBKEY=$(cat "$SSH_KEY")
  echo "    authorising $SSH_KEY in the guest"
fi

# Answered on the host, not in the container: /repo arrives as a bind mount
# whose inode metadata does not match this .git/index, so a stat-based check in
# there calls every tracked file modified with no content difference in any.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
DIRTY=0
git diff --quiet HEAD -- 2>/dev/null || DIRTY=1

say "builder image"
docker build --platform linux/arm64 -f vm/Dockerfile -t omarchy-mobile-builder . \
  || die "docker build failed"

say "packages"
# Anything Arch Linux ARM is behind on, built from Arch's packaging repo at the
# commit manifest.toml pins. Cached on that commit, so this is a no-op on every
# run where the pin has not moved -- which is nearly all of them.
# /pkgs is a named volume for the same reason the cache is: makepkg's output
# and pacman's downloads both want ordinary Linux filesystem semantics. The
# built packages are copied out to vm/out/packages afterwards so they are
# visible from the host without being built there.
docker volume create omarchy-mobile-packages >/dev/null
docker run --rm \
  --platform linux/arm64 \
  --entrypoint /usr/local/bin/build-packages \
  -v omarchy-mobile-packages:/pkgs \
  -v omarchy-mobile-pkgcache:/var/cache/pacman/pkg \
  omarchy-mobile-builder || die "the package build failed"

mkdir -p vm/out/packages
docker run --rm --platform linux/arm64 \
  --entrypoint /bin/bash \
  -v omarchy-mobile-packages:/pkgs -v "$REPO_ROOT/vm/out/packages:/copy" \
  omarchy-mobile-builder -c 'cp -f /pkgs/*.pkg.tar.* /copy/ 2>/dev/null || true'

say "disk image"
mkdir -p vm/out
# --privileged: arch-chroot bind-mounts /proc, /sys and /dev to run mkinitcpio.
docker run --rm --privileged \
  --platform linux/arm64 \
  -v "$REPO_ROOT/vm/out:/out" \
  -v omarchy-mobile-pkgcache:/var/cache/pacman/pkg \
  -v omarchy-mobile-packages:/pkgs \
  -e SESSION_ONLY="$SESSION_ONLY" \
  -e COMMIT="$COMMIT" -e DIRTY="$DIRTY" \
  -e SSH_PUBKEY="$PUBKEY" \
  omarchy-mobile-builder || die "the disk build failed"

say "built"
ls -lh vm/out/*.img 2>/dev/null | awk '{print "    " $9 "  " $5}'
echo "    next: ./scripts/vm-run.sh"
