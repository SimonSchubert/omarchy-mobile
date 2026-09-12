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
//   Splash.qml        the launching app's icon, from the tap to its window
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
// `gestures`, `recents`, `drawer`, `splash`, `shade`, `bar`, `wifi`,
// `bluetooth` and `settings` -- moarchy's names, so every check moarchy's spec
// writes as `omarchy-shell recents state` runs here verbatim.
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
    // A window's class need not be its desktop id. A web app arrives as
    // org.gnome.Epiphany.WebApp_<host>, which is nothing like the `X` or
    // `Spotify` its entry is called (the entries say so themselves, in
    // StartupWMClass), and Quickshell hands that key over as `startupClass`.
    // After every id, because an id is the app naming itself and this is the
    // app naming its window; before every display name, because a class
    // answers "which app is this window" and a name only answers "who sent
    // this notification".
    for (var k = 0; k < rows.length; k++) {
      var classed = rows[k].entry
      var cls = classed ? String(classed.startupClass || "").toLowerCase() : ""
      if (cls && map[cls] === undefined) map[cls] = classed
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

  // ------------------------------------------------------------- launching
  //
  // windows.md L1. Every launch this shell makes goes through here, so that
  // every one of them gets the splash: the drawer's grid, its search field,
  // its `launch` IPC -- which is the store's Open (L9) -- and a tap on a
  // notification card from an app with no window (shade.md S27).
  //
  // The splash opens BEFORE the library is asked, not after: `launch` forks
  // gtk-launch through uwsm-app, and the icon is meant to be on screen in the
  // frame the tap produced rather than in the one the fork returns in.
  //
  // `entry` is the desktop entry when the caller has one, which is where both
  // the icon and the name come from; `desktopId` is for the one caller that
  // does not -- `drawer launch` with an id the grid lists no entry for, which
  // the library is asked to launch anyway. That one gets L7's outline.
  function launchApp(entry, desktopId): void {
    if (!root.apps) return
    var id = String((entry ? entry.id : desktopId) || "")
    if (!id) return
    splash.begin(entry ? root.apps.iconSource(entry.icon) : "", id)
    root.apps.launch(id, entry ? root.apps.entryName(entry) : id)
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

  // The focused window: what a back gesture would close (G4), and what the
  // strip's band asks about to decide whether to fill itself (I1a).
  //
  // NOT ToplevelManager.activeToplevel on its own. moarchy records it reading
  // null with a window plainly focused, while `toplevels` was populated the
  // whole time, and the back gesture then found nothing and closed nothing. The
  // per-toplevel `activated` flag is the one that demonstrably tracks focus --
  // it is what puts the accent border on the right card in the carousel. So
  // prefer the singleton when it answers and fall back to the flag that works.
  //
  // One definition, in one place, because the two callers must never disagree:
  // a band that fills for a window the back gesture cannot find is the same
  // fault reported twice, and a second copy of this walk is how it would start.
  function focusedToplevel() {
    if (ToplevelManager.activeToplevel) return ToplevelManager.activeToplevel
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].activated) return list[i]
    return null
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
  //
  // F3. The keyboard goes with the app: a home screen has nothing to type
  // into. On Sway it failed to go *down* rather than popping up -- the app got
  // its text-input leave, but an empty workspace has no window to take the
  // input state over, so nothing lowered it. Here it does pop up: leaving one
  // of this shell's own windows for an empty workspace activates a text input
  // after the switch, so a hide sent before it is undone (see
  // retreatKeyboard). Unconditional, as moarchy's is: SetVisible false on a
  // keyboard already down does nothing, and asking first would put a DBus
  // round trip on the one gesture that has to feel instant.
  function goHome(): void {
    root.retreatKeyboard()
    root.focusWorkspace("empty")
  }

  // ------------------------------------------------------ on-screen keyboard
  //
  // moarchy-keyboard, started from hypr/mobile.lua. It raises itself when a
  // text field takes focus and retracts when focus leaves one; what is left to
  // the shell is putting it away where Wayland says nothing (F3, I5d).
  //
  // It owns sm.puri.OSK0, Phosh's interface, so this is the same call
  // omarchy-mobile-toggle-keyboard makes. Fire-and-forget: nothing here needs
  // the answer, and it runs at the end of gestures.
  function hideKeyboard(): void {
    Quickshell.execDetached(["busctl", "--user", "call", "sm.puri.OSK0",
                             "/sm/puri/OSK0", "sm.puri.OSK0", "SetVisible",
                             "b", "false"])
  }

  // F3, I5d. Put the keyboard away now, and again if it comes up within the
  // next second.
  //
  // Hiding once is not enough on Hyprland, because what raises the keyboard
  // arrives after the hide. Going home from Settings, a text input activated
  // after the switch, with the hide already sent; closing the drawer over a
  // terminal, the terminal got the seat's keyboard back and its text input
  // re-entered 132ms after the close. moarchy answers the second with a hide
  // 250ms later, and a fixed delay is a race: the same close failed 6 of 6 in
  // one run. So the second hide is not timed. It answers the raise itself,
  // read off the home surface's height, which drops when the keyboard's zone
  // arrives. The second is how long to keep answering.
  //
  // The cost is that a field tapped within that second has its keyboard put
  // away, and is tapped again -- the trade F3 and I5d already make.
  function retreatKeyboard(): void {
    root.hideKeyboard()
    keyboardRetreat.restart()
  }

  Timer {
    id: keyboardRetreat
    interval: 1000
  }

  Connections {
    target: edgeGestures
    function onKeyboardUpChanged() {
      if (edgeGestures.keyboardUp && keyboardRetreat.running) root.hideKeyboard()
    }
  }

  // What the keyboard's panel reserves at the bottom when it is up: its own
  // default, in logical px, and deliberately not through Style.space -- it is
  // another client's height, and that client never sees this theme's spacing.
  // Only ever used as half of a threshold (I1a, I5e), so it has to be nowhere
  // near either height it separates rather than exact.
  readonly property int keyboardPanelHeight: 200

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

  // G1. The back gesture: undo the topmost thing on screen, and undo exactly
  // one of them.
  //
  //   1. the on-screen keyboard   G2
  //   2. any open sheet           G3
  //   3. the focused window       K7 walks its pages first if it is one of
  //                               ours, then G4 asks it to close
  //   4. nothing                  G5, on a bare home screen
  //
  // Here rather than in EdgeGestures because this is the file that owns the
  // sheets and the windows. The edge surface only decides that a swipe
  // happened.
  //
  // Whether the keyboard is up is read off this shell's own surface and not
  // from sm.puri.OSK0. moarchy asks the bus -- a probe started on press and
  // read on release, with a retry budget and a warm-up for the answer that has
  // not arrived yet, and a branch that takes the keyboard fork anyway when it
  // never does. I1a is why none of that is here: the bus property is stale
  // between gestures and has been seen reading `Visible true` with nothing
  // drawn, while a surface the compositor has resized cannot be wrong about
  // it. The answer is synchronous, so there is no unknown to guess at.
  function performBack(): void {
    // G2. The keyboard, and nothing else. Not retreatKeyboard(): its second
    // hide answers a raise that a *focus change* provokes, and back changes no
    // focus -- arming it here would put away a keyboard the user summoned again
    // within the second, which is more than "dismisses the keyboard and changes
    // nothing else" allows.
    if (edgeGestures.keyboardUp) { root.hideKeyboard(); return }

    // G3
    if (root.backTopmost()) return

    // K7. A shell app owns a page stack, and back walks up it before leaving
    // the window. Asked of the *focused window* and not of a list of open
    // screens: a screen is a window (K1), so "which one am I in" is the same
    // question G4 asks below, and asking it here is what keeps back inside
    // Settings from falling through to closing the app on the workspace beside
    // it.
    //
    // goBack() answers true when it consumed the gesture; false means there is
    // nothing left, and the window takes G4's close request like any other.
    var tl = root.focusedToplevel()
    var own = root.screenForToplevel(tl)
    if (own && typeof own.goBack === "function" && own.goBack() === true) return

    // G4, G7. close() is xdg_toplevel.close -- a close *request*, so an editor
    // with unsaved work prompts rather than dies. That is what makes firing it
    // from a swipe acceptable at all.
    //
    // K6. For one of this shell's own screens it is also exactly what the
    // carousel's card flick sends, so the two ways out of a screen are one
    // mechanism rather than two that have to be kept agreeing.
    //
    // G5. A bare home screen has nothing focused, so this is where back stops.
    if (tl) tl.close()
  }

  // G3. The sheets, topmost first, with a page stack getting first refusal:
  // goBack() answers true when it consumed the gesture, false when there is
  // nothing left to go back to and the sheet itself should go.
  //
  // The same order clearTopmost() walks, and deliberately not the same
  // function. An up-flick means "get me out of here" and never walks a stack
  // (A7, A8); back means "up one level" and always does. The carousel is also
  // asked a different question there, because a strip drag may have it part-way
  // up and clearing it mid-drag is what A6 exists to prevent.
  function backTopmost(): bool {
    if (shade.opened || shade.progress > 0) { shade.close(); return true }
    if (drawer.opened || drawer.progress > 0) {
      if (drawer.goBack()) return true
      drawer.dismiss()
      return true
    }
    if (carousel.opened || carousel.progress > 0) { carousel.close(); return true }
    return false
  }

  // S6b, S6d, K10. The screens that are windows: Wi-Fi, Bluetooth and
  // Settings. `returnTo` is where each one's back chevron goes afterwards --
  // the shade, when its long press is what opened Wi-Fi; Settings, when one of
  // its rows did. `page` is Settings' alone, and names the page to open at.
  readonly property var screens: [wifiScreen, bluetoothScreen, settingsScreen]

  // `extra` is the rest of the payload, for the one caller that needs more than
  // a page: the drawer's search asks Settings to fire a row without showing
  // itself (`activate` and `quiet`, settings.md O4). Optional, so the three
  // callers that want a page and nothing else are unchanged.
  function openScreen(name, returnTo, page, extra): bool {
    var s = name === "wifi" ? wifiScreen
          : name === "bluetooth" ? bluetoothScreen
          : name === "settings" ? settingsScreen : null
    if (!s) return false
    // L5. Settings is a .desktop entry whose Exec summons this shell rather
    // than starting a process, so the launch that opened it is over now: its
    // window may already be up and focused, in which case no toplevel moves
    // and nothing else would ever take the splash down.
    splash.finish()
    var payload = { returnTo: returnTo || "", page: page || "" }
    if (extra) for (var k in extra) payload[k] = extra[k]
    s.open(JSON.stringify(payload))
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

  // The bar's own band, which is the shade's grab handle (A8) and therefore
  // the one piece of the screen's edge the back band gives up (G10, the top
  // half). Read off the shade, which reads it off the bar, so the surface that
  // yields and the surface that takes cannot drift apart.
  readonly property int barBand: shade.stripHeight

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

  Splash {
    id: splash
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
