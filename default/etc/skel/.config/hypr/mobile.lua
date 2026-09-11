-- omarchy-mobile: what a phone needs from the window manager.
--
-- Loaded from hyprland.lua after Omarchy's defaults and the other user files,
-- so everything here is an override of upstream and never an edit to it.
-- The contract is docs/spec/windows.md W1-W5 and the "one app per workspace"
-- vocabulary in docs/spec/gestures.md.

-- One app per workspace. Half of a 360-logical-pixel screen is 180, which no
-- app can use, so a new tiled window goes to a workspace of its own and focus
-- follows it -- tap an app in the drawer and you land in it, full width. The
-- workspace then becomes the unit the strip's sideways swipe moves through,
-- so "next workspace" reads as "next app".
--
-- "empty" is the lowest-numbered workspace with nothing on it, which is also
-- what the shell's home gesture dispatches (gestures.md F1). The same word in
-- both places means launching and going home cannot disagree about which
-- workspace is free. moarchy needs a Python daemon on Sway's IPC for this;
-- Hyprland's rule engine does it at map time.
--
-- Floating windows are left where they open. That is how a toolkit ships a
-- dialog, and a "Save changes?" sheet must not fly off to its own workspace
-- leaving the document behind.
hl.window_rule({
  match = { class = ".*", float = false },
  workspace = "empty",
})

-- W1, W2. A single app fills its workspace exactly: no gaps at the workspace
-- edge, where upstream's gaps_out = 10 costs 20px of a 360px width.
hl.config({
  general = {
    gaps_in = 0,
    gaps_out = 0,
  },
})

-- The shell's own sheets animate themselves -- the carousel and the drawer
-- follow the finger, the shade's scrim tracks its sheet -- so Hyprland's layer
-- fade on map and unmap is a second animation on top of the first, paid for in
-- frames on a software renderer. Upstream turns it off for its own surfaces
-- the same way (default/hypr/apps/omarchy-shell.lua).
hl.layer_rule({
  match = { namespace = "^(omarchy-mobile-.*)$" },
  no_anim = true,
  animation = "none",
})

-- The shell's own screens -- Settings, Wi-Fi, Bluetooth -- are windows, and
-- upstream tags every window for 0.985 / 0.96 opacity (default/hypr/windows.lua).
-- The wallpaper then tints the theme background they draw, away from the same
-- colour in the bar, which is a layer surface and opaque: on Tokyo Night the
-- bar measured #1a1b26 and Settings under it #1e1d27. Opted out the way
-- upstream opts out its media windows (default/hypr/apps/system.lua).
hl.window_rule({
  match = { class = "^org\\.quickshell$" },
  tag = "-default-opacity",
  opacity = "1 1",
})

-- The on-screen keyboard: moarchy's, pinned in manifest.toml. It raises itself
-- when a text field takes focus and retracts when focus leaves one -- no
-- toggle, no gesture -- because Hyprland advertises
-- zwp_input_method_manager_v2 and zwp_text_input_manager_v3 as Sway does, so
-- an input method that binds them is sent activate and deactivate as apps
-- focus text. It reads the theme's colors.toml itself and recolours on
-- omarchy-theme-set.
--
-- Started through uwsm-app, like the rest of upstream's autostart. A second
-- instance exits at once -- the protocol grants one input method per seat --
-- so two can never fight over the keys.
o.launch_on_start("moarchy-keyboard")

-- For an app that never asks for a keyboard, or a hardware keyboard attached:
-- force the soft one up or down. The key moarchy binds.
o.bind("SUPER + I", "Toggle the on-screen keyboard", "omarchy-mobile-toggle-keyboard")

-- W3. The border stays and costs nothing in the normal case: it is dropped on
-- a workspace holding one tiled window, which one-app-per-workspace makes the
-- normal case. Split a workspace and it comes back -- it is then the only thing
-- saying which pane has focus.
hl.window_rule({
  match = { workspace = "w[tv1]" },
  border_size = 0,
})
