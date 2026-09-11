// The pull-down: quick settings and notifications, dragged out of the top
// edge. docs/spec/shade.md is what it shows; gestures.md A8, H2, H5 and H7 are
// how it moves.
//
// Ported from moarchy.shade. What changed on the way, and why:
//
//   the surface   moarchy grows its surface from the bar's height to the
//                 screen's at the top of a drag and relies on the implicit
//                 grab to keep the touch while it does. Hyprland stops motion at
//                 a layer surface's edge, so this surface is full-screen and
//                 always mapped and its INPUT REGION grows instead: the bar's
//                 band at rest, the whole screen from press to release. The
//                 edge surface's pattern, for the same reason.
//   the bar       Bar.qml, this plugin's other entry point, is display-only for
//                 the reason moarchy.bar is: this surface is Overlay, above the
//                 bar's Top, and every touch along the bar arrives here.
//   services      Through firstPartyServiceFor(), which the host grants a
//                 plugin that declares kind "bar" -- one of the reasons this
//                 plugin declares one (Bar.qml).
//   clearing      The notifications proxy carries doNotDisturb and nothing that
//                 clears, so Clear all goes through the service's own public
//                 IPC, `omarchy-shell notifications`.
//   toasts        There are none (S24). Bar.qml declares notificationPopups
//                 false, and the service writes every notification straight
//                 into the history this lists
//                 (patches/notification-popups-bar-opt-out.patch). This file
//                 used to absorb the toasts on each open instead, which left
//                 them over every app until somebody pulled the shade down.
//   tapping       A card does what clicking its toast did, as far as history
//                 keeps it (S27): the notification's --exec argv, else the
//                 sender's window, else a launch of its app.
//   the gear      Opens Settings, and power opens it at its Power page (S2,
//                 S3, settings.md A1, A3). Until Settings existed both opened
//                 upstream's Omarchy menu, which on Hyprland at least
//                 dismissed on a tap outside it.
//   rotate        hl.monitor({ transform }) through hyprctl eval (S11).
//   brightness    Hidden with no backlight to drive, the way the torch is
//                 (S10). This VM has none.
//
// Radii are written out rather than taken from Style.cornerRadius, which
// mirrors Hyprland's decoration:rounding -- right for tiled windows, wrong for
// every surface in a phone UI. Colours all come from the theme.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui as Ui
import "Theme.js" as Theme

Item {
  id: root

  property var host: null
  readonly property var shell: root.host ? root.host.shell : null

  readonly property string historyDir:
    Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"

  // ------------------------------------------------------------ geometry
  //
  // The grab band is exactly the bar, so the whole status bar is the handle.
  // Read off the host's bar state, which Bar.qml publishes, so a bar that
  // changes height cannot leave a dead sliver or an overhang.
  readonly property int stripHeight: root.shell && root.shell.bar && root.shell.bar.barSize > 0
    ? root.shell.bar.barSize : Style.space(26)

  // The home pill's band. While the shade is up this surface takes it and
  // forwards it to the strip's own logic (A8; the last MouseArea at the foot of
  // this file). The back edge will need the same forwarding when G lands.
  readonly property int gestureStrip: root.host ? root.host.stripHeight : Style.space(20)

  readonly property int screenHeight: shadeWindow.screen ? shadeWindow.screen.height : 720

  // S22. Deliberately short of the full screen. The band of scrim underneath is
  // the tap-to-dismiss target and where a thumb starts the up-drag that closes
  // the shade (H2); a sheet allowed to reach the bottom would leave the close
  // drag starting within 26px of the top with nowhere to travel.
  readonly property real sheetFraction: 0.9
  readonly property int sheetMax:
    Math.max(1, Math.round((root.screenHeight - root.gestureStrip) * root.sheetFraction))

  readonly property int sheetPadTop: Style.space(8)
  readonly property int sheetPadBottom: Style.space(18)
  readonly property int sheetPadSide: Style.space(12)
  readonly property int sheetGap: Style.space(10)

  // S21. As tall as what is in it, measured off the Column rather than summed
  // here -- a sum at this end of the file would be a second layout to keep in
  // step with the first.
  readonly property int sheetWanted:
    sheetColumn.implicitHeight + root.sheetPadTop + root.sheetPadBottom

  // S22. The cap is enforced one level down, on the list, whose ceiling is
  // derived from sheetMax -- so an overrunning sheet becomes a sheet at sheetMax
  // with a scrolling list, never one with its bottom cut off.
  readonly property int sheetTarget:
    Math.max(1, Math.min(root.sheetMax, root.sheetWanted))

  // S23. sheetHeight is the divisor for both drag mappings, so a notification
  // landing mid-drag would rescale the gesture under the finger. Latched when a
  // drag latches, released by this binding when it ends; latched from
  // sheetHeight rather than sheetTarget, so a growth part-way through its
  // Behavior freezes where it is on screen instead of snapping.
  property int sheetFrozen: 0
  property int sheetHeight: root.dragging ? root.sheetFrozen : root.sheetTarget

  // Both drag entry points go through this. The latch is written before
  // `dragging` flips, so the binding above never reads a stale sheetFrozen.
  function beginDrag(): void {
    root.sheetFrozen = root.sheetHeight
    root.dragging = true
  }

  // -------------------------------------------------------------- type
  readonly property int textWeight: Font.DemiBold

  // Every glyph gets a fixed square slot and is centred on the ink it paints,
  // not on the box the font reserves -- Nerd Font advances differ per glyph,
  // and the painted glyph is rarely centred in its own advance.
  readonly property int glyphSlot: Math.round(Style.font.iconLarge * 1.35)

  // The square a bare glyph answers in (docs/spec/style.md E1, E2, E5). From
  // glyphSlot, so a theme with a larger base size does not shrink it back.
  readonly property int tapSlot: Math.max(Style.space(44), root.glyphSlot)

  // ------------------------------------------------------------- shape
  readonly property int radiusSheet: Style.space(28)
  readonly property int radiusTile: Style.space(20)
  readonly property int radiusCard: Style.space(18)

  // ------------------------------------------------------------ colours
  //
  // The theme's popup role, so every Omarchy theme restyles the shade for free.
  // NOT `onSurface` / `onAccent`: QML reserves the `on<Uppercase>` prefix for
  // signal handlers, the property reads as undefined, and a colour bound to it
  // paints pure black with nothing logged.
  readonly property color surface: Color.popups.background
  readonly property color textOnSurface: Color.popups.text
  readonly property color container: Util.alpha(Color.popups.text, 0.08)
  readonly property color accent: Color.accent
  readonly property color textOnAccent: Color.background
  readonly property color subduedBase: Theme.mix(
    Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1), Color.popups.text, 0.08)
  readonly property color subdued: Theme.readableOn(root.subduedBase,
                                                   Color.popups.text, 0.55, 4.5)

  component PressVeil: Veil { ink: root.textOnSurface }

  // ---------------------------------------------------------- drag state
  property real progress: 0        // 0 shut .. 1 open
  property bool dragging: false

  // Mid-drag is neither open nor shut. Reporting "open" there would let a
  // swipe on the home pill try to close a shade still being pulled out.
  readonly property bool opened: root.progress >= 1 && !root.dragging

  // Travel that commits, as a fraction of the sheet. Less than half to open:
  // a shade is cheap to close and annoying to have to drag all the way.
  readonly property real openFraction: 0.35
  readonly property real closeFraction: 0.75
  // Speed that commits regardless of travel, logical px per ms.
  readonly property real flingVelocity: 0.6
  readonly property int slop: Style.space(6)

  // Shortest interval a speed may be measured over. Date.now() has millisecond
  // resolution, and a compositor handing on a pointer stream delivers two
  // motion events in the same millisecond often enough that moarchy's
  // `max(1, dt)` turns a 3px step into a fling (docs/build-log.md, the drawer).
  readonly property int velocityFloor: 8

  Behavior on progress {
    enabled: !root.dragging
    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
  }

  // Only while parked open: shut it is invisible, and mid-gesture the progress
  // ramp already owns the frame budget. 180 rather than 220, because a list
  // filling in is not a second open.
  Behavior on sheetHeight {
    enabled: root.opened
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  // One integer per frame while a drag is in flight. "Does it follow the
  // finger" is a question about the number of samples, and polling `state`
  // answers it at a tenth of the frame rate. Cleared on press, not on latch,
  // so a gesture that never latched shows as empty; gated on `dragging`, so the
  // fall after release -- which runs whether or not a finger drove anything --
  // is not counted (H2).
  property var dragTrace: []

  onProgressChanged: {
    if (!root.dragging) return
    var next = root.dragTrace.slice()
    if (next.length < 200) next.push(Math.round(root.progress * 100))
    root.dragTrace = next
  }

  // A gesture that ends without a release would leave the input region full
  // screen and the phone answering nothing, which is far worse than a stranded
  // sheet -- so this is not optional.
  Timer {
    id: watchdog
    interval: 4000
    onTriggered: {
      root.handleTracking = false
      root.sheetDragging = false
      root.dragging = false
      root.progress = 0
    }
  }

  // ------------------------------------------- the pull from the status bar
  property bool handleTracking: false
  property bool handleLatched: false
  property real startProgress: 0
  property real startY: 0
  property real velocity: 0
  property real lastY: 0
  property real lastT: 0

  function sample(y: real): void {
    var now = Date.now()
    var dt = now - root.lastT
    if (dt < root.velocityFloor) return
    // Smoothed, so one jittery frame cannot read as a fling. Positive is down,
    // which for this sheet is the opening direction.
    root.velocity = root.velocity * 0.6 + ((y - root.lastY) / dt) * 0.4
    root.lastY = y
    root.lastT = now
  }

  function handlePress(y: real): void {
    root.dragTrace = []
    root.startY = y
    root.lastY = y
    root.lastT = Date.now()
    root.startProgress = root.progress
    root.velocity = 0
    root.handleLatched = false
    root.handleTracking = true
    watchdog.restart()
  }

  function handleMove(y: real): void {
    if (!root.handleTracking) return
    var dy = y - root.startY
    if (!root.handleLatched) {
      if (Math.abs(dy) < root.slop) return
      root.handleLatched = true
      // S21a. The list is read per open. Starting the read as the pull begins
      // means the sheet has its contents by the time anyone sees them; the
      // height is frozen for the drag either way (S23).
      if (root.startProgress === 0) root.refresh()
      root.beginDrag()
      root.lastY = y
      root.lastT = Date.now()
    }
    root.sample(y)
    root.progress = Math.max(0, Math.min(1, root.startProgress + dy / root.sheetHeight))
    watchdog.restart()
  }

  function handleRelease(): void {
    if (!root.handleTracking) return
    root.handleTracking = false
    watchdog.stop()
    if (!root.handleLatched) return   // a tap on the bar is nothing
    var wasOpen = root.startProgress >= 0.5
    var target
    if (root.velocity >= root.flingVelocity) target = 1
    else if (root.velocity <= -root.flingVelocity) target = 0
    else if (wasOpen) target = root.progress >= root.closeFraction ? 1 : 0
    else target = root.progress >= root.openFraction ? 1 : 0
    root.dragging = false
    if (target === 1) root.open()
    else root.close()
  }

  function handleCancel(): void {
    root.handleTracking = false
    watchdog.stop()
    root.dragging = false
    root.progress = root.startProgress >= 0.5 ? 1 : 0
  }

  // ------------------------------------------------- H2: dragging the body
  //
  // The grab band is the affordance, not the whole gesture: dragging up
  // anywhere on the sheet closes it. Every tile here is a MouseArea and holds
  // the grab for its gesture, so the tiles do both jobs -- a touch that never
  // travels activates, one that goes up past the slop drags the sheet.
  readonly property int dragSlop: Style.space(10)

  // Android's long-press interval. Milliseconds, not a length.
  readonly property int holdInterval: 500

  // Scene coordinates: every one of those MouseAreas is a child of the sheet,
  // and the sheet is what moves.
  property real sheetPressY: 0
  property real sheetStartProgress: 0
  property bool sheetDragging: false

  // Cleared on the next press, not on release: Qt delivers `released` then
  // `clicked`, so a flag cleared on release is already false when the click
  // lands and the tile fires the action the drag started on.
  property bool sheetWasDrag: false

  // A short, fast flick means the same as a long slow drag. Without it a close
  // gesture that starts near the top of the sheet cannot commit at all.
  property real sheetVelocity: 0
  property real sheetLastY: 0
  property real sheetLastT: 0

  function sheetPress(item, mouse): void {
    root.dragTrace = []
    root.sheetPressY = item.mapToItem(null, mouse.x, mouse.y).y
    root.sheetStartProgress = root.progress
    root.sheetDragging = false
    root.sheetWasDrag = false
    root.sheetVelocity = 0
    root.sheetLastY = root.sheetPressY
    root.sheetLastT = Date.now()
    watchdog.restart()
  }

  function sheetMove(item, mouse): void {
    var nowY = item.mapToItem(null, mouse.x, mouse.y).y
    var dy = nowY - root.sheetPressY
    if (!root.sheetDragging) {
      // Upward only. A downward drag on an open shade means nothing, and
      // claiming it would fight the notification list (H5).
      if (dy >= -root.dragSlop) return
      // sheetDragging first: it holds the input region open, and beginDrag
      // is about to make `opened` false.
      root.sheetDragging = true
      root.beginDrag()
    }
    var now = Date.now()
    var dt = now - root.sheetLastT
    if (dt >= root.velocityFloor) {
      // Negative is upward, which for this sheet is the closing direction.
      root.sheetVelocity = root.sheetVelocity * 0.6 + ((nowY - root.sheetLastY) / dt) * 0.4
      root.sheetLastY = nowY
      root.sheetLastT = now
    }
    root.progress = Math.max(0, Math.min(1, root.sheetStartProgress + dy / root.sheetHeight))
    watchdog.restart()
  }

  // H3. Short of the commit it springs back and changes nothing.
  function sheetRelease(): void {
    watchdog.stop()
    if (!root.sheetDragging) return
    root.sheetWasDrag = true
    root.sheetDragging = false
    root.dragging = false
    if (root.sheetVelocity <= -root.flingVelocity) root.close()
    else if (root.sheetVelocity >= root.flingVelocity) root.progress = 1
    else if (root.progress >= root.closeFraction) root.progress = 1
    else root.close()
  }

  function sheetCancel(): void {
    watchdog.stop()
    if (!root.sheetDragging) return
    root.sheetDragging = false
    root.dragging = false
    root.progress = root.sheetStartProgress >= 0.5 ? 1 : 0
  }

  // ------------------------------------------------------------ open / close
  function open(): void {
    if (root.host) root.host.closeOthers("shade")
    root.dragging = false
    root.progress = 1
    root.refresh()
  }

  function close(): void {
    root.dragging = false
    root.handleTracking = false
    root.progress = 0
  }

  // Everything that cannot be bound reactively, pulled once per open rather
  // than on a timer: none of it changes while the shade is shut.
  function refresh(): void {
    if (!airplaneProbe.running) airplaneProbe.running = true
    if (!brightnessProbe.running) brightnessProbe.running = true
    if (!torchProbe.running) torchProbe.running = true
    // Twice, and the deferred one is not the redundant one. Immediately, so the
    // height the sheet opens at is decided before the open animation starts;
    // deferred, because the service writes through its own file-job queue, and
    // a notification that arrived as the pull began can be a moment behind the
    // read in the same tick.
    if (!historyRead.running) historyRead.running = true
    historyRefresh.restart()
  }

  Timer { id: historyRefresh; interval: 300; onTriggered: historyRead.running = true }

  // S18, S21a. The list is live while the shade is down, not read once per
  // open. The service writes each notification into the history directory
  // through its own file-job queue, and on this VM that finished after the
  // deferred read above: three notifications sent, two listed, the third
  // turning up only on the next open. A notification arriving with the shade
  // already down belongs in the list too, which S21a's "per open" never
  // promised against -- it is one of the spec's unconfirmed lines. The height
  // stays put under a finger regardless (S23).
  //
  // The directory, not a file: a FileView cannot watch a path that does not
  // exist yet, and the service creates and deletes rows rather than editing
  // them. Debounced through historyRefresh, because a burst of notifications
  // and Clear all both write several files at once.
  FileView {
    path: root.historyDir
    watchChanges: true
    printErrors: false
    onFileChanged: if (root.progress > 0) historyRefresh.restart()
  }

  // ------------------------------------------------------------- sources
  readonly property var notifications: root.shell && typeof root.shell.firstPartyServiceFor === "function"
    ? root.shell.firstPartyServiceFor("omarchy.notifications") : null
  readonly property var media: root.shell && typeof root.shell.firstPartyServiceFor === "function"
    ? root.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var player: root.media ? root.media.activePlayer : null

  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property var sink: Pipewire.defaultAudioSink
  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  readonly property var wifiDevice: {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].type === DeviceType.Wifi) return devices[i]
    return null
  }

  // S4. The tiles say what they are connected to, not just on or off -- the
  // difference between a switch and a status panel.
  readonly property string wifiLabel: {
    if (!root.wifiDevice) return "No Wi-Fi"
    if (!Networking.wifiEnabled) return "Off"
    var device = root.wifiDevice
    if (!device.connected) return "Not connected"
    var networks = device.networks ? device.networks.values : []
    for (var i = 0; i < networks.length; i++)
      if (networks[i] && networks[i].connected) return String(networks[i].name || "Connected")
    return "Connected"
  }

  // S6a. A known network in range is one the phone is about to join by itself,
  // so toggling the radio off mid-reconnect is the last thing a tap should
  // mean; with none in range the picker is the only way out.
  readonly property bool wifiKnownInRange: {
    var device = root.wifiDevice
    var networks = device && device.networks ? device.networks.values : []
    for (var i = 0; i < networks.length; i++)
      if (networks[i] && networks[i].known) return true
    return false
  }

  readonly property bool wifiStranded:
    !!root.wifiDevice && Networking.wifiEnabled && !root.airplane
    && !root.wifiDevice.connected && !root.wifiKnownInRange

  // S5
  readonly property string btLabel: {
    if (!root.btAdapter) return "No adapter"
    if (!root.btAdapter.enabled) return "Off"
    var devices = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].connected) return String(devices[i].name || "Connected")
    return "On"
  }

  property bool airplane: false
  property int brightness: 50
  property bool brightnessAvailable: false
  property bool torchAvailable: false
  property bool torchOn: false
  property string torchPath: ""

  // S8. Airplane mode is one lever over every radio, which is what a phone
  // means by it -- `nmcli radio` would leave Bluetooth up. "1" means every
  // switch reads blocked; anything else means at least one radio is live.
  // With no rfkill switches at all the answer is empty, which is not airplane.
  Process {
    id: airplaneProbe
    command: ["bash", "-c", "cat /sys/class/rfkill/*/soft 2>/dev/null | sort -u | tr -d '\\n'"]
    stdout: StdioCollector {
      onStreamFinished: root.airplane = String(text || "").trim() === "1"
    }
  }

  // S12, S13. The first backlight, by class rather than by the PinePhone's
  // device name. No backlight -- this VM -- and the slider is not drawn.
  Process {
    id: brightnessProbe
    command: ["bash", "-c", "brightnessctl -c backlight -m 2>/dev/null | head -1 | cut -d, -f4 | tr -d '%\\n'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var v = parseInt(String(text || "").trim(), 10)
        root.brightnessAvailable = isFinite(v)
        if (isFinite(v)) root.brightness = Math.max(1, Math.min(100, v))
      }
    }
  }

  // S10. Any writable flash or torch LED, rather than the PinePhone's one path.
  // Probed, not assumed: a tile that is drawn and does nothing is worse than
  // one that is not drawn.
  Process {
    id: torchProbe
    command: ["bash", "-c",
      "for f in /sys/class/leds/*flash*/brightness /sys/class/leds/*torch*/brightness; do " +
      "[ -w \"$f\" ] && { echo \"$f $(cat \"$f\")\"; exit 0; }; done; echo unavailable"]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(text || "").trim()
        root.torchAvailable = out !== "unavailable" && out !== ""
        var parts = out.split(" ")
        root.torchPath = root.torchAvailable ? parts[0] : ""
        root.torchOn = root.torchAvailable && parts.length > 1 && parts[1] !== "0"
      }
    }
  }

  // --------------------------------------------------------- actions

  // Set by `shade dryRun 1`. What a tile decided is recorded either way; only
  // the radio write, which cannot be taken back on a phone reached over that
  // radio, is held back. Summoning a screen is not held back -- it can be
  // closed again, and holding it back made S6 unpassable by construction in
  // moarchy.
  property bool dryRun: false
  property string lastLaunch: ""
  property string lastAction: ""

  function setAirplane(on) {
    root.lastAction = on ? "airplane-on" : "airplane-off"
    root.airplane = on
    if (!root.dryRun) Quickshell.execDetached(["rfkill", on ? "block" : "unblock", "all"])
    airplaneRecheck.restart()
  }

  // S9. Turning a radio on from inside airplane mode clears airplane mode, by
  // unblocking just that radio: airplane is "every switch blocked", so freeing
  // one clears it without switching the others back on behind the user.
  property string pendingRadio: ""

  function enableRadio(kind) {
    Quickshell.execDetached(["rfkill", "unblock", kind])
    root.pendingRadio = kind
    airplaneRecheck.restart()
  }

  // After the unblock has landed, not alongside it: NetworkManager refuses to
  // enable an interface rfkill still has blocked, and drops the write silently.
  Timer {
    id: airplaneRecheck
    interval: 700
    onTriggered: {
      airplaneProbe.running = true
      if (root.pendingRadio === "wifi") Networking.wifiEnabled = true
      else if (root.pendingRadio === "bluetooth" && root.btAdapter)
        root.btAdapter.enabled = true
      root.pendingRadio = ""
    }
  }

  function wifiTap() {
    if (root.airplane) {
      root.lastAction = "unblock"
      if (!root.dryRun) root.enableRadio("wifi")
      return
    }
    if (root.wifiStranded) {
      root.openWifi()
      return
    }
    root.lastAction = "toggle"
    if (!root.dryRun) Networking.wifiEnabled = !Networking.wifiEnabled
  }

  function wifiHold() { root.openWifi() }

  // S6, S6c. Both wide tiles hold to open the screen their radio is for. The
  // shade goes first: it is a sheet over this workspace, and the screen is a
  // window on another one (gestures.md K1).
  function openScreen(name) {
    root.close()
    root.lastAction = "picker"
    root.lastLaunch = name
    // returnTo: the screen's back chevron brings the shade back down, which is
    // where the long press came from.
    if (root.host) root.host.openScreen(name, "shade")
  }

  function openWifi() { root.openScreen("wifi") }
  function openBluetooth() { root.openScreen("bluetooth") }

  // S6c. No stranded case: a Bluetooth adapter with nothing in range is the
  // normal resting state of one, not a dead end.
  function btTap() {
    if (root.airplane) {
      root.lastAction = "unblock"
      if (!root.dryRun) root.enableRadio("bluetooth")
      return
    }
    root.lastAction = "toggle"
    if (!root.dryRun && root.btAdapter) root.btAdapter.enabled = !root.btAdapter.enabled
  }

  function btHold() { root.openBluetooth() }

  function setBrightness(percent) {
    // S13. Never below 1%: a screen at zero is a device you cannot recover
    // without a keyboard.
    var v = Math.max(1, Math.min(100, Math.round(percent)))
    root.brightness = v
    Quickshell.execDetached(["brightnessctl", "-c", "backlight", "set", v + "%"])
  }

  function setTorch(on) {
    if (!root.torchAvailable || root.torchPath === "") return
    root.torchOn = on
    Quickshell.execDetached(["bash", "-c",
      "echo " + (on ? "1" : "0") + " > '" + root.torchPath + "'"])
  }

  // S11. Portrait and one landscape, toggled -- not a cycle through all four,
  // which put upside-down on the route to the landscape anybody wants.
  //
  // Hyprland 0.56 has no rotate verb and no keyword parser, so the monitor is
  // re-declared with hl.monitor() carrying everything it already has and the
  // other transform. Measured: transform 1 rotates, transform 0 restores. It
  // lasts until the next config reload, which re-reads monitors.lua.
  function rotate() {
    root.lastAction = "rotate"
    Quickshell.execDetached(["bash", "-c",
      "m=$(hyprctl -j monitors | jq -r 'first(.[]) | " +
      "\"\\(.name) \\(.width)x\\(.height)@\\(.refreshRate) \\(.x)x\\(.y) \\(.scale) \\(.transform)\"'); " +
      "read -r name mode pos scale t <<<\"$m\"; " +
      "[ \"$t\" = 0 ] && n=1 || n=0; " +
      "hyprctl eval \"hl.monitor({ output = \\\"$name\\\", mode = \\\"$mode\\\", " +
      "position = \\\"$pos\\\", scale = $scale, transform = $n })\""])
  }

  // S2, S3. Settings, at the root or at its Power page (settings.md A1, A3).
  // The gear names no page, so a Settings already running on another
  // workspace comes back on the page it was left on (A7); power names one, and
  // goes there whatever Settings was showing.
  function openSettings(page) {
    root.close()
    root.lastAction = "settings"
    root.lastLaunch = "settings:" + (page || "root")
    if (root.host) root.host.openScreen("settings", "", page || "")
  }

  // ---------------------------------------------------- notification history
  //
  // Read off disk rather than through the service's showRecentHistory(), which
  // replays history back into the popup model and so sprays toasts over the
  // top of the shade that is displaying it.
  property var historyRows: []

  Process {
    id: historyRead
    command: ["bash", "-c", "cat '" + root.historyDir + "'/*.json 2>/dev/null | tail -40"]
    stdout: StdioCollector {
      onStreamFinished: {
        var rows = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (!line) continue
          try { rows.push(JSON.parse(line)) } catch (e) { /* half-written file */ }
        }
        rows.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
        root.historyRows = rows
      }
    }
  }

  // The service names each file <timestamp>-<originalId>.json, so one row can
  // be dropped without disturbing the rest.
  function rowStem(row) {
    return String(row.timestamp || 0) + "-" + String(row.originalId || 0)
  }

  // S25. What leads a card, first match wins: the notification's own picture
  // (an avatar, album art -- upstream copies these beside the history, so they
  // outlive the sender's temp file), its app icon, the icon of the desktop
  // entry its app name matches, the glyph omarchy-notification-send attaches,
  // and last a bell. `glyph` is always set, because a picture that is named
  // and will not load falls back to it. `kind` is what `shade icons` reports.
  readonly property int cardIcon: Style.space(36)
  readonly property string bellGlyph: "󰂚"

  // Upstream NotificationCard's rule, so a card here and a toast on the
  // desktop resolve one value the same way. `check` is what keeps an unknown
  // themed name from coming back as Qt's missing-texture placeholder.
  function iconSource(value): string {
    var s = String(value || "")
    if (s === "") return ""
    if (s.indexOf("file://") === 0 || s.indexOf("image://") === 0) return s
    if (s.charAt(0) === "/") return Util.fileUrl(s)
    return String(Quickshell.iconPath(s, true) || "")
  }

  function iconFor(row) {
    var r = row || {}
    var glyph = String(r.glyph || "") || root.bellGlyph
    var image = root.iconSource(r.image)
    if (image !== "") return { kind: "image", source: image, glyph: glyph }
    var appIcon = root.iconSource(r.appIcon)
    if (appIcon !== "") return { kind: "appIcon", source: appIcon, glyph: glyph }
    var entry = root.host ? root.host.entryFor(r.app) : null
    var apps = root.host ? root.host.apps : null
    var fromEntry = entry && apps ? String(apps.iconSource(entry.icon) || "") : ""
    if (fromEntry !== "") return { kind: "entry", source: fromEntry, glyph: glyph }
    return { kind: r.glyph ? "glyph" : "fallback", source: "", glyph: glyph }
  }

  // S27. What a tap on a card does, first match wins -- the order upstream's
  // toast click takes, less the one step history cannot keep:
  //
  //   exec    Omarchy's own `--exec` argv, which the row carries as data, so
  //           it survives into history. The first-run "Update System" is one.
  //   focus   the sender's window, if it has one open.
  //   launch  the sender's app, if a desktop entry answers to its name --
  //           what a phone does with a notification from an app not running.
  //   none    nothing to do: the card does not light, and a tap leaves it.
  //
  // A libnotify "default" action is the step missing. It lives on the
  // sender's live notification, which the service lets go of once the
  // notification is written into history; focusing the sender is upstream's
  // own answer for the senders that register none.

  // Upstream's parseExecArgv (NotificationLogic.js): a structural check that
  // fails closed. Which senders may set the hint is the notification bus's
  // boundary, not this function's -- the same one upstream's toast has.
  function execArgvFor(row) {
    var text = String((row && row.execArgv) || "")
    if (!text) return null
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { return null }
    if (!Array.isArray(parsed) || parsed.length === 0) return null
    for (var i = 0; i < parsed.length; i++)
      if (typeof parsed[i] !== "string") return null
    if (!parsed[0] || parsed[0].charAt(0) === "-") return null
    return parsed
  }

  // The sender's window: its app id is the notification's app name, the tail
  // of a reverse-DNS one, or the id of the desktop entry the name matches --
  // "Web" notifies, "org.gnome.Epiphany" is the window.
  function windowFor(row) {
    var app = String((row && row.app) || "").toLowerCase()
    if (!app) return null
    var entry = root.host ? root.host.entryFor(app) : null
    var entryId = entry ? String(entry.id || "").toLowerCase().replace(/\.desktop$/, "") : ""
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var id = String((list[i] && list[i].appId) || "").toLowerCase()
      if (id && (id === app || id === entryId || id.split(".").pop() === app)) return list[i]
    }
    return null
  }

  function actionFor(row): string {
    if (root.execArgvFor(row)) return "exec"
    if (root.windowFor(row)) return "focus"
    var entry = root.host && row ? root.host.entryFor(row.app) : null
    return entry && root.host.apps ? "launch" : "none"
  }

  // The notification is done with once acted on, as on Android: the card goes
  // and the shade with it, so what the tap opened is what is on screen. The
  // row is dropped last -- that destroys the delegate this was called from.
  function runRow(row): void {
    var kind = root.actionFor(row)
    root.lastAction = "card:" + kind
    if (kind === "none") return
    if (kind === "exec") {
      // Through bash's positional parameters, as upstream runs it: never a
      // shell string, so a title or a filename cannot become a command.
      Util.execArgv(root.execArgvFor(row))
    } else if (kind === "focus") {
      root.host.focusToplevel(root.windowFor(row))
    } else {
      // Through the host, so a card's launch gets the same splash a tap in
      // the drawer gets (windows.md L1).
      root.host.launchApp(root.host.entryFor(row.app), "")
    }
    root.close()
    root.dismissRow(row)
  }

  // H7. Matched on the stem, not on object identity: with a JS array as the
  // model QML can hand out a fresh wrapper per access, and moarchy's `!==`
  // filter removed nothing while the file was already gone.
  function dismissRow(row) {
    if (!row) return
    var stem = root.rowStem(row)
    Quickshell.execDetached(["rm", "-f", root.historyDir + "/" + stem + ".json"])
    var next = []
    for (var i = 0; i < root.historyRows.length; i++)
      if (root.rowStem(root.historyRows[i]) !== stem) next.push(root.historyRows[i])
    root.historyRows = next
  }

  // S19. Every notification, the live popups and the history. Popups first and
  // history after, in one process, because dismissAll archives popups INTO the
  // history -- two independent processes could clear the history first and
  // leave the archived popups behind.
  function clearNotifications() {
    root.lastAction = "clear"
    var p = Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    Quickshell.execDetached(["bash", "-c",
      "export OMARCHY_PATH='" + p + "'; omarchy-shell -q notifications dismissAll; " +
      "sleep 0.4; omarchy-shell -q notifications clear"])
    root.historyRows = []
  }

  IpcHandler {
    target: "shade"

    function state(): string {
      if (root.dragging) return "dragging " + Math.round(root.progress * 100) + "%"
      return root.opened ? "open" : "closed"
    }

    // The samples the last drag produced (H2). A shade that jumps shut reaches
    // `closed` exactly as fast as one that followed the finger, which is why
    // the criterion is the trace and not the state.
    function dragTrace(): string { return root.dragTrace.join(" ") }

    // S21, S22. height == wanted below the cap and both == max at it; a sheet
    // that stretched shows height > wanted, one truncating its own chrome shows
    // wanted > max. `content` is an estimate for unbuilt rows above the cap:
    // assert content > list, never equality.
    function sheet(): string {
      return ["height=" + root.sheetHeight,
              "wanted=" + root.sheetWanted,
              "max=" + root.sheetMax,
              "rows=" + root.historyRows.length,
              "listy=" + Math.round(notificationList.y),
              "listmax=" + notificationList.listMax,
              "list=" + Math.round(notificationList.height),
              "content=" + Math.round(notificationList.contentHeight),
              "scrolls=" + (notificationList.interactive ? 1 : 0)].join(" ")
    }

    // Where a control is on screen, in the logical coordinates vm-drag.sh
    // takes, so a check taps the real thing rather than calling its function.
    // The surface ignores exclusive zones, so surface coordinates are screen
    // coordinates.
    function target(name: string): string {
      var items = {
        gear: gearButton, power: powerButton, wifi: wifiTile, bluetooth: btTile,
        silent: silentTile, airplane: airplaneTile, rotate: rotateTile,
        clearAll: clearAll, volume: volumeSlider
      }
      var item = items[name] || null
      if (name === "card0") item = notificationList.itemAtIndex(0)
      if (name === "card0icon") {
        var first = notificationList.itemAtIndex(0)
        item = first ? first.iconItem : null
      }
      if (!item || !item.visible) return "none"
      var p = item.mapToItem(null, item.width / 2, item.height / 2)
      return Math.round(p.x) + " " + Math.round(p.y) + " " + Math.round(item.width)
    }

    function clear(): string { root.clearNotifications(); return "ok" }
    function open(): string { root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string {
      if (root.opened) root.close(); else root.open()
      return root.opened ? "open" : "closed"
    }

    // One line per notification in the history, so a dismissal is assertable
    // by counting -- the swipe is the only per-card dismissal there is (H7).
    function notifications(): string {
      var out = []
      for (var i = 0; i < root.historyRows.length; i++) {
        var r = root.historyRows[i]
        if (r) out.push(root.rowStem(r) + " " + (r.app || "?") + " " + (r.summary || ""))
      }
      return out.join("\n")
    }

    // S27. What a tap on each card would do, one line per row, in list order.
    function actions(): string {
      var out = []
      for (var i = 0; i < root.historyRows.length; i++) {
        var r = root.historyRows[i]
        if (r) out.push(root.rowStem(r) + " " + root.actionFor(r))
      }
      return out.join("\n")
    }

    // S25. Where each card's icon came from, one line per row, in list order.
    function icons(): string {
      var out = []
      for (var i = 0; i < root.historyRows.length; i++) {
        var r = root.historyRows[i]
        if (r) out.push(root.rowStem(r) + " " + root.iconFor(r).kind)
      }
      return out.join("\n")
    }

    // S4, S6a. What the Wi-Fi tile is reading, so a check can tell which branch
    // a tap will take without inferring it from the network around it.
    function wifi(): string {
      var device = root.wifiDevice
      return [!device ? "absent" : (Networking.wifiEnabled ? "on" : "off"),
              device && device.connected ? "connected" : "disconnected",
              root.wifiKnownInRange ? "known-in-range" : "none-known",
              root.wifiStranded ? "stranded" : "ok",
              "label=" + JSON.stringify(root.wifiLabel)].join(" ")
    }

    function bluetooth(): string {
      return "label=" + JSON.stringify(root.btLabel)
    }

    // The quick settings, as the tiles read them.
    function tiles(): string {
      return ["silent=" + (root.notifications && root.notifications.doNotDisturb ? 1 : 0),
              "airplane=" + (root.airplane ? 1 : 0),
              "torch=" + (root.torchAvailable ? (root.torchOn ? "on" : "off") : "absent"),
              "brightness=" + (root.brightnessAvailable ? root.brightness : "absent"),
              "volume=" + (root.sink && root.sink.audio ? Math.round(root.sink.audio.volume * 100) : "absent"),
              "media=" + (root.player ? "playing" : "none")].join(" ")
    }

    function wifiTap(): string { root.wifiTap(); return root.lastAction }
    function wifiHold(): string { root.wifiHold(); return root.lastAction }
    function btTap(): string { root.btTap(); return root.lastAction }
    function btHold(): string { root.btHold(); return root.lastAction }

    function dryRun(on: string): string {
      root.dryRun = (on === "1" || on === "true" || on === "on")
      return root.dryRun ? "on" : "off"
    }
    function lastLaunch(): string { return root.lastLaunch }
    function lastAction(): string { return root.lastAction }
  }

  // ========================================================== components

  // A quick-settings tile with room for a state line. Two fit across the
  // screen: the two radios you actually want to read, then a row of plain
  // toggles under them.
  component WideTile: Rectangle {
    id: tile
    property string glyph: ""
    property string label: ""
    property string detail: ""
    property bool on: false
    signal activated()

    // S6. Opt-in: a tile with no long press keeps the tap it always had.
    property bool holdable: false
    signal held()

    // Fired while the finger is still down, as Android does. Cleared on the
    // next press rather than on release, for the reason sheetWasDrag is.
    property bool heldFired: false

    height: Style.space(62)
    radius: root.radiusTile
    color: tile.on ? root.accent : root.container
    Behavior on color { ColorAnimation { duration: 140 } }

    // Guarded on the drag: these tiles *are* the sheet's drag handle, so
    // `pressed` stays true for the whole gesture and an unguarded veil would
    // light every tile a scrolling thumb crossed.
    PressVeil {
      anchors.fill: parent
      radius: parent.radius
      ink: tile.on ? root.textOnAccent : root.textOnSurface
      on: tileArea.pressed && !root.sheetDragging
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Ui.OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        width: root.glyphSlot
        height: root.glyphSlot
        text: tile.glyph
        fontFamily: Style.font.family
        fontSize: Style.font.iconLarge
        color: tile.on ? root.textOnAccent : root.textOnSurface
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - root.glyphSlot - Style.space(10)
        spacing: 0

        Text {
          width: parent.width
          text: tile.label
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.weight: root.textWeight
          color: tile.on ? root.textOnAccent : root.textOnSurface
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: tile.detail !== ""
          text: tile.detail
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: root.textWeight
          color: tile.on ? Util.alpha(root.textOnAccent, 0.75) : root.subdued
          elide: Text.ElideRight
        }
      }
    }

    Timer {
      id: hold
      interval: root.holdInterval
      onTriggered: { tile.heldFired = true; tile.held() }
    }

    MouseArea {
      id: tileArea
      anchors.fill: parent
      onPressed: mouse => {
        root.sheetPress(this, mouse)
        tile.heldFired = false
        if (tile.holdable) hold.restart()
      }
      onPositionChanged: mouse => {
        root.sheetMove(this, mouse)
        // Cancelled by the sheet drag latching, not by any movement at all: a
        // thumb held still for half a second still travels a few pixels.
        if (root.sheetDragging) hold.stop()
      }
      onReleased: { hold.stop(); root.sheetRelease() }
      onCanceled: { hold.stop(); root.sheetCancel() }
      onClicked: if (!root.sheetWasDrag && !tile.heldFired) tile.activated()
    }
  }

  // The compact form, for toggles whose whole state is on or off.
  component SmallTile: Rectangle {
    id: small
    property string glyph: ""
    property string label: ""
    property bool on: false
    signal activated()

    height: Style.space(62)
    radius: root.radiusTile
    color: small.on ? root.accent : root.container
    Behavior on color { ColorAnimation { duration: 140 } }

    PressVeil {
      anchors.fill: parent
      radius: parent.radius
      ink: small.on ? root.textOnAccent : root.textOnSurface
      on: smallArea.pressed && !root.sheetDragging
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(3)

      Ui.OpticalGlyph {
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.glyphSlot
        height: root.glyphSlot
        text: small.glyph
        fontFamily: Style.font.family
        fontSize: Style.font.iconLarge
        color: small.on ? root.textOnAccent : root.textOnSurface
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: small.label
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: root.textWeight
        color: small.on ? Util.alpha(root.textOnAccent, 0.75) : root.subdued
      }
    }

    MouseArea {
      id: smallArea
      anchors.fill: parent
      onPressed: mouse => root.sheetPress(this, mouse)
      onPositionChanged: mouse => root.sheetMove(this, mouse)
      onReleased: root.sheetRelease()
      onCanceled: root.sheetCancel()
      onClicked: if (!root.sheetWasDrag) small.activated()
    }
  }

  // A track you can put a thumb on rather than a hairline with a knob. The
  // glyph rides inside it, so the control is its own label.
  component FatSlider: Item {
    id: slider
    property real value: 0        // 0..1
    property string glyph: ""
    // S12. Volume is in-process and free to follow the finger; brightness forks
    // brightnessctl per write, so it waits for the release.
    property bool live: false
    signal committed(real value)

    height: Style.space(48)
    readonly property real clamped: Math.max(0, Math.min(1, slider.value))
    property real dragValue: slider.clamped
    property bool dragging: false
    readonly property real shown: slider.dragging ? slider.dragValue : slider.clamped

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: root.container

      Rectangle {
        height: parent.height
        // Never narrower than the corner diameter: below that a rounded fill
        // collapses into a lens and reads as a rendering fault.
        width: Math.max(parent.height, parent.width * slider.shown)
        radius: parent.radius
        color: root.accent
        Behavior on width {
          enabled: !slider.dragging
          NumberAnimation { duration: 120 }
        }
      }

      // Tap a slider at its current value and nothing else happens -- this is
      // the one response it has then.
      PressVeil {
        anchors.fill: parent
        radius: parent.radius
        on: sliderArea.pressed && !sliderArea.handedOver
      }

      Ui.OpticalGlyph {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(20) - Math.round(root.glyphSlot / 2)
        anchors.verticalCenter: parent.verticalCenter
        width: root.glyphSlot
        height: root.glyphSlot
        text: slider.glyph
        fontFamily: Style.font.family
        fontSize: Style.font.icon
        color: root.textOnAccent
      }
    }

    // S15. Tap-to-set, so the value has already moved by the time it is known
    // whether the finger is going sideways or up. A vertical drag hands the
    // gesture to the sheet and puts the value back -- for a live slider that
    // means undoing a commit it has already sent.
    MouseArea {
      id: sliderArea
      anchors.fill: parent
      property real preValue: 0
      property real pressX: 0
      property bool handedOver: false
      function valueAt(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))) }

      onPressed: mouse => {
        preValue = slider.value
        pressX = mouse.x
        handedOver = false
        root.sheetPress(this, mouse)
        slider.dragging = true
        slider.dragValue = valueAt(mouse.x)
        if (slider.live) slider.committed(slider.dragValue)
      }

      onPositionChanged: mouse => {
        if (handedOver) { root.sheetMove(this, mouse); return }
        if (!slider.dragging) return
        var dyScene = mapToItem(null, mouse.x, mouse.y).y - root.sheetPressY
        if (dyScene < -root.dragSlop && Math.abs(dyScene) > Math.abs(mouse.x - pressX)) {
          slider.dragging = false
          handedOver = true
          if (slider.live) slider.committed(preValue)
          slider.dragValue = preValue
          root.sheetMove(this, mouse)
          return
        }
        slider.dragValue = valueAt(mouse.x)
        if (slider.live) slider.committed(slider.dragValue)
      }

      onReleased: mouse => {
        if (handedOver) { root.sheetRelease(); handedOver = false; return }
        if (!slider.dragging) return
        slider.dragging = false
        slider.committed(valueAt(mouse.x))
      }

      onCanceled: {
        if (handedOver) { root.sheetCancel(); handedOver = false }
        slider.dragging = false
      }
    }
  }

  // A circular tonal button, for the two things in the header that are not
  // quick settings. 36 drawn, 44 answering (docs/spec/style.md E1-E3).
  component RoundButton: Rectangle {
    id: rb
    property string glyph: ""
    signal activated()
    width: Style.space(36)
    height: width
    radius: width / 2
    color: root.container

    PressVeil {
      anchors.fill: parent
      radius: parent.radius
      on: rbArea.pressed && !root.sheetDragging
    }

    Ui.OpticalGlyph {
      anchors.fill: parent
      text: rb.glyph
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: root.textOnSurface
    }

    MouseArea {
      id: rbArea
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      onPressed: mouse => root.sheetPress(this, mouse)
      onPositionChanged: mouse => root.sheetMove(this, mouse)
      onReleased: root.sheetRelease()
      onCanceled: root.sheetCancel()
      onClicked: if (!root.sheetWasDrag) rb.activated()
    }
  }

  // ============================================================== surface

  PanelWindow {
    id: shadeWindow

    // Always mapped and full-screen, for the reason in the header: on this
    // compositor the surface that owns a gesture has to be as large as the
    // gesture already when the press lands. Shut, nothing is drawn -- the scrim
    // and the sheet are both `visible: progress > 0`.
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    surfaceFormat.opaque: false

    WlrLayershell.namespace: "omarchy-mobile-shade"
    WlrLayershell.layer: WlrLayer.Overlay
    // No text input anywhere in here, and None makes it structurally impossible
    // for the shade to take focus from the app underneath -- so a pull-down, a
    // tap on a tile and a flick back up leaves you exactly where you were. It
    // is also what keeps this compositor routing pointer events to the edges
    // at all: a layer surface holding the keyboard takes every one of them.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserve nothing. With Auto, pulling the shade would reflow every tiled
    // window.
    exclusionMode: ExclusionMode.Ignore

    // The input region: the bar's band while shut, so every touch below it
    // reaches the app; the whole screen from the first press until the sheet is
    // back up, so a drag that leaves the band keeps being delivered. Two Regions
    // swapped rather than one bound, because a Region's own property changes do
    // not re-apply the mask.
    //
    // There is deliberately no third state with the home pill's band cut out,
    // which is moarchy's answer to A8 and was this file's first. It cannot work
    // here, for two reasons measured one after the other:
    //
    //   - the cut-out region, applied as the open animation ended, stayed
    //     uncommitted until something repainted: a strip press reached nothing
    //     after an open, by IPC or by drag, and reached the edge surface once a
    //     tile had been tapped twice
    //   - once it did reach the edge, the up-drag still stopped dead: it has to
    //     travel over this surface, and Hyprland hands a drag to whichever
    //     surface is topmost under the finger -- the grab rule the drawer found,
    //     arriving from the other side
    //
    // So the shade keeps the band, and forwards it (the last MouseArea below).
    readonly property bool inputFull: root.handleTracking || root.sheetDragging
                                      || root.dragging || root.progress > 0

    mask: shadeWindow.inputFull ? fullMask : bandMask

    property Region bandMask: Region {
      width: shadeWindow.width
      height: root.stripHeight
    }

    property Region fullMask: Region {
      width: shadeWindow.width
      height: shadeWindow.height
    }

    // ------------------------------------------------------------ scrim
    Rectangle {
      anchors.fill: parent
      // Straight off the theme background: Color.menu.scrim is already a
      // composed colour with its own alpha, and re-alpha'ing it is whatever the
      // theme happened to choose rather than a dim.
      color: Util.alpha(Color.background, 0.72 * root.progress)
      // Visible for the whole of a drag, not only while progress > 0. A close
      // drag that reaches the top takes progress to 0, and an item that turns
      // invisible under its own MouseArea's grab gets `canceled` -- which put
      // the sheet straight back to open. Measured: a 300px drag on a 272px
      // sheet, eleven samples delivered, and the shade ended the gesture open.
      visible: root.progress > 0 || root.sheetDragging

      // H2. Tap-to-dismiss *and* the close drag, because the band of scrim
      // below the sheet is where a thumb starts an up-swipe. Wired to the same
      // trio as the sheet rather than to `clicked` alone -- a MouseArea that
      // only answers `clicked` still consumes the whole gesture, and in moarchy
      // an up-drag begun here moved nothing and then dismissed on release.
      //
      // Gated on `progress`, NOT on `opened`: `opened` goes false on the first
      // frame of the drag, and an area that disables mid-gesture delivers
      // `canceled`.
      MouseArea {
        anchors.fill: parent
        enabled: root.progress > 0 || root.sheetDragging
        onPressed: mouse => root.sheetPress(this, mouse)
        onPositionChanged: mouse => root.sheetMove(this, mouse)
        onReleased: root.sheetRelease()
        onCanceled: root.sheetCancel()
        onClicked: if (!root.sheetWasDrag) root.close()
      }
    }

    // ------------------------------------------------------------- sheet
    Item {
      id: sheet
      width: parent.width
      height: root.sheetHeight
      y: -root.sheetHeight * (1 - root.progress)
      // As the scrim: a drag that starts on a tile and carries the sheet all
      // the way up must not be cancelled by the sheet disappearing under it.
      visible: root.progress > 0 || root.sheetDragging

      // The height animates and the content's does not, so for the 180ms of a
      // growth the content is taller than its box. Axis-aligned and unrotated,
      // so this clip is a scissor rect, not an off-screen pass.
      clip: true

      // Rounded at the bottom only: the top corners are never on screen.
      Rectangle {
        anchors.fill: parent
        color: root.surface
        radius: root.radiusSheet
      }
      Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: root.radiusSheet
        color: root.surface
      }

      // H2, for a drag that starts on empty sheet. Declared before the Column
      // so it sits under it and only sees what nothing else claimed.
      MouseArea {
        anchors.fill: parent
        onPressed: mouse => root.sheetPress(this, mouse)
        onPositionChanged: mouse => root.sheetMove(this, mouse)
        onReleased: root.sheetRelease()
        onCanceled: root.sheetCancel()
      }

      Column {
        id: sheetColumn
        // Top/left/right, not fill: the sheet's height is derived from this
        // Column's implicitHeight, and a Column stretched to fill the thing
        // measuring it is a binding loop.
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.sheetPadSide
        anchors.rightMargin: root.sheetPadSide
        anchors.topMargin: root.sheetPadTop
        spacing: root.sheetGap

        // ------------------------------------------------------- header
        Item {
          width: parent.width
          height: Style.space(44)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            // S1. The sheet covers the status bar, so the time reappears here.
            Text {
              text: Qt.formatDateTime(shadeClock.date, "H:mm")
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.weight: root.textWeight
              color: root.textOnSurface
            }
            Text {
              text: Qt.formatDateTime(shadeClock.date, "dddd d MMMM")
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: root.textWeight
              color: root.subdued
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            // Escapes, not the glyphs themselves: both are private-use code
            // points, and the first port of this file lost them in transit and
            // drew two empty circles.
            RoundButton {
              id: gearButton
              glyph: "\ue615"
              onActivated: root.openSettings("")
            }
            RoundButton {
              id: powerButton
              glyph: "\uf011"
              onActivated: root.openSettings("system.power")
            }
          }
        }

        // ---------------------------------------------------- wide tiles
        Row {
          width: parent.width
          spacing: Style.space(8)
          readonly property int cell: Math.floor((width - spacing) / 2)

          WideTile {
            id: wifiTile
            width: parent.cell
            glyph: "󰤨"
            label: "Wi-Fi"
            detail: root.wifiLabel
            on: !!root.wifiDevice && Networking.wifiEnabled
            holdable: true
            onActivated: root.wifiTap()
            onHeld: root.wifiHold()
          }

          WideTile {
            id: btTile
            width: parent.cell
            glyph: "󰂯"
            label: "Bluetooth"
            detail: root.btLabel
            on: root.btAdapter ? root.btAdapter.enabled : false
            holdable: true
            onActivated: root.btTap()
            onHeld: root.btHold()
          }
        }

        // --------------------------------------------------- small tiles
        Row {
          id: smallTiles
          width: parent.width
          spacing: Style.space(8)
          // S10. The torch is the one that can be missing rather than off, so
          // the row divides by what is actually shown.
          readonly property int shown: root.torchAvailable ? 4 : 3
          readonly property int cell: Math.floor((width - spacing * (shown - 1)) / shown)

          SmallTile {
            id: silentTile
            width: smallTiles.cell
            glyph: "󰂛"
            label: "Silent"
            on: root.notifications ? root.notifications.doNotDisturb : false
            onActivated: {
              root.lastAction = "silent"
              if (root.notifications)
                root.notifications.setDoNotDisturb(!root.notifications.doNotDisturb)
            }
          }
          SmallTile {
            id: airplaneTile
            width: smallTiles.cell
            glyph: "󰀝"
            label: "Airplane"
            on: root.airplane
            onActivated: root.setAirplane(!root.airplane)
          }
          SmallTile {
            width: smallTiles.cell
            visible: root.torchAvailable
            glyph: "󰉄"
            label: "Torch"
            on: root.torchOn
            onActivated: root.setTorch(!root.torchOn)
          }
          SmallTile {
            id: rotateTile
            width: smallTiles.cell
            glyph: "󰑥"
            label: "Rotate"
            on: false
            onActivated: root.rotate()
          }
        }

        // ------------------------------------------------------ sliders
        FatSlider {
          width: parent.width
          visible: root.brightnessAvailable
          glyph: "󰃟"
          value: root.brightness / 100
          onCommitted: v => root.setBrightness(v * 100)
        }

        // S14. Hidden, not disabled, with no sink.
        FatSlider {
          id: volumeSlider
          width: parent.width
          visible: !!(root.sink && root.sink.audio)
          glyph: "󰕾"
          live: true
          value: root.sink && root.sink.audio ? root.sink.audio.volume : 0
          onCommitted: v => { if (root.sink && root.sink.audio) root.sink.audio.volume = v }
        }

        // -------------------------------------------------------- media
        //
        // S16. Only while something is playing, off the media service's own
        // active player rather than a second Mpris watcher.
        Rectangle {
          width: parent.width
          height: Style.space(56)
          visible: !!root.player
          radius: root.radiusCard
          color: root.container

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(10)

            Column {
              width: parent.width - root.tapSlot * 3 - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                width: parent.width
                text: root.player ? String(root.player.trackTitle || "") : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.weight: root.textWeight
                color: root.textOnSurface
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                visible: text !== ""
                text: root.player ? String(root.player.trackArtist || "") : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: root.textWeight
                color: root.subdued
                elide: Text.ElideRight
              }
            }

            // Three tapSlot squares butted together with the glyph centred in
            // each, so the gap is inside the target (docs/spec/style.md E4).
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Repeater {
                model: [
                  { glyph: "󰒮", action: "previous" },
                  { glyph: "󰒧", action: "playPause" },
                  { glyph: "󰒜", action: "next" }
                ]
                delegate: Item {
                  required property var modelData
                  width: root.tapSlot
                  height: root.tapSlot

                  PressVeil {
                    anchors.centerIn: parent
                    width: root.tapSlot - Style.space(10)
                    height: width
                    radius: width / 2
                    on: mediaArea.pressed && !root.sheetDragging
                  }

                  Ui.OpticalGlyph {
                    anchors.centerIn: parent
                    width: root.glyphSlot
                    height: root.glyphSlot
                    text: modelData.glyph
                    fontFamily: Style.font.family
                    fontSize: Style.font.iconLarge
                    color: root.textOnSurface
                  }

                  MouseArea {
                    id: mediaArea
                    anchors.fill: parent
                    onPressed: mouse => root.sheetPress(this, mouse)
                    onPositionChanged: mouse => root.sheetMove(this, mouse)
                    onReleased: root.sheetRelease()
                    onCanceled: root.sheetCancel()
                    onClicked: if (!root.sheetWasDrag && root.media)
                      root.media.runAction(modelData.action)
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------------ notifications
        Item {
          width: parent.width
          height: Style.space(24)
          // Off the model, not off the list's count: the sheet's height is this
          // Column's implicitHeight, so nothing that decides it may be read
          // back out of the list item.
          visible: root.historyRows.length > 0

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: "Notifications"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: root.textWeight
            color: root.subdued
          }

          PressVeil {
            anchors.fill: clearAll
            anchors.margins: -Style.space(6)
            radius: height / 2
            ink: root.accent
            on: clearArea.pressed && !root.sheetDragging
          }

          // S19, H8. The one dismissal reachable by tap.
          Text {
            id: clearAll
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: "Clear all"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: root.textWeight
            color: root.accent
            MouseArea {
              id: clearArea
              anchors.fill: parent
              anchors.margins: -Style.space(10)
              onPressed: mouse => root.sheetPress(this, mouse)
              onPositionChanged: mouse => root.sheetMove(this, mouse)
              onReleased: root.sheetRelease()
              onCanceled: root.sheetCancel()
              onClicked: if (!root.sheetWasDrag) root.clearNotifications()
            }
          }
        }

        ListView {
          id: notificationList
          width: parent.width

          // A ListView with an empty model is not zero-height -- it is its
          // bottom margin -- and a visible child of a Column takes a gap above
          // it. Read off the model, for the reason the header states.
          visible: root.historyRows.length > 0

          // S22. The cap, from `y` rather than the sheet's height: the sheet is
          // as tall as this Column, so measuring against it is a loop. `y` is
          // safe because this is the last child, so nothing may go below it.
          readonly property int listMax: Math.max(0, root.sheetMax
            - root.sheetPadTop - root.sheetPadBottom - notificationList.y)

          // Only as tall as its rows, + bottomMargin or the cap defeats itself:
          // contentHeight excludes the margin, so a list that fits would become
          // scrollable by exactly the margin and swallow the close drag.
          height: Math.min(notificationList.listMax, contentHeight + bottomMargin)
          // H5, S20. While it can scroll, the list owns vertical drags.
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          // A buffer of a whole sheet forces every row within reach of the
          // viewport to exist, so contentHeight is exact across the range that
          // decides the height.
          cacheBuffer: root.sheetMax
          clip: true
          spacing: Style.space(6)
          bottomMargin: Style.space(10)
          model: root.historyRows

          delegate: Item {
            id: card
            required property var modelData
            width: notificationList.width
            height: Math.max(cardBody.implicitHeight, root.cardIcon) + Style.space(20)

            // For `shade target card0icon`.
            readonly property Item iconItem: cardIconSlot

            // H7a. Measured in moarchy: 100px leaves the notification, 340
            // removes it, on a 336px card.
            readonly property real dismissAt: card.width * 0.35

            Rectangle {
              id: sheetCard
              width: parent.width
              height: parent.height
              radius: root.radiusCard
              color: root.container
              // Fades as it travels, so a half-swipe reads as "not yet".
              opacity: 1 - Math.min(0.75, Math.abs(sheetCard.x) / card.width)

              // S27. A card that has something to do lights under a finger;
              // one that has nothing does not, so it does not promise a tap.
              readonly property string action: root.actionFor(card.modelData)
              readonly property bool still: Math.abs(sheetCard.x) < root.slop

              PressVeil {
                anchors.fill: parent
                radius: parent.radius
                on: cardArea.pressed && sheetCard.still && sheetCard.action !== "none"
              }

              // H7, H7b. The only way to dismiss one notification unread, and
              // horizontal only with preventStealing false, so the list still
              // takes any drag that turns out to be a scroll (H5). Claiming one
              // axis rather than the gesture is what keeps a wandering scroll
              // from throwing away something you were reading.
              MouseArea {
                id: cardArea
                anchors.fill: parent
                drag.target: sheetCard
                drag.axis: Drag.XAxis
                drag.minimumX: -card.width
                drag.maximumX: card.width
                onReleased: {
                  if (Math.abs(sheetCard.x) >= card.dismissAt) root.dismissRow(card.modelData)
                  else springBack.restart()
                }
                onCanceled: springBack.restart()
                // S27. A tap, told from a swipe by where the card is: a swipe
                // that springs back short of dismissAt still releases inside
                // the card, and must not run anything on the way.
                onClicked: if (sheetCard.still) root.runRow(card.modelData)
              }

              NumberAnimation {
                id: springBack
                target: sheetCard; property: "x"; to: 0
                duration: 140; easing.type: Easing.OutCubic
              }

              // S25. The sender, leading the card the way Android leads one.
              Item {
                id: cardIconSlot
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: root.cardIcon
                height: root.cardIcon

                readonly property var icon: root.iconFor(card.modelData)

                Image {
                  id: cardImage
                  anchors.fill: parent
                  visible: status === Image.Ready
                  source: cardIconSlot.icon.source
                  // Decoded at the size it is drawn: an avatar can be a
                  // full-size photo, and there may be ten of them.
                  sourceSize: Qt.size(root.cardIcon, root.cardIcon)
                  asynchronous: true
                  smooth: true
                  fillMode: Image.PreserveAspectFit
                }

                // A glyph on a tonal disc: nothing to load, or what was named
                // will not load. Not while it is still loading, or every
                // picture would open on a flash of bell.
                Rectangle {
                  anchors.fill: parent
                  visible: cardIconSlot.icon.source === "" || cardImage.status === Image.Error
                  radius: width / 2
                  color: root.container

                  Ui.OpticalGlyph {
                    anchors.fill: parent
                    text: cardIconSlot.icon.glyph
                    fontFamily: Style.font.family
                    fontSize: Style.font.icon
                    color: root.textOnSurface
                  }
                }
              }

              Column {
                id: cardBody
                anchors.left: cardIconSlot.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: card.modelData.app || ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.weight: root.textWeight
                  color: root.subdued
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  visible: text !== ""
                  text: card.modelData.summary || ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Bold
                  color: root.textOnSurface
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  visible: text !== ""
                  text: card.modelData.body || ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.weight: root.textWeight
                  color: Util.alpha(root.textOnSurface, 0.85)
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }

    // -------------------------------------------------------- drag handle
    //
    // The bar's band, and last, so it takes the press ahead of the sheet. Shut,
    // it is the whole input region and every touch along the bar is a pull.
    // Open, it sits over the top of the sheet's header, so the same gesture
    // still works there and every control below it keeps its taps.
    MouseArea {
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: root.stripHeight
      onPressed: mouse => root.handlePress(mapToItem(null, mouse.x, mouse.y).y)
      onPositionChanged: mouse => root.handleMove(mapToItem(null, mouse.x, mouse.y).y)
      onReleased: root.handleRelease()
      onCanceled: root.handleCancel()
    }

    // A8, B3. The home pill's band, while the shade is up. The press lands here
    // because this surface is on top and keeps its whole input region (see the
    // mask), and it is handed straight to EdgeGestures' own strip logic -- the
    // same functions its own surface calls, so an up-flick clears the shade and
    // a sideways swipe changes workspace with no second copy of either rule.
    //
    // `borrowed` tells the edge surface not to open its own input region for
    // this gesture: it would then be the topmost region under the finger and
    // take the rest of the drag from this surface, which is the problem this
    // exists to get round. Surface coordinates are screen coordinates, so the
    // points pass through unchanged.
    MouseArea {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: root.gestureStrip
      enabled: root.progress > 0 && !!root.host && !!root.host.gestures
      onPressed: mouse => {
        var p = mapToItem(null, mouse.x, mouse.y)
        root.host.gestures.stripPressed(p.x, p.y, true)
      }
      onPositionChanged: mouse => {
        var p = mapToItem(null, mouse.x, mouse.y)
        root.host.gestures.stripMoved(p.x, p.y)
      }
      onReleased: root.host.gestures.stripReleased()
      onCanceled: root.host.gestures.stripCanceled()
    }
  }

  SystemClock {
    id: shadeClock
    precision: SystemClock.Minutes
  }
}
