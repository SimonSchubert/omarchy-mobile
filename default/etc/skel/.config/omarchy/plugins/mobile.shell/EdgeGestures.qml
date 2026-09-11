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
// The three surfaces
// ---------------------------------------------------------------------------
//   strip   Overlay, bottom, 20px, exclusive, INPUT-TRANSPARENT.
//           Reserves the band off every window the way Android's navigation
//           bar does, so an app is laid out above the pill, and draws the
//           pill. It takes no input: it cannot grow without a resize.
//   edge    Overlay, full screen, reserves nothing. Owns the strip gesture.
//           Its input region is the band at rest and the whole screen from
//           press to release, so a drag that leaves the band keeps being
//           delivered. Overlay puts it above both sheets, so the band stays
//           live with either one up (A6, A7).
//   home    Bottom, full screen, zero zone. The drag that opens the drawer (D).
//           Below every window: on an empty workspace it gets the touch, and on
//           an occupied one the app is over it and it gets nothing. The layer
//           answers "is this the home screen", and nothing here asks. It never
//           has to grow -- it is already the size of the gesture.
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
        root.carousel.close()
        root.host.goHome()
      } else if (root.pull >= root.recentsCommit || root.velocity >= root.fling) {
        root.carousel.open()
      } else {
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
    }
  }

  // ============================================================ the strip
  PanelWindow {
    id: strip

    // Anchoring left+right+bottom without `top` gives a full-width band whose
    // height we set, and ExclusionMode.Auto reserves exactly that height off
    // every window.
    anchors { bottom: true; left: true; right: true }
    implicitHeight: root.stripHeight
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-strip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Auto

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

    MouseArea {
      anchors.fill: parent
      onPressed: mouse => root.homePressed(mouse.x, mouse.y)
      onPositionChanged: mouse => root.homeMoved(mouse.x, mouse.y)
      onReleased: root.homeReleased()
      onCanceled: root.homeReleased()
    }
  }
}
