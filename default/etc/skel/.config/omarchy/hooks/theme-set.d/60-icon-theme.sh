#!/bin/bash
# omarchy-mobile: keep the icon theme to one that is actually installed.
#
# omarchy-hook runs this after omarchy-theme-set has staged the theme and run
# omarchy-theme-set-gnome, which ends with:
#
#   GNOME_ICONS_THEME=$HOME/.local/state/omarchy/current/theme/icons.theme
#   if [[ -f $GNOME_ICONS_THEME ]]; then
#     gsettings set org.gnome.desktop.interface icon-theme "$(<$GNOME_ICONS_THEME)"
#   else
#     gsettings set org.gnome.desktop.interface icon-theme "Yaru-blue"
#   fi
#
# Every one of upstream's themes ships an `icons.theme`, and every one of them
# names a Yaru: Yaru-blue, Yaru-purple, Yaru-red, Yaru-magenta, Yaru-olive,
# Yaru-grey, Yaru-sage-dark, Yaru-wartybrown. The fallback is a Yaru too.
#
# There is no Yaru for aarch64. Not in Arch Linux ARM, and not in the AUR:
# neither yaru-icon-theme nor yaru-colors-icon-theme exists there at all. So on
# this image every theme set has been pointing GTK at an icon theme that is not
# on the disk, and GTK has been answering every themed icon name with
# `image-missing` -- the white square with a corner fold that Spot drew for
# each of its transport controls, its Library, its Saved Tracks and every
# playlist in its sidebar, and that other GTK apps drew wherever they ask for
# an icon by name.
#
# The shell is not affected and never was: Quickshell's icon lookups walk the
# icon directories themselves (AppLibrary.iconIndexScanCommand), so the drawer
# has always drawn its grid correctly whatever this setting said. That is why
# this went unnoticed -- the surface this project looks at hardest is the one
# surface the bug cannot reach.
#
# Adwaita rather than breeze, because it is GNOME's own and this image's apps
# are GNOME's. Both are installed; breeze is here for the four names nothing
# else answers (vm/packages/apps).
#
# Checked rather than replaced unconditionally: install a Yaru one day -- a
# package, or by hand -- and upstream's own choice starts working and this hook
# stops touching it.
set -uo pipefail

FALLBACK=Adwaita

want=$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")
[ -n "$want" ] || exit 0
[ "$want" = "$FALLBACK" ] && exit 0

# The directories an icon theme may live in, in the order the spec searches
# them. A theme is present when its index.theme is: a bare directory is what an
# uninstalled theme's leftovers look like.
dirs=("$HOME/.icons" "${XDG_DATA_HOME:-$HOME/.local/share}/icons")
IFS=: read -ra data_dirs <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${data_dirs[@]}"; do dirs+=("$d/icons"); done

for d in "${dirs[@]}"; do
  [ -f "$d/$want/index.theme" ] && exit 0
done

gsettings set org.gnome.desktop.interface icon-theme "$FALLBACK"
