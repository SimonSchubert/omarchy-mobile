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

# Never fail a theme switch over this. omarchy-hook prints "Hook failed:" and
# carries on, but a non-zero exit here would say something is wrong when the
# truthful answer is "there was nothing running to restart".
exit 0
