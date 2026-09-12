#!/usr/bin/env bash
# Push the mobile overlay into the RUNNING guest, without rebuilding the image.
#
#   ./scripts/vm-push.sh
#
# Copies what the image build would put in /etc/skel into the live user's home
# -- the shell plugins and hypr/mobile.lua -- does the two things
# vm/configure.sh does at build time (enable each plugin in shell.json, require
# mobile.lua from hyprland.lua), applies any of patches/ the installed Omarchy
# does not carry yet, and restarts the shell so it loads them.
#
# A restart rather than the shell's own hot reload, which watches plugin files
# and reloads on change. That reload segfaulted quickshell three times in
# `QQmlComponent::createObject` while a file was still being written
# (docs/build-log.md), and a plugin that is now several files is several
# windows for that race. A restart costs a second and cannot half-load.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
. scripts/manifest.sh

USER_NAME=$(manifest_get guest user) || exit 1
PORT=$(manifest_get vm ssh_port)     || exit 1
SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)
SKEL=default/etc/skel/.config

# Staged beside the destination and swapped in with one rename per plugin, so
# nothing ever reads a directory that is half copied.
ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@127.0.0.1" \
  'rm -rf ~/.cache/omarchy-mobile-push && mkdir -p ~/.cache/omarchy-mobile-push'
# The gtk-4.0/gtk.css symlink is NOT copied: it points at a path that exists
# only in the guest, and scp follows symlinks -- it would try to read a target
# that is not there on this Mac. The guest makes its own, below.
scp "${SSH_OPTS[@]}" -P "$PORT" -rq \
  "$SKEL/omarchy/plugins" "$SKEL/hypr/mobile.lua" "$SKEL/omarchy/themed" \
  "$SKEL/omarchy/hooks" "$SKEL/mimeapps.list" default/etc/skel/.local \
  default/usr/local default/etc/pacman.d patches vm/packages/session \
  "$USER_NAME@127.0.0.1:.cache/omarchy-mobile-push/"

ssh "${SSH_OPTS[@]}" -p "$PORT" "$USER_NAME@127.0.0.1" bash -s <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
STAGE=~/.cache/omarchy-mobile-push
PLUGINS=~/.config/omarchy/plugins
SHELL_JSON=~/.config/omarchy/shell.json

# Stop the shell BEFORE touching a file it watches. The running shell reloads a
# plugin whose files change, and that reload has crashed quickshell while a file
# was mid-write (docs/build-log.md). This script used to swap the files first
# and restart after, so every push set the reload off: the journal showed
# "Local plugin changed, reloading" twice per push, and each push left the shell
# with another child quickshell process and a mapped window titled "quickshell"
# that the carousel counted as an app. The same kill loop upstream's own
# omarchy-restart-shell uses.
while timeout 5 quickshell kill -p "$OMARCHY_PATH/shell" --any-display >/dev/null 2>&1; do :; done

# Upstream's patches, onto the tree the image build installed. The build
# applies them to a fresh tarball; this tree already carries the ones it was
# built with, so a patch that reverses cleanly is in and is skipped. Dry-run
# forward before the real thing, because a patch that fails half-way leaves
# the hunks it did land. A failure is reported, not fatal: the shell is down
# by now, and a push that stops here leaves the phone with no shell at all.
patch_failed=0
for p in "$STAGE"/patches/*.patch; do
  [ -e "$p" ] || continue
  name=$(basename "$p")
  sudo patch -d "$OMARCHY_PATH" -p1 -R -f --dry-run --fuzz=0 -s <"$p" >/dev/null 2>&1 && continue
  if sudo patch -d "$OMARCHY_PATH" -p1 --forward --dry-run --fuzz=0 -s <"$p" >/dev/null 2>&1; then
    sudo patch -d "$OMARCHY_PATH" -p1 --forward --fuzz=0 --no-backup-if-mismatch -s <"$p"
    echo "patched $name"
  else
    echo "!! $name does not apply to $OMARCHY_PATH" >&2
    patch_failed=1
  fi
done

mkdir -p "$PLUGINS"
for dir in "$STAGE"/plugins/*/; do
  name=$(basename "$dir")
  rm -rf "$PLUGINS/.$name.old"
  [ -d "$PLUGINS/$name" ] && mv "$PLUGINS/$name" "$PLUGINS/.$name.old"
  mv "$dir" "$PLUGINS/$name"
  rm -rf "$PLUGINS/.$name.old"
  id=$(jq -re '.id' "$PLUGINS/$name/manifest.json")
  # As vm/configure.sh: a bar-kind plugin is enabled by being `bar.id`.
  is_bar=$(jq '.kinds | index("bar") != null' "$PLUGINS/$name/manifest.json")
  tmp=$(mktemp)
  jq --arg id "$id" --argjson bar "$is_bar" '
    if $bar then .bar.id = $id | .plugins = ((.plugins // []) | map(select(.id != $id)))
    else .plugins = ((.plugins // []) | if any(.id == $id) then . else . + [{id: $id}] end)
    end' "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
  echo "pushed $id$([ "$is_bar" = true ] && echo ', as the bar')"
done

install -m644 "$STAGE/mobile.lua" ~/.config/hypr/mobile.lua

# The palette, in the pieces the image build puts in skel: one template per
# toolkit for upstream's own engine to render on every theme set, the hook that
# switches GTK3's theme and restarts the app daemons afterwards, and the two
# symlinks GTK reads. The symlinks are made here rather than copied, and -n so
# that a second push replaces the link instead of writing through it into the
# staged theme directory.
install -d ~/.config/omarchy/themed ~/.config/omarchy/hooks/theme-set.d \
  ~/.config/gtk-4.0 ~/.config/gtk-3.0
install -m644 "$STAGE/themed/gtk.css.tpl" ~/.config/omarchy/themed/gtk.css.tpl
install -m644 "$STAGE/themed/gtk3.css.tpl" ~/.config/omarchy/themed/gtk3.css.tpl
install -m755 "$STAGE/hooks/theme-set.d/50-gtk-apps.sh" \
  ~/.config/omarchy/hooks/theme-set.d/50-gtk-apps.sh
ln -sfn ../../.local/state/omarchy/current/theme/gtk.css ~/.config/gtk-4.0/gtk.css
ln -sfn ../../.local/state/omarchy/current/theme/gtk3.css ~/.config/gtk-3.0/gtk.css
echo "pushed the GTK4 and GTK3 palette templates, hook and symlinks"

# The drawer entries for the shell's own screens, and their icons.
[ -d "$STAGE/.local" ] && cp -r "$STAGE/.local/." ~/.local/ && echo "pushed ~/.local entries"

# The default handlers. Overwritten rather than merged: this file is the
# image's answer to "which browser", and a push that left a stale
# chromium.desktop in place would be testing the old one.
install -m644 "$STAGE/mimeapps.list" ~/.config/mimeapps.list
echo "pushed mimeapps.list"

# The /usr/local/bin shadows of upstream's chromium-only scripts. Root-owned
# and outside the home, so sudo, as the patches above already use.
if [ -d "$STAGE/local/bin" ]; then
  sudo install -d /usr/local/bin
  sudo install -m755 "$STAGE"/local/bin/* /usr/local/bin/
  echo "pushed $(ls "$STAGE"/local/bin | tr '\n' ' ')to /usr/local/bin"
fi

# The icons QtSvg cannot clip. The repairs live in /usr/local/share/icons and
# are generated from what pacman has put under /usr/share, so they are made
# here rather than shipped: a guest built before this landed has none, and one
# built after has whatever its own packages installed (docs/build-log.md).
sudo install -Dm644 "$STAGE/pacman.d/hooks/60-omarchy-mobile-icon-repair.hook" \
  /etc/pacman.d/hooks/60-omarchy-mobile-icon-repair.hook
sudo /usr/local/bin/omarchy-mobile-icon-repair

# The session tier, which the long-press card's removal script refuses to
# remove anything from (gestures.md L12). vm/build-disk.sh installs the same
# file at image build; a push carries it too, because the script that reads it
# treats a missing list as "cannot tell" and blocks every package removal --
# which is the right answer for a guest built before this landed, and the wrong
# one for a guest that just had the script pushed to it.
sudo install -Dm644 "$STAGE/session" /etc/omarchy-mobile/session-packages
echo "pushed the session tier to /etc/omarchy-mobile/session-packages"
grep -qF 'require("hypr.mobile")' ~/.config/hypr/hyprland.lua \
  || printf '\n-- omarchy-mobile: one app per workspace, filling it.\nrequire("hypr.mobile")\n' \
       >>~/.config/hypr/hyprland.lua
hyprctl reload >/dev/null && echo "hyprland reloaded"

# Launched the way upstream's restart launches it, through the compositor, so it
# lands in the session's environment rather than this ssh login's.
hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")' >/dev/null
for _ in $(seq 1 40); do
  omarchy-shell shell ping >/dev/null 2>&1 && { echo "shell up"; exit "$patch_failed"; }
  sleep 0.25
done
echo "!! shell did not come back" >&2
exit 1
GUEST
