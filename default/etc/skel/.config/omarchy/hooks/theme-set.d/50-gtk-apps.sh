#!/bin/bash
# omarchy-mobile: make a theme switch reach GTK apps that are already running.
#
# omarchy-hook runs every file in ~/.config/omarchy/hooks/theme-set.d after
# omarchy-theme-set has staged the new theme and run its own post-theme
# commands, so by the time this runs ~/.config/gtk-4.0/gtk.css already points
# at the new palette (the symlink beside this file's template) and
# omarchy-theme-set-gnome has already set light/dark.
#
# GTK reads the user stylesheet once, at process start. Closing the window is
# not enough for a GNOME app: it is D-Bus activatable, so the process stays
# behind as a windowless `--gapplication-service` daemon and the next open
# paints a days-old theme out of the copy it parsed at boot. That is the exact
# failure basecamp/omarchy#7557 measured, and the reason the two open upstream
# PRs each carry a reload mechanism.
#
# The daemons are the only thing killed: no window is closed, because every one
# of them respawns on demand the moment something asks D-Bus for it. A mapped
# window keeps its old colours until it is reopened -- retinting one in place
# needs a per-app extension (upstream #8408 ships a nautilus-python one for
# Files alone), which is a lot of moving parts for a phone where reopening an
# app is one tap.
#
# ---------------------------------------------------------------------------
# Why this is not one pkill
#
# `pkill -f -- '--gapplication-service'` matches any command line that merely
# CONTAINS the flag, and the first thing it caught here was the ssh command
# inspecting the guest for it -- the pattern was inside the shell's own -c
# string. A theme switch that kills somebody's ssh session, or anything else
# that happens to name the flag, is a worse bug than a stale palette.
#
# So the flag has to be the LAST argument, which is what a real daemon looks
# like -- `gnome-calendar --gapplication-service`, or
# `python3 /usr/bin/gnome-music --gapplication-service` -- and never what a
# shell running a command string looks like, where the last argument is the
# whole string.
for pid in $(pgrep -f -- '--gapplication-service' 2>/dev/null); do
  [ "$pid" = "$$" ] && continue
  argv=()
  mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || continue
  [ "${#argv[@]}" -ge 2 ] || continue
  [ "${argv[-1]}" = "--gapplication-service" ] || continue
  kill "$pid" 2>/dev/null
done

# ---------------------------------------------------------------------------
# GTK3, which is Geary and the portal's file chooser
#
# Neither can take the palette the way the GTK4 apps do: GTK3's built-in
# Adwaita has its colours baked in at build time, so the names a user
# stylesheet overrides are not the ones its rules read (#7557 measured it).
# adw-gtk3 is libadwaita's stylesheet ported to GTK3, and its rules DO read
# named colours, so themed/gtk3.css.tpl can recolour it.
#
# This runs after upstream's omarchy-theme-set-gnome, which sets gtk-theme to
# Adwaita or Adwaita-dark, so pointing it at adw-gtk3 here is the last word.
# Only when the theme is installed, though: a --session-only image has no apps
# tier and therefore no adw-gtk-theme, and naming a theme that is not there
# would drop every GTK3 app to the fallback rather than leave it on Adwaita.
if [ -d /usr/share/themes/adw-gtk3 ]; then
  mode=$(omarchy-theme-color --file "$HOME/.local/state/omarchy/current/theme/colors.toml" mode 2>/dev/null)
  if [ "$mode" = light ]; then gtk3_theme=adw-gtk3; else gtk3_theme=adw-gtk3-dark; fi
  gsettings set org.gnome.desktop.interface gtk-theme "$gtk3_theme" 2>/dev/null
fi

# Never fail a theme switch over this. omarchy-hook prints "Hook failed:" and
# carries on, but a non-zero exit here would say something is wrong when the
# truthful answer is "there was nothing running to restart".
exit 0
