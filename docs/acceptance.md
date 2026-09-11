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
| B3 | pass | Checked for the drawer and for the shade. There is no theme picker yet |

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
| G1–G10a | todo | Not built. When it is, the shade has to forward the left edge the way it forwards the pill (A8), and G10's 220px inset -- Sway's layer-by-layer exclusive zones -- has to be re-measured on Hyprland |

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
| J1–J10 | todo | Not built. The constraint behind J10 ("no window thumbnails, except the app you are leaving") is Sway's: Hyprland implements `hyprland-toplevel-export-v1`, so every card *could* carry a picture. Measure the cost before deciding |

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
| K7 | todo | Needs the back gesture. Settings' `goBack()` walks its stack and answers false at the root, for the gesture to close it then |
| K8 | pass | A bridged row's terminal comes up tiled on a workspace of its own and Settings stays running (settings.md E6) |
| K9 | holds | Measured: the class is `org.quickshell`, and each screen is told apart by a title prefix |
| K10 | pass | Wi-Fi, Bluetooth and Settings, and the theme picker is a page of Settings, not a screen |
| K11 | todo | Needs J |
| K12 | pass | **Changed:** by Hyprland address, for the reason under E2 |

### L. Long-press on an app

| AC | Status | Note |
| --- | --- | --- |
| L1–L13 | todo | L11/L12's package names are moarchy's and would become this project's |

### Constraints

| Constraint | Status | Note |
| --- | --- | --- |
| The strip reserves 20px off every window | holds | `hyprctl monitors`: `reserved: 0 26 0 20`. **Changed:** the band surface reserves it, from Bottom, and the strip only draws the pill (I6) |
| Only the left edge may take touch ahead of an app | holds | Nothing takes touch ahead of an app yet; the edge surface's input region is the strip's band at rest (`gestures geometry`: `input=band`) |
| No window thumbnails except the app you are leaving | open | See J |
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
| L1–L9a | todo | The launch splash. Upstream's launch OSD still runs |

## [style.md](spec/style.md)

| AC | Status | Note |
| --- | --- | --- |
| A1–I4 | todo | No `scripts/style-check.sh` yet. The surfaces here follow moarchy's radii, roles, weights and 44px targets by hand, unchecked |

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
| B3, B5 | todo | Need the back gesture (gestures.md G). `goBack()` is there for it to call |
| B4 | partial | The carousel rises over Settings with its card leading (the K6 check does exactly that); the home band leaving it running is not checked |
| B6 | pass | |
| B7 | holds | **Changed:** Theme is a page here, not a plugin, so it returns to where it was opened from by being popped |
| B8 | pass | Firefox's row hidden with no Firefox; and Lock, below |
| B9 | pass | |
| C1 | pass | Stay awake against `omarchy-toggle-idle status` |
| C2, C3 | pass | The battery flag, set and put back |
| C4 | pass | Both ways, read off `bar metrics`. The target is this project's `bar`, whose `syncFlags` Bar.qml declares |
| C4a, C6 | holds | No Show status bar and no transparency row. Not checked |
| C5 | holds | **Changed:** upstream's `omarchy-toggle-idle`, whose state file the shell's own idle service reads (it logs `stay-awake: disabled state-file`). There is no swayidle to check |
| C7 | todo | The crash-capture unit is not checked |
| C8 | pass | |
| C9 | partial | Not activated for real, since it changes sshd; E6 shows a bridged terminal leaving Settings running |
| D1 | pass | DNS, and Theme against `omarchy-theme-current` |
| D2 | holds | A choice ticks only on an exact match with the reader. Not checked with a stub |
| D3 | holds | The Epiphany row, which needs Epiphany installed to be seen |
| D4 | pass | The default terminal, written as the one it already is. Choice writes re-read when the write exits, not when it starts |
| D5, D6, D7 | pass | |
| D8 | changed | AI agent is hidden: `omarchy-default-agent` installs through mise, which this image does not have. The rows are upstream's thirteen, writing upstream's `omarchy-default-agent <name>` |
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
| F8 | changed | AI agent's row is guarded again -- on mise, the installer, not on the agents (D8) |
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
| O1–O12 | todo | Search from the drawer is not ported |
| O13, O14 | holds | Update system and Authorize SSH keys are rows, claiming no upstream id |
| O15 | pass | |
| P1–P11 | todo | The coding-agent tile needs mise |
| Lock | changed | Not in settings.md. Lock is hidden unless `passwd -S` reads `P`: upstream's lock is the shell's lock screen, which asks PAM, and this image locks the account password. The selftest checks it (`s.B8`) |

---

## Found on the way

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
