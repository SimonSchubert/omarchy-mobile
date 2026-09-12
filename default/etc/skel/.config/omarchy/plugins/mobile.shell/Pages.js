// Every screen in Settings, as data (docs/spec/settings.md).
//
// Ported from moarchy.settings/Pages.js. The tree, the row types and the
// guards are moarchy's. What changed is what a row runs, because most of the
// reasons moarchy's rows depart from upstream are Sway, and this is Hyprland:
//
//   - A bridged row runs upstream's own action string wherever upstream's
//     command works here, which on Hyprland is nearly everywhere. moarchy's
//     Sway stand-ins -- nightlight on wlsunset, lock on swaylock, screenshot
//     on bare grim, logout through swaymsg -- are gone, and so is its
//     presentation-terminal wrapper around the package rows, which call
//     xdg-terminal-exec themselves now that the image has it.
//   - Four rows depart from upstream on purpose, and each says why where it
//     stands: Screenshot takes `fullscreen`, Change password runs under sudo,
//     Lock is guarded on there being a password to unlock with, and AI agent
//     on mise, which installs the agents.
//   - The phone-shaped native pages -- audio routing, reminders, time zone,
//     plugins, About -- keep their helpers, as omarchy-mobile-* in
//     ~/.local/bin (default/etc/skel/.local/bin).
//   - Theme is a page, not a plugin: omarchy-theme-list's names, ticked by
//     omarchy-theme-current, which prints the same names.
//   - Wi-Fi and Bluetooth are screens of this same plugin, so their rows name
//     the screen rather than summoning another plugin.
//
// ---------------------------------------------------------------------------
// Row types
// ---------------------------------------------------------------------------
//   nav      pushes `page`. A second line comes from `detail` (prose) or
//            `detailCmd` (a shell expression the guard batch answers).
//   plugin   opens another surface and leaves Settings where it is: one of
//            this shell's screens by name ("wifi", "bluetooth"), whose back
//            chevron comes back here, or any other plugin id by summon.
//   switch   `read` prints the state; `on`/`off` set it. `invert` for the
//            negative-polarity flags, where the file existing means OFF.
//   choice   a radio row. The page's `reader` says which is current; the row's
//            `readValue` is what to compare (defaults to `value`), and `write`
//            is what to run. Separate fields because they can differ: the
//            Epiphany row reads a desktop id and writes an xdg-settings call.
//   action   runs `run`. `launch: "inline"` runs it in place and re-reads the
//            page when it exits; `back: true` pops one page first. `launch:
//            "tui"` wraps it in upstream's presentation terminal. Anything
//            else is fire-and-forget. `argsFrom` names `input` rows whose text
//            is appended, shell-quoted, in order; `requires` names one that
//            must be non-empty or the row is dimmed and inert (J8). `confirm`
//            asks first.
//   link     a URL, through omarchy-launch-webapp.
//   info     read-only text.
//   input    a text field. Its text does not outlive the page (J12).
//
// A page may build its rows at open instead: `provider.list` turns one value
// per line into `choice` rows, `provider.json` takes a JSON array of whole
// rows, and `before: true` puts those above the declared rows rather than
// replacing them. A `text` page renders a command's columns as info rows.
//
// Any row may carry `when`, copied verbatim from omarchy-menu.jsonc where
// upstream has one, so the guard upstream uses is the guard used here.
// `covers` maps an upstream menu id to N(ative) or B(ridged), and is what
// `omarchy-shell settings coverage` emits.
//
// Two fields exist only for the drawer's search (spec/settings.md section O).
// `keywords` is extra words it matches on, for the cases where the word a
// person types is not in the label -- "timer" for Reminders, "capture" for
// Screenshot. It is a handful of rows and not a discipline; a label that says
// what it is needs none. `unlisted: true` keeps a row out of that search while
// leaving it in Settings, and one shape needs it: a nav row whose only
// destination is a page a provider builds, which search cannot see into.
//
// ---------------------------------------------------------------------------
// Glyphs are escapes
// ---------------------------------------------------------------------------
// Every glyph is a private-use code point, and this project has lost literal
// ones in transit (docs/build-log.md). `\u{...}` above U+FFFF, never `\uXXXX`
// with the rest appended: the four-digit form takes exactly four digits, so
// "1" is U+F043 and a "1" -- two characters, a real glyph, and the wrong
// picture (settings.md I2).
.pragma library

// Ids satisfied outside this stack. `apps` is the app drawer, which already is
// upstream's apps provider; a launcher inside Settings would repeat it.
var EXTERNAL = {
    "apps": { cls: "N", where: "mobile.shell drawer" }
};

// Already a shade control. Recorded so coverage is complete, never rendered
// (H2).
var SHADE = {
    "trigger.toggle.notifications": "shade > Silent tile"
};

// The presentation terminal: upstream's logo, the command, then "Done" until
// a key is pressed. One name for the forty-odd rows that use it.
var PRESENT = "omarchy-launch-floating-terminal-with-presentation";

var PAGES = {

// --------------------------------------------------------------------- root
"root": { title: "Settings", rows: [
  { id: "net", type: "nav", page: "net", glyph: "\u{F06F3}", label: "Network & internet",
    detailCmd: "omarchy-mobile-network-name", covers: { "setup": "N", "setup.network": "N" } },
  { id: "display", type: "nav", page: "display", glyph: "\u{F0379}", label: "Display",
    covers: { "trigger.toggle": "N" } },
  { id: "sound", type: "nav", page: "sound", glyph: "", label: "Sound & notifications",
    detailCmd: "omarchy-mobile-audio output-name" },
  { id: "appearance", type: "nav", page: "appearance", glyph: "", label: "Appearance",
    detailCmd: "omarchy-theme-current", covers: { "style": "N" } },
  { id: "apps", type: "nav", page: "apps", glyph: "\u{F003B}", label: "Apps & defaults",
    covers: { "install": "N", "remove": "N" } },
  { id: "shell", type: "nav", page: "shell", glyph: "\u{F035C}", label: "Shell & plugins",
    detailCmd: "omarchy-mobile-plugins summary" },
  { id: "security", type: "nav", page: "security", glyph: "", label: "Security",
    covers: { "setup.security": "N", "remove.security": "N" } },
  { id: "tools", type: "nav", page: "tools", glyph: "\u{F14DE}", label: "Tools",
    covers: { "trigger": "N" } },
  { id: "system", type: "nav", page: "system", glyph: "", label: "System",
    covers: { "system": "N", "update": "N" } },
  { id: "about", type: "nav", page: "about", glyph: "", label: "About phone",
    detailCmd: "omarchy-mobile-about device", covers: { "learn": "N" } }
]},

// ------------------------------------------------------------------ network
"net": { title: "Network & internet", rows: [
  { id: "dns", type: "nav", page: "net.dns", glyph: "\u{F01D6}", label: "Private DNS",
    detailCmd: "omarchy-dns", covers: { "setup.network.dns": "N" } },
  // The shade toggles the radios (H1). These two rows open the screen each
  // tile opens on a long press -- one picker behind two entry points, twice --
  // and neither has an upstream id, because a desktop joins a network from a
  // bar applet.
  { id: "wifi", type: "plugin", plugin: "wifi", glyph: "\u{F16BE}", label: "Wi-Fi networks",
    keywords: "wlan wireless internet connect",
    detailCmd: "omarchy-mobile-network-name wifi" },
  { id: "bluetooth", type: "plugin", plugin: "bluetooth", glyph: "\u{F00AF}",
    keywords: "pair headset",
    label: "Bluetooth devices" },
  { id: "qr", type: "action", glyph: "\u{F0432}", label: "Wi-Fi QR code",
    when: "[[ $(omarchy-network-status) == wifi* ]]",
    run: "omarchy-shell shell summon omarchy.wifiqr",
    covers: { "setup.network.qr": "B" } }
]},

"net.dns": { title: "Private DNS", reader: "omarchy-dns", rows: [
  { id: "dhcp", type: "choice", label: "Automatic (DHCP)", value: "DHCP",
    write: "omarchy-dns DHCP", covers: { "setup.network.dns.dhcp": "N" } },
  { id: "cloudflare", type: "choice", label: "Cloudflare", value: "Cloudflare",
    write: "omarchy-dns Cloudflare", covers: { "setup.network.dns.cloudflare": "N" } },
  { id: "google", type: "choice", label: "Google", value: "Google",
    write: "omarchy-dns Google", covers: { "setup.network.dns.google": "N" } },
  // A bridged write inside a native radio: the tick still comes from
  // omarchy-dns, and only the prompt for the address leaves the screen.
  { id: "custom", type: "choice", label: "Custom...", value: "Custom",
    write: PRESENT + " 'omarchy-dns Custom'",
    covers: { "setup.network.dns.custom": "B" } }
]},

// ------------------------------------------------------------------ display
"display": { title: "Display", rows: [
  // Upstream's hyprsunset toggle, which moarchy had to replace with wlsunset.
  // It toggles and nothing else, so each direction checks first: `set on`
  // twice must not turn it off.
  { id: "nightlight", type: "switch", glyph: "\u{F050E}", label: "Night light",
    read: "omarchy-toggle-nightlight --status | jq -r .enabled",
    on: "[[ $(omarchy-toggle-nightlight --status | jq -r .enabled) == true ]] || omarchy-toggle-nightlight",
    off: "[[ $(omarchy-toggle-nightlight --status | jq -r .enabled) == false ]] || omarchy-toggle-nightlight",
    covers: { "trigger.toggle.nightlight": "N" } },
  { id: "stayawake", type: "switch", glyph: "\u{F0176}", label: "Stay awake",
    detail: "Keep the screen on",
    read: "omarchy-toggle-idle status | jq -r .enabled",
    on: "omarchy-toggle-idle stay-awake",
    off: "omarchy-toggle-idle allow-idle",
    covers: { "trigger.toggle.idle-lock": "N" } }
]},

// -------------------------------------------------------------------- sound
"sound": { title: "Sound & notifications", rows: [
  // Routing, not a mixer: volume belongs to the shade (H1). What the shade has
  // no room for is *which* device.
  { id: "output", type: "nav", page: "sound.output", glyph: "\u{F04C3}",
    label: "Output device", detailCmd: "omarchy-mobile-audio output-name" },
  { id: "input", type: "nav", page: "sound.input", glyph: "\u{F036C}",
    label: "Input device", detailCmd: "omarchy-mobile-audio input-name" },
  { id: "crashcapture", type: "switch", glyph: "\u{F16A1}", label: "Crash capture",
    detail: "Keep a log when an app dies",
    read: "omarchy-toggle-enabled crash-capture-off && echo true || echo false",
    invert: true,
    on: "omarchy-toggle crash-capture-off off",
    off: "omarchy-toggle crash-capture-off on",
    covers: { "trigger.toggle.crash-capture": "N" } }
]},

// provider.json, because the label a person reads (PipeWire's Description) and
// the handle pactl takes back are different strings (K2).
"sound.output": { title: "Output device",
  reader: "omarchy-mobile-audio current-output",
  provider: { json: "omarchy-mobile-audio outputs" },
  rows: [] },

"sound.input": { title: "Input device",
  reader: "omarchy-mobile-audio current-input",
  provider: { json: "omarchy-mobile-audio inputs" },
  rows: [] },

// --------------------------------------------------------------- appearance
"appearance": { title: "Appearance", rows: [
  { id: "theme", type: "nav", page: "appearance.theme", glyph: "\u{F0E0C}", label: "Theme",
    detailCmd: "omarchy-theme-current", covers: { "style.theme": "N" } },
  { id: "background", type: "nav", page: "appearance.background", glyph: "",
    label: "Wallpaper", detailCmd: "omarchy-theme-bg-current",
    covers: { "style.background": "N" } },
  { id: "font", type: "nav", page: "appearance.font", glyph: "", label: "Font",
    detailCmd: "omarchy-font-current", covers: { "style.font": "N" } },
  { id: "bar", type: "nav", page: "appearance.bar", glyph: "\u{F035C}", label: "Status bar",
    covers: { "style.bar": "N" } },
  { id: "more", type: "nav", page: "appearance.more", glyph: "\u{F0249}", label: "Get more",
    covers: { "install.style": "N" } }
]},

// Upstream's Theme row runs omarchy-theme-switcher, a picker of preview images
// sized for a desktop. The list is the same list, and omarchy-theme-current
// prints the names omarchy-theme-list does, so the tick needs no translation.
// omarchy-theme-set recolours the shell in place; it restarts terminals, not
// the shell, so this screen survives its own write.
//
// A `json` provider rather than a `list` one, and that is the whole of what
// makes this a picker rather than a column of names: each row carries the
// palette of the theme it names, and the list draws it in those colours. The
// argument is moarchy.themes' -- "Ristretto" and "Miasma" tell you nothing, so
// picking by name means applying a theme to find out what it is -- and the
// rows are built by omarchy-mobile-themes, which explains how it recovers each
// theme's colors.toml without deriving a name omarchy-theme-set would not
// recognise. The row's `write` comes built for the same reason.
"appearance.theme": { title: "Theme",
  reader: "omarchy-theme-current",
  provider: { json: "omarchy-mobile-themes rows" },
  rows: [] },

// The rows are paths, so the reader is a path: omarchy-theme-bg-current
// prettifies ("Sunset Lake"), and against a list of paths it matched nothing
// (D7). The label carries the prettifying instead.
"appearance.background": { title: "Wallpaper",
  reader: "readlink -f \"$HOME/.local/state/omarchy/current/background\"",
  provider: { list: "ls -1 \"$HOME/.local/state/omarchy/current/theme/backgrounds\"/* 2>/dev/null", label: "background" },
  write: "omarchy-theme-bg-set",
  rows: [] },

// omarchy-font-list enumerates `fc-list :spacing=100`, and the font in use
// need not be on it: with nothing configured, fc-match falls back to a family
// fontconfig does not tag that way. So the current font joins the list when
// the list omits it (D6).
"appearance.font": { title: "Font",
  reader: "omarchy-font-current",
  provider: { list: "{ omarchy-font-list; omarchy-font-current; } | awk 'NF' | sort -u" },
  write: "omarchy-font-set",
  rows: [] },

"appearance.bar": { title: "Status bar", rows: [
  // Negative polarity: the flag existing means the percentage is OFF. `bar
  // syncFlags` is Bar.qml's own IPC, and the FileView on the toggles
  // directory catches the flag even without it (C4).
  { id: "battery", type: "switch", glyph: "\u{F0079}", label: "Battery percentage",
    read: "omarchy-toggle-enabled battery-percentage-off && echo true || echo false",
    invert: true,
    on: "omarchy-toggle battery-percentage-off off && omarchy-shell -q bar syncFlags",
    off: "omarchy-toggle battery-percentage-off on && omarchy-shell -q bar syncFlags",
    covers: { "trigger.toggle.battery-percentage": "N" } }
  // No Show status bar row and no transparency row, for moarchy's reasons
  // (C4a, C6): the shade's grab strip owns the top edge whether or not the bar
  // draws, and `omarchy-bar transparent` reloads the shell config into the
  // desktop bar.
]},

"appearance.more": { title: "Get more", rows: [
  { id: "theme-install", type: "action", glyph: "\u{F0E0C}", label: "Install a theme",
    run: PRESENT + " omarchy-theme-install",
    covers: { "install.style.theme": "B" } },
  { id: "bg-install", type: "action", glyph: "", label: "Install a wallpaper",
    run: "omarchy-theme-bg-install",
    covers: { "install.style.background": "B" } },
  { id: "font-install", type: "nav", page: "appearance.more.font", glyph: "",
    label: "Install a font", covers: { "install.style.font": "N" } },
  { id: "theme-remove", type: "action", glyph: "\u{F0B4C}", label: "Remove a theme",
    run: "omarchy-theme-remove", covers: { "remove.theme": "B" } },
  { id: "theme-update", type: "action", glyph: "\u{F0E0C}", label: "Update extra themes",
    when: "omarchy-theme-extras",
    run: PRESENT + " omarchy-theme-update",
    covers: { "update.themes": "B" } }
]},

// omarchy-install-font surfaces its own install in a floating terminal, so
// these run bare, as upstream runs them.
"appearance.more.font": { title: "Install a font", rows: [
  { id: "cascadia", type: "action", glyph: "", label: "Cascadia Mono",
    run: "omarchy-install-font 'Cascadia Mono' ttf-cascadia-mono-nerd 'CaskaydiaMono Nerd Font'",
    covers: { "install.style.font.cascadia": "B" } },
  { id: "meslo", type: "action", glyph: "", label: "Meslo LG Mono",
    run: "omarchy-install-font 'Meslo LG Mono' ttf-meslo-nerd 'MesloLGL Nerd Font'",
    covers: { "install.style.font.meslo": "B" } },
  { id: "fira", type: "action", glyph: "", label: "Fira Code",
    run: "omarchy-install-font 'Fira Code' ttf-firacode-nerd 'FiraCode Nerd Font'",
    covers: { "install.style.font.fira": "B" } },
  { id: "victor", type: "action", glyph: "", label: "Victor Code",
    run: "omarchy-install-font 'Victor Code' ttf-victor-mono-nerd 'VictorMono Nerd Font'",
    covers: { "install.style.font.victor": "B" } },
  { id: "bitstream", type: "action", glyph: "", label: "Bitstream Vera Mono",
    run: "omarchy-install-font 'Bitstream Vera Code' ttf-bitstream-vera-mono-nerd 'BitstromWera Nerd Font'",
    covers: { "install.style.font.bitstream": "B" } },
  { id: "iosevka", type: "action", glyph: "", label: "Iosevka",
    run: "omarchy-install-font Iosevka ttf-iosevka-nerd 'Iosevka Nerd Font Mono'",
    covers: { "install.style.font.iosevka": "B" } }
]},

// ----------------------------------------------------------------- apps
"apps": { title: "Apps & defaults", rows: [
  { id: "defaults", type: "nav", page: "apps.default", glyph: "", label: "Default apps",
    covers: { "setup.default": "N" } },
  { id: "webapps", type: "nav", page: "apps.webapps", glyph: "", label: "Web apps" },
  { id: "tuis", type: "nav", page: "apps.tuis", glyph: "", label: "Terminal apps" },
  { id: "packages", type: "nav", page: "apps.packages", glyph: "\u{F08C7}",
    keywords: "install remove software pacman", label: "Packages" }
]},

"apps.default": { title: "Default apps", rows: [
  { id: "browser", type: "nav", page: "apps.default.browser", glyph: "", label: "Browser",
    detailCmd: "omarchy-default-browser", covers: { "setup.default.browser": "N" } },
  { id: "terminal", type: "nav", page: "apps.default.terminal", glyph: "", label: "Terminal",
    detailCmd: "omarchy-default-terminal", covers: { "setup.default.terminal": "N" } },
  { id: "editor", type: "nav", page: "apps.default.editor", glyph: "", label: "Editor",
    detailCmd: "omarchy-default-editor", covers: { "setup.default.editor": "N" } },
  // The page installs what it lists, through mise, and then runs it -- so a
  // guard on "is the agent installed" would hide the only screen that could
  // install one (F8). But mise is not in this image (vm/packages/omitted), and
  // without it every row on the page is a terminal that fails. The guard is on
  // the installer, not on the agents.
  { id: "agent", type: "nav", page: "apps.default.agent", glyph: "\u{F06A9}", label: "AI agent",
    when: "omarchy-cmd-present mise",
    detailCmd: "omarchy-default-agent", covers: { "setup.default.agent": "N" } }
]},

// GNOME Web first: it is the browser this image installs (vm/packages/apps),
// so on a base install it is the one row of the three that is drawn. The other
// two are guarded on a browser that is not here until somebody installs one --
// Firefox from More software, Chromium from `pacman -S chromium`.
//
// No upstream id: omarchy-default-browser has no name for Epiphany, so its
// reader falls through to printing the raw desktop id, which is what readValue
// is for (D3). Writing has to go around it for the same reason.
"apps.default.browser": { title: "Browser", reader: "omarchy-default-browser", rows: [
  { id: "epiphany", type: "choice", label: "GNOME Web", value: "epiphany",
    readValue: "org.gnome.Epiphany.desktop",
    when: "omarchy-cmd-present epiphany",
    write: "env -u BROWSER xdg-settings set default-web-browser org.gnome.Epiphany.desktop" },
  { id: "chromium", type: "choice", label: "Chromium", value: "chromium",
    when: "omarchy-cmd-present chromium", write: "omarchy-default-browser chromium",
    covers: { "setup.default.browser.chromium": "B" } },
  { id: "firefox", type: "choice", label: "Firefox", value: "firefox",
    when: "omarchy-cmd-present firefox", write: "omarchy-default-browser firefox",
    covers: { "setup.default.browser.firefox": "B" } }
]},

// Each row is guarded on its terminal being installed, so installing kitty
// brings its row back with no change here. The reader goes through
// xdg-terminal-exec --print-id, which is why this page ticked nothing until
// the image had xdg-terminal-exec.
"apps.default.terminal": { title: "Terminal", reader: "omarchy-default-terminal", rows: [
  { id: "alacritty", type: "choice", label: "Alacritty", value: "alacritty",
    when: "omarchy-cmd-present alacritty", write: "omarchy-default-terminal alacritty",
    covers: { "setup.default.terminal.alacritty": "N" } },
  { id: "foot", type: "choice", label: "Foot", value: "foot",
    when: "omarchy-cmd-present foot", write: "omarchy-default-terminal foot",
    covers: { "setup.default.terminal.foot": "N" } },
  { id: "kitty", type: "choice", label: "Kitty", value: "kitty",
    when: "omarchy-cmd-present kitty", write: "omarchy-default-terminal kitty",
    covers: { "setup.default.terminal.kitty": "B" } }
]},

"apps.default.editor": { title: "Editor", reader: "omarchy-default-editor", rows: [
  { id: "neovim", type: "choice", label: "Neovim", value: "nvim",
    when: "omarchy-cmd-present nvim", write: "omarchy-default-editor nvim",
    covers: { "setup.default.editor.neovim": "N" } },
  { id: "helix", type: "choice", label: "Helix", value: "helix",
    when: "omarchy-cmd-present helix", write: "omarchy-default-editor helix",
    covers: { "setup.default.editor.helix": "B" } },
  { id: "vim", type: "choice", label: "Vim", value: "vim",
    when: "omarchy-cmd-present vim", write: "omarchy-default-editor vim",
    covers: { "setup.default.editor.vim": "B" } }
]},

// Upstream's thirteen, each writing this project's own wrapper around
// upstream's action. No glyphs: six of upstream's icons are drawn from
// Omarchy's own font rather than the Nerd Font every row here is set in, and
// would come out as whatever the Nerd Font has at those code points.
//
// The write is `omarchy-mobile-agent open <name>` rather than
// `omarchy-default-agent <name>` for one reason: it writes the drawer tile
// first. An agent reachable only from this page is four taps deep and invisible
// in the grid, which is settings.md P and the whole of why that script exists.
// Everything after the tile is upstream's: omarchy-mobile-agent execs
// omarchy-default-agent, which installs through mise (or, for Hermes and
// OpenClaw, through their own installers), writes
// ~/.config/omarchy/defaults/agent and launches.
//
// One tile, not one per agent. omarchy-mobile-agent.desktop is REWRITTEN by
// every tap on this page -- name, icon and Exec -- so picking a second agent
// moves the tile rather than adding one. This page is also the only thing that
// keeps the tile honest: `omarchy-default-agent <name>` typed into a terminal
// sets the default without coming through here and leaves the tile naming the
// agent before it; `omarchy-mobile-agent entry` with no argument is the repair.
//
// The same thirteen, in the same order, are omarchy-mobile-agent's `agents()`
// and the thirteen agent icons in
// ~/.local/share/icons/hicolor/scalable/apps/omarchy-mobile-agent-*.svg. Three
// lists, and vm-selftest.sh asserts all three against upstream's own
// `omarchy:args=` line rather than against each other, so an agent upstream
// adds fails loudly here instead of quietly arriving with no icon.
"apps.default.agent": { title: "AI agent", reader: "omarchy-default-agent", rows: [
  { id: "how", type: "info", glyph: "\u{F06A9}", label: "Tap one to install it",
    detail: "The first run downloads the agent, then opens it" },
  { id: "claude", type: "choice", label: "Claude", value: "claude",
    write: "omarchy-mobile-agent open claude", covers: { "setup.default.agent.claude": "B" } },
  { id: "codex", type: "choice", label: "Codex", value: "codex",
    write: "omarchy-mobile-agent open codex", covers: { "setup.default.agent.codex": "B" } },
  { id: "copilot", type: "choice", label: "Copilot", value: "copilot",
    write: "omarchy-mobile-agent open copilot", covers: { "setup.default.agent.copilot": "B" } },
  { id: "crush", type: "choice", label: "Crush", value: "crush",
    write: "omarchy-mobile-agent open crush", covers: { "setup.default.agent.crush": "B" } },
  { id: "cursor-agent", type: "choice", label: "Cursor CLI", value: "cursor-agent",
    write: "omarchy-mobile-agent open cursor-agent",
    covers: { "setup.default.agent.cursor-agent": "B" } },
  { id: "gemini", type: "choice", label: "Gemini", value: "gemini",
    write: "omarchy-mobile-agent open gemini", covers: { "setup.default.agent.gemini": "B" } },
  { id: "grok", type: "choice", label: "Grok", value: "grok",
    write: "omarchy-mobile-agent open grok", covers: { "setup.default.agent.grok": "B" } },
  { id: "hermes", type: "choice", label: "Hermes", value: "hermes",
    write: "omarchy-mobile-agent open hermes", covers: { "setup.default.agent.hermes": "B" } },
  { id: "muse", type: "choice", label: "Muse Code", value: "muse",
    write: "omarchy-mobile-agent open muse", covers: { "setup.default.agent.muse": "B" } },
  { id: "omp", type: "choice", label: "omp", value: "omp",
    write: "omarchy-mobile-agent open omp", covers: { "setup.default.agent.omp": "B" } },
  { id: "openclaw", type: "choice", label: "OpenClaw", value: "openclaw",
    write: "omarchy-mobile-agent open openclaw", covers: { "setup.default.agent.openclaw": "B" } },
  { id: "opencode", type: "choice", label: "OpenCode", value: "opencode",
    write: "omarchy-mobile-agent open opencode", covers: { "setup.default.agent.opencode": "B" } },
  { id: "pi", type: "choice", label: "Pi", value: "pi",
    write: "omarchy-mobile-agent open pi", covers: { "setup.default.agent.pi": "B" } }
]},

"apps.webapps": { title: "Web apps", rows: [
  { id: "add", type: "action", glyph: "", label: "Add a web app",
    run: PRESENT + " omarchy-webapp-install",
    covers: { "install.webapp": "B" } },
  { id: "remove", type: "action", glyph: "\u{F0B4C}", label: "Remove a web app",
    when: "grep -qE '^Exec=.*(omarchy-launch-webapp|omarchy-webapp-handler)' $HOME/.local/share/applications/*.desktop",
    run: "omarchy-webapp-remove", covers: { "remove.webapp": "B" } }
]},

"apps.tuis": { title: "Terminal apps", rows: [
  { id: "add", type: "action", glyph: "", label: "Add a terminal app",
    run: PRESENT + " omarchy-tui-install",
    covers: { "install.tui": "B" } },
  { id: "remove", type: "action", glyph: "\u{F0B4C}", label: "Remove a terminal app",
    when: "grep -qE '^Exec=.*(\\$TERMINAL|xdg-terminal-exec).*-e' $HOME/.local/share/applications/*.desktop",
    run: "omarchy-tui-remove", covers: { "remove.tui": "B" } }
]},

// Upstream's strings, byte for byte. moarchy wrapped these three in the
// presentation terminal because its phone had no xdg-terminal-exec; this image
// does.
"apps.packages": { title: "Packages", rows: [
  { id: "install", type: "action", glyph: "\u{F08C7}", label: "Install a package",
    run: "xdg-terminal-exec --app-id=org.omarchy.terminal omarchy-pkg-install",
    covers: { "install.package": "B" } },
  // Guarded on yay, which is what the AUR picker searches and installs
  // through. It is not in this image (vm/packages/omitted), and without it the
  // picker opens on an empty list that cannot be filled.
  { id: "aur", type: "action", glyph: "\u{F08C7}", label: "Install from the AUR",
    when: "omarchy-cmd-present yay",
    run: "xdg-terminal-exec --app-id=org.omarchy.terminal omarchy-pkg-aur-install",
    covers: { "install.aur": "B" } },
  { id: "remove", type: "action", glyph: "\u{F0B4C}", label: "Remove a package",
    run: "xdg-terminal-exec --app-id=org.omarchy.terminal omarchy-pkg-remove",
    covers: { "remove.package": "B" } },
  { id: "more", type: "nav", page: "apps.packages.more", glyph: "\u{F03D3}", label: "More software" }
]},

// One row per install/remove pair. Upstream keeps two mirror trees only because
// each row is guarded on the complement of its twin, so at most one of a pair
// is ever visible -- two trees to show one row each is a dmenu artifact.
"apps.packages.more": { title: "More software",
  covers: { "install.browser": "N", "install.editor": "N", "install.terminal": "N",
            "remove.browser": "N" },
  rows: [
  { id: "firefox-install", type: "action", glyph: "", label: "Install Firefox",
    when: "! omarchy-pkg-present firefox",
    run: PRESENT + " 'omarchy-install-browser firefox'",
    covers: { "install.browser.firefox": "B" } },
  { id: "firefox-remove", type: "action", glyph: "", label: "Remove Firefox",
    when: "omarchy-pkg-present firefox",
    run: PRESENT + " 'omarchy-remove-browser firefox'",
    covers: { "remove.browser.firefox": "B" } },
  { id: "signal", type: "action", glyph: "\u{F0B79}", label: "Install Signal",
    when: "! omarchy-pkg-present signal-desktop",
    run: PRESENT + " omarchy-install-service-signal",
    covers: { "install.service.signal": "B" } },
  { id: "vim", type: "action", glyph: "", label: "Install Vim",
    when: "! omarchy-pkg-present vim", run: "omarchy-install-app Vim vim",
    covers: { "install.editor.vim": "B" } },
  { id: "helix", type: "action", glyph: "", label: "Install Helix",
    when: "! omarchy-pkg-present helix",
    run: PRESENT + " omarchy-install-editor-helix",
    covers: { "install.editor.helix": "B" } },
  { id: "kitty", type: "action", glyph: "", label: "Install Kitty",
    when: "! omarchy-pkg-present kitty",
    run: PRESENT + " 'omarchy-install-terminal kitty'",
    covers: { "install.terminal.kitty": "B" } },
  { id: "alacritty", type: "action", glyph: "", label: "Install Alacritty",
    when: "! omarchy-pkg-present alacritty",
    run: PRESENT + " 'omarchy-install-terminal alacritty'",
    covers: { "install.terminal.alacritty": "B" } },
  // Hidden while foot is installed, which is always on this image -- listed
  // because it is exactly the row that should come back if foot is removed.
  { id: "foot", type: "action", glyph: "", label: "Install Foot",
    when: "! omarchy-pkg-present foot",
    run: PRESENT + " 'omarchy-install-terminal foot'",
    covers: { "install.terminal.foot": "B" } }
]},

// -------------------------------------------------------------------- shell
"shell": { title: "Shell & plugins", rows: [
  { id: "plugins", type: "nav", page: "shell.plugins", glyph: "\u{F0431}", label: "Plugins",
    detailCmd: "omarchy-mobile-plugins summary",
    covers: { "setup.plugin": "N" } },
  // Upstream's restart, which moarchy had to replace because it reaches for
  // Hyprland's socket. Here that socket is the point. It takes this screen down
  // with the rest of the shell.
  { id: "restart", type: "action", glyph: "\u{F035C}", label: "Restart shell",
    detail: "Bar, shade, drawer and screens",
    run: "omarchy-restart-shell",
    covers: { "update.process.shell": "B", "update.process": "N" } },
  { id: "tmux", type: "action", glyph: "", label: "Reset tmux config",
    run: PRESENT + " omarchy-refresh-tmux",
    covers: { "update.config.tmux": "B", "update.config": "N" } }
]},

"shell.plugins": { title: "Plugins",
  // A list of switches instead of two launches of a select box, neither of
  // which showed what was already on (M1). Add, clone and remove stay bridged:
  // they are terminal work, not a switch (M6).
  provider: { json: "omarchy-mobile-plugins rows", before: true },
  covers: { "setup.plugin.enable": "N", "setup.plugin.disable": "N" },
  rows: [
  { id: "add", type: "action", glyph: "\u{F059F}", label: "Add a plugin",
    run: PRESENT + " 'omarchy-plugin-add'",
    covers: { "setup.plugin.add": "B" } },
  { id: "clone", type: "action", glyph: "\u{F018F}", label: "Clone a plugin",
    run: "omarchy-menu-plugin clone",
    covers: { "setup.plugin.clone": "B" } },
  // Upstream's guard matches this project's own plugin: mobile.shell lives in
  // ~/.config/omarchy/plugins, the one directory omarchy-plugin-remove works
  // in. So the row is there on every phone, and one wrong tap in its list
  // takes the whole phone UI away -- hence the question first.
  { id: "remove", type: "action", glyph: "\u{F0B4C}", label: "Remove a plugin",
    when: "compgen -G \"$HOME/.config/omarchy/plugins/*/manifest.json\"",
    confirm: "The phone UI is one of these plugins, mobile.shell. Removing it leaves desktop Omarchy.",
    run: "omarchy-menu-plugin remove",
    covers: { "setup.plugin.remove": "B" } }
]},

// ----------------------------------------------------------------- security
"security": { title: "Security", rows: [
  // Read natively, written through a terminal: the state is a systemctl
  // question, but the write asks questions of its own with gum (C8, C9).
  { id: "ssh", type: "switch", glyph: "\u{F08C0}", label: "Remote access (SSH)",
    read: "systemctl is-enabled --quiet sshd && echo true || echo false",
    on: PRESENT + " omarchy-setup-security-sshd",
    off: PRESENT + " omarchy-remove-security-sshd",
    covers: { "setup.security.sshd": "B", "remove.security.sshd": "B" } },
  // The same script on demand, because once the daemon is on the switch shows
  // ON and there is nothing left to tap -- which is the state a phone is in
  // when sshd came up and no key was ever authorized (O14). The detail answers
  // what the switch cannot, and a missing file counts 0 rather than blank (O15).
  { id: "sshkeys", type: "action", glyph: "\u{F0306}", label: "Authorize SSH keys",
    keywords: "github remote login publickey",
    detailCmd: "echo \"$(grep -c '^[a-z]' $HOME/.ssh/authorized_keys 2>/dev/null || echo 0) authorized\"",
    run: PRESENT + " omarchy-setup-security-sshd" },
  // vm/configure.sh already grants wheel NOPASSWD, so upstream's timed rule
  // changes nothing you can see. Kept because it covers the id, with the detail
  // saying why it looks inert.
  { id: "sudo", type: "action", glyph: "\u{F07F5}", label: "Passwordless sudo",
    detail: "Already on for this image",
    run: PRESENT + " omarchy-sudo-passwordless",
    covers: { "setup.security.passwordless-sudo": "B" } },
  // `sudo passwd`, not upstream's bare `passwd`: the image locks the account's
  // password, so `passwd` has no current password to check and fails on its
  // first question. Under sudo it sets one outright, and the NOPASSWD rule
  // means that costs no prompt. It is the only way to give the account a
  // password, which is what Lock needs before it is offered (system.power).
  { id: "passwd", type: "action", glyph: "", label: "Change password",
    run: PRESENT + " 'sudo passwd \"$USER\"'",
    covers: { "update.password.user": "B", "update.password": "N" } }
]},

// -------------------------------------------------------------------- tools
"tools": { title: "Tools", rows: [
  // `fullscreen`, where upstream's row says nothing and gets `smart`: a
  // region picker that wants a drag across the part to keep. A tap on a phone
  // means the screen. What it captures is this screen, which is the honest
  // outcome of a window photographing its own output.
  { id: "screenshot", type: "action", glyph: "", label: "Screenshot",
    keywords: "capture grab screen",
    run: "omarchy-capture-screenshot fullscreen",
    covers: { "trigger.capture.screenshot": "B", "trigger.capture": "N" } },
  { id: "record", type: "nav", page: "tools.record", glyph: "", label: "Screen record",
    when: "omarchy-cmd-present gpu-screen-recorder",
    covers: { "trigger.capture.screenrecord": "N" } },
  { id: "emoji", type: "action", glyph: "", label: "Emoji",
    run: "omarchy-menu-emoji", covers: { "trigger.emoji": "B" } },
  // `trigger.reminder.show` is this row: the page is the list, so opening it
  // is the whole of showing them (J1).
  { id: "reminders", type: "nav", page: "tools.reminders", glyph: "\u{F088C}", label: "Reminders",
    keywords: "timer alarm",
    detailCmd: "omarchy-mobile-reminders summary",
    covers: { "trigger.reminder": "N", "trigger.reminder.show": "N" } },
  { id: "tests", type: "nav", page: "tools.tests", glyph: "\u{F04C5}", label: "Speed tests",
    covers: { "trigger.tests": "N" } }
]},

"tools.record": { title: "Screen record", rows: [
  { id: "stop", type: "action", glyph: "", label: "Stop recording",
    when: "pgrep -f '^gpu-screen-recorder'",
    run: "omarchy-capture-screenrecording --stop-recording",
    covers: { "trigger.capture.screenrecord.stop": "B" } },
  { id: "silent", type: "action", glyph: "", label: "Record with no audio",
    run: "omarchy-capture-screenrecording",
    covers: { "trigger.capture.screenrecord.no-audio": "B" } },
  { id: "desktop-audio", type: "action", glyph: "", label: "Record with desktop audio",
    run: "omarchy-capture-screenrecording --with-desktop-audio",
    covers: { "trigger.capture.screenrecord.desktop-audio": "B" } }
]},

// Upstream's three reminder rows are a command line wearing a menu: `-i` wants
// a number typed then Return, and `show` and `clear` answer in a notification.
// settings.md J is what they are instead. The list comes back as rows because
// each carries its own cancel command; `before` puts them above the two
// declared rows.
"tools.reminders": { title: "Reminders",
  provider: { json: "omarchy-mobile-reminders rows", before: true },
  rows: [
  { id: "new", type: "nav", page: "tools.reminders.new", glyph: "\u{F0415}",
    label: "Set a reminder", covers: { "trigger.reminder.set": "N" } },
  // Guarded on there being something to clear, so it is not offered as a
  // no-op (J5), and inline because it runs where it stands (J6).
  { id: "clear", type: "action", glyph: "\u{F0156}", label: "Clear all",
    when: "[ \"$(omarchy-mobile-reminders count)\" -gt 0 ]",
    confirm: "Clear every reminder?",
    run: "omarchy-reminder clear", launch: "inline",
    covers: { "trigger.reminder.clear": "N" } }
]},

// Presets first, because a thumb wants one tap, then the pair that takes any
// duration. Every row runs `omarchy-mobile-reminders set <minutes> <message>`,
// and an empty message arrives as an empty argument rather than not at all.
"tools.reminders.new": { title: "Set a reminder", rows: [
  { id: "message", type: "input", glyph: "\u{F0B79}", label: "Message",
    placeholder: "Message (optional)" },
  { id: "m5",   type: "action", glyph: "\u{F088C}", label: "In 5 minutes",
    run: "omarchy-mobile-reminders set 5",   argsFrom: ["message"], launch: "inline", back: true },
  { id: "m10",  type: "action", glyph: "\u{F088C}", label: "In 10 minutes",
    run: "omarchy-mobile-reminders set 10",  argsFrom: ["message"], launch: "inline", back: true },
  { id: "m15",  type: "action", glyph: "\u{F088C}", label: "In 15 minutes",
    run: "omarchy-mobile-reminders set 15",  argsFrom: ["message"], launch: "inline", back: true },
  { id: "m30",  type: "action", glyph: "\u{F088C}", label: "In 30 minutes",
    run: "omarchy-mobile-reminders set 30",  argsFrom: ["message"], launch: "inline", back: true },
  { id: "m45",  type: "action", glyph: "\u{F088C}", label: "In 45 minutes",
    run: "omarchy-mobile-reminders set 45",  argsFrom: ["message"], launch: "inline", back: true },
  { id: "m60",  type: "action", glyph: "\u{F088C}", label: "In 1 hour",
    run: "omarchy-mobile-reminders set 60",  argsFrom: ["message"], launch: "inline", back: true },
  { id: "m120", type: "action", glyph: "\u{F088C}", label: "In 2 hours",
    run: "omarchy-mobile-reminders set 120", argsFrom: ["message"], launch: "inline", back: true },
  { id: "minutes", type: "input", glyph: "\u{F0150}", label: "Minutes",
    placeholder: "Minutes", numeric: true },
  // Dimmed and inert until the field above holds something (J8). The script
  // validates the number too -- this is the affordance, not the check.
  { id: "custom", type: "action", glyph: "\u{F012C}", label: "Set reminder",
    run: "omarchy-mobile-reminders set", argsFrom: ["minutes", "message"],
    requires: "minutes", launch: "inline", back: true }
]},

"tools.tests": { title: "Speed tests", rows: [
  { id: "network", type: "action", glyph: "\u{F04C5}", label: "Network speed test",
    run: "omarchy-shell shell summon omarchy.speedtest",
    covers: { "trigger.tests.network-speedtest": "B" } },
  { id: "disk", type: "action", glyph: "\u{F02CA}", label: "Disk speed test",
    run: "omarchy-shell shell summon omarchy.disk-speedtest",
    covers: { "trigger.tests.disk-speedtest": "B" } }
]},

// ------------------------------------------------------------------- system
"system": { title: "System", rows: [
  { id: "time", type: "nav", page: "system.time", glyph: "", label: "Date & time" },
  { id: "hardware", type: "nav", page: "system.hardware", glyph: "\u{F01C5}",
    label: "Restart hardware", covers: { "update.hardware": "N" } },
  // No `covers`: this is not upstream's `update.omarchy`, which wants
  // pkgs.omarchy.org's aarch64 tree (a 404) and snapshots. It is the plain
  // upgrade, and claiming the id would promise what that script does.
  { id: "update", type: "action", glyph: "\u{F06B0}", label: "Update system",
    keywords: "upgrade pacman packages",
    detail: "pacman -Syu in a terminal",
    run: "sudo pacman -Syu", launch: "tui" },
  { id: "power", type: "nav", page: "system.power", glyph: "\u{F0425}", label: "Power" }
]},

"system.time": { title: "Date & time", rows: [
  { id: "zone", type: "nav", page: "system.time.zone", glyph: "\u{F05F0}",
    label: "Time zone", detailCmd: "omarchy-mobile-timezone current",
    covers: { "update.timezone": "N" } },
  { id: "time", type: "action", glyph: "", label: "Set the time",
    run: PRESENT + " omarchy-update-time",
    covers: { "update.time": "B" } }
]},

// Region, then city: two taps down a list you can read, instead of a filter
// field over four hundred entries (L1). UTC is a choice and not a region,
// because timedatectl lists it flat (L4). The region rows are generated below.
"system.time.zone": { title: "Time zone",
  reader: "omarchy-mobile-timezone current",
  rows: [
  { id: "utc", type: "choice", glyph: "\u{F0954}", label: "UTC", value: "UTC",
    write: "omarchy-mobile-timezone set UTC" }
]},

"system.hardware": { title: "Restart hardware", rows: [
  { id: "audio", type: "action", glyph: "", label: "Audio",
    run: PRESENT + " omarchy-restart-audio",
    covers: { "update.hardware.audio": "B" } },
  { id: "wifi", type: "action", glyph: "\u{F16BE}", label: "Wi-Fi",
    run: PRESENT + " omarchy-restart-wifi",
    covers: { "update.hardware.wifi": "B" } },
  { id: "bluetooth", type: "action", glyph: "\u{F00AF}", label: "Bluetooth",
    run: PRESENT + " omarchy-restart-bluetooth",
    covers: { "update.hardware.bluetooth": "B" } }
]},

"system.power": { title: "Power", rows: [
  // Offered only when the account has a password that works. Upstream's lock
  // is the shell's own lock screen, which asks PAM, and this image ships the
  // account with a LOCKED password (`passwd -S` reads L): a lock nobody can
  // lift, over a session you then reach only by ssh. Change password on
  // Security is how a phone earns this row.
  { id: "lock", type: "action", glyph: "", label: "Lock",
    when: "[[ $(passwd -S \"$USER\" 2>/dev/null | awk '{print $2}') == P ]]",
    run: "omarchy-system-lock", covers: { "system.lock": "B" } },
  { id: "logout", type: "action", glyph: "\u{F0343}", label: "Log out",
    confirm: "Log out of the session? The phone logs straight back in.",
    run: "omarchy-system-logout", covers: { "system.logout": "B" } },
  { id: "reboot", type: "action", glyph: "\u{F0709}", label: "Restart",
    confirm: "Restart the phone?",
    run: "omarchy-system-reboot", covers: { "system.reboot": "B" } },
  { id: "shutdown", type: "action", glyph: "\u{F0425}", label: "Power off",
    confirm: "Power off the phone?",
    run: "omarchy-system-shutdown", covers: { "system.shutdown": "B" } }
]},

// -------------------------------------------------------------------- about
"about": { title: "About phone", rows: [
  { id: "version", type: "info", glyph: "", label: "Omarchy",
    read: "omarchy-mobile-about omarchy" },
  { id: "kernel", type: "info", glyph: "\u{F0322}", label: "Kernel", read: "uname -r" },
  { id: "device", type: "info", glyph: "\u{F0124}", label: "Device",
    read: "omarchy-mobile-about device" },
  { id: "keys", type: "nav", page: "about.keys", glyph: "", label: "Keybindings",
    covers: { "learn.keybindings": "N" } },
  { id: "help", type: "nav", page: "about.help", glyph: "\u{F09D1}", label: "Help & docs" },
  // A page of rows, not fastfetch in a terminal that re-measures itself on
  // every resize (N1).
  { id: "aboutomarchy", type: "nav", page: "about.omarchy", glyph: "\u{F02FD}",
    label: "About Omarchy", covers: { "about": "N" } }
]},

// A text page. Upstream's learn.keybindings opens the list in a picker; here it
// is rows, what each binding does first and its keys under it.
"about.keys": { title: "Keybindings", text: "omarchy-menu-keybindings --print", rows: [] },

"about.omarchy": { title: "About Omarchy",
  provider: { json: "omarchy-mobile-about rows" },
  rows: [] },

"about.help": { title: "Help & docs", rows: [
  { id: "manual", type: "link", glyph: "", label: "Omarchy manual",
    url: "https://omarchy.org/manual/", covers: { "learn.omarchy": "B" } },
  // Back on Hyprland, so back in the list: moarchy dropped it because its
  // compositor was Sway.
  { id: "hyprland", type: "link", glyph: "", label: "Hyprland wiki",
    url: "https://wiki.hypr.land/", covers: { "learn.hyprland": "B" } },
  { id: "arch", type: "link", glyph: "\u{F08C7}", label: "Arch wiki",
    url: "https://wiki.archlinux.org/title/Main_page", covers: { "learn.arch": "B" } },
  { id: "bash", type: "link", glyph: "\u{F1183}", label: "Bash",
    url: "https://devhints.io/bash", covers: { "learn.bash": "B" } },
  { id: "neovim", type: "link", glyph: "", label: "Neovim",
    url: "https://www.lazyvim.org/keymaps", covers: { "learn.neovim": "B" } },
  { id: "tmux", type: "action", glyph: "", label: "Tmux keybindings",
    run: "omarchy-menu-tmux-keybindings",
    covers: { "learn.tmux-keybindings": "B" } },
  { id: "community", type: "action", glyph: "\u{F066F}", label: "Community",
    run: "omarchy-launch-discord-community",
    covers: { "learn.community": "B" } }
]}

};

// The tzdata areas. Static, because a page id has to exist here before
// anything can navigate to it -- a provider cannot invent a destination.
var TZ_REGIONS = ["Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic",
                  "Australia", "Europe", "Indian", "Pacific", "Etc"];

for (var _t = 0; _t < TZ_REGIONS.length; _t++) {
    var _region = TZ_REGIONS[_t];
    PAGES["system.time.zone"].rows.push(
        // `unlisted`, so the drawer's search does not answer "a" with Asia,
        // Africa, Arctic and America. The page each of these opens is built by
        // the provider below, and provider rows are not in the search index by
        // design (Search.js, O10) -- so these lead only where search cannot
        // follow. Findable by walking Settings, which is how a region was ever
        // meant to be reached.
        { id: "r" + _t, type: "nav", page: "system.time.zone." + _region,
          glyph: "\u{F05F0}", label: _region, unlisted: true });
    // `label: "city"` keeps the whole zone as the row's value -- what
    // timedatectl takes and what the reader answers -- while showing the half
    // a person is looking for (L2).
    PAGES["system.time.zone." + _region] = {
        title: _region,
        reader: "omarchy-mobile-timezone current",
        provider: { list: "timedatectl list-timezones | grep '^" + _region + "/'",
                    label: "city" },
        write: "omarchy-mobile-timezone set",
        rows: []
    };
}

function page(id) { return PAGES[id] || null; }
function exists(id) { return !!PAGES[id]; }

function ids() {
    var out = [];
    for (var id in PAGES) out.push(id);
    return out;
}

// The coverage map, emitted over IPC. Rows first, then the page-level `covers`
// some container ids hang off, then the ids satisfied outside this stack.
function coverage() {
    var out = [];
    for (var pid in PAGES) {
        var p = PAGES[pid];
        if (p.covers)
            for (var c in p.covers) out.push([c, p.covers[c], pid, ""]);
        for (var i = 0; i < p.rows.length; i++) {
            var r = p.rows[i];
            if (!r.covers) continue;
            for (var id in r.covers) out.push([id, r.covers[id], pid, r.id]);
        }
    }
    for (var e in EXTERNAL) out.push([e, EXTERNAL[e].cls, EXTERNAL[e].where, ""]);
    for (var s in SHADE) out.push([s, "S", SHADE[s], ""]);
    return out;
}
