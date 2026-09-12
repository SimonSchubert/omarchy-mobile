# Acceptance — where each criterion stands

The criteria are moarchy's, copied into [`spec/`](spec/) with every id and
every line unchanged. They were written against Sway on a PinePhone. This file
is the other half: **which of them hold here, how that is checked, and where
Hyprland changes the mechanism or the answer.** The specs say what; this says
whether.

```
./scripts/vm-selftest.sh              # every section; ~10 minutes on a windowed VM
./scripts/vm-selftest.sh A S K        # just those
```

Every line it prints names the AC it proves, so an id below marked **pass**
has a line there, and one with no line is visible by its absence. It closes
only the windows it opened, and reports **SKIP** for the two criteria that need
an empty phone (A9, E6) while anybody else's window is up.

| Status | Means |
| --- | --- |
| **pass** | `vm-selftest.sh` checks it, and it passes |
| **holds** | True by construction, or ported and visibly right, with no check |
| **partial** | Part of the criterion is met; the note says which part |
| **todo** | Not built, or built and not yet exercised -- the note says which |

Last full run: 2026-09-11, 129 checks -- 128 passing in one full run. The one
it failed, S0 (the shade read closed after a pull that had followed the finger
for 125 samples), passed on a rerun of H then S, the full run's order. That
rerun lost S7, S10, S11 and S14 instead, each finding the shade shut under it,
in a VM another session was pushing to at the same time; all four had passed
in the full run. VM headless, Omarchy 4.0.3 with this project's patches, on
Hyprland 0.56.2 at 360x720 logical.

---

## [gestures.md](spec/gestures.md)

### A. Strip — swipe up

| AC | Status | Note |
| --- | --- | --- |
| A1 | pass | `recents dragTrace` ≥ 8 samples over a 1.5s drag: 8 with the VM windowed on a busy Mac, where a 360ms drag left 3-5. Headless, 360ms left 13-14 |
| A2 | pass | 30px of 324 springs back, focus unchanged |
| A3 | pass | |
| A4 | pass | |
| A5 | pass | Asserted after every strip gesture in section A. This reverses the drawer's old edge toggle |
| A6 | pass | |
| A7 | pass | |
| A8 | pass | **Changed:** the shade forwards the pill's band to the strip's own logic rather than cutting it out of its input region -- see "Found on the way" |
| A9 | pass | SKIP while a window the suite did not open is up |

### B. Strip — swipe sideways

| AC | Status | Note |
| --- | --- | --- |
| B1 | pass | `hl.dsp.focus({ workspace = "e+1" })`, which wraps, as `next_on_output` did |
| B2 | pass | A 150px swipe drifting 50px up |
| B3 | pass | Checked for the drawer and for the shade, which are the two sheets there are. The theme picker is a page of a window here rather than a sheet of its own (K10), so there is no third surface for this to clear |

### C. Strip — press and hold

| AC | Status | Note |
| --- | --- | --- |
| C1 | pass | 2s press: window count, workspace and both sheets unchanged |

### D. Home screen

| AC | Status | Note |
| --- | --- | --- |
| D1 | pass | |
| D2 | pass | |
| D2a | pass | 300px left the drawer at 43% against a 694px sheet |
| D3 | pass | Holds because W1 leaves no gap or border for the home surface to show through |
| D4 | pass | |

### E. The carousel

| AC | Status | Note |
| --- | --- | --- |
| E1 | pass | A screen's card prints its id, `mobile.wifi` (K5, K9) |
| E2 | pass | **Changed:** focus goes through Hyprland's dispatcher by window address. `Toplevel.activate()` works for other clients' windows and does nothing for the shell's own (K12) |
| E3 | pass | A real 200px flick on card 0, aimed with `recents cardTarget`, only ever on a card the suite opened |
| E4 | partial | The row runs right to left (E1), so the next card peeks in from the left: its right edge is at x=57 of 360. Paging itself is not checked |
| E5 | pass | |
| E6 | pass | SKIP while a window the suite did not open is up |
| E7 | holds | No clear-all control exists |

### F. Going home

| AC | Status | Note |
| --- | --- | --- |
| F1 | pass | **Changed:** Hyprland's own `empty` workspace selector *is* this rule, measured to pick the lowest free number including a gap. The window rule in `hypr/mobile.lua` uses the same word, so there is no second implementation to drift from the first |
| F2 | pass | |
| F3 | partial | Home from a terminal passes, six samples over 3s. Home from Settings failed before `retreatKeyboard` existed, and its check has not run since. **Changed:** On Hyprland the keyboard does pop up on the way home, when it leaves one of the shell's own windows: a text input activates after the switch, with the hide already sent. `goHome` hides, then hides again if the keyboard rises within the next second (`retreatKeyboard` in Shell.qml). A bare `hyprctl` jump from Settings to an empty workspace goes round `goHome` and still leaves it up; what activates is not found |
| F4 | pass | The first retire frame keeps its home hint (`100:80`, not `100:0`) |

### G. Left edge — back

| AC | Status | Note |
| --- | --- | --- |
| G1 | pass | The order is one function, `performBack()` in Shell.qml. Checked on the two rungs that can be on screen at once: with the keyboard up over an open drawer, the first back takes the keyboard and leaves the drawer open, and the second closes the drawer |
| G2 | pass | **Changed:** the instrument, not the answer. moarchy asks `sm.puri.OSK0` over the bus -- a probe started on press and read on release, with a retry budget, a warm-up and a branch for the answer that never came. Here the shell already has a synchronous one: the home surface's own height, which the compositor shrinks by the keyboard's zone (I1a). That is the instrument I1a argues for in moarchy's own words, so the probe and all three of its hedges are gone |
| G3 | pass | Checked with the drawer and with the shade. The shade is the interesting one: it is on Overlay too and keeps its whole input region while up, so it takes the press and forwards the band -- A8's bargain applied to this edge, in the last MouseArea of Shade.qml |
| G4 | pass | `tl.close()`, on the toplevel `focusedToplevel()` finds. One definition of "focused window", shared with the band's fill (I1a), because the two disagreeing is one fault reported twice |
| G5 | pass | Checked on a bare home screen with a window left running on another workspace: back closes neither it nor anything else |
| G6 | pass | Both halves: 20px of travel does nothing, and 80px in with 150px up does nothing either |
| G7 | holds | `close()` is xdg_toplevel.close, a request. Not checked against an app that actually prompts |
| G8 | pass | 16px, reported by `gestures geometry` because an input region cannot be seen from outside |
| G9 | pass | The mirror swipe from the right edge does nothing -- there is no surface there |
| G10 | pass | **Re-measured on Hyprland, and the number is unchanged.** 220 = one strip plus one keyboard panel, and `hyprctl layers` puts the keyboard's surface at y=500 on a 720 screen, which is exactly where the band stops. The reasoning changes even though the answer does not: Sway subtracts exclusive zones from Overlay down, so moarchy cannot fix this by arrangement; here they resolve the other way up and the keyboard genuinely is arranged first, but that settles placement and not input, and Overlay still takes every touch Top would have had |
| G10 (top) | changed | **Added here**, and the spec has no clause for it: the band also stops the bar's 26px short of the *top*. The shade keeps the bar's band as its input region even while shut and is on Overlay too, so the two surfaces want the same top-left corner and map order picks the winner. Measured with no inset, the shade won -- back answered nothing at y=10 and fired from y=30 down. Writing the same 26 down changes no behaviour and stops it depending on which surface mapped first. Cutting the column out of the shade's band is the other way round, and Shade.qml already records why that is not taken |
| G10a | holds | Outside the two cuts the leftmost 16px of every app is the gesture's, which is what D3 checks from the other side |

Not moarchy's mechanism, and the one real port difference: **the band is an input
region, not a surface.** moarchy's back edge is a 16px-wide layer surface that
reads the press and the release, because Sway keeps delivering motion after the
finger leaves it. Hyprland stops at that surface's own edge to the pixel, so the
same surface would see 16px of a 60px swipe and never reach the commit
threshold. The surface here is full-screen and masked to the band, and opens to
the whole screen from press to release -- which is what the strip's edge surface
already does, for the same measured reason.

### H. Closing an overlay by dragging it

| AC | Status | Note |
| --- | --- | --- |
| H1 | partial | The drawer's sheet body and every grid cell close it; a drag that *starts on the search field* does not, because the text field takes the press |
| H2 | pass | The shade: an up-drag on the scrim, and a tap on it. Both stay visible for the length of a drag -- an item that disappears under its MouseArea's grab cancels it, which put the sheet straight back up |
| H3 | pass | |
| H4 | pass | A real tap on the Foot icon, aimed with `drawer cellTarget`, launches it |
| H5 | partial | The shade's list: a vertical drag on a list that can scroll scrolls it and the shade stays. The drawer's grid never overflows with 13 apps, so its half is unexercised |
| H6 | pass | |
| H7 | pass | A 230px swipe dismisses the card, and it stays gone when the shade is reopened |
| H7a | pass | A 100px swipe dismisses nothing |
| H7b | partial | The shade stays open under a vertical drag over the list (H5); "nothing dismissed" is not asserted separately |
| H8 | pass | Clear all, by tap (S19) |

### I. What the strip is drawn over

| AC | Status | Note |
| --- | --- | --- |
| I1 | todo | The drawer does extend under the strip, but its pixel check is not written. Settings, which I1 also names, is a window now, so its band is I1a's |
| I1a | pass | The home surface (Bottom) reaches under the strip and fills the band with `Color.background` while any window is focused. Behind Settings, one device pixel of the last row is the `fill=` that `gestures geometry` reports; on a home screen the band is the wallpaper again (`band=0`). Read at the output's own scale: `grim -s 1` blends the edge row with what lies beyond it. The keyboard clause passes too: behind a terminal, `kbd=1 band=0` with the keyboard up and `kbd=0 band=1` down, read off the home surface's height (494 against 694) |
| I2–I4 | todo | None of their pixel or geometry checks are written |
| I5 | pass | **Changed:** a real tap on the search field raises the keyboard and the drawer goes from 694 to 474. moarchy's "gap unchanged" cannot hold here: this grid is as tall as its apps rather than the sheet, so its end stays where it is while the surface's bottom moves. The check is what the gap is for, that the grid ends at least a strip above the keyboard |
| I5a | pass | The inset is -20 with the keyboard down and 0 with the field up |
| I5b | pass | **Changed:** read off `hyprctl monitors` rather than the drawer: 220 reserved at the bottom with the keyboard up, the band's 20 plus the panel's 200 |
| I5c | pass | |
| I5d | partial | **Changed:** only the drawer takes the seat's keyboard here, OnDemand after a tap on it. Settings is a window and the theme picker a page of it. Over a terminal, tapped and closed: the terminal's text input re-entered 132ms after the close. moarchy's fixed 250ms second hide passed once and lost that race once, so the second hide answers the rise instead (F3). That version's check has not run yet |
| I5e | pass | |
| I6 | pass | **Changed:** the pill keeps the screen's edge because the band is reserved from Bottom. Hyprland arranges exclusive zones from Background up, so from Overlay the strip lost the edge to the keyboard on Top and sat between the app and the keys. Checked from `hyprctl layers`: the strip at 700, the keyboard's keys ending at 700. With the keyboard up, an up-flick from the strip still goes home |
| I7 | todo | |

### J. The app you are leaving

| AC | Status | Note |
| --- | --- | --- |
| J1 | holds | Built. Measured mid-drag with a held gesture: at `progress=50` the preview reads `armed=true content=true track=50 scale=78`, and 78 is exactly `1 - (1 - 0.56) * 0.5`. The shrunken still is on screen in the screenshot, the app's own clock and keyboard inside it |
| J2 | holds | `live: false`, so the capture is one frame per gesture. The cost is not measured here -- moarchy's numbers are a Mali-400's |
| J3 | holds | `landed=56` and `cardh=403` agree exactly: `0.56 * 720 = 403`, the card slot's height. Read off `recents preview`, not from a pixel |
| J4 | holds | Enters at `scale=100` and eases from wherever the finger has got to, through `beginPreviewCatchUp`. That it never draws before `hasContent` is by construction -- `shown` requires it -- and is not separately checked |
| J5, J6 | holds | The two `disarmPreview` calls, `true` on a spring-back and on a cancel, `false` past either commit. The 200ms restore itself is too short to sample from outside, as `homeHint`'s is (F4) |
| J7, J8 | holds | The disarm is unconditional and runs on every path out, the watchdog included, so a capture that never arrives is dropped rather than waited on. Not exercised against a blanked output |
| J9 | holds | Declaration order: `appPreview` is the last child of the surface, above both the scrim and the sheet |
| J10 | holds | **Changed:** the reason, not the answer. Only the app you are leaving gets a picture, and here that is a choice -- Hyprland implements `hyprland-toplevel-export-v1`, so a card *could* carry one. Sway implements nothing of the kind, which is why it was moarchy's constraint. The cost of a capture per card is still unmeasured |

**Not moarchy's mechanism, and it is the same one.** The capture is of the whole
output through `wlr-screencopy` -- what `grim` uses -- and not of a window. That
is why moarchy could have this section on Sway at all, and it is what makes the
arrival invisible: at track 0 the still is pixel-aligned with what is already on
screen. The dmabuf error this VM logs at startup (`Failed to find render device:
no render or primary node found`) does not stop it; `content=true` on every
gesture measured.

### K. Settings is an app

Three screens are windows: Wi-Fi, Bluetooth and Settings. Section K of the
selftest checks Wi-Fi; its Settings section checks the same criteria on
Settings.

| AC | Status | Note |
| --- | --- | --- |
| K1 | pass | `class org.quickshell`, alone on its workspace, the usable area exactly -- Wi-Fi and Settings |
| K2 | pass | Swiped off and back, the screen is still there; for Settings, on the page it was left on |
| K3 | todo | Not checked for the other ways a workspace moves |
| K4 | todo | Not checked |
| K5 | pass | Glyph, name and page, from the screen itself -- there is no desktop entry for an app id that names the shell process |
| K6 | pass | Flicking the card closes the window; summoned again, it opens (moarchy's visible-false-then-true, measured after a compositor-side close too). Settings reopens at the root |
| K7 | pass | Both halves, which is the whole criterion: from depth 2 one back leaves `settings page` one page up with the window count unchanged, and from the root the same gesture leaves `settings state` closed with one window fewer. Asked of the focused window, not of a list of open screens. Printed by the `G` section, because the back gesture is what reaches it |
| K8 | pass | A bridged row's terminal comes up tiled on a workspace of its own and Settings stays running (settings.md E6) |
| K9 | holds | Measured: the class is `org.quickshell`, and each screen is told apart by a title prefix |
| K10 | pass | Wi-Fi, Bluetooth and Settings, and the theme picker is a page of Settings, not a screen |
| K11 | todo | Needs J |
| K12 | pass | **Changed:** by Hyprland address, for the reason under E2 |

### L. Long-press on an app

| AC | Status | Note |
| --- | --- | --- |
| L1 | pass | A real 900ms press on Foot's cell, aimed with `drawer cellTarget`, leaves `drawer detail` naming it |
| L2 | pass | The click Qt delivers after the hold launches nothing. `holdFired` is cleared on the next press, as `sheetWasDrag` is, and for the same reason |
| L3 | pass | A 1.2s drag down from a cell closes the sheet, opens no card, and leaves 25+ drag samples |
| L4 | holds | The grid fits its 20 apps, so it never scrolls here and the `onCanceled` path is unexercised -- the same gap H5 has |
| L5 | pass | **Changed:** `drawer back`, not `gestures back` -- G is not built, so the drawer answers the walk itself (card, then grid, then closed) and the edge gesture will call the same `goBack()` when it lands. Escape walks the same levels |
| L6 | pass | `drawer detail` prints `id`, `info.kind`, and for a package `info.package`, `info.version` and `info.size` -- `foot package foot`, `1.28.0-2`, `936.39 KiB`. The id carries no `.desktop`, which is what this library's entries hold |
| L7 | pass | Uninstall arms a plan and never removes: Clocks answers `1, 3.5 MiB`, a personal entry its `note` |
| L8 | pass | Files is Nautilus and `nautilus-python` declares it, so `canRemove` is `no` and the card carries pacman's own line -- `removing nautilus breaks dependency 'nautilus' required by nautilus-python` |
| L9 | pass | Checked against a launcher the suite writes and then removes, never against a package: Remove deletes it and the card closes. The notification is the script's |
| L10 | pass | The grid's app count drops by one with the drawer still open |
| L11 | pass | Notes (`moarchy-keep`) answers `protected 1` and draws the reason in place of an Uninstall button |
| L12 | pass | **Changed:** the rule is the same, the mechanism is not. This image pacstraps both tiers as explicit targets and has no meta package, so pacman objects to nothing and `pacman -Rs foot` would take the terminal every TUI and every bridged Settings row opens in. `vm/build-disk.sh` installs `vm/packages/session` at `/etc/omarchy-mobile/session-packages`, and the script refuses anything on it -- asked of the whole plan rather than of the target, because `-Rs` takes orphans and that is how `upower` went out with KWeather on moarchy. moarchy-meta's `--assume-installed` waiver has nothing to waive here and is not carried |
| L13 | n/a | Nothing reinstalls what the card removes. L13 exists because every app is in `moarchy-meta`'s `depends` and a later upgrade resolves them; this image has no meta package, so a removed app stays removed across a `pacman -Syu` |

19 checks, and they were run four times. One run lost L5 and L6 to a card that
had closed between two of the suite's own ssh round trips, in a VM another
session was driving at the same time -- the same interference the note at the
top of this file records for S0. L6 reads the card in one round trip now
rather than five, which is the half of that this file can fix.

### Constraints

| Constraint | Status | Note |
| --- | --- | --- |
| The strip reserves 20px off every window | holds | `hyprctl monitors`: `reserved: 0 26 0 20`. **Changed:** the band surface reserves it, from Bottom, and the strip only draws the pill (I6) |
| Only the left edge may take touch ahead of an app | holds | Nothing takes touch ahead of an app yet; the edge surface's input region is the strip's band at rest (`gestures geometry`: `input=band`) |
| No window thumbnails except the app you are leaving | holds | The preview is the one picture of a window this shell draws, and every card is icon and title (J10). On this compositor that is a decision rather than a limit |
| One app per workspace | holds | A window rule, not a daemon: `hypr/mobile.lua` |

---

## [shade.md](spec/shade.md)

The bar is this project's (Bar.qml), selected through shell.json's `bar.id`,
which is also what grants the shade its Do Not Disturb and media services.

| AC | Status | Note |
| --- | --- | --- |
| S1 | holds | `H:mm` and `dddd d MMMM`, per minute. Not checked as text |
| S2 | pass | A real tap on the gear opens Settings at the root, and no `omarchy-menu` layer maps. Until Settings existed it opened upstream's Omarchy menu, which dismissed on a tap outside it here -- HyprlandFocusGrab, which moarchy's port had to stub out |
| S3 | pass | A real tap on the power glyph opens Settings at `system.power` |
| S4 | partial | Ported. This VM has no Wi-Fi device, so the tile reads "No Wi-Fi" -- a state S4 does not list, added rather than showing "Off" for a radio that is not there |
| S5 | partial | Ported; "No adapter" is the only state reachable here |
| S6 | pass | A 900ms hold opens the Wi-Fi screen and puts the shade away; the tap it interrupts does not fire |
| S6a | todo | Ported, unexercised: needs a Wi-Fi device. `mac80211_hwsim` is in the VM's kernel |
| S6b | pass | The screen is a window (K1), and its back chevron closes it and brings the shade back |
| S6c | pass | |
| S6d-1–S6d-8 | todo | Ported, unexercised: no adapter. `hci_vhci` is in the kernel, with no emulator to drive it |
| S7 | pass | And the bar's DND glyph follows |
| S8 | pass | Re-reads the real state: with no rfkill switch in the VM, the tile goes back to off |
| S9 | todo | Needs a radio |
| S10 | pass | No flash LED: three tiles share the row |
| S11 | pass | **Changed:** `hl.monitor({ transform })` through hyprctl -- 0.56 has no rotate verb and no keyword parser |
| S12 | partial | **Changed:** the brightness slider is not drawn with no backlight to drive, as the torch is not (S10). Volume commits live |
| S13 | holds | Clamped at 1% |
| S14 | pass | Drawn with a sink; the suite checks whichever case the VM is in |
| S15 | holds | Tap-to-set, with the hand-over to the sheet on a vertical drag. Not checked |
| S16 | todo | No player in the VM; the card follows the media service's active player |
| S17 | partial | The card shows the artist as well as the title, as moarchy's code does; S17 is one of the spec's unconfirmed lines |
| S18 | pass | Newest first, off the history directory |
| S19 | pass | Popups and history, and they stay gone across a reopen |
| S20 | pass | See H5 |
| S21 | pass | `height == wanted`, under the cap |
| S21a | holds | Read per open, as in moarchy |
| S22 | pass | At the cap, the list scrolls |
| S23 | holds | Latched at the start of a drag. Not checked |
| S24 | pass | **Changed:** by a patch -- upstream's service asks the bar whether to toast, and this bar says no (`notification-popups-bar-opt-out.patch`). Three notifications with the shade shut map no `omarchy-notifications` layer, and all three are listed |
| S25 | pass | The first card's icon is on screen, and every row names where its icon came from |
| S26 | pass | Shown after a notification, gone after Clear all, and Silent's glyph instead while Silent is on |
| S27 | pass | A real tap on an `--exec` card runs it, removes the card and closes the shade; one on a card from an app with a window open focuses it; one on a card with nothing to run leaves it. The launch branch (an app with no window) is not checked. A sender's libnotify "default" action is not carried -- it dies with the live notification -- so those senders get focused instead, upstream's own fallback |

| Constraint | Status | Note |
| --- | --- | --- |
| Covers the whole screen and reserves nothing | holds | `ExclusionMode.Ignore` |
| Takes no keyboard focus | holds | `WlrKeyboardFocus.None` -- which is also what keeps Hyprland routing pointer events to the edges |
| The bar underneath has no tap targets | holds | Bar.qml takes no input at all |
| Two edges cut out of its input region | changed | The pill's band is forwarded instead (A8). The back edge will need the same |

## [windows.md](spec/windows.md)

| AC | Status | Note |
| --- | --- | --- |
| W1 | pass | A lone window's rect is the usable area exactly, `[0,26] 360x674` |
| W2 | pass | Reads `hypr/mobile.lua`, as moarchy's reads `pinephone.conf` |
| W3 | partial | The lone window's border is gone (W1 proves it); the border coming back on a split workspace is not checked |
| W4 | todo | Upstream's gaps toggle writes the same `hl.config` call, and `mobile.lua` loads after it, so the toggle is currently a no-op |
| W5 | pass | And its typing half: a focused terminal raises the keyboard by itself, and a real tap on the keyboard's `q` types `q` into it |
| W6 | pass | **Added here.** Settings' window is untagged and at opacity 1, and samples `#1a1b26` down its length, as the bar does |
| L1 | pass | **Changed:** the state is the shell plugin's, not AppLibrary's -- an installed plugin is handed a seven-callback app-library facade with no launch feedback on it. `Shell.launchApp()` opens the splash in the same call that asks for the launch, and `splash state` reads `open` in the same round trip as the launch that opened it. Checked for `drawer launch` and for a real tap on the Calculator cell |
| L2, L2a | pass | `splash geometry` reads `w=130 h=130 icon=96 layer=overlay`, and the compositor maps that surface at `115 295 130 130` -- centred on a 360x720 screen with no anchor asked for on either axis |
| L3 | pass | Checked with a finger, not by reading the mask back: with the splash up, a drag from the status bar to y=400, straight through the icon, still opens the shade, and the splash is still up afterwards |
| L4 | pass | `splash state` reads `closed` once the window has mapped, with the 160ms fade. The rule is a toplevel that was not there when the launch started; upstream's "any change of active toplevel" half is left out, and [build-log.md](build-log.md) has the measurement that says why it costs nothing |
| L5 | pass | Settings' entry summons this shell rather than starting a process, so `Shell.openScreen()` ends the launch as it puts the screen up -- checked by launching `omarchy-mobile-settings` and reading `splash state` back to `closed` with no window having appeared for it |
| L6 | pass | An id no entry answers to leaves the splash up and `splash state` reads `closed` 16s later |
| L7 | pass | `splash drawn` reads `icon file:///usr/share/icons/hicolor/scalable/apps/foot.svg` for Foot, and `fallback` -- the outline -- for an id with no entry. Never `nothing` |
| L8 | holds | The pulse is drawn and not read back, as Veil is. One transform on one textured quad |
| L9 | pass | The hand-off holds: the installed store's Open calls `omarchy-shell drawer launch`, the drawer answers it, and it now goes down the same `launchApp()` path a tap on the grid does, splash included |
| L9a | pass | `drawer launch` with a bare id finds the grid's entry for Keep and for the store, and each maps a window |

## [style.md](spec/style.md)

| AC | Status | Note |
| --- | --- | --- |
| A1–I4 | todo | No `scripts/style-check.sh` yet. The surfaces here follow moarchy's radii, roles, weights and 44px targets by hand, unchecked. I1a is the exception below |
| I1a | holds | GNOME's apps read the palette through `~/.config/gtk-4.0/gtk.css`, rendered per theme from `themed/gtk.css.tpl`. Checked in the guest 2026-09-12 against tokyo-night, catppuccin-latte and osaka-jade: Calendar drew each theme's own ground, text and accent, and the `--gapplication-service` daemons were restarted by the hook. No `vm-selftest.sh` line yet |
| I1a (GTK3) | holds | Geary reads `~/.config/gtk-3.0/gtk.css` from `themed/gtk3.css.tpl`, on top of `adw-gtk3`, which the hook selects by the theme's own mode. Checked the same day on the same three themes, with the control: on osaka-jade it drew #121d19 against the theme's #111c18, and #222226 -- adw-gtk3's stock grey -- with the rendered stylesheet moved aside. No `vm-selftest.sh` line yet |

## [settings.md](spec/settings.md)

Settings is `SettingsScreen.qml` in `mobile.shell`, a screen that is a window
like Wi-Fi and Bluetooth. `vm-selftest.sh settings` checks it with real taps on
the gear, the power glyph, a row and the back chevron, and over IPC for the
rest; its lines print with an `s.` in front, because settings.md's ids reuse
gestures.md's letters. Checked 2026-09-11 with `vm-selftest.sh S K settings`:
85 checks, 53 of them Settings', all passing on the first run.

Where a row runs upstream's command rather than moarchy's -- most of them, since
moarchy's stand-ins are for Sway -- the criterion is read against upstream's
command. The helpers moarchy calls `bin/moarchy-*` are `omarchy-mobile-*` in
`~/.local/bin`.

| AC | Status | Note |
| --- | --- | --- |
| A1 | pass | A real tap on the gear |
| A2 | pass | With the drawer up |
| A3 | pass | A real tap on the power glyph; no `omarchy-menu` layer maps |
| A4 | pass | |
| A5 | holds | open() sets the page and defers every read to `Qt.callLater`. Not checked against slow readers |
| A6 | pass | |
| A7 | pass | From another app's workspace, at `appearance.bar`: focus comes back, the page is kept, one card |
| A8 | pass | **Added here**, not moarchy's. A real tap on the drawer's Settings tile, found with `drawer cellTarget`: `omarchy-mobile-settings.desktop`, running `omarchy-shell settings open`. Settings opens at the root, and the drawer is put away |
| B1 | pass | A real tap on a row, aimed with `settings rowTarget` |
| B2 | pass | The chevron by tap, and `back` walking up from the power glyph's deep link to `closed` |
| B3 | pass | The same check as K7, and the same two halves: one page up, then closed, and never the app underneath |
| B5 | todo | **Not reachable unpatched**, unlike the rest of G. moarchy dismisses a vendored popup by reading the host's `openPanelIds` and calling `shell.hide(id)` for any `omarchy.` id, and gets both by patching `shell.qml` to hand its own namespace the trusted host. Omarchy 4.0.3's third-party facade has no `openPanelIds` at all, and its `_hide` resolves every request to the caller's own id (`owns(requestedId) ? ... : false`, shell.qml:719). So back cannot see a vendored popup here, let alone put one away. The other half of B5's premise still holds -- `HyprlandFocusGrab` is stubbed, so none of them dismisses on tap-outside |
| B4 | partial | The carousel rises over Settings with its card leading (the K6 check does exactly that); the home band leaving it running is not checked |
| B6 | pass | |
| B7 | holds | **Changed:** Theme is a page here, not a plugin, so it returns to where it was opened from by being popped. Its rows are drawn in the themes they name -- see D1 |
| B8 | pass | Chromium's and Firefox's rows hidden with neither installed, GNOME Web's drawn; and Lock, below |
| B9 | pass | |
| C1 | pass | Stay awake against `omarchy-toggle-idle status` |
| C2, C3 | pass | The battery flag, set and put back |
| C4 | pass | Both ways, read off `bar metrics`. The target is this project's `bar`, whose `syncFlags` Bar.qml declares |
| C4a, C6 | holds | No Show status bar and no transparency row. Not checked |
| C5 | holds | **Changed:** upstream's `omarchy-toggle-idle`, whose state file the shell's own idle service reads (it logs `stay-awake: disabled state-file`). There is no swayidle to check |
| C7 | todo | The crash-capture unit is not checked |
| C8 | pass | |
| C9 | partial | Not activated for real, since it changes sshd; E6 shows a bridged terminal leaving Settings running |
| D1 | pass | DNS, Theme against `omarchy-theme-current`, and Browser against the desktop id the image ships in `mimeapps.list` |
| D1 (the picker) | holds | **Added here**, and settings.md has no clause for it: each of the 22 theme rows is painted in the theme it names -- its `background` as the card, its `foreground` as the label, its `accent` as the tick, and six of its colours where the glyph would go. moarchy's argument for a picker of colours rather than a column of names, on a list instead of a grid of tiles. The rows come from `omarchy-mobile-themes`, a `provider.json`, and a theme whose `colors.toml` cannot be read still gets a row with no palette on it. Checked in the guest: all 22 answer a background and six chips, the ticked row is the one `omarchy-theme-current` names (s.D1, unchanged), and the row whose write is in flight reads "Applying…" until it exits. Not dimmed or disabled while it runs, unlike moarchy's tiles: this queues a second tap rather than refusing it (D4), and a row that is still going to act must not look like one that cannot |
| D2 | holds | A choice ticks only on an exact match with the reader. Not checked with a stub |
| D3 | pass | **Changed:** the GNOME Web row is the image's default browser now, so the mechanism is exercised rather than merely present: `omarchy-default-browser` has no name for Epiphany and prints the raw `org.gnome.Epiphany.desktop`, which is the row's `readValue`, while its `write` goes around that script to `xdg-settings` |
| D4 | pass | The default terminal, written as the one it already is. Choice writes re-read when the write exits, not when it starts |
| D5, D6, D7 | pass | |
| D8 | changed | AI agent is visible on an image built from 2026-09-12 on, and hidden on every one built before it. `omarchy-default-agent` installs through mise; mise is a pin now (`[pkg.mise-bin]`, moved out of `vm/packages/omitted`) rather than an omission, so the row's guard is unchanged and says yes once the apps tier carries it. **Not yet seen on a built image** -- the pin builds in the pinned aarch64 builder, and no image has been rebuilt around it. The rows are upstream's thirteen, writing `omarchy-mobile-agent open <name>` rather than upstream's own action, which is P: the wrapper writes the drawer tile and then execs `omarchy-default-agent` |
| E1 | pass | And Screenshot records `omarchy-capture-screenshot fullscreen`, and Restart asks before Continue records `omarchy-system-reboot` |
| E2 | holds | Checked statically against `omarchy-menu.jsonc`, not by the selftest: no bridged row differs from upstream's action except Screenshot (`fullscreen`) and Change password (`sudo passwd "$USER"`). moarchy's three package-row exceptions are gone -- they call `xdg-terminal-exec` as upstream does |
| E3 | holds | Every first word resolves under the shell's PATH, checked by hand, not by the selftest |
| E4 | changed | No bridge shims: upstream's own commands work on Hyprland. The one missing piece was `xdg-terminal-exec` itself, which is a package now (`[pkg.xdg-terminal-exec]`) |
| E5 | partial | The presentation terminal comes up tiled, filling its own workspace at 360x674 -- class `foot`, because foot's desktop entry gives xdg-terminal-exec no way to pass `--app-id` on. Typeable needs the keyboard |
| E6 | pass | A real terminal from Add a web app, closed afterwards |
| E7 | todo | |
| E8 | holds | The presentation wrapper waits for a key after the command. Seen, not checked |
| E9 | partial | **Changed:** About reads the Omarchy pin from `/etc/omarchy-mobile/release`, because `omarchy-version` asks pacman for a package this image does not install. An image built before 2026-09-11 has no pin there and falls back to upstream's version file, which reads 4.0.0.alpha |
| F1, G1–G7 | todo | `settings coverage` emits 133 lines from `Pages.js`, but `docs/menu-coverage.md` is not ported, so parity has nothing to be checked against |
| F2–F7 | holds | Guards.js is moarchy's, unchanged. F6 is what hides Lock, AI agent and Install from the AUR |
| F8 | changed | AI agent's row is guarded again -- on mise, the installer, not on the agents (D8). The guard stays now that mise ships, because it is still the right answer for a `--session-only` image: no mise, no working row, and `omarchy-mobile-agent` withholds its wrappers on the same condition (P6) |
| H1 | pass | Walked over every page |
| H2 | holds | `settings coverage` carries `trigger.toggle.notifications` as Shade |
| I1 | holds | `listPlugins` shows `mobile.shell` and `settings state` answers |
| I2 | holds | Every glyph is one code point, checked statically. They are written as escapes here, as everywhere in this project |
| I3, I4 | holds | Checked by the greps the criteria give |
| I5 | changed | No bin directory to put first: the helpers are in `~/.local/bin`, which the session already has on PATH |
| I6 | holds | `omarchy-mobile-network-name` |
| J1 | partial | The list is the page; the no-notification half is not checked |
| J2, J5, J6, J13 | holds | Seen over IPC, not asserted |
| J3, J4, J8, J12 | pass | A reminder set, listed, asked about and cancelled |
| J7, J9, J10 | todo | |
| J11 | todo | No keyboard here. The window is what the compositor shrinks, as moarchy's is now |
| s.K1, s.K3, s.K5, s.K6 | holds | Audio rows exist, monitors are filtered, an empty list is an info row, nothing opens a terminal. Not asserted |
| s.K2 | pass | One sink in this VM |
| s.K4 | todo | Needs a second sink |
| L1–L4 | pass | Europe against `timedatectl` |
| L5 | todo | Not set, so as not to move the VM's clock |
| M1, M2, M5 | pass | |
| M3, M6 | holds | |
| M4 | todo | Not flipped for real |
| N1 | holds | |
| N2, N3 | pass | **Changed:** it names Omarchy and omarchy-mobile, this project's counterpart to moarchy |
| O1 | holds | `drawer type ""` answers no results, and `drawer entries` lists fourteen `.desktop` ids and nothing else |
| O2 | holds | 1..5 results, every field filled. Stronger than the criterion asks: all 144 indexed rows carry a glyph, a label and a section, so no query can produce an empty field. The glyph is the row's own or the one its page is reached by |
| O3 | holds | Every key in `drawer results` resolves: `settings rowsOn <pageId>` lists its `<rowId>`, walked over the whole index as well as over live queries |
| O4 | holds | **By a real tap**, with `lastLaunch` primed to something else first so the evidence could not be stale: a tap on the Screenshot result left `lastLaunch` = `omarchy-capture-screenshot fullscreen`, `settings state` = `closed`, `settings running` = `stopped` -- it never mapped -- and the drawer closed. `running` is the load-bearing half |
| O5 | holds | **By a real tap** on the System result: `settings state` = `open`, `page` = `system`, one `org.quickshell` window titled "Settings — System". Over IPC, `tools.reminders/new` lands on `tools.reminders.new`, the screen and not the page the row lives on |
| O6 | holds | `display/nightlight` opens `display` and `settings value nightlight` still reads `off` |
| O7 | holds | Both halves: `drawer type screenshot` leaves no guarded row in `matches`, so `Guards.build` answers "" and nothing forks; `drawer type qr` leaves exactly one (`net/qr guarded`), and with no Wi-Fi device its guard says no, so `results` is empty while `matches` is not |
| O8 | holds | With a reminder set so the guard says yes: `settings confirmText` reads "Clear every reminder?" with the page shown and nothing run. Withheld and answering `hidden` with no reminders set, which is O7 from the other side |
| O9 | holds | `tools.reminders.new/custom` with nothing typed opens `tools.reminders.new` and leaves `lastLaunch` untouched -- read as the *previous* command, so an untouched value is visible rather than assumed. `matches` ranks the screen above the inert row |
| O10 | holds | `drawer type europe` answers nothing, and no query names a city, a font, a wallpaper or a theme. **The spec's arrow is stale here, and moarchy's code is what this follows:** it says "`europe` answers the region nav row", but those eleven rows carry `unlisted: true` in both projects, because a row that leads only where search cannot follow is scaffolding. So the answer is nothing at all |
| O11 | holds | `gap` >= `strip` with results showing, at both heights: 30 against 20 with five results and the keyboard down, and 30 against 20 with four and the keyboard up. The inset is the sheet column's rather than the last child's, so it holds whatever ends up last |
| O12 | holds | No `switch` or `choice` row in the whole index has a label matching H1's regex. Checked over the index rather than over a query, so it holds for every query |
| O13, O14 | holds | Update system and Authorize SSH keys are rows, claiming no upstream id |
| Search, generally | holds | `Search.js` is moarchy's, unchanged but for the file references. The quiet open O4 needs is `SettingsScreen.qml`'s -- `quietOpen`, `settlePending` and a 3s floor under a guard batch that never answers. None of it has a `vm-selftest.sh` line yet |
| O15 | pass | |
| P1 | todo | **Written, not yet run.** One `omarchy-mobile-agent.desktop`, rewritten. This port never shipped the per-agent tiles moarchy's P1 was written against, so there was nothing to clean up -- which is also why P8 below is a different criterion here rather than the same one |
| P2 | todo | **Written, not yet run.** `Name`, `Exec` and `Icon` move together, with `X-Omarchy-Mobile-Agent` rather than moarchy's `X-Moarchy-Agent` |
| P3 | todo | **Written, not yet run.** Absent and junk `defaults/agent` both answer the setup tile. `current_agent()` is moarchy's, unchanged but for the thirteen names it validates against |
| P4 | todo | **Written, not yet run.** Changed: **The one place this port reverses moarchy.** moarchy writes `Icon=/usr/share/moarchy/agents/<name>.svg` because no agent has an icon in Adwaita, breeze or hicolor, so an absolute path was the only escape from `system-run`. That reason stops applying once the icons are ours: this ships fourteen as `omarchy-mobile-agent-<name>` and `omarchy-mobile-agent` under `~/.local/share/icons/hicolor/scalable/apps/`, so the lookup is ordinary. It is the argument the three shell-screen entries beside it already make (`omarchy-mobile-wifi.desktop`): a name of our own cannot be shadowed by a theme's monochrome panel glyph, and the tile's `Icon=` stays portable instead of naming a path |
| P5 | todo | **Written, not yet run.** Three lists checked against upstream's `omarchy:args=`, not against each other: `omarchy-mobile-agent list`, the choice-row ids on `apps.default.agent`, and the icon basenames with the prefix stripped. **Thirteen, not moarchy's nine** -- upstream grew Cursor, Hermes, Muse and OpenClaw after moarchy's set was made |
| P6 | todo | **Written, not yet run.** Changed: Eleven of thirteen, not all of them (P8), and only on an image that has mise. Without mise `write_shim` writes nothing at all: the wrapper's whole body is a `mise` call, so seeding one would put eleven names on PATH that answer `mise: command not found` and make `omarchy-cmd-present` lie to the one launcher that asks it. The same image hides the row on the same condition (F8), so this is the agreed answer there. The tile is still written |
| P7 | todo | **Written, not yet run.** A non-mise `~/.local/bin/claude` survives `seed` byte-identical. Upstream depends on this too: `user_install()` in `omarchy-default-agent` reads that same file and treats a non-mise wrapper as the user's own install |
| P8 | todo | **Written, not yet run.** Changed: **Not moarchy's P8**, which was about deleting per-agent tiles a flashed phone still carried; this port never wrote any. The criterion that earns the slot here is Hermes and OpenClaw, which are never shimmed. Each has an installer of its own (`omarchy-install-hermes-cli`, `omarchy-install-openclaw-cli`) that owns `~/.local/bin/<name>`, writes a marker line into it and refuses to touch anything foreign; Hermes needs its interpreter pinned, which a bare `mise use` cannot say, and OpenClaw comes from a pacman package. A mise wrapper at either path would leave the real installer standing aside from a stub that installs the wrong thing. Both still install from the row and the tile, because `omarchy-default-agent` calls those installers directly |
| P9 | todo | **Written, not yet run.** `omarchy-default-agent codex` behind the script's back, then `omarchy-mobile-agent entry` with no argument repairs the tile |
| P10 | todo | **Written, not yet run.** `omarchy-shell settings openAt apps.default.agent` answers `ok` and leaves `settings page` there with thirteen choice rows drawn |
| P11 | todo | **Written, not yet run.** All thirteen names in `Keywords`. This is the criterion the whole section exists for: searching the drawer for "agent" answered nothing, and it answered nothing twice over -- no tile, and the settings row that would have matched withheld by its mise guard, which the drawer honours (O7) |
| Lock | changed | Not in settings.md. Lock is hidden unless `passwd -S` reads `P`: upstream's lock is the shell's lock screen, which asks PAM, and this image locks the account password. The selftest checks it (`s.B8`) |

---

## Found on the way

**`opened` is false the moment a drag latches, and A6 read it.** The carousel's
`opened` is `progress >= 1 && !dragging`, so the order of two lines at the latch
decides whether an already-open carousel still looks open: setting `dragging`
first makes it read shut, and the preview's A6 guard -- "a second drag is a drag
over the switcher, and the app it would capture is already behind it" -- never
fires. Measured with a held second drag: `armed=true content=true`, a capture
taken for nothing. Invisible, because the preview's fade is zero past 82% of the
travel, which is exactly why it would not have been noticed. moarchy arms before
`setTargetProgress`, and that is the whole of the difference.

**A drag goes to the topmost surface under the finger.** moarchy's answer to
A8 cuts the pill's band out of the open shade's input region so that an up-swipe
falls through to the strip. Measured twice over here: the cut-out region stayed
uncommitted until something repainted (a press after an open reached nothing),
and once it did reach the strip's surface the drag stopped dead, because it has
to travel up over the shade. The shade forwards the band instead.

**`Toplevel.activate()` ignores the shell's own windows**, where it focuses
anybody else's. Every focus goes through `hl.dsp.focus({ window = "address:…" })`.

**Persistent toasts owned the top of the screen.** Upstream's two first-run
notifications do not time out, and the toast column took every touch in
roughly the top 170px until they were dismissed -- the drawer's handle and first
grid row included. H6 once failed on it for a reason that had nothing to do
with H6. There are no toasts now (S24); the suite still dismisses any before
each section, for a guest whose Omarchy predates the patch.

**Every `vm-push.sh` used to crash the shell.** It swapped the plugin's files
while the shell was running, the shell hot-reloaded the plugin mid-copy, and
quickshell segfaulted and restarted itself -- sometimes leaving the previous
instance running beside the new one, surfaces, stray window and all. Two
"quickshell" cards that belonged to no screen were the tell. The push stops the
shell before it touches a file now. Any check that failed inconsistently before
that fix is suspect on that account alone.

**Hyprland's debug overlay deadlocked Hyprland.** Turned on to read frame
times, and off again, it left every compositor thread in `__futex_wait` next to
a new pango font thread. Frame cost is read from the drag traces instead.

**The drag traces measure the renderer, not just the gesture.** They read 13-14
samples for a carousel drag headless and 3-4 windowed on a busy Mac (macOS's
`mediaanalysisd` at 269% CPU). Neither the shade's always-mapped surface nor
pointer-device churn moved the number when tested alone. The trace checks drag
for 1.5 seconds, long enough to leave eight frames at the rates this VM reaches
windowed -- a slower drag proves "follows the finger" just as well.

**A bar with no widgets leaves upstream's weather panel talking to nothing.** It
binds `root.bar.foreground` on a host widget that is not there and logs a
`TypeError` a few times a minute. Noise, not breakage.
