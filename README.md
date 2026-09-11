# omarchy-mobile

Upstream Omarchy on **Hyprland**, on an aarch64 VM, with a mobile UI built on
top of it rather than instead of it.

<p align="center">
  <img src="docs/screenshots/home.png" width="24%" alt="The home screen: the phone bar, the themed wallpaper, and the home pill">
  <img src="docs/screenshots/drawer-open.png" width="24%" alt="The app drawer open: a search field and a four-column app grid">
  <img src="docs/screenshots/shade.png" width="24%" alt="The shade pulled down: clock, quick-settings tiles, the volume slider, and three notifications">
  <img src="docs/screenshots/carousel.png" width="24%" alt="The recents carousel over two open terminals, the next card peeking in at the left">
</p>

<sub>Straight off the VM, not mocked: the home screen, the app drawer, the
shade, and the recents carousel.</sub>

This is the sibling of [moarchy](https://github.com/SimonSchubert/moarchy), which
puts Omarchy on an original PinePhone. That phone's hardware forces moarchy to
swap Hyprland for Sway. This project gives up the phone to keep Hyprland, so the
mobile UI is built on Omarchy as it actually is.

## Why not just extend moarchy?

The PinePhone's Mali-400 tops out at **OpenGL ES 2.0**, and Hyprland 0.50
removed its GLES2 renderer. So moarchy runs Sway and carries `port-4x.patch`,
264 insertions that rewrite the shell from `Quickshell.Hyprland` to
`Quickshell.I3` and lose `HyprlandFocusGrab`, and with it click-outside-to-dismiss.
A VM has no Mali-400: Mesa's **llvmpipe advertises GLES 3.2 in software**, which
clears Hyprland's floor without a GPU.

| | moarchy | omarchy-mobile |
| --- | --- | --- |
| Compositor | Sway (wlroots, GLES 2.0) | **Hyprland 0.56**, upstream |
| Omarchy config layer | vendored + `port-4x.patch` | vendored, **unpatched** |
| Shell IPC | `Quickshell.I3` | `Quickshell.Hyprland` |
| `HyprlandFocusGrab` | unavailable | available |
| Blur, shadows, rounded corners, animations | dropped | available |
| Target | real PinePhone hardware | a VM, for now |

The trade: moarchy runs on a phone you can hold, and this does not.

## Quick start

```bash
brew install qemu
./scripts/vm-build.sh          # ~30 min the first time, most of it downloads
./scripts/vm-run.sh            # a window on the Mac
```

`vm-run.sh` prints the ssh and VNC ports it forwards. The guest autologins on
tty1 straight into Hyprland, so there is nothing to type.

```bash
./scripts/vm-ssh.sh --wait                 # a shell in the guest
./scripts/vm-ssh.sh hyprctl monitors       # one command
./scripts/vm-screenshot.sh                 # grim, from inside the session
./scripts/vm-run.sh --headless             # no window; Hyprland headless + VNC
./scripts/vm-run.sh --detach               # the window, owned by no terminal or session
./scripts/vm-run.sh --geometry 1080x2340   # a different panel
./scripts/vm-drag.sh 180 712 -300          # swipe up from the bottom edge
./scripts/vm-push.sh                       # the overlay into a running guest, no rebuild
./scripts/vm-selftest.sh                   # the gestures, one line per acceptance criterion
```

`./scripts/vm-build.sh --session-only` skips the application tier (chromium
alone is nearly a quarter of its download) for fast iteration on the session
itself.

## How the image is built

- **A plain UEFI disk.** The ESP is mounted at `/boot`, so an in-guest
  `pacman -Syu` that updates the kernel writes it where the firmware reads it.
  Both partitions have fixed PARTUUIDs, so `fstab` and the loader entry are the
  same in every build.
- **No loop devices.** `mkfs.ext4 -d` and `mcopy` fill filesystem images
  straight from directories, which Docker Desktop cannot reliably do with
  mounts. Only `mkinitcpio` needs a chroot, which is why the builder runs
  `--privileged`. The initramfs drops `autodetect`, which would keep only the
  modules of the container doing the build, and names the virtio drivers
  instead.
- **The package set.** 120 of upstream's 147 base packages exist for aarch64 in
  Arch Linux ARM. Of the other 27, one is built here from the AUR:
  xdg-terminal-exec, which every terminal Omarchy opens goes through. The other
  26 are listed with reasons in [`vm/packages/omitted`](vm/packages/omitted),
  along with six that do exist and are left out on purpose.
  [`session`](vm/packages/session) is what Hyprland and the shell need to start;
  [`apps`](vm/packages/apps) is the rest, plus GNOME's phone apps.
- **Hyprland is rebuilt.** ALARM moved `aquamarine` to `libaquamarine.so=14`
  without rebuilding `hyprland`, so a plain `pacstrap` fails. This project
  builds Arch's own `hyprland 0.56.2-2` packaging for aarch64 at a commit pinned
  in `manifest.toml`. Once ALARM catches up, its package wins on version and
  `[pkg.hyprland]` can be deleted.

## Where this deliberately differs from upstream Omarchy

The intent is to track upstream, not to fork it. Omarchy is vendored at the
commit `manifest.toml` pins (v4.0.3 today), and keeping up with upstream means
moving that pin. The mobile UI adds to upstream rather than changing it: it is
an ordinary user plugin, and pointing `bar.id` back at `omarchy.bar` gives stock
desktop Omarchy.

Where upstream's own code has to change, the change is a patch in
[`patches/`](patches/), applied with `--fuzz=0` and no offset. If upstream moves
under a patch, the build fails and names the hunk rather than landing it
somewhere it was never aimed. Every patch is meant to go upstream and be deleted
here once it lands:

| Patch | What it fixes | Upstream |
| --- | --- | --- |
| `notification-card-max-width.patch` | Toast cards are a fixed 380 wide, so on a 360-wide screen they hang off the left edge | [#11034](https://github.com/omacom/omarchy/pull/11034) |
| `lock-field-max-width.patch` | The lock screen's password field is 381px, wider than the screen it is centred on | [#11244](https://github.com/omacom/omarchy/pull/11244) |
| `weather-panel-fit.patch` | The weather panel's hero row overlaps itself and its forecast row clips in a narrow popup | [#11238](https://github.com/omacom/omarchy/pull/11238) |
| `plugin-manifest-kinds.patch` | A plugin that declares `kind: "menu"` never gets the app library, because its manifest's `kinds` is not an `Array` after a `QVariant` round trip | not submitted yet |
| `notification-popups-bar-opt-out.patch` | A bar that shows notifications itself cannot turn the toasts off, so they float over its shade and every app | not submitted yet |

The first three matter only on a narrow screen and change nothing at desktop
width. The fourth is a plain bug. The fifth is a hook that does nothing unless
a bar asks for it, so desktop Omarchy keeps its toasts. None of them is specific
to aarch64 or to phones.

Three divergences are deliberate and will stay, because they come from building
a phone image rather than from aarch64:

- **No display manager.** Upstream enables `sddm`. Here tty1 autologins into
  `uwsm start -- hyprland-uwsm.desktop`, because a phone shows no login screen,
  and on a software-rendered VM sddm is one more thing that can fail before
  Hyprland starts.
- **No password.** The account is locked and ssh password login is off, as on
  moarchy's phone image. `vm-build.sh` authorises your ssh public key so that
  `vm-ssh.sh` can get in (`--no-ssh-key` opts out). That is acceptable only
  because this image is a local development VM and is never published.
- **A phone's app set.** Upstream's LibreOffice, Kdenlive, Moonlight,
  Xournal++ and Evince are left out, and so is sushi, which depends on Evince.
  GNOME's Calculator, Calendar, Contacts, Maps, Clocks, Weather, Text Editor,
  Geary, Camera, Music and Sound Recorder are added: the apps a phone is
  expected to have, and libadwaita apps that fit a 360px screen.

## The mobile UI

<p align="center">
  <img src="docs/screenshots/shade.png" width="24%" alt="The shade pulled down: clock, Wi-Fi and Bluetooth tiles, Silent, Airplane and Rotate, the volume slider, and three notifications, each led by its app's icon">
  <img src="docs/screenshots/wifi-screen.png" width="24%" alt="The Wi-Fi screen as a window of its own: a back chevron, the radio switch, and no Wi-Fi device in this VM">
  <img src="docs/screenshots/settings-root.png" width="24%" alt="Settings at the root: ten sections, each with the value it holds underneath">
  <img src="docs/screenshots/settings-theme.png" width="24%" alt="The Theme page: upstream's themes as a list, the one in use ticked">
</p>

It ships as one ordinary Omarchy shell plugin, `mobile.shell`, in the user
plugin directory upstream already scans, and `bar.id` in `shell.json` switches
it on.

- **Swipe up from the pill** for the recents carousel, which follows the
  finger. Let go short of 15% of the travel and it springs back, between 15% and
  75% it stays, and past 75% you land on a home screen with every app still
  running. Tap a card to switch to it; flick it up to close it.
- **Swipe sideways along the pill** for the next or previous app. Every app
  gets a workspace of its own, filling it, through a window rule in
  [`hypr/mobile.lua`](default/etc/skel/.config/hypr/mobile.lua).
- **Drag up on the wallpaper** of a home screen for the app drawer, 1:1 with
  the finger. Drag down to put it away.
- **Pull down the status bar** for the shade: Wi-Fi, Bluetooth, Silent,
  Airplane and Rotate, brightness and volume where there is hardware for them,
  the media player, and your notifications, each led by its app's icon: tap
  one to open it, swipe it away to dismiss it. Nothing toasts over the screen:
  a bell in the status bar says something is waiting. Holding the Wi-Fi or
  Bluetooth tile opens that radio's screen, which is the way to both: neither
  is in the drawer.
- **Screens are windows**, so each gets a workspace and a carousel card: Wi-Fi,
  Bluetooth and Settings. Settings is ten phone-style sections over upstream's
  Omarchy menu, opened from the shade's gear, its power glyph (straight to
  Power), the drawer, or `omarchy-shell settings open`. Its pages are data in
  [`Pages.js`](default/etc/skel/.config/omarchy/plugins/mobile.shell/Pages.js),
  its rows run upstream's own commands, and it has native pages where a
  terminal was the wrong shape: audio routing, reminders, time zone, plugins,
  and Theme, Wallpaper and Font. A row this image cannot run (Lock, AI agent,
  installing from the AUR) is hidden until it can.
- **The on-screen keyboard** is moarchy's,
  [moarchy-keyboard](https://github.com/SimonSchubert/moarchy-keyboard), built
  from its pin in `manifest.toml` like any package ALARM lacks. It rises by
  itself when a text field takes focus and retracts when focus leaves one,
  types into apps whether or not they speak a text input protocol, and
  recolours with the theme. Going home and closing the drawer put it away;
  Super+I forces it up or down.
- **Notes and the App Store** are moarchy's two default apps,
  [moarchy-keep](https://github.com/SimonSchubert/moarchy-keep) and
  [moarchy-store](https://github.com/SimonSchubert/moarchy-store), built from
  their pins like the keyboard and in the drawer from first boot. The store
  installs from its curated catalogue by touch with no password: the image
  locks the account, so a polkit rule grants the store's one action to wheel,
  as moarchy's does. Its Open goes through `omarchy-shell drawer launch`.

The criteria are moarchy's, copied into [`docs/spec/`](docs/spec/) with their
ids unchanged. [`docs/acceptance.md`](docs/acceptance.md) says which of them hold
here, and `./scripts/vm-selftest.sh` checks them by driving a real pointer
through `/dev/uinput` in the guest.

**One plugin, where moarchy has nine.** Omarchy 4.0.3 sandboxes plugins so that
each can summon only itself, and one surface has to own the edges and drive
every sheet anyway (see below). moarchy patches the host to get round the
sandbox; this project does not.

### What Hyprland does differently from Sway

All measured, and the surface layout is shaped around them.
[`docs/build-log.md`](docs/build-log.md) has the numbers.

- **The implicit pointer grab ends at a layer surface's edge.** A drag stops
  getting motion when it leaves the surface it started on, so the edge surface
  is full-screen and opens its input mask to the whole screen for the length of
  a drag.
- **A layer surface with exclusive keyboard focus takes every pointer event.**
  So the drawer holds `OnDemand` focus (tap the search field before typing) and
  the carousel holds none, which keeps the bottom edge live over both.
- **A drag goes to the topmost surface under the finger.** So the shade handles
  an up-swipe from the pill itself instead of letting it fall through.
- **`Toplevel.activate()` focuses apps but ignores the shell's own windows.**
  Sway drops it for both. Every focus goes through Hyprland's dispatcher by
  window address.
- **Exclusive zones are arranged from Background up, not from Overlay down.**
  On one edge the lowest layer gets the screen's edge. The keyboard is on Top,
  as moarchy ships it, and while the strip reserved its band from Overlay the
  keyboard took the edge and the pill landed between the app and the keys. The
  band is reserved from a Bottom surface instead, and the strip on Overlay only
  draws the pill.
- **The `empty` workspace selector** is where the window rule sends a new app
  and where the home gesture goes, so the two always agree on which workspace
  is free. moarchy computes that twice, and the two copies drifted.

## Layout

| Path | What it is |
| --- | --- |
| `manifest.toml` | The version pins. The only file that says what version of anything is built |
| `vm/Dockerfile` | The aarch64 container both build stages run in |
| `vm/build-packages.sh` | Builds what ALARM is behind on or lacks, from Arch's packaging repos and the AUR |
| `vm/build-disk.sh` | pacstrap → configure → ESP + ext4 → GPT disk |
| `vm/configure.sh` | Runs in the rootfs under `arch-chroot`: identity, fstab, initramfs, user, session |
| `vm/packages/` | The package set, in three files, with every omission explained |
| `default/` | This project's own overlay, copied onto the rootfs |
| `default/etc/skel/.config/omarchy/plugins/mobile.shell/` | The mobile UI -- status bar, shade, gestures, sheets and the Wi-Fi, Bluetooth and Settings screens -- as one Omarchy shell plugin. Settings' pages are data, in `Pages.js` |
| `default/etc/skel/.config/hypr/mobile.lua` | One app per workspace, filling it, no layer animation on the shell's own sheets, and the on-screen keyboard started and bound to Super+I -- a user override loaded after upstream's defaults |
| `default/etc/skel/.local/bin/` | `omarchy-mobile-*`, the helpers behind Settings' native pages: audio routing, reminders, time zone, plugins, About; and the keyboard toggle |
| `default/etc/skel/.local/share/` | Desktop entries and icons for the Wi-Fi, Bluetooth and Settings screens. Only Settings shows in the drawer |
| `patches/` | Fixes to the vendored upstream. Applied with `--fuzz=0`, so a moved upstream fails the build |
| `scripts/vm-*.sh` | Build, run, ssh, screenshot, drag, push the overlay into a running guest, selftest |
| `docs/spec/` | moarchy's acceptance criteria, copied with their ids unchanged |
| `docs/acceptance.md` | Which of those criteria hold here, and how each one is checked |
| `docs/build-log.md` | The chronological account, including the dead ends |

## Status

**Phase 1**, upstream Omarchy 4.0.3 on Hyprland 0.56.2 in a VM at phone
geometry, is done. **Phase 2** ports moarchy's mobile UI back up from Sway to
the Hyprland it was first written against. The bottom-edge gestures, the
carousel, the home screen, the drawer, the status bar, the shade, the Wi-Fi,
Bluetooth and Settings screens, and the on-screen keyboard are in (gestures.md
A to F, H, I and K, shade.md, settings.md). [`docs/build-log.md`](docs/build-log.md) is the chronological
account, dead ends included.

### Not done yet

- The back gesture and the still of an app being put away (gestures.md G and
  J). Settings already keeps the page stack a back gesture would walk, and the
  keyboard can leave the left edge's column to it (`--back-edge-inset`, 0 by
  default).
- An image built before the keyboard, Notes and the App Store landed has none
  of them, and no `archlinuxarm-keyring` either, so pacman in that guest trusts
  none of ALARM's signatures and can fetch nothing, the store's installs
  included. Install the keyring first, as a local file from the builder's
  pacman cache; then `pacman -U` `moarchy-keyboard`, `moarchy-keep` and
  `moarchy-store-git` from `vm/out/packages/`, and copy
  `default/usr/share/polkit-1/rules.d/49-moarchy-store.rules` to the same path
  in the guest. Or rebuild. The image build itself was never affected, since it
  verifies against the builder's keyring.
- Settings search from the drawer (settings.md O) and the coding-agent tile
  (P). The drawer also has no long-press or uninstall, which want a detail
  sheet this shell does not have yet.
- An image built before 2026-09-11 has no xdg-terminal-exec, and on it every
  Settings row that opens a terminal shows nothing. Rebuild, or install the
  package.
- The Wi-Fi and Bluetooth screens are untested: the VM has neither device.
  `mac80211_hwsim` and `hci_vhci` are in its kernel, which is where testing
  them starts.
- Upstream's first-run toasts do not time out, and until dismissed they take
  every touch in the top ~170px of any sheet. Pulling the shade down clears
  them.
- The phone bar hosts no widgets, so upstream's weather panel logs
  `Cannot read property 'foreground' of null` a few times a minute. Noise, not
  breakage.
- `yay`, `ttf-ia-writer` and `mise-bin` are omitted, and Settings hides the rows
  that need yay and mise. `vm/build-packages.sh` builds any `[pkg.*]` the
  manifest pins, as it does xdg-terminal-exec, so each is a pin away.
- On upstream's bar at phone width, the centred clock overlaps the workspace
  list. It is unpatched because the fix is a design call: elide the centre, or
  shift it the way `PopupCard.onAnchoring` shifts popups.
- Nothing verifies a built image. `vm-selftest.sh` tests the running session;
  moarchy has `scripts/verify-image.sh` for the image.
- Touch is a QEMU `usb-tablet`, a mouse that reports absolute coordinates, so
  every gesture is a `MouseArea` rather than moarchy's `MultiPointTouchArea`.
  Real multi-touch will need something else.
