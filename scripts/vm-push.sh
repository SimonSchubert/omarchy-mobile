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
scp "${SSH_OPTS[@]}" -P "$PORT" -rq \
  "$SKEL/omarchy/plugins" "$SKEL/hypr/mobile.lua" default/etc/skel/.local patches \
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

# The drawer entries for the shell's own screens, and their icons.
[ -d "$STAGE/.local" ] && cp -r "$STAGE/.local/." ~/.local/ && echo "pushed ~/.local entries"
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
