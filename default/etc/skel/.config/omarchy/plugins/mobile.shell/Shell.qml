// The phone shell: the status bar, the shade, the bottom edge, the recents
// carousel, the home screen, the app drawer and the screens that are windows,
// as one Omarchy shell plugin.
//
// Implements docs/spec/gestures.md, docs/spec/shade.md and
// docs/spec/settings.md. AC ids in comments refer to those files, which are the
// contract; docs/acceptance.md says which of them hold here.
//
// ---------------------------------------------------------------------------
// Why one plugin
// ---------------------------------------------------------------------------
// Omarchy 4.0.3 sandboxes an installed plugin. Its `shell` is a facade whose
// summon/hide accept only the plugin's OWN id, with no panelLoaders and no
// callIfLoaded. moarchy splits its UI into nine plugins that drive each other
// frame by frame, which only works because it patches shell.qml to hand its
// own namespace the trusted host. This project does not patch the host, so
// everything that has to talk to everything else lives in one scope.
//
// Hyprland arrives at the same layout from the other side. It does not hold
// the implicit pointer grab across a layer surface's edge, so the surface that
// owns a gesture has to be as large as the gesture; and a surface holding
// exclusive keyboard focus takes every pointer event, which would deafen every
// edge whenever a sheet is up. One surface per edge, each driving its sheet
// directly, is what both facts leave (README, "What Hyprland does differently
// from Sway here").
//
// The files split for reading, not for isolation:
//
//   Bar.qml           the status bar -- this plugin's other entry point
//   Shade.qml         the pull-down from the bar
//   EdgeGestures.qml  the strip, the home screen, and the gestures on both
//   Carousel.qml      recent apps
//   AppDrawer.qml     the app grid
//   WifiScreen.qml, BluetoothScreen.qml, SettingsScreen.qml
//                     screens that are windows (gestures.md K), each through
//                     MobileAppWindow.qml. Settings' pages are data, in
//                     Pages.js, drawn by SettingsRow.qml and read by Guards.js
//
// ---------------------------------------------------------------------------
// Why kinds "menu" and "bar"
// ---------------------------------------------------------------------------
// "menu" is the kind that gets an application library: shell.qml hands the
// appLibrary facade to a plugin whose manifest declares it and to no other
// (patches/plugin-manifest-kinds.patch is what makes it keep that promise to a
// third-party plugin at all).
//
// "bar" makes this plugin a bar option, selected by shell.json's `bar.id`, and
// the host gives a bar-kind plugin two things the shade needs: first-party
// service proxies (Do Not Disturb, the media player) and leave to summon any
// other plugin, which a Settings row falls back on for a surface that is not
// one of this shell's own. Both come with the manifest, so the menu instance
// below has them too.
//
// It also makes `bar.id` the one switch for the whole phone UI: the host
// enables a bar-kind plugin exactly when `bar.id` names it, for every entry
// point it has. Point it back at omarchy.bar and this is stock desktop Omarchy.
//
// ---------------------------------------------------------------------------
// IPC targets
// ---------------------------------------------------------------------------
// `gestures`, `recents`, `drawer`, `shade`, `bar`, `wifi`, `bluetooth` and
// `settings` -- moarchy's names, so every check moarchy's spec writes as
// `omarchy-shell recents state` runs here verbatim.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  // Injected by the host in the panel Loader's onLoaded. None of these may be
  // `readonly` or `required`: a plugin is created first and configured
  // afterwards, so readonly makes the assignment throw and required makes the
  // component fail to instantiate. Either way it fails silently.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property var service: null

  readonly property var apps: root.shell ? root.shell.appLibrary : null

  // ------------------------------------------------- name -> desktop entry
  //
  // appLibrary turns an icon name into a source but has no lookup by id, so
  // the index is built once and rebuilt when the app list moves -- scanning
  // sortedEntries() per card would be O(apps) per card per frame. Here rather
  // than in Carousel.qml, where it started, because a notification names its
  // sender too, and the shade takes a card's icon from the same index.
  property var entryIndex: ({})

  function buildEntryIndex(): void {
    var map = ({})
    if (!root.apps) { root.entryIndex = map; return }
    var rows = root.apps.sortedEntries("")
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      if (!entry) continue
      var id = String(entry.id || "").toLowerCase().replace(/\.desktop$/, "")
      if (!id) continue
      if (map[id] === undefined) map[id] = entry
      // An app often reports only the last segment of a reverse-DNS desktop
      // id as its app id -- org.gnome.Papers runs as "papers". Index both;
      // first writer wins, so an exact match is never displaced by a suffix.
      var tail = id.split(".").pop()
      if (tail && map[tail] === undefined) map[tail] = entry
    }
    // A notification's app name is usually the display name -- "Firefox",
    // not "firefox.desktop" -- so names go in too, after every id, so that
    // no name can displace one.
    for (var j = 0; j < rows.length; j++) {
      var named = rows[j].entry
      var name = named ? String(named.name || "").toLowerCase() : ""
      if (name && map[name] === undefined) map[name] = named
    }
    root.entryIndex = map
  }

  Connections {
    target: root.apps
    function onAppsChanged() { root.buildEntryIndex() }
  }

  onAppsChanged: root.buildEntryIndex()

  // An app id or an app name, in any case; null for anything unknown.
  function entryFor(name) {
    if (!name) return null
    var e = root.entryIndex[String(name).toLowerCase()]
    return e === undefined ? null : e
  }

  // Deep enough to hit without looking, shallow enough that it rarely lands on
  // an app's own bottom controls. Through Style.space like every other length
  // here, so a theme's spacing scale moves it with the rest of the shell.
  readonly property int stripHeight: Style.space(20)

  // ------------------------------------------------------- the host contract
  //
  // shell.isPluginOpen() reads `opened` by name, and summon/hide arrive as
  // open()/close(). A summon names the sheet in its payload --
  // `{"surface": "recents"}` or `"shade"` -- and defaults to the drawer, which
  // is what a keybinding for "the launcher" means. A screen's summon may also
  // carry `returnTo` and, for Settings, `page`.
  readonly property bool opened: drawer.opened || carousel.opened || shade.opened

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (e) { payload = ({}) }
    if (payload.surface === "recents") {
      // A9. The carousel has no empty state, so there is nothing to summon.
      if (root.hasApps()) carousel.open()
    } else if (payload.surface === "shade") {
      shade.open()
    } else if (payload.surface === "wifi" || payload.surface === "bluetooth"
               || payload.surface === "settings") {
      root.openScreen(payload.surface, payload.returnTo || "", payload.page || "")
    } else {
      drawer.open()
    }
  }

  function close() {
    root.hideSheets()
  }

  // ------------------------------------------------------------ compositor
  //
  // Hyprland 0.56 is configured in Lua and parses a dispatch the same way:
  // `dispatch <request>` is evaluated as `return hl.dispatch(<request>)`, so
  // the legacy `workspace 3` is a Lua syntax error and the request has to be
  // an hl.dsp expression. Measured with hyprctl:
  //
  //   $ hyprctl dispatch workspace 3
  //   error: [string "return hl.dispatch(workspace 3)"]:1: ')' expected near '3'
  //
  // Through Quickshell's socket rather than a forked hyprctl: this runs at the
  // end of a gesture, which is the one moment a fork would be felt.
  function dispatch(request: string): void {
    Hyprland.dispatch(request)
  }

  function focusWorkspace(selector: string): void {
    root.dispatch('hl.dsp.focus({ workspace = "' + selector + '" })')
  }

  // Every window, from the foreign-toplevel list the carousel reads too, so
  // "is anything open" has one answer everywhere.
  function hasApps(): bool {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    return list.length > 0
  }

  // E2, K12. Focus a window, through Hyprland's own dispatcher by address.
  //
  // Not the foreign-toplevel activate() request on its own, which is what this
  // was. It works for anybody else's window -- tapping foot's card focused
  // foot -- and does nothing for this shell's OWN windows: summoning the Wi-Fi
  // screen while Bluetooth was focused left Bluetooth focused, with the handle
  // resolved and no warning anywhere. (moarchy's Sway ignored activate() for
  // every window, and moarchy rebuilt focusing as a criteria dispatch for the
  // same reason.) The address is the compositor's own name for the window, so
  // one path now serves every card and every screen. activate() stays as the
  // fallback for a handle Hyprland has not reported an address for yet.
  function focusToplevel(tl): void {
    if (!tl) return
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var h = list[i]
      if (!h || h.wayland !== tl) continue
      var addr = String(h.address || "")
      if (addr === "") break
      if (addr.indexOf("0x") !== 0) addr = "0x" + addr
      root.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
      return
    }
    tl.activate()
  }

  // F1. Hyprland's own "empty" selector is this rule: the lowest-numbered
  // workspace with nothing on it. moarchy computes it twice, in QML and in
  // Python, and records the two ways they drifted apart; here it is one word
  // the compositor evaluates, and the window rule in hypr/mobile.lua is the
  // same word, so going home and launching an app cannot disagree about which
  // workspace is free.
  //
  // From a home screen it is a no-op -- the workspace you are on is the lowest
  // empty one -- so there is no "am I already home" test to get wrong.
  function goHome(): void {
    root.focusWorkspace("empty")
  }

  // B1, B3. The sheets are put away before the workspace moves, because a
  // sheet left standing while the workspace changes underneath is a gesture
  // that visibly does nothing and silently does something.
  //
  // `e+1` is the next workspace that exists, wrapping -- the order the strip
  // walks, and the one upstream binds to its own next/previous keys.
  function switchWorkspace(direction: string): void {
    root.hideSheets()
    root.focusWorkspace(direction === "next" ? "e+1" : "e-1")
  }

  // Only one sheet is up at a time. Every sheet's open() calls this with its
  // own name, so the rule lives in one place rather than in each sheet naming
  // the others.
  function closeOthers(keep: string): void {
    if (keep !== "shade" && (shade.opened || shade.progress > 0)) shade.close()
    if (keep !== "drawer" && (drawer.opened || drawer.progress > 0)) drawer.dismiss()
    if (keep !== "recents" && (carousel.opened || carousel.progress > 0)) carousel.close()
  }

  function hideSheets(): void {
    root.closeOthers("")
  }

  // A7, A8. Put away whatever is covering the screen, and nothing else. Never
  // opens anything: an up-flick from the strip means "get me out of here".
  // The shade first, because it can be pulled down over either of the others.
  function clearTopmost(): bool {
    if (shade.opened || shade.progress > 0) { shade.close(); return true }
    if (drawer.opened || drawer.progress > 0) { drawer.dismiss(); return true }
    if (carousel.opened) { carousel.close(); return true }
    return false
  }

  // S6b, S6d, K10. The screens that are windows: Wi-Fi, Bluetooth and
  // Settings. `returnTo` is where each one's back chevron goes afterwards --
  // the shade, when its long press is what opened Wi-Fi; Settings, when one of
  // its rows did. `page` is Settings' alone, and names the page to open at.
  readonly property var screens: [wifiScreen, bluetoothScreen, settingsScreen]

  function openScreen(name, returnTo, page): bool {
    var s = name === "wifi" ? wifiScreen
          : name === "bluetooth" ? bluetoothScreen
          : name === "settings" ? settingsScreen : null
    if (!s) return false
    s.open(JSON.stringify({ returnTo: returnTo || "", page: page || "" }))
    return true
  }

  // K5, K9. The screen whose window this toplevel is, or null for anybody
  // else's window. Compared on the handle, which each window resolves once for
  // itself (MobileAppWindow.qml), rather than on the title a second time.
  function screenForToplevel(tl) {
    if (!tl) return null
    for (var i = 0; i < root.screens.length; i++)
      if (root.screens[i].appWindow.toplevel === tl) return root.screens[i]
    return null
  }

  // The strip's logic, for a sheet that has to deliver a strip gesture itself
  // because it is on top of the edge surface (Shade.qml, A8).
  readonly property var gestures: edgeGestures

  // ------------------------------------------------------------- the pieces
  AppDrawer {
    id: drawer
    host: root
  }

  Carousel {
    id: carousel
    host: root
  }

  Shade {
    id: shade
    host: root
  }

  WifiScreen {
    id: wifiScreen
    host: root
  }

  BluetoothScreen {
    id: bluetoothScreen
    host: root
  }

  SettingsScreen {
    id: settingsScreen
    host: root
  }

  // Not `Edges`, which is what this file was first called. Quickshell exports
  // an uncreatable `Edges` enum, and an explicit import outranks a file in the
  // plugin's own directory, so the whole plugin failed to load with
  // "Element is not creatable" pointing at this line.
  EdgeGestures {
    id: edgeGestures
    host: root
    drawer: drawer
    carousel: carousel
    shade: shade
  }
}
