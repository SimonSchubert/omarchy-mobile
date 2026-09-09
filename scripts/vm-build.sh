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

say "disk image"
mkdir -p vm/out
# --privileged: arch-chroot bind-mounts /proc, /sys and /dev to run mkinitcpio.
mkdir -p .cache/pacman
docker run --rm --privileged \
  --platform linux/arm64 \
  -v "$REPO_ROOT/vm/out:/out" \
  -v "$REPO_ROOT/.cache/pacman:/var/cache/pacman/pkg" \
  -e SESSION_ONLY="$SESSION_ONLY" \
  -e COMMIT="$COMMIT" -e DIRTY="$DIRTY" \
  -e SSH_PUBKEY="$PUBKEY" \
  omarchy-mobile-builder || die "the disk build failed"

say "built"
ls -lh vm/out/*.img 2>/dev/null | awk '{print "    " $9 "  " $5}'
echo "    next: ./scripts/vm-run.sh"
