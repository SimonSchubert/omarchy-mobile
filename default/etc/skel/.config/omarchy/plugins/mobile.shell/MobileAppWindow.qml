// A shell screen that is an ordinary window (docs/spec/gestures.md K).
// Ported from moarchy.common/AppWindow.qml.
//
//     MobileAppWindow {
//       id: wifiWindow
//       host: root.host
//       appName: "Wi-Fi"
//       pageTitle: root.pageTitle
//       onUnmapped: ...
//     }
//
// Not named AppWindow: this file is found through the plugin directory's
// implicit import, which ranks below every explicit one, and a same-named type
// in any of them would win without a word -- the way `Edges` did.
//
// ---------------------------------------------------------------------------
// Why a window and not a layer surface (K1)
// ---------------------------------------------------------------------------
// Wi-Fi and Bluetooth are screens you sit in: a passphrase retyped, a headset
// put into pairing mode and tried again. moarchy spent two releases emulating
// an app around its screens as layer surfaces -- a card built by hand, a
// workspace claimed on their behalf -- and the emulation always stopped one
// gesture short. Quickshell's FloatingWindow is an xdg toplevel owned by the
// shell's own process, which the compositor treats like any other client's: the
// window rule in hypr/mobile.lua gives it a workspace of its own and focuses
// it, ToplevelManager reports it, and the carousel's card for it is a real card.
//
// ---------------------------------------------------------------------------
// Identity is the title (K9)
// ---------------------------------------------------------------------------
// Qt sets the xdg-toplevel app id once per process and has no per-window
// override, so every screen carries the shell's own app id and the only thing
// that tells them apart is the title. Matched as a prefix on appName: the title
// carries the page and changes as you navigate, and the compositor echoes the
// change back a frame later, so an equality match has a window in which it
// resolves to nothing.
//
// ---------------------------------------------------------------------------
// `visible` is driven, never bound
// ---------------------------------------------------------------------------
// A window can be closed from outside -- the carousel's flick sends
// xdg_toplevel.close -- and Quickshell answers by setting `visible` false. A
// binding assigned to from C++ is broken rather than re-evaluated, so a screen
// bound to `visible: root.opened` would never map again after the first close.
// The window owns the state and the screen reads it back.
import QtQuick
import Quickshell
import Quickshell.Wayland

FloatingWindow {
  id: win

  property var host: null

  // What the carousel calls this screen, and the first half of the title.
  property string appName: ""

  // The page inside it, or "" at the top level: the card's third line (K5).
  property string pageTitle: ""

  // The glyph the card wears, since there is no desktop entry to look one up
  // in -- this is a window the shell draws, not a package anyone installed.
  property string glyph: ""

  // Printed by `recents list` in place of an app id, which names the shell
  // process rather than the screen (E1, K9).
  property string screenId: ""

  signal mapped
  signal unmapped

  // Quickshell maps a window as soon as it is constructed, and this plugin is
  // constructed when the shell starts -- moarchy's phone came up with Settings
  // and Wi-Fi already open, mapped before the bar and so sized against an
  // output with no exclusive zones on it. Nothing maps until something asks.
  // show() assigns `visible` and breaks this binding, which is the intent.
  visible: false

  // Construction sets `visible` false over Quickshell's default and fires
  // visibleChanged before the screen around this window is built; `unmapped`
  // reaches into that screen, so it must not fire for the setup frame.
  property bool completed: false
  Component.onCompleted: win.completed = true

  title: win.pageTitle && win.pageTitle !== win.appName
         ? win.appName + " — " + win.pageTitle
         : win.appName

  // A size for the frame before the compositor's first configure. The window
  // is tiled to its workspace at once, so these are only what it asks for.
  implicitWidth: win.screen ? win.screen.width : 360
  implicitHeight: win.screen ? win.screen.height : 720

  // The compositor's handle on this window, or null while it is unmapped.
  // Everything the carousel asks of a screen goes through it.
  property var toplevel: null

  readonly property bool activated: !!(win.toplevel && win.toplevel.activated)

  function matches(tl): bool {
    return !!tl && win.appName !== ""
           && String(tl.title || "").indexOf(win.appName) === 0
           && String(tl.appId || "").indexOf("quickshell") !== -1
  }

  function claimToplevel(): void {
    if (win.toplevel) return
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++)
      if (win.matches(list[i])) { win.toplevel = list[i]; return }
  }

  // K12. Summoning a screen that is already running focuses its window rather
  // than opening a second one.
  function focusWindow(): void {
    if (win.toplevel && win.host) win.host.focusToplevel(win.toplevel)
  }

  // The false is not redundant. After an external close Quickshell drops the
  // backing window and `visible` reads false, but its stored value does not
  // follow, so a bare `visible = true` compares equal and does nothing -- the
  // screen could never open again. moarchy isolated it on the device; false
  // then true maps it.
  function show(): void {
    if (win.visible) { win.focusWindow(); return }
    win.visible = false
    win.visible = true
  }

  function hide(): void {
    win.visible = false
  }

  onVisibleChanged: {
    win.toplevel = null
    if (!win.completed) return
    if (win.visible) { win.claimToplevel(); win.mapped() }
    else win.unmapped()
  }

  // The handle usually arrives with the map, but not always in the same frame,
  // and it can go away under us when the window is closed from outside.
  Connections {
    target: ToplevelManager.toplevels

    function onValuesChanged() {
      if (!win.visible) { win.toplevel = null; return }
      if (!win.toplevel) { win.claimToplevel(); return }
      var list = ToplevelManager.toplevels.values
      for (var i = 0; i < list.length; i++) if (list[i] === win.toplevel) return
      win.toplevel = null
    }
  }

  // Insurance that stops itself: a handle whose title was not committed yet
  // in the frame the set changed would otherwise get no second chance.
  Timer {
    interval: 200
    repeat: true
    running: win.visible && !win.toplevel
    onTriggered: win.claimToplevel()
  }
}
