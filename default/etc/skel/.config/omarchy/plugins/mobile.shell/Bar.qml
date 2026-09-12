// The phone status bar: this plugin's second entry point.
//
// Ported from moarchy.bar. Selected through shell.json's `bar.id`, which is
// the host's own way to replace the whole bar -- a plugin declaring kind "bar"
// is loaded in place of omarchy.bar (shell.qml, activeBarId), so this is a
// plugin and not a patch.
//
// ---------------------------------------------------------------------------
// Why a whole bar rather than a different widget list
// ---------------------------------------------------------------------------
// Upstream's bar is a general-purpose widget host -- drag-to-rearrange, hover
// peek, per-widget popouts -- and its default layout puts thirteen widgets in
// 360 logical pixels: the clock starts at x=121 while the workspace list runs
// to x=140.5 (docs/build-log.md). On a phone the bar is a status line.
//
// ---------------------------------------------------------------------------
// Why nothing here is tappable
// ---------------------------------------------------------------------------
// Android's status bar is not tappable either, and here that is forced: the
// shade (Shade.qml) owns the top edge with an Overlay input band so a drag
// anywhere along the bar pulls it down. Overlay outranks this surface's Top, so
// a tap here would never arrive. This surface draws and nothing else.
//
// ---------------------------------------------------------------------------
// The bar and the rest of the phone are one switch
// ---------------------------------------------------------------------------
// The host enables a plugin that declares kind "bar" exactly when shell.json's
// `bar.id` names it (PluginRegistry.isEnabled), and that answer covers every
// entry point the plugin has. So `bar.id = "mobile.shell"` turns the whole
// phone UI on, and pointing it back at omarchy.bar is stock desktop Omarchy
// with nothing of this plugin loaded.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui as Ui
import "Theme.js" as Theme

Item {
  id: root

  // ------------------------------------------------------------- injected
  //
  // shell.qml's configureBar() assigns each of these by name, under an `in`
  // test. NOT `readonly`: the assignment throws against a read-only
  // declaration, the plugin fails to load, and the host falls back to
  // omarchy.bar without a word.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  // Assigned and read by nothing, on purpose: this bar is handed the same
  // config upstream's is, and draws none of it.
  property var barConfig: ({})

  // ------------------------------------------------- the shell.bar contract
  //
  // Other parts of the shell reach into `shell.bar` by name, and a replacement
  // bar that omits any of this degrades something elsewhere rather than failing
  // loudly. Read directly:
  //   barSize, barHidden, position  notifications/Service.qml places toasts
  //                                 under the bar; the shade's grab band is
  //                                 exactly barSize tall
  //   fontFamily                    notifications/Service.qml renders toasts
  //   notificationPopups            false, so notifications/Service.qml puts
  //                                 every notification in the history the
  //                                 shade lists and toasts none of them
  //                                 (patches/notification-popups-bar-opt-out.patch)
  //   launchOsd                     false, so services/AppLibrary.qml shows no
  //                                 launch panel: this shell draws the app's
  //                                 own icon instead (Splash.qml, windows.md
  //                                 L1) -- (patches/launch-osd-bar-opt-out.patch)
  // Called behind a typeof guard, so a missing one is survivable:
  //   summonBarWidget / hideBarWidget / isBarWidgetOpen   shell.summon routing
  //   panelWidgetIdAt                                     togglePanelAt IPC
  //   debugBarGeometry                                    debug IPC
  readonly property int barSize: Style.bar.sizeHorizontal
  readonly property string position: "top"
  readonly property string fontFamily: Style.font.family
  readonly property bool barHidden: false

  // S24. No toasts: a phone reads its notifications in the shade. A toast here
  // was an Overlay surface over the top 170px of every app and every sheet,
  // taking their touches until it expired.
  readonly property bool notificationPopups: false

  // windows.md L1. No launch OSD either, for the same shape of reason: this
  // shell answers a tap with the app's own icon, in the frame the tap
  // produced, where upstream's panel arrives two seconds later and says
  // "Launching Files..." over whatever is on screen.
  readonly property bool launchOsd: false

  // This bar hosts no widgets, so every widget-routing call has one honest
  // answer. Returning false rather than omitting the function is what makes
  // shell.summon log "no live bar widget" instead of throwing.
  function summonBarWidget(id: string): bool { return false }
  function hideBarWidget(id: string): bool { return false }
  function isBarWidgetOpen(id: string): bool { return false }
  function panelWidgetIdAt(section: string, index: string): string { return "" }
  function debugBarGeometry(): var { return [] }

  // `omarchy-toggle battery-percentage-off` flips a flag file. The parent
  // directory is watched, not the file: FileView cannot watch a path that does
  // not exist yet, and a flag file is created and deleted rather than edited.
  property bool batteryPercentShown: true

  readonly property string togglesDir:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/toggles"

  Process {
    id: flagProbe
    running: true
    command: ["bash", "-c",
      "[[ -f \"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/battery-percentage-off\" ]] " +
      "&& echo pct=off || echo pct=on"]
    stdout: StdioCollector {
      onStreamFinished: root.batteryPercentShown = String(text || "").indexOf("pct=on") >= 0
    }
  }

  FileView {
    path: root.togglesDir
    watchChanges: true
    printErrors: false
    onFileChanged: flagProbe.running = true
  }

  // ------------------------------------------------------------- appearance
  readonly property color background: Color.bar.background
  readonly property color foreground: Color.bar.text
  readonly property color dim: Theme.subduedOn(root.background, root.foreground)
  readonly property int edgePad: Style.space(8)

  // DemiBold, not Regular. moarchy measured it on the device: light text on a
  // dark bar reads thinner than it measures, and at 12px Medium was
  // indistinguishable from Regular where DemiBold put 47% more ink down.
  readonly property int textWeight: Font.DemiBold

  // Glyphs at the clock's size, so the two ends of the bar carry the same
  // weight, each in a fixed square slot re-centred on its painted ink --
  // advance widths differ per glyph in a Nerd Font, and one spacing value
  // produced visibly uneven gaps.
  readonly property int iconSize: Style.font.body
  readonly property int glyphSlot: Math.round(root.iconSize * 1.35)
  readonly property int glyphGap: Style.space(4)

  component StatusGlyph: Ui.OpticalGlyph {
    width: root.glyphSlot
    height: root.glyphSlot
    fontFamily: Style.font.family
    fontSize: root.iconSize
    color: root.foreground
    visible: text !== ""
  }

  // ------------------------------------------------------------- battery
  //
  // UPower.displayDevice is the aggregate the desktop bar uses; the glyph
  // ramps are upstream's own (plugins/panels/power/Model.js), so a phone that
  // charges looks like the rest of Omarchy. Absent here: the VM has no battery,
  // and an absent battery draws nothing.
  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool batteryPresent: root.batteryDevice && root.batteryDevice.isPresent
  readonly property real batteryFraction: root.batteryPresent ? Number(root.batteryDevice.percentage || 0) : 0
  readonly property int batteryPercent: Math.round(root.batteryFraction * 100)
  readonly property bool charging: !UPower.onBattery

  readonly property string batteryGlyph: {
    if (!root.batteryPresent) return ""
    var charge = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
    var drain  = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    var i = Math.max(0, Math.min(9, Math.floor(root.batteryFraction * 10)))
    if (root.batteryDevice.state === UPowerDeviceState.FullyCharged) return "󰂅"
    return root.charging ? charge[i] : drain[i]
  }

  readonly property bool batteryLow: root.batteryPresent && !root.charging && root.batteryPercent <= 10

  // ------------------------------------------------------------- wifi
  //
  // Event-driven off NetworkManager, so this costs nothing between changes.
  readonly property var wifiDevice: {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].type === DeviceType.Wifi) return devices[i]
    return null
  }

  readonly property real wifiStrength: {
    var device = root.wifiDevice
    if (!device || !device.connected) return -1
    var networks = device.networks ? device.networks.values : []
    for (var i = 0; i < networks.length; i++) {
      if (!networks[i] || !networks[i].connected) continue
      var raw = Number(networks[i].signalStrength)
      if (!isFinite(raw)) return 0
      // The binding's scale is not documented; at or below 1 it is a fraction.
      return raw <= 1 ? raw * 100 : raw
    }
    return 0
  }

  readonly property string wifiGlyph: {
    if (!root.wifiDevice) return ""
    if (!Networking.wifiEnabled) return "󰤮"
    if (root.wifiStrength < 0) return "󰤯"
    var ramp = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
    return ramp[Math.max(0, Math.min(4, Math.ceil(root.wifiStrength / 20) - 1))]
  }

  // ------------------------------------------------------------- bluetooth
  //
  // Hidden with the adapter off, the way a phone does it: an always-lit
  // "bluetooth is off" glyph is a permanent 12px of nothing on a 360px bar.
  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property bool btOn: root.btAdapter && root.btAdapter.enabled
  readonly property bool btConnected: {
    if (!root.btOn) return false
    var devices = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].connected) return true
    return false
  }
  readonly property string btGlyph: !root.btOn ? "" : (root.btConnected ? "󰂱" : "󰂯")

  // ------------------------------------------------------------- cellular
  //
  // ModemManager has no Quickshell binding, so this is the one polled value,
  // and it backs off to two minutes when there is nothing to report. No modem
  // at all -- this VM -- draws nothing.
  property string modemState: ""
  property string modemFailedReason: ""
  property int modemSignal: -1

  readonly property bool simMissing: root.modemFailedReason === "sim-missing"
  readonly property bool modemUsable: root.modemState !== "" && !root.simMissing

  readonly property string cellGlyph: {
    if (root.modemState === "") return ""
    if (root.simMissing) return "󰓥"
    if (root.modemState === "failed" || root.modemState === "disabled") return "󰞃"
    if (root.modemSignal < 0) return "󰣂"
    var ramp = ["󰣂", "󰢿", "󰣀", "󰣁"]
    return ramp[Math.max(0, Math.min(3, Math.ceil(root.modemSignal / 25)))]
  }

  Process {
    id: modemProbe
    command: ["mmcli", "-m", "any", "--output-keyvalue"]
    stdout: StdioCollector {
      onStreamFinished: {
        var state = ""
        var reason = ""
        var signal = -1
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split(":")
          if (parts.length < 2) continue
          var key = parts[0].trim()
          var value = parts.slice(1).join(":").trim()
          if (key === "modem.generic.state") state = value
          else if (key === "modem.generic.state-failed-reason") reason = value
          else if (key === "modem.generic.signal-quality.value") signal = parseInt(value, 10)
        }
        root.modemState = state
        root.modemFailedReason = reason === "--" ? "" : reason
        root.modemSignal = isFinite(signal) ? signal : -1
      }
    }
  }

  Timer {
    id: modemPoll
    interval: root.modemUsable ? 20000 : 120000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!modemProbe.running) modemProbe.running = true
  }

  // ------------------------------------------------------------- notifications
  //
  // Through the host's first-party proxy, which it hands a plugin that declares
  // kind "bar". The proxy carries doNotDisturb and not the popup model -- and
  // with notificationPopups false there are no popups to count anyway: every
  // notification goes straight into the history directory the shade lists. So
  // the bell (S26) counts that directory, watched the way the toggles are.
  readonly property var notifications: root.shell && typeof root.shell.firstPartyServiceFor === "function"
    ? root.shell.firstPartyServiceFor("omarchy.notifications") : null
  readonly property bool dnd: root.notifications ? root.notifications.doNotDisturb === true : false

  // The service's own path, which does not read XDG_STATE_HOME.
  readonly property string historyDir:
    Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"

  property int historyCount: 0
  readonly property bool bellShown: !root.dnd && root.historyCount > 0

  // The directory is made before it is watched: FileView cannot watch a path
  // that does not exist yet, and on a first boot this can run before the
  // service has made it. So the watch is armed by the first count, not before.
  property bool historyWatched: false

  Process {
    id: historyProbe
    running: true
    command: ["bash", "-c", "mkdir -p \"$1\" && ls -1 \"$1\" | grep -c '\\.json$'", "--", root.historyDir]
    stdout: StdioCollector {
      onStreamFinished: {
        var n = parseInt(String(text || "").trim(), 10)
        root.historyCount = isFinite(n) ? n : 0
        root.historyWatched = true
      }
    }
  }

  // Debounced: Clear all, and the service's history trim, touch several files
  // in one burst.
  Timer {
    id: historyRecount
    interval: 150
    onTriggered: {
      if (historyProbe.running) historyRecount.restart()
      else historyProbe.running = true
    }
  }

  FileView {
    path: root.historyWatched ? root.historyDir : ""
    watchChanges: true
    printErrors: false
    onFileChanged: historyRecount.restart()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  // Proof that this file loaded, which nothing else can give: shell.json goes
  // on naming this plugin when its QML fails to compile, while the host quietly
  // falls back to omarchy.bar. An answer here comes from an instantiated bar.
  IpcHandler {
    target: "bar"

    function metrics(): string {
      return "height=" + root.barSize
           + " icon=" + root.iconSize
           + " slot=" + root.glyphSlot
           + " weight=" + root.textWeight
           + " dnd=" + (root.dnd ? "on" : "off")
           + " bell=" + (root.bellShown ? "shown" : "none")
           + " history=" + root.historyCount
           + " wifi=" + (root.wifiGlyph !== "" ? "shown" : "none")
           + " bt=" + (root.btGlyph !== "" ? "shown" : "none")
           + " pct=" + (root.batteryPercentShown ? "on" : "off")
    }

    function syncFlags(): string {
      flagProbe.running = true
      return "ok"
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: barWindow

        required property var modelData
        screen: modelData

        anchors { top: true; left: true; right: true }
        implicitHeight: root.barSize
        // Opaque, and `bar.transparent` is ignored: the only thing that writes
        // it is `omarchy-bar transparent`, whose reload would swap this bar out.
        color: root.background
        surfaceFormat.opaque: false

        WlrLayershell.namespace: "omarchy-mobile-bar"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // Reserved, not floating: an app that draws under the status bar has
        // its first line hidden, and on a phone that is usually the heading.
        exclusionMode: ExclusionMode.Auto

        // No input at all, for the reason in the header.
        mask: Region {}

        // ---------------------------------------------------------- left
        Row {
          anchors.left: parent.left
          anchors.leftMargin: root.edgePad
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.glyphGap

          Text {
            anchors.verticalCenter: parent.verticalCenter
            // H, not HH: a phone clock reads "9:06", not "09:06". The padded
            // form is a desktop habit from a centre-anchored clock; this one is
            // anchored left, so nothing moves when the hour loses a digit.
            text: Qt.formatDateTime(clock.date, "H:mm")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.weight: root.textWeight
            color: root.foreground
          }

          StatusGlyph {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.dnd
            text: "󰂛"
            color: root.dim
          }

          // S26. Something is waiting in the shade. While Silent is on, its
          // glyph takes this one's place: the shade still fills, and the bar
          // says only that you asked not to be told.
          StatusGlyph {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.bellShown
            text: "󰂚"
          }
        }

        // --------------------------------------------------------- right
        Row {
          anchors.right: parent.right
          anchors.rightMargin: root.edgePad
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.glyphGap

          StatusGlyph {
            anchors.verticalCenter: parent.verticalCenter
            text: root.cellGlyph
            color: root.simMissing ? root.dim : root.foreground
          }

          StatusGlyph {
            anchors.verticalCenter: parent.verticalCenter
            text: root.wifiGlyph
          }

          StatusGlyph {
            anchors.verticalCenter: parent.verticalCenter
            text: root.btGlyph
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.batteryPresent
            // No spacing: the glyph's slot carries its own padding, and more
            // detached the percentage from the battery it belongs to.
            spacing: 0

            StatusGlyph {
              anchors.verticalCenter: parent.verticalCenter
              text: root.batteryGlyph
              color: root.batteryLow ? Color.bar.active : root.foreground
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.batteryPercentShown
              text: root.batteryPercent + "%"
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.weight: root.textWeight
              color: root.batteryLow ? Color.bar.active : root.foreground
            }
          }
        }
      }
    }
  }
}
