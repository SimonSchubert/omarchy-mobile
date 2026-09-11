#!/bin/bash
# Build the packages Arch Linux ARM is behind on, for aarch64, from Arch's own
# packaging repos at the commits manifest.toml pins.
#
# Runs inside vm/Dockerfile as root, and drops to the `builder` user for
# makepkg alone -- makepkg refuses to run as root, but the script around it
# needs to own /pkgs, which arrives as a Docker volume owned by root. Output
# goes to /pkgs, which vm/build-disk.sh then turns into a local pacman
# repository placed ahead of ALARM's.
#
# It began with one package (hyprland; see [pkg.hyprland] in the manifest) and
# is written as a loop over [pkg.*] because ALARM falling behind on a package,
# or never carrying it, is a recurring hazard for an aarch64 port, not a
# one-off. xdg-terminal-exec, from the AUR, was the second, and
# moarchy-keyboard, from its own repo, the third.
set -euo pipefail

PKGS=${PKGS:-/pkgs}
SHARE=${SHARE:-/usr/local/share/omarchy-mobile}
WORK=${WORK:-/home/builder/work}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

. "$SHARE/manifest.sh"

mkdir -p "$PKGS" "$WORK"
# /pkgs is a Docker volume created root-owned; makepkg writes into it as
# `builder` through PKGDEST, so hand it over before dropping privileges.
chown -R builder:builder "$PKGS" "$WORK"
pacman -Sy --noconfirm >/dev/null

for name in $(manifest_pkgs); do
  url=$(manifest_get "pkg.$name" url) || die "[pkg.$name] has no url"
  ref=$(manifest_get "pkg.$name" ref) || die "[pkg.$name] has no ref"
  tag=$(manifest_get "pkg.$name" tag) || tag="(none)"

  # Already built and still current? The cache is keyed on the pinned commit,
  # so a rebuild only happens when the pin actually moves -- which matters a
  # lot here, because hyprland is a twenty-minute compile and the disk build
  # in front of it is iterated on far more often than the pin is.
  stamp="$PKGS/.$name.ref"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$ref" ] && \
     compgen -G "$PKGS/$name-*.pkg.tar.*" >/dev/null; then
    info "$name $tag already built at ${ref:0:12} -- skipping"
    continue
  fi

  say "$name $tag (${ref:0:12})"
  rm -rf "$WORK/$name"
  git clone --quiet "$url" "$WORK/$name" || die "could not clone $url"
  git config --global --add safe.directory "$WORK/$name"
  git -C "$WORK/$name" checkout --quiet "$ref" || die "no such commit in $name: $ref"

  # Arch's packaging repos and the AUR both put the PKGBUILD at the root. A
  # repo of our own may keep it further down and says where with
  # `pkgbuilddir`, as moarchy's manifest does: moarchy-keyboard's is in
  # packaging/. Optional, so its absence is quiet rather than manifest_get's
  # loud miss.
  pkgdir=$(manifest_get "pkg.$name" pkgbuilddir 2>/dev/null) || pkgdir=.
  build="$WORK/$name/$pkgdir"
  [ -f "$build/PKGBUILD" ] || die "$name has no PKGBUILD in $pkgdir"

  # An earlier build of the same package is not a duplicate, it is ambiguity:
  # the disk build's repo-add takes whichever the glob puts last, so the
  # version that ends up installed would be chosen by lexicographic order
  # rather than by anyone. Clear it before building, not after, so a makepkg
  # that dies halfway cannot leave the old one behind looking current.
  rm -f "$PKGS/$name"-*.pkg.tar.* "$stamp"

  chown -R builder:builder "$WORK/$name"

  # --nocheck: the test suites want a running compositor, which a container
  # does not have. -s installs build dependencies, --noconfirm because there is
  # nobody at the keyboard, and no --sign because these are consumed through a
  # file:// repo the disk build marks SigLevel = Never.
  #
  # PKGDEST puts the result straight where the disk build looks for it.
  runuser -u builder -- bash -c "cd '$build' && PKGDEST='$PKGS' \
    makepkg -s --noconfirm --nocheck --needed" \
    || die "makepkg failed for $name"

  printf '%s\n' "$ref" >"$stamp"
  info "built $(ls -1 "$PKGS/$name"-*.pkg.tar.* | tail -1 | xargs basename)"
  cd /
  rm -rf "$WORK/$name"
done

say "packages"
ls -1 "$PKGS"/*.pkg.tar.* 2>/dev/null | sed 's|.*/|    |' || info "(none)"
