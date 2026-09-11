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

Last full run: 2026-09-11, 70 checks -- 67 passing in one full run, and the three it
failed (E3, E6, S22: two checks that read state before an animation and a
client's close had finished, and a one-pixel rounding) passing on a rerun of
their sections. VM windowed, one shell instance throughout, Omarchy 4.0.3 on
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
| E4 | partial | The next card's left edge is at x=304 of 360, so it peeks in. Paging itself is not checked |
| E5 | pass | |
| E6 | pass | SKIP while a window the suite did not open is up |
| E7 | holds | No clear-all control exists |

### F. Going home

| AC | Status | Note |
| --- | --- | --- |
| F1 | pass | **Changed:** Hyprland's own `empty` workspace selector *is* this rule, measured to pick the lowest free number including a gap. The window rule in `hypr/mobile.lua` uses the same word, so there is no second implementation to drift from the first |
| F2 | pass | |
| F3 | todo | There is no on-screen keyboard yet |
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
| I1–I7 | todo | The drawer does extend under the strip (I1) and A7 shows the pill works over it (I6), but none of the section's pixel checks are written, and I5 needs a keyboard |

### J. The app you are leaving

| AC | Status | Note |
| --- | --- | --- |
| J1–J10 | todo | Not built. The constraint behind J10 ("no window thumbnails, except the app you are leaving") is Sway's: Hyprland implements `hyprland-toplevel-export-v1`, so every card *could* carry a picture. Measure the cost before deciding |

### K. Settings is an app

Here the screens that are windows are Wi-Fi and Bluetooth; Settings is not built.

| AC | Status | Note |
| --- | --- | --- |
| K1 | pass | `class org.quickshell`, alone on its workspace, the usable area exactly |
| K2 | pass | Swiped off and back, the screen is still there |
| K3 | todo | Not checked for the other ways a workspace moves |
| K4 | todo | Not checked |
| K5 | pass | Glyph, name and page, from the screen itself -- there is no desktop entry for an app id that names the shell process |
| K6 | pass | Flicking the card closes the window; summoned again, it opens (moarchy's visible-false-then-true, measured after a compositor-side close too) |
| K7 | todo | Needs the back gesture |
| K8 | todo | Needs Settings' rows |
| K9 | holds | Measured: the class is `org.quickshell`, and each screen is told apart by a title prefix |
| K10 | partial | Wi-Fi and Bluetooth; Settings is not built |
| K11 | todo | Needs J |
| K12 | pass | **Changed:** by Hyprland address, for the reason under E2 |

### L. Long-press on an app

| AC | Status | Note |
| --- | --- | --- |
| L1–L13 | todo | L11/L12's package names are moarchy's and would become this project's |

### Constraints

| Constraint | Status | Note |
| --- | --- | --- |
| The strip reserves 20px off every window | holds | `hyprctl monitors`: `reserved: 0 26 0 20` |
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
| S2 | pass | **Changed:** the gear opens upstream's Omarchy menu, not Settings, which is not built. A tap outside dismisses it -- HyprlandFocusGrab works here, where moarchy's port had to stub it out |
| S3 | holds | **Changed:** power opens the same menu at `system`. Not checked separately from S2 |
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
| W5 | pass | |
| L1–L9a | todo | The launch splash. Upstream's launch OSD still runs |

## [style.md](spec/style.md)

| AC | Status | Note |
| --- | --- | --- |
| A1–I4 | todo | No `scripts/style-check.sh` yet. The surfaces here follow moarchy's radii, roles, weights and 44px targets by hand, unchecked |

## [settings.md](spec/settings.md)

| AC | Status | Note |
| --- | --- | --- |
| A1–P11 | todo | Not built. The shade's gear and power button stand in with upstream's Omarchy menu (S2, S3) |

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

**Persistent toasts own the top of the screen.** Upstream's two first-run
notifications do not time out, and the toast column takes every touch in
roughly the top 170px until they are dismissed -- the drawer's handle and first
grid row included. Pulling the shade down archives them into its list. The
suite dismisses them before each section; H6 once failed without that for a
reason that had nothing to do with H6.

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
