// The launch splash: the app's own icon on the wallpaper, from the tap until
// its window appears. Implements docs/spec/windows.md L1-L9.
//
// ---------------------------------------------------------------------------
// What this replaces
// ---------------------------------------------------------------------------
// Upstream's AppLibrary shows a launch OSD -- a rounded panel reading
// "Launching Files..." with a rocket glyph -- two seconds after the tap, and
// takes it down when a toplevel appears. Two things are wrong with that here.
//
// Two seconds is most of an app launch on this VM, so the feedback arrives
// after the moment it was for: you tap, nothing happens, you tap again, and
// the panel appears to tell you about the launch you had already given up on.
// And a panel of chrome with a generic glyph is not what a phone shows while
// an app opens; every phone shows the app.
//
// ---------------------------------------------------------------------------
// Why the state is here and not in AppLibrary
// ---------------------------------------------------------------------------
// moarchy draws the same splash off AppLibrary's own launch state, which it
// can read because its port patch rewrites that service anyway. This project
// does not patch upstream except where the patch could go upstream, and a
// plugin here cannot reach that state at all: `shell.appLibrary` is
// services/PluginAppLibraryApi.qml, seven callbacks -- entryName, entrySubtext,
// sortedEntries, iconSource, refreshIcons, launch, remove -- and no launch
// feedback of any kind.
//
// So the shell plugin owns the whole thing. Shell.launchApp() opens the splash
// in the same call that asks the library to launch, and this file decides when
// the launch is over. The one thing upstream still has to agree to is silence:
// Bar.qml declares `launchOsd: false` and patches/launch-osd-bar-opt-out.patch
// is what makes AppLibrary read it, the same shape as the bar's opt-out from
// the notification toasts.
//
// ---------------------------------------------------------------------------
// When a launch is over
// ---------------------------------------------------------------------------
// Four ways to end, and every one of them is an event rather than a guess at
// how long an app takes:
//
//   a new window   a toplevel that was not there when the launch started (L4)
//   the app itself the active window's app id is the id that was launched --
//                  what a second tap on an app already running produces, where
//                  no new window is ever going to map
//   a screen       Settings and the rest are .desktop entries that summon this
//                  shell rather than starting a process (L5); Shell.openScreen
//                  calls finish() as it puts one up
//   15 seconds     nothing came (L6). Upstream's timeout, kept
//
// Upstream's own rule is the first of those OR any change of active toplevel,
// and the second half is deliberately left out. It answers a question this
// splash is not asking: a focus change during a launch -- going home over it,
// a window closing underneath it -- is not the app arriving, and the two rules
// above already cover every way it can arrive.
//
// The stronger reason for leaving it out turned out not to be true here, and
// it is written down because it looked certain: the drawer takes the seat's
// keyboard on a tap (AppDrawer.qml, `inputFull`), so closing it should hand
// focus back to the window underneath, and upstream's rule would then end
// every launch made from a drawer opened over a running app, before the app
// it announces had mapped. Measured on Hyprland 0.56 it does not: with foot
// mapped and focused, `hyprctl activewindow` reads foot with the drawer open
// over it, still reads foot after a tap on the sheet, and still reads foot
// once the drawer has closed. A window keeps its activated state while a layer
// surface holds OnDemand keyboard focus.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var host: null

  // ------------------------------------------------------------------ state
  //
  // `serial` is what makes a second launch cancel the first one's timeout
  // rather than the first one's timeout cancelling the second's splash.
  property int serial: 0
  property bool launching: false
  property string iconSource: ""

  // The id that was launched, lowercased, with `.desktop` off: what an app id
  // coming back off the compositor is matched against.
  property string launchedId: ""

  // Every toplevel that existed when this launch started. Objects, not ids: a
  // second window of an app already running is a launch that finished, and
  // counting windows per app id would miss it.
  //
  // NOT `baseline`, which is what this was called for an afternoon: `baseline`
  // is one of Item's anchor lines and it is FINAL, so the declaration fails
  // with "Cannot override FINAL property" and the whole type goes unavailable
  // -- Shell.qml then logs "Type Splash unavailable" and every launch is back
  // to having no feedback at all.
  property var windowsAtLaunch: []

  // ------------------------------------------------------------------ sizing
  //
  // Rather more than twice the drawer's grid icon (Style.space(42)): 96 of a
  // 360px-wide screen, about the fraction a phone splash usually gives its
  // icon. The surface is 130, which keeps it well under half the screen -- see
  // the input region below for why that matters.
  readonly property int iconSize: Style.space(96)
  readonly property int surfaceSize: Math.round(root.iconSize * 1.35)

  // The fallback outline's colour, off the theme so it recolours with
  // everything else. Color.foreground rather than Color.menu.text: this draws
  // on the wallpaper, not on the drawer's sheet, which has already gone.
  readonly property color placeholder: Color.foreground

  // ------------------------------------------------------------------- fade
  //
  // Set on the way in, animated on the way out. The whole complaint about the
  // OSD was that its feedback arrived after the moment it was for; a fade-in
  // would put a slower version of that straight back. Going out is animated so
  // the app that just mapped is not revealed by a jump cut (L4).
  property real fade: 0

  NumberAnimation {
    id: fadeOut
    target: root
    property: "fade"
    to: 0
    duration: 160
    easing.type: Easing.OutCubic
  }

  // ---------------------------------------------------------------- the API
  //
  // Called by Shell.launchApp(), which is the one place in this plugin that
  // asks the library to launch anything.
  function begin(icon, desktopId): void {
    root.serial++
    root.iconSource = String(icon || "")
    root.launchedId = String(desktopId || "").toLowerCase().replace(/\.desktop$/, "")
    root.windowsAtLaunch = root.toplevels()
    root.launching = true
    fadeOut.stop()
    root.fade = 1
    launchTimeout.restart()
  }

  function finish(): void {
    if (!root.launching) return
    root.launching = false
    launchTimeout.stop()
    if (root.fade > 0) fadeOut.restart()
  }

  function toplevels() {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    // Copied out of the live model: `values` is the model's own array, and a
    // baseline that is a reference to it is a baseline that grows with it.
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i])
    return out
  }

  // The window an app id names, matched the way Shade.windowFor() matches a
  // notification's sender: an app often reports only the last segment of a
  // reverse-DNS desktop id -- org.gnome.Papers runs as "papers".
  function isLaunched(tl): bool {
    if (!tl || root.launchedId === "") return false
    var id = String(tl.appId || "").toLowerCase()
    if (!id) return false
    return id === root.launchedId
        || id.split(".").pop() === root.launchedId
        || root.launchedId.split(".").pop() === id
  }

  function maybeFinish(): void {
    if (!root.launching) return
    var list = root.toplevels()
    for (var i = 0; i < list.length; i++)
      if (root.windowsAtLaunch.indexOf(list[i]) < 0) { root.finish(); return }
    if (root.isLaunched(ToplevelManager.activeToplevel)) root.finish()
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.maybeFinish() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.maybeFinish() }
  }

  // L6. Upstream's 15s, and the same job: an app that never appears leaves its
  // icon on the wallpaper, and the wallpaper is what the splash is drawn on.
  Timer {
    id: launchTimeout
    interval: 15000
    onTriggered: root.finish()
  }

  // Lets the splash be asserted without a camera, which is how
  // `vm-selftest.sh splash` proves L1-L7.
  IpcHandler {
    target: "splash"

    function state(): string { return root.launching ? "open" : "closed" }
    function icon(): string { return root.iconSource }

    // What is actually on the surface, which is not the same question as what
    // the icon source is: a source that resolves to a file Qt cannot load
    // draws nothing at all. L7 is about the pixels, so it asks about those.
    function drawn(): string {
      // The surface first. Image.status stays Ready after the splash comes
      // down -- the component is not destroyed, only hidden -- so without this
      // `drawn` answers about the last launch instead of about the screen.
      if (!splashWindow.visible) return "down"
      if (appIcon.status === Image.Ready) return "icon " + root.iconSource
      if (fallbackIcon.visible) return "fallback"
      return "nothing"
    }

    // Reported from the properties the surface is built from rather than from
    // the window, which has no size at all while it is unmapped -- a geometry
    // that reads 0 when the splash is down would make the L2 check pass for
    // the wrong reason.
    function geometry(): string {
      // The layer is read back off the window rather than restated as a
      // literal, so a regression to Top fails a check instead of waiting for
      // someone to take a screenshot over a fullscreen app (L2a).
      var layer = "?"
      try {
        layer = splashWindow.WlrLayershell.layer === WlrLayer.Overlay ? "overlay"
              : splashWindow.WlrLayershell.layer === WlrLayer.Top ? "top"
              : String(splashWindow.WlrLayershell.layer)
      } catch (e) { layer = "?" }
      return "w=" + root.surfaceSize + " h=" + root.surfaceSize
           + " icon=" + root.iconSize + " layer=" + layer
    }
  }

  // ============================================================ the surface
  //
  // Sized to its own icon, not to the screen, and that is the whole shape of
  // L3: a splash must never eat a touch, because the phone's only navigation
  // is the home pill and the back edge and both are live while an app opens. A
  // surface the size of its content cannot swallow anything outside it -- the
  // same argument EdgeGestures makes for the strip -- so L3 holds by
  // construction rather than by getting a mask right. The mask is set as well,
  // and belt and braces is deliberate here: an app that never opens leaves
  // this on screen for fifteen seconds.
  //
  // A layer surface with no anchor on an axis is centred on that axis by the
  // compositor, which is what puts a 130px square in the middle of the screen.
  PanelWindow {
    id: splashWindow

    visible: root.fade > 0

    // Deliberately unanchored: see above. implicitWidth/Height are what the
    // compositor is given, and with no anchor on either axis it centres the
    // result on the output.
    implicitWidth: root.surfaceSize
    implicitHeight: root.surfaceSize
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-splash"

    // Overlay, not Top (L2a). A fullscreen window is drawn above the Top layer
    // on this compositor as on Sway, so on Top this vanishes behind the first
    // fullscreen window it meets. Nothing here fullscreens on the user's
    // behalf (W5), which changes how often that bites and not whether it is a
    // bug: $mod+Shift+f and any app that asks for fullscreen still put a
    // window above Top.
    //
    // The usual reason to prefer Top -- staying under the strip and the shade
    // -- costs nothing. Ordering within Overlay is map order and this maps
    // last, so it draws over both; but it is a 130px square in the middle of
    // the screen, the pill is at the bottom edge, and the shade cannot be open
    // during a launch because a launch comes from the drawer or from a card
    // that closes the shade on its way out.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserve nothing. An exclusive zone here would reflow every tiled window
    // twice per launch, which is the opposite of what a splash is for.
    exclusionMode: ExclusionMode.Ignore

    // One pixel, not an empty region, and the difference is the whole point.
    // An empty mask reads as "no input" and means the opposite: Qt treats an
    // empty mask as *unset*, and an unset input region is the entire surface.
    // AppDrawer.qml keeps an empty Region for the same reason, as the thing it
    // swaps in when the sheet is to take nothing -- and it can, because that
    // surface is full-screen and an unset region there is what it wants
    // anyway. Here it would be a 130px square that swallows the middle of the
    // screen for fifteen seconds.
    mask: Region { x: 0; y: 0; width: 1; height: 1 }

    Image {
      id: appIcon

      anchors.centerIn: parent
      width: root.iconSize
      height: root.iconSize
      // Without sourceSize an SVG rasterises at its natural size. The drawer
      // learned this holding 512px squares for every visible app.
      sourceSize: Qt.size(root.iconSize, root.iconSize)
      fillMode: Image.PreserveAspectFit
      // Synchronous on purpose: this image exists to be on screen in the frame
      // the tap produced, and an async load hands back an empty square first.
      asynchronous: false
      cache: true
      source: root.iconSource
      opacity: root.fade
    }

    // L7. The fallback, for an entry whose icon resolves to nothing. Drawn
    // rather than shipped as a file, because there is no generic icon to ship
    // to: application-x-executable and its neighbours exist on this image only
    // inside AdwaitaLegacy's mimetypes/ and legacy/ directories, which the
    // active theme does not inherit -- so Qt's themed lookup comes back empty
    // and upstream's own iconSource("") fallback resolves to "". An outline in
    // the theme's foreground is never missing and costs no asset.
    Rectangle {
      id: fallbackIcon

      anchors.centerIn: parent
      width: root.iconSize
      height: root.iconSize
      // Not Ready covers both halves of the problem: no source at all, and a
      // source pointing at something Qt could not decode.
      visible: appIcon.status !== Image.Ready
      radius: Math.round(root.iconSize / 5)
      color: "transparent"
      border.width: Math.max(2, Math.round(root.iconSize / 24))
      border.color: root.placeholder
      opacity: root.fade * 0.7
      scale: appIcon.scale
    }

    // L8. Slow, small, and on the transform only -- one textured quad being
    // scaled is what llvmpipe can afford, and it is what says the launch is
    // still running rather than stuck.
    SequentialAnimation {
      running: splashWindow.visible
      loops: Animation.Infinite
      NumberAnimation {
        target: appIcon; property: "scale"
        from: 1.0; to: 1.06; duration: 900; easing.type: Easing.InOutSine
      }
      NumberAnimation {
        target: appIcon; property: "scale"
        to: 1.0; duration: 900; easing.type: Easing.InOutSine
      }
    }
  }
}
