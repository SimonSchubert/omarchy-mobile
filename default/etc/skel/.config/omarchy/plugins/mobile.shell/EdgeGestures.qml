// The bottom edge and the home screen: every gesture that does not start on a
// sheet.
//
// Implements docs/spec/gestures.md A-D. Ported from moarchy.gestures, whose
// decisions carry over unchanged. What changes is how the surfaces are built,
// because Hyprland delivers input differently from Sway in two measured ways:
//
//   the grab     Motion stops at the edge of the layer surface the press
//                landed on, to the pixel. moarchy's 20px strip tracks a
//                full-height swipe on Sway; here it would see 18px of a 300px
//                drag and read it as a tap.
//   exclusive    A layer surface with exclusive keyboard focus takes every
//                pointer event, so nothing here asks for it.
//
// ---------------------------------------------------------------------------
// The four surfaces
// ---------------------------------------------------------------------------
//   strip   Overlay, bottom, 20px, reserves nothing, INPUT-TRANSPARENT.
//           Draws the pill, on the screen's last rows and over every sheet.
//           It takes no input: it cannot grow without a resize.
//   band    Bottom, bottom, 20px, exclusive, draws nothing, no input.
//           Reserves the band off every window the way Android's navigation
//           bar does, so an app is laid out above the pill. On Bottom so that
//           it is arranged before the on-screen keyboard and keeps the screen
//           edge (see the surface itself).
//   edge    Overlay, full screen, reserves nothing. Owns the strip gesture.
//           Its input region is the band at rest and the whole screen from
//           press to release, so a drag that leaves the band keeps being
//           delivered. Overlay puts it above both sheets, so the band stays
//           live with either one up (A6, A7).
//   home    Bottom, full screen, zero zone. The drag that opens the drawer (D).
//           Below every window: on an empty workspace it gets the touch, and on
//           an occupied one the app is over it and it gets nothing. The layer
//           answers "is this the home screen", and nothing here asks. It never
//           has to grow -- it is already the size of the gesture. It reaches
//           under the strip too, and fills the band with the theme's
//           background whenever a window is focused (I1a).
//
// ---------------------------------------------------------------------------
// What the up-drag from the strip means
// ---------------------------------------------------------------------------
//   0 ---- 40% -------- 75% ---- 100%   of pullTravel
//   app    RECENTS       HOME
//
// It never opens the drawer (A5). The drawer is one drag up on the home screen
// itself (D1), which is Android's split: the navigation area is the overview,
// the home screen is the launcher.
//
// ---------------------------------------------------------------------------
// MouseArea, not MultiPointTouchArea
// ---------------------------------------------------------------------------
// moarchy uses MultiPointTouchArea, because it runs on a touchscreen. This
// VM's pointer is a `usb-tablet` -- a mouse that reports absolute coordinates
// -- and Qt synthesises a mouse event from an unhandled touch but never a
// touch from a mouse, so a MultiPointTouchArea here would receive nothing.
// MouseArea takes both: the tablet directly, and a finger through Qt's
// synthesis on hardware. It gives up the second finger, which no gesture here
// has a use for.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var host: null
  property var drawer: null
  property var carousel: null
  property var shade: null

  // ------------------------------------------------------------- geometry
  //
  // The numbers are moarchy's, measured on the PinePhone this VM stands in for.
  readonly property int stripHeight: root.host ? root.host.stripHeight : Style.space(20)

  // Movement past this is a drag rather than a stationary touch.
  readonly property int slop: Style.space(8)

  // Travel that commits a sideways swipe, and an up-flick that clears a sheet.
  // Below it the pill springs back and nothing happens, so resting a thumb on
  // the edge is not a workspace switch.
  readonly property int commitDistance: Style.space(56)

  // --------------------------------------------------------- the back edge
  //
  // G8. About 3mm on this panel, which is roughly what Android's back edge
  // feels like at its default sensitivity. Deliberately one property rather
  // than a number inlined in a binding: Android makes this device-configurable
  // *and* user-adjustable *and* queryable by apps, which is three admissions
  // that no single value is right. Expect to change it.
  readonly property int backEdgeWidth: Style.space(16)

  // G10. How far short of the bottom the band stops: one strip plus one
  // keyboard panel. Below this the strip wants the touch, and above the strip
  // the keyboard does.
  //
  // A number rather than an arrangement, on this compositor for a different
  // reason than on Sway. moarchy cannot reach the keys by arrangement because
  // Sway subtracts exclusive zones from Overlay down, so the keyboard's Top
  // zone is taken off after this surface has been placed. Here zones resolve
  // the other way up and the keyboard genuinely is arranged first -- but that
  // settles placement, not input, and an Overlay surface still takes every
  // touch a Top one would have had. Either way the input region is the only
  // knob, and the number is the same 220.
  //
  // The keyboard's 200 is measured and not ours to choose, so unlike
  // backEdgeWidth it does NOT go through Style.space: the keyboard is a
  // separate client that never sees this theme, and scaling the inset with the
  // theme would cut the band shorter than the keys it exists to clear.
  readonly property int backEdgeBottomInset:
    root.stripHeight + (root.host ? root.host.keyboardPanelHeight : 200)

  // G10, the other end, and the one part of this the spec does not already
  // say. The band stops short of the TOP as well, by the height of the bar --
  // which is the shade's grab handle (A8, Shade.qml's `stripHeight`).
  //
  // Measured rather than assumed, and it is a decision made out of a race. The
  // shade is Overlay too and keeps the bar's band as its input region even
  // while shut, so the two surfaces want the same top-left corner and map
  // order picks the winner. Measured with no inset, the shade won: a back
  // swipe answered nothing at y=10 and fired from y=30 down. Writing the same
  // 26px down here changes no behaviour today and stops the behaviour
  // depending on which surface happened to map first.
  //
  // Cutting the column out of the shade's band instead is the other way round,
  // and Shade.qml records why it is not taken: a cut-out region there does not
  // commit until something repaints.
  readonly property int backEdgeTopInset: root.host ? root.host.barBand : Style.space(26)

  // The band's own height, published by `gestures geometry` because the
  // surface is transparent and reserves nothing: from outside, a band that
  // failed to shrink and one that is fine look identical (G10).
  readonly property int backEdgeHeight:
    Math.max(0, back.height - root.backEdgeTopInset - root.backEdgeBottomInset)

  // G6. Inward travel that commits a back swipe -- three times the band, so
  // brushing the edge never closes an app.
  readonly property int backCommit: Style.space(48)

  // The pill moves a fraction of the finger's travel. Full 1:1 tracking on a
  // 360px screen runs the pill off the edge long before the commit threshold.
  readonly property real damping: 0.32
  readonly property int pillTravel: Style.space(80)

  // Travel a full strip drag takes. Not the whole screen: the band does not
  // move under the thumb, so a full-screen reach there would be a cost with
  // nothing bought -- the pill is not the thing being dragged (D2a).
  readonly property real pullTravel:
    Math.max(1, (edge.screen ? edge.screen.height : 720) * 0.45)

  // A1-A4. The carousel is fully up at 40%, which leaves the rest of the drag
  // to mean "keep going"; 75% is far enough that landing on home is deliberate.
  readonly property real recentsFull: 0.40
  readonly property real recentsCommit: 0.15
  readonly property real homeCommit: 0.75

  // D1-D2. Fraction of the drawer's height past which a release opens it, and
  // the speed, in logical px per millisecond, that means the same thing in
  // less distance.
  readonly property real drawerCommit: 0.35
  readonly property real fling: 0.6

  // Shortest interval a speed may be measured over. Date.now() has millisecond
  // resolution, so two motion events in the same millisecond give a dt of zero
  // -- and clamping that to 1, as moarchy does, turns a 3px step into 3 px/ms,
  // five times the fling threshold. Measured here: a 41px drag over 120ms
  // reported 2.98 px/ms and opened the drawer on what should have been a
  // spring-back. A touchscreen samples at 60-120Hz and never trips this; a
  // compositor handing on a pointer stream is not rate-limited the same way.
  readonly property int velocityFloor: 8

  function clamp01(v: real): real { return Math.max(0, Math.min(1, v)) }

  // ---------------------------------------------------------- shared state
  //
  // One pointer, so the strip and the home screen can share the velocity
  // sampler. They do NOT share `tracking`: that one flag opens the edge's input
  // region, and opening it during a drag on the home screen would put an
  // Overlay surface under the finger -- which, on this compositor, is where
  // the rest of the drag would then go.
  property bool tracking: false
  property real startX: 0
  property real startY: 0
  property real dx: 0
  property real dy: 0
  property real velocity: 0
  property real lastY: 0
  property real lastT: 0

  // Which sheet the strip drives: "none" or "recents". Latched on the first
  // clearly-upward movement and held for the rest of the gesture, so a swipe
  // that starts up and drifts sideways cannot hand the sheet back mid-pull and
  // change workspace instead.
  property string dragMode: "none"

  // What the press decided, before it was known the gesture was even upward.
  property string pendingMode: "none"

  // Where the pull stood when the finger went down, so a second drag with the
  // carousel already up carries on into the home band (A6).
  property real dragStartPull: 0

  // The live pull, in units of pullTravel.
  property real pull: 0

  readonly property bool homeArmed: root.dragMode === "recents" && root.pull >= root.homeCommit

  readonly property real pillOffset: root.tracking
    ? Math.max(-root.pillTravel, Math.min(root.pillTravel, root.dx * root.damping))
    : 0

  // Smoothed, so one jittery frame at the end of a slow drag cannot read as a
  // fling, and sampled at most once per velocityFloor. Negative dy is upward,
  // so the sign is flipped to make "faster up" positive.
  function sample(y: real, now: real): void {
    var dt = now - root.lastT
    if (dt < root.velocityFloor) return
    root.velocity = root.velocity * 0.6 + ((root.lastY - y) / dt) * 0.4
    root.lastY = y
    root.lastT = now
  }

  // ------------------------------------------------------------- J. preview
  //
  // The carousel paints a still of the app being put away (spec/gestures.md J).
  // Armed at the latch rather than at the press: the capture needs the
  // carousel's surface mapped, and that only happens once progress leaves 0.
  function armPreview(): void {
    if (root.dragMode !== "recents" || !root.carousel) return

    // A6 -- a second drag with the carousel already up -- is a drag over the
    // switcher, and the app it would capture is already behind it.
    if (root.carousel.opened) return

    // K11. A shell app is a window, so this one question covers Settings,
    // Wi-Fi and Bluetooth too. Nothing to picture means nothing to arm: a
    // bare home screen reaches here only through A9, which stops the gesture
    // earlier, but a workspace whose window has just closed does not.
    if (!root.host.focusedToplevel()) return
    root.carousel.armPreview()
  }

  // `restore` true means the gesture changed nothing and the app goes back to
  // full size (J5); false means it was put away and the preview stays where
  // the finger left it (J6).
  function disarmPreview(restore): void {
    if (root.carousel) root.carousel.disarmPreview(restore)
  }

  // A7, A8. A sheet is covering the screen, so the release clears it rather
  // than raising anything -- the shade and the drawer both. The carousel is not
  // in this list: a second drag continues it into the home band (A6) rather
  // than clearing it.
  function coveringSheet(): bool {
    return root.drawer.opened || root.drawer.progress > 0
      || root.shade.opened || root.shade.progress > 0
  }

  // A strip gesture another surface is delivering -- the shade, which is on top
  // of the edge surface while it is up and keeps the band for exactly this
  // (Shade.qml, A8). The edge surface must not open its own input region then:
  // it would become the topmost region under the finger and take the drag.
  property bool borrowed: false

  // ======================================================== the strip gesture
  //
  // Untyped, unlike its neighbours, because the third argument is optional:
  // the edge surface's own MouseArea passes two.
  function stripPressed(x, y, borrowed): void {
    root.borrowed = !!borrowed
    root.startX = x
    root.startY = y
    root.lastY = y
    root.lastT = Date.now()
    root.dx = 0
    root.dy = 0
    root.pull = 0
    root.velocity = 0
    root.dragMode = "none"
    root.tracking = true

    // The whole decision, and it never mentions opening the drawer (A5):
    //
    //   a sheet covering the screen -> the release clears it (A7, A8)
    //   the carousel already up     -> keep dragging it, on to home (A6)
    //   apps open                   -> the carousel (A1-A4)
    //   nothing open at all         -> nothing (A9)
    if (root.coveringSheet())
      root.pendingMode = "none"
    else if (root.carousel.opened || root.host.hasApps())
      root.pendingMode = "recents"
    else
      root.pendingMode = "none"

    // The carousel reaches its stop at 40% of the travel, so an open one
    // starts the next drag already there.
    root.dragStartPull = root.pendingMode === "recents"
      ? root.carousel.progress * root.recentsFull : 0
    watchdog.restart()
  }

  function stripMoved(x: real, y: real): void {
    if (!root.tracking) return
    var now = Date.now()
    root.dx = x - root.startX
    root.dy = y - root.startY

    // B2. Re-tested every frame rather than only at the first movement, so a
    // thumb that starts its arc sideways still latches once the upward travel
    // dominates, instead of falling through to a workspace switch.
    if (root.dragMode === "none" && root.pendingMode === "recents"
        && root.dy < -root.slop && Math.abs(root.dy) > Math.abs(root.dx)) {
      root.dragMode = "recents"
      // Before `dragging`, and that order is the whole of A6. The carousel's
      // `opened` is `progress >= 1 && !dragging`, so setting dragging first
      // makes an already-open carousel read shut and armPreview's A6 guard
      // never fires -- measured: a second drag over the switcher armed a
      // capture and took it. Invisible, because the preview's fade is zero
      // past 82% of the travel, and wasted on every second drag.
      root.armPreview()
      root.carousel.dragging = true
    }

    if (root.dragMode === "recents") {
      root.sample(y, now)
      root.pull = root.dragStartPull - root.dy / root.pullTravel
      root.carousel.progress = root.clamp01(root.pull / root.recentsFull)
      // Past the carousel's stop the rest of the drag has to mean something,
      // so hand it over as a 0..1 ramp the cards fade and travel with.
      root.carousel.homeHint = root.clamp01(
        (root.pull - root.recentsFull) / (root.homeCommit - root.recentsFull))
    } else {
      // Not latched: keep the sampler's origin fresh, so the first latched
      // frame measures its speed from here and not from the press.
      root.lastY = y
      root.lastT = now
    }
    watchdog.restart()
  }

  function stripReleased(): void {
    if (!root.tracking) return
    if (root.dragMode === "recents") {
      // A2-A4. Distance alone decides home. A fling may rescue a short, fast
      // flick into the recents band -- people do that when they know where
      // they are going -- but never carry the drag past a stop the finger did
      // not reach, or the destination stops being predictable.
      //
      // `dragging` goes false before either call, so the carousel's own
      // Behaviors animate the release: that is what retires homeHint instead
      // of snapping it to 0 while progress is still on its way out (F4).
      root.carousel.dragging = false
      if (root.pull >= root.homeCommit) {
        // J6. The app was put away, so the preview stays where the finger
        // left it and fades -- it has already landed on the card by here.
        root.disarmPreview(false)
        root.carousel.close()
        root.host.goHome()
      } else if (root.pull >= root.recentsCommit || root.velocity >= root.fling) {
        root.disarmPreview(false)
        root.carousel.open()
      } else {
        // A2, J5: nothing happened, so the app comes back at full size rather
        // than appearing to have been put somewhere.
        root.disarmPreview(true)
        root.carousel.close()
      }
    } else {
      root.commit()
    }
    root.reset()
  }

  function stripCanceled(): void {
    if (root.dragMode === "recents") {
      root.carousel.dragging = false
      // A dropped touch changed nothing, so the app goes back (J5). This is
      // also the path the watchdog takes, and so the one that catches a
      // capture which never arrived (J7, J8).
      root.disarmPreview(true)
      root.carousel.close()
    }
    root.reset()
  }

  // B1, B2. Horizontal wins ties: a sideways swipe that drifts upward is still
  // a workspace change, which is the gesture people actually aim for. Reached
  // only when no sheet was being dragged -- a latched drag is decided by
  // travel and speed in stripReleased instead.
  //
  // C1. A press that never travels reaches here with dx and dy both zero and
  // does nothing. There is no hold on the strip.
  function commit(): void {
    if (Math.abs(root.dx) >= Math.abs(root.dy)) {
      if (root.dx <= -root.commitDistance) root.host.switchWorkspace("next")
      else if (root.dx >= root.commitDistance) root.host.switchWorkspace("prev")
    } else if (root.dy <= -root.commitDistance) {
      root.host.clearTopmost()
    }
  }

  function reset(): void {
    watchdog.stop()
    root.tracking = false
    root.borrowed = false
    root.dragMode = "none"
    root.pendingMode = "none"
    root.dragStartPull = 0
    root.pull = 0
    root.velocity = 0
    root.dx = 0
    root.dy = 0
  }

  // ==================================================== the home-screen drag
  property bool homeTracking: false
  property bool homeDragging: false
  property real homeStartX: 0
  property real homeStartY: 0
  property real homeStartProgress: 0

  function homePressed(x: real, y: real): void {
    root.homeTracking = true
    root.homeDragging = false
    root.homeStartX = x
    root.homeStartY = y
    root.lastY = y
    root.lastT = Date.now()
    root.velocity = 0
    root.homeStartProgress = root.drawer.progress
    watchdog.restart()
  }

  function homeMoved(x: real, y: real): void {
    if (!root.homeTracking) return
    var now = Date.now()
    var hdx = x - root.homeStartX
    var hdy = y - root.homeStartY

    // D4. Up only. Sideways and downward on the home screen do nothing, for
    // now: the strip changes workspace and nothing else here needs a meaning.
    if (!root.homeDragging && root.homeStartProgress < 1
        && hdy < -root.slop && Math.abs(hdy) > Math.abs(hdx)) {
      root.homeDragging = true
      root.drawer.dragging = true
    }

    if (root.homeDragging) {
      root.sample(y, now)
      // D2a. 1:1 with the finger, measured against the drawer's own height --
      // the same divisor its close drag uses, read off the drawer so the two
      // directions cannot drift apart.
      root.drawer.progress = root.clamp01(
        root.homeStartProgress - (y - root.homeStartY) / root.drawer.closeTravel)
    } else {
      root.lastY = y
      root.lastT = now
    }
    watchdog.restart()
  }

  function homeReleased(): void {
    if (!root.homeTracking) return
    if (root.homeDragging) {
      // A fling rescues a short, fast flick, but a downward one wins over the
      // distance, so a drag that reverses does not open behind the finger (D2).
      var open = root.velocity >= root.fling
        || (root.velocity > -root.fling && root.drawer.progress >= root.drawerCommit)
      root.drawer.dragging = false
      if (open) root.drawer.open()
      else root.drawer.dismiss()
    }
    root.homeTracking = false
    root.homeDragging = false
    watchdog.stop()
  }

  // ========================================================= the back gesture
  //
  // G. One gesture that always undoes the most recent thing: the keyboard,
  // then an open sheet, then the focused app (G1). The order is the host's --
  // it owns the sheets and the windows -- and this is only the surface that
  // decides a swipe happened at all.
  //
  // A press and a release are all moarchy reads, because on Sway motion keeps
  // being delivered after the finger leaves a 16px surface. Here it does not:
  // motion stops at that surface's own edge to the pixel, so a 16px-wide
  // surface would see 16px of a 60px swipe and never reach backCommit. So the
  // band is the input region and not the surface, and it opens to the whole
  // screen for the length of the gesture -- exactly what the edge surface does
  // for the strip, for the same measured reason (this file's header).
  property bool backTracking: false
  property real backStartX: 0
  property real backStartY: 0
  property real backDx: 0
  property real backDy: 0

  // A back gesture the shade is delivering, which keeps its whole input region
  // while it is up and is on top of this surface (Shade.qml, A8). Same bargain
  // the strip's `borrowed` strikes: this surface must not open its own region
  // for a gesture it is not receiving, or it becomes the topmost region under
  // the finger and takes the rest of the drag.
  property bool backBorrowed: false

  // Untyped for the reason stripPressed is: the third argument is optional,
  // and this surface's own MouseArea passes two.
  function backPressed(x, y, borrowed): void {
    root.backBorrowed = !!borrowed
    root.backTracking = true
    root.backStartX = x
    root.backStartY = y
    root.backDx = 0
    root.backDy = 0
    watchdog.restart()
  }

  function backMoved(x: real, y: real): void {
    if (!root.backTracking) return
    root.backDx = x - root.backStartX
    root.backDy = y - root.backStartY
    watchdog.restart()
  }

  function backReleased(): void {
    if (!root.backTracking) return
    // G6. Inward, far enough, and more sideways than not -- so a vertical
    // scroll that begins at the edge is never a back, and brushing the edge
    // never closes an app.
    var commit = root.backDx >= root.backCommit
                 && Math.abs(root.backDx) > Math.abs(root.backDy)
    // Reset first, so the region is back to its band before anything the
    // gesture does can put a sheet or a window under the finger.
    root.backReset()
    if (commit) root.host.performBack()
  }

  function backCanceled(): void { root.backReset() }

  function backReset(): void {
    watchdog.stop()
    root.backTracking = false
    root.backBorrowed = false
    root.backDx = 0
    root.backDy = 0
  }

  // The edge's input region is the whole screen for as long as `tracking` is
  // true, so something has to close it if the release never comes -- a client
  // that loses the pointer without a release would otherwise leave the screen
  // answering to this surface and nothing else. Re-armed on every motion, so
  // only a gesture that has gone silent trips it.
  Timer {
    id: watchdog
    interval: 3000
    onTriggered: {
      if (root.tracking) root.stripCanceled()
      if (root.backTracking) root.backReset()
      if (root.homeTracking) {
        if (root.homeDragging) {
          root.drawer.dragging = false
          if (root.drawer.progress >= root.drawerCommit) root.drawer.open()
          else root.drawer.dismiss()
        }
        root.homeTracking = false
        root.homeDragging = false
      }
    }
  }

  // Lets the wiring be tested without a finger:
  //   omarchy-shell gestures swipe left
  //   omarchy-shell gestures status
  IpcHandler {
    target: "gestures"

    function swipe(direction: string): string {
      if (direction === "left") { root.host.switchWorkspace("next"); return "ok: next workspace" }
      if (direction === "right") { root.host.switchWorkspace("prev"); return "ok: previous workspace" }
      if (direction === "home") { root.host.goHome(); return "ok: home" }
      if (direction === "up") {
        // The same choice a real strip swipe makes, so this exercises the
        // decision and not just one branch of it.
        if (root.coveringSheet()) { root.host.clearTopmost(); return "ok: cleared" }
        if (!root.host.hasApps()) return "ok: nothing (no apps open)"
        root.carousel.open()
        return "ok: recents"
      }
      return "usage: swipe left|right|up|home"
    }

    // G. Reachable without a finger, and the only way to exercise the priority
    // order without a keyboard on screen to swipe past.
    function back(): string {
      root.host.performBack()
      return "ok: back"
    }

    function status(): string {
      var s = root.tracking
        ? "tracking mode=" + root.dragMode + " pending=" + root.pendingMode
          + (root.borrowed ? " borrowed" : "")
          + " pull=" + Math.round(root.pull * 100)
          + " dx=" + Math.round(root.dx) + " dy=" + Math.round(root.dy)
        : (root.homeTracking ? "home dragging=" + root.homeDragging : "idle")
      return s + " apps=" + (root.host.hasApps() ? 1 : 0)
    }

    // The edge is transparent, so where its input region is cannot be seen
    // from outside -- a band that failed to shrink back is a screen that
    // answers nothing, and looks exactly like one that is fine. Ask instead.
    function geometry(): string {
      return "strip=" + root.stripHeight
        + " edge=" + Math.round(edge.width) + "x" + Math.round(edge.height)
        + " input=" + (root.tracking ? "full" : "band")
        + " home=" + Math.round(home.width) + "x" + Math.round(home.height)
        + " travel=" + Math.round(root.pullTravel)
        // I1a: whether the band is filled, and with what, so a check can hold
        // one pixel of the screen against what this surface says it painted.
        + " band=" + (root.bandFilled ? 1 : 0)
        + " fill=" + Color.background
        + " kbd=" + (root.keyboardUp ? 1 : 0)
        // G10. The back band, which is an input region and not a surface, so
        // this is the only place it can be read from at all. `screen` is
        // published with it because a check that saw only `back` could not
        // tell a band that failed to shrink from one this output never
        // configured.
        + " back=" + root.backEdgeWidth + "x" + root.backEdgeHeight
        + " backTop=" + root.backEdgeTopInset
        + " backInset=" + root.backEdgeBottomInset
        + " screen=" + (back.screen ? Math.round(back.screen.height) : 0)
    }
  }

  // ============================================================ the strip
  PanelWindow {
    id: strip

    // Anchoring left+right+bottom without `top` gives a full-width band whose
    // height we set. It reserves nothing -- the band surface below does that --
    // so Ignore places it against the whole output: on the screen's last rows,
    // whatever else is reserving there.
    anchors { bottom: true; left: true; right: true }
    implicitHeight: root.stripHeight
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-strip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // No input at all: an empty mask, so the press falls through to the edge
    // surface, which can grow.
    mask: Region {}

    Rectangle {
      id: pill

      width: Style.space(96)
      height: Math.max(2, Style.space(4))
      radius: height / 2
      anchors.verticalCenter: parent.verticalCenter
      x: (parent.width - width) / 2 + root.pillOffset

      // Brightens while tracking, and stretches as an upward swipe approaches
      // the first stop. Armed for home it goes accent -- once the carousel
      // covers the screen the pill is the only cue left that letting go now
      // goes somewhere else.
      color: root.homeArmed ? Color.accent
                            : Util.alpha(Color.foreground, root.tracking ? 0.9 : 0.3)
      scale: root.homeArmed ? 1.6
           : 1 + Math.min(0.4, Math.max(0, -root.dy) / (root.commitDistance * 4))

      Behavior on x {
        enabled: !root.tracking
        SpringAnimation { spring: 4; damping: 0.35 }
      }
      // Arming happens mid-drag, so this one has to run while tracking --
      // otherwise the accent state snaps in with no cue.
      Behavior on scale {
        enabled: !root.tracking || root.homeArmed
        SpringAnimation { spring: 4; damping: 0.35 }
      }
      Behavior on color { ColorAnimation { duration: 140 } }
    }
  }

  // ============================================================= the band
  //
  // The strip's reservation, split off the strip and put on Bottom.
  //
  // Hyprland resolves exclusive zones layer by layer from Background up to
  // Overlay, the reverse of Sway, which starts at Overlay. On one edge the
  // lowest layer gets the screen's edge and each one above is stacked on top
  // of it. While the strip reserved from Overlay, the on-screen keyboard on
  // Top was arranged first. Measured: the keys took y 520-720 and the strip
  // landed at 500-520, between the app and the keys.
  //
  // moarchy settles the same contest by keeping the keyboard on Top, below the
  // strip's Overlay, because Sway starts at Overlay. Here the keyboard runs
  // exactly as moarchy ships it and the reservation moves under it instead.
  // It draws nothing and takes no input: Bottom is below every window and
  // every sheet, so the band is reserved from where nothing can be seen.
  PanelWindow {
    id: band

    anchors { bottom: true; left: true; right: true }
    implicitHeight: root.stripHeight
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-band"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Auto

    mask: Region {}
  }

  // ======================================================= the edge surface
  PanelWindow {
    id: edge

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-edge"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // The whole output, bar band and strip band included, so the band below
    // sits at the true bottom of the screen and the region can open over
    // everything.
    exclusionMode: ExclusionMode.Ignore

    // Two regions swapped, rather than one region whose geometry is bound to
    // `tracking`. A Region's own property changes do not re-apply the mask --
    // the surface keeps whatever the region measured when it was attached --
    // and assigning a different Region object does.
    mask: root.tracking && !root.borrowed ? fullMask : bandMask

    property Region fullMask: Region {
      width: edge.width
      height: edge.height
    }

    property Region bandMask: Region {
      y: edge.height - root.stripHeight
      width: edge.width
      height: root.stripHeight
    }

    MouseArea {
      anchors.fill: parent
      onPressed: mouse => root.stripPressed(mouse.x, mouse.y)
      onPositionChanged: mouse => root.stripMoved(mouse.x, mouse.y)
      onReleased: root.stripReleased()
      onCanceled: root.stripCanceled()
    }
  }

  // I1a. Whether the strip's band is the theme's background rather than the
  // wallpaper: whenever a window is focused. A window stops at the top of the
  // strip -- the band surface reserves it off every window -- so without this
  // Settings, Wi-Fi and every app end in a stripe of wallpaper with the pill
  // drawn on it. An empty workspace keeps the wallpaper, because it is the
  // home screen. Asked the way the carousel's activeToplevel() asks it.
  //
  // I1a's other clause: the wallpaper again while the on-screen keyboard is up,
  // when the band sits under the keyboard rather than under the app.
  //
  // Read off the home surface's own height, not from sm.puri.OSK0, which would
  // be a DBus round trip and stale between asks. The home surface reserves
  // nothing, so it is arranged into what every exclusive surface left and
  // shrinks by the keyboard's zone when the keyboard comes up.
  readonly property bool keyboardUp: !!home.screen
    && home.height < home.screen.height
                     - (root.host ? root.host.keyboardPanelHeight : 200) / 2

  // Through the host's focusedToplevel() rather than walking the toplevel list
  // again here, which is what this was. It is the same walk the back gesture
  // makes to decide what G4 closes, and two copies of it can disagree: a band
  // that fills for a window back cannot find is one fault reported twice.
  readonly property bool bandFilled:
    !root.keyboardUp && !!(root.host && root.host.focusedToplevel())

  // ========================================================== the left edge
  //
  // G. The one surface here that takes touch ahead of an app, which is why the
  // band is 16px and why it stops short of the bottom. Overlay so it sits above
  // the drawer and the carousel and can close them (G3) -- on Top they map
  // later and would win.
  //
  // Full-screen, unlike moarchy's 16px-wide surface, because this compositor
  // stops delivering motion at the surface's own edge: the surface that owns a
  // gesture has to be as large as the gesture. What is 16px here is the input
  // region, and it opens to the whole screen from press to release the way the
  // edge surface's does.
  PanelWindow {
    id: back

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-back"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserve nothing: this band overlaps whatever is under it rather than
    // moving it, which is what makes the leftmost 16px of every app still
    // belong to the gesture (G10a, D3).
    exclusionMode: ExclusionMode.Ignore

    // Two regions swapped rather than one region bound to `backTracking`, for
    // the reason the edge surface gives: a Region's own property changes do
    // not re-apply the mask, and assigning a different Region object does.
    mask: root.backTracking && !root.backBorrowed ? backFullMask : backBandMask

    property Region backFullMask: Region {
      width: back.width
      height: back.height
    }

    // G8, G10. The band: 16px wide, starting below the bar and stopping one
    // strip plus one keyboard panel short of the bottom.
    property Region backBandMask: Region {
      y: root.backEdgeTopInset
      width: root.backEdgeWidth
      height: root.backEdgeHeight
    }

    MouseArea {
      anchors.fill: parent
      onPressed: mouse => root.backPressed(mouse.x, mouse.y)
      onPositionChanged: mouse => root.backMoved(mouse.x, mouse.y)
      onReleased: root.backReleased()
      onCanceled: root.backCanceled()
    }
  }

  // ======================================================= the home screen
  PanelWindow {
    id: home

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-home"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserve nothing, and be arranged into what the bar and the strip left.
    // This must never change any window's geometry; it only catches a gesture
    // on empty space.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    // I1a. One strip further down, under the strip's band, the way the drawer
    // extends (I1). The zone stays zero, so no window moves: what grows is only
    // where this surface can draw, and the edge surface above it still takes
    // every press in the band.
    margins.bottom: -root.stripHeight

    // Bottom is below every window, so this shows only where no window is
    // drawn -- the band -- and every sheet draws over it as before.
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: root.stripHeight
      visible: root.bandFilled
      color: Color.background
    }

    MouseArea {
      anchors.fill: parent
      onPressed: mouse => root.homePressed(mouse.x, mouse.y)
      onPositionChanged: mouse => root.homeMoved(mouse.x, mouse.y)
      onReleased: root.homeReleased()
      onCanceled: root.homeReleased()
    }
  }
}
