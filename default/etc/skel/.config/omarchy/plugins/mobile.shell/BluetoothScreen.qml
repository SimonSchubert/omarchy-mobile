// Pairing and connecting a Bluetooth device, with a finger (docs/spec/shade.md
// S6c, S6d).
//
// Ported from moarchy.bluetooth, and the same shape as WifiScreen.qml: a screen
// that is a window, with a back chevron, a radio switch and one list.
//
// Not bluetui: it was operable -- it asks for mouse reporting -- but a row is
// one terminal line, ~17 logical px against the 44 style.md E1 asks for, and a
// terminal cannot show what BlueZ already knows: battery, "Connecting…".
//
// ---------------------------------------------------------------------------
// The one place this differs from Wi-Fi (S6d-6)
// ---------------------------------------------------------------------------
// Everything here READS Quickshell.Bluetooth, and nothing parses bluetoothctl.
// But pair, connect and forget go through `omarchy-bluetooth-device`, because
// Quickshell registers no org.bluez.Agent1: its pair() is a bare Device1.Pair(),
// which BlueZ answers with "No agent available" -- into the journal. The
// upstream wrapper registers an agent through bluetoothctl, unblocks rfkill
// first (BlueZ will not power up under a soft block) and trusts the device
// afterwards (without which it will not reconnect itself). Upstream's own
// Bluetooth panel calls it for exactly these reasons. Disconnect needs none of
// that and stays native.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import qs.Commons
import "Theme.js" as Theme

Item {
  id: root

  property var host: null

  readonly property string screenId: "mobile.bluetooth"

  // K10: a screen you sit in -- wait for the device to appear, put it in
  // pairing mode, try again -- which is the shape of an app and nothing like a
  // sheet dismissed in one motion.
  readonly property bool opened: bluetoothWindow.visible
  readonly property var appWindow: bluetoothWindow

  // K5. The card shows the device you are on.
  readonly property string pageTitle: {
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].connected) return root.rows[i].name
    if (!root.adapter) return "No adapter"
    return root.adapter.enabled ? "Not connected" : "Off"
  }

  property string returnTo: ""

  // --------------------------------------------------------------- palette
  readonly property int radiusCard: Style.space(18)
  readonly property int textWeight: Font.DemiBold
  readonly property color surface: Color.popups.background
  readonly property color textOnSurface: Color.popups.text
  readonly property color container: Util.alpha(Color.popups.text, 0.08)
  readonly property color containerHigh: Util.alpha(Color.popups.text, 0.14)
  readonly property color accent: Color.accent
  readonly property color textOnAccent: Color.background

  readonly property color subdued: Theme.subduedOnContainer(root.surface,
                                                            root.textOnSurface)

  component PressVeil: Veil { ink: root.textOnSurface }

  // ------------------------------------------------------------------ data
  readonly property var adapter: Bluetooth.defaultAdapter

  // PRIMITIVES ONLY, for the reason WifiScreen.qml gives: BlueZ churn can
  // destroy a device object while a delegate holding it is still incubating,
  // which segfaults quickshell. Actions resolve the object again by address.
  property var frozenRows: []

  // S6d-4. Held still while a row is open or an action is in flight: discovery
  // reorders the list every few seconds, and a row moving under a finger aimed
  // at Forget is a mis-tap with no undo.
  readonly property bool listFrozen: root.expandedAddress !== "" || root.busyAddress !== ""
  readonly property var rows: root.listFrozen ? root.frozenRows : root.liveRows

  onListFrozenChanged: if (root.listFrozen) root.frozenRows = root.liveRows

  property var actionRowItem: null

  readonly property var liveRows: {
    var objs = Bluetooth.devices ? Bluetooth.devices.values : []
    var out = []
    for (var i = 0; i < objs.length; i++) {
      var d = objs[i]
      if (!d || !d.address) continue
      var label = String(d.name || d.deviceName || "").trim()
      if (!root.hasHumanName(label, d.address)) continue
      out.push({
        address: String(d.address),
        name: label,
        icon: String(d.icon || ""),
        connected: !!d.connected,
        // BlueZ pairs, bonds and trusts separately; "remembered" is any.
        known: !!(d.paired || d.bonded || d.trusted),
        pairing: !!d.pairing,
        blocked: !!d.blocked,
        batteryAvailable: !!d.batteryAvailable,
        battery: Math.round((d.battery || 0) * 100)
      })
    }
    // S6d-1. Connected, then remembered, then the scan's finds; each by name.
    // Quickshell exposes no RSSI to sort by, and alphabetical holds still.
    out.sort(function(a, b) {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      if (a.known !== b.known) return a.known ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    return out
  }

  // S6d-1. A name that is only the device's own address, or a bare UUID, is a
  // beacon nobody chose -- a café shows dozens. Ported from upstream's Model.js.
  function hasHumanName(label, address) {
    if (!label) return false
    var flat = label.toLowerCase().replace(/[^0-9a-f]/g, "")
    if (flat === String(address).toLowerCase().replace(/[^0-9a-f]/g, "")) return false
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(label)) return false
    if (/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(label)) return false
    return true
  }

  function deviceForAddress(address) {
    var objs = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < objs.length; i++)
      if (objs[i] && String(objs[i].address) === String(address)) return objs[i]
    return null
  }

  // BlueZ's `Icon` is a freedesktop icon name, so it is a vocabulary. Code
  // points from moarchy's table, written as escapes.
  function deviceGlyph(icon) {
    var name = String(icon || "")
    if (name === "audio-headset") return "\u{F02CE}"
    if (name === "audio-headphones") return "\u{F02CB}"
    if (name === "audio-speakers" || name === "audio-card") return "\u{F04C3}"
    if (name === "multimedia-player") return "\u{F075A}"
    if (name === "audio-input-microphone") return "\u{F036C}"
    if (name === "input-keyboard") return "\u{F030C}"
    if (name === "input-mouse") return "\u{F037D}"
    if (name === "input-gaming") return "\u{F0297}"
    if (name === "input-tablet") return "\u{F04F6}"
    if (name === "phone") return "\u{F011C}"
    if (name === "computer") return "\u{F0322}"
    if (name === "video-display") return "\u{F0379}"
    if (name === "printer" || name === "scanner") return "\u{F042A}"
    if (name === "camera-photo" || name === "camera-video") return "\u{F0100}"
    if (name === "phone-car" || name === "car") return "\u{F010B}"
    if (name.indexOf("watch") !== -1) return "\u{F0589}"
    // A wrong picture of a device is worse than no picture of it.
    return "\u{F00AF}"
  }

  // ----------------------------------------------------------- interaction
  property string expandedAddress: ""
  property string busyAddress: ""
  property string busyVerb: ""
  property string busyName: ""
  property string errorAddress: ""
  property string errorText: ""

  // S6d-3. Nothing acts on a tap of the row itself: no Bluetooth device is
  // unambiguous the way an open network is, so every row opens its drawer.
  function rowTapped(row) {
    if (root.busyAddress !== "") return          // one action at a time
    root.errorAddress = ""
    root.errorText = ""
    root.expandedAddress = root.expandedAddress === row.address ? "" : row.address
  }

  // S6d-6. Detached and fire-and-forget: the device's own properties coming
  // good is what tells us it worked.
  function runAction(row, verb, label) {
    root.busyAddress = row.address
    root.busyVerb = label
    root.busyName = row.name
    root.errorAddress = ""
    root.errorText = ""
    actionTimeout.restart()
    Quickshell.execDetached(["omarchy-bluetooth-device", verb, row.address])
  }

  function connectRow(row) {
    if (row.connected) return
    // pair for a device BlueZ has no record of, connect for one it has.
    root.runAction(row, row.known ? "connect" : "pair", row.known ? "Connecting" : "Pairing")
  }

  function disconnectRow(row) {
    var dev = root.deviceForAddress(row.address)
    if (!dev) return
    root.busyAddress = row.address
    root.busyVerb = "Disconnecting"
    root.busyName = row.name
    root.errorAddress = ""
    root.errorText = ""
    actionTimeout.restart()
    dev.disconnect()
  }

  function forgetRow(row) {
    root.runAction(row, "forget", "Forgetting")
  }

  // Observed, off liveRows -- rows are frozen while an action is in flight.
  onLiveRowsChanged: {
    if (root.busyAddress === "") return
    var found = null
    for (var i = 0; i < root.liveRows.length; i++)
      if (root.liveRows[i].address === root.busyAddress) { found = root.liveRows[i]; break }

    var done = false
    if (root.busyVerb === "Forgetting") done = !found || !found.known
    else if (root.busyVerb === "Disconnecting") done = !found || !found.connected
    else done = !!(found && found.connected)

    if (!done) return
    actionTimeout.stop()
    root.busyAddress = ""
    root.busyVerb = ""
    root.busyName = ""
    root.expandedAddress = ""
  }

  // S6d-7. Says only what it knows: it did not land in time. Spelled out per
  // verb -- "Forgetting" minus "ing" is "forgett".
  function failureText(verb) {
    if (verb === "Pairing")
      return "Could not pair — put the device in pairing mode and try again"
    if (verb === "Forgetting")
      return "Could not forget this device"
    if (verb === "Disconnecting")
      return "Could not disconnect — the device may already be gone"
    return "Could not connect — check the device is on and in range"
  }

  Timer {
    id: actionTimeout
    interval: 25000
    onTriggered: {
      if (root.busyAddress === "") return
      root.errorAddress = root.busyAddress
      root.errorText = root.failureText(root.busyVerb)
      root.expandedAddress = root.busyAddress
      root.busyAddress = ""
      root.busyVerb = ""
      root.busyName = ""
    }
  }

  // ------------------------------------------------------------- the radio
  // S6d-8. Unblock first when the adapter reads blocked, then write `enabled`
  // once the unblock has landed: BlueZ drops the write under a soft block.
  function setEnabled(on) {
    if (!root.adapter) return
    if (on && root.adapter.state === BluetoothAdapterState.Blocked) {
      Quickshell.execDetached(["rfkill", "unblock", "bluetooth"])
      unblockThenEnable.restart()
      return
    }
    root.adapter.enabled = on
  }

  Timer {
    id: unblockThenEnable
    interval: 700
    onTriggered: if (root.adapter) root.adapter.enabled = true
  }

  // ---------------------------------------------------------- discovery
  // S6d-2. Only while the screen is up, and retried: BlueZ rejects
  // StartDiscovery on an adapter still powering on, and a session times out on
  // its own after a couple of minutes.
  property bool owesDiscoveryStop: false

  Timer {
    id: discoveryStart
    interval: 1500
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.adapter !== null
             && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.owesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  // Bound to the confirmed state rather than written once at close: Quickshell
  // only forwards a `discovering` write that differs from the last state BlueZ
  // reported, so a stop issued while a start is in flight is dropped. Capped,
  // so a session some other client holds cannot draw StopDiscovery forever.
  Timer {
    id: discoveryStop
    interval: 400
    repeat: true
    property int attempts: 0
    running: !root.opened && root.owesDiscoveryStop
             && root.adapter !== null && root.adapter.discovering
    onTriggered: {
      discoveryStop.attempts += 1
      if (discoveryStop.attempts > 4) {
        root.owesDiscoveryStop = false
        discoveryStop.attempts = 0
        return
      }
      root.adapter.discovering = false
    }
  }

  Connections {
    target: root.adapter
    ignoreUnknownSignals: true
    function onDiscoveringChanged() {
      if (root.adapter && !root.adapter.discovering) {
        root.owesDiscoveryStop = false
        discoveryStop.attempts = 0
      }
    }
  }

  // ------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    if (root.host) root.host.hideSheets()
    bluetoothWindow.show()
    root.returnTo = ""
    root.expandedAddress = ""
    root.errorAddress = ""
    root.errorText = ""
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      if (payload && payload.returnTo) root.returnTo = String(payload.returnTo)
    } catch (e) {
      // A malformed payload is not worth refusing to open over.
    }
  }

  function close() { bluetoothWindow.hide() }

  function quit(): void { root.close() }

  function dismiss() {
    var back = root.returnTo
    root.close()
    if (back && root.host) root.host.open(JSON.stringify({ surface: back }))
  }

  IpcHandler {
    target: "bluetooth"

    function state(): string { return root.opened ? "open" : "closed" }
    function open(): string { root.open("{}"); return "ok" }
    // As Wi-Fi's: `close` is the chevron, `quit` just closes.
    function close(): string { root.dismiss(); return "ok" }
    function quit(): string { root.quit(); return "ok" }
    function enabled(): string {
      if (!root.adapter) return "no-adapter"
      return root.adapter.enabled ? "on" : "off"
    }

    // S6d-2: the scan is up while the screen is, and down after it.
    function scanning(): string {
      return root.adapter && root.adapter.discovering ? "on" : "off"
    }

    function list(): string {
      var out = []
      for (var i = 0; i < root.rows.length; i++) {
        var r = root.rows[i]
        out.push([r.name, r.address,
                  r.connected ? "connected" : "-",
                  r.known ? "known" : "new",
                  r.batteryAvailable ? r.battery + "%" : "-"].join("\t"))
      }
      return out.join("\n")
    }

    // Window coordinates; add the window's position from `hyprctl clients`.
    function actionTarget(): string {
      if (!root.actionRowItem) return ""
      var p = root.actionRowItem.mapToItem(null, 0, 0)
      return "actions=" + Math.round(p.x) + "," + Math.round(p.y)
           + " " + Math.round(root.actionRowItem.width)
           + "x" + Math.round(root.actionRowItem.height)
           + " row=" + root.expandedAddress
    }
  }

  // ----------------------------------------------------------------- window
  MobileAppWindow {
    id: bluetoothWindow

    host: root.host
    appName: "Bluetooth"
    pageTitle: root.pageTitle
    screenId: root.screenId
    glyph: "\u{F00AF}"
    color: root.surface

    onUnmapped: {
      root.expandedAddress = ""
      root.errorAddress = ""
      root.errorText = ""
    }

    Rectangle {
      anchors.fill: parent
      color: root.surface

      focus: true
      Keys.onEscapePressed: root.dismiss()

      Column {
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        anchors.topMargin: Style.space(8)
        anchors.bottomMargin: Style.space(8)
        spacing: Style.space(10)

        // --------------------------------------------------------- header
        Item {
          width: parent.width
          height: Style.space(44)

          BackChevron {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            fill: root.container
            ink: root.textOnSurface
            onActivated: root.dismiss()
          }

          Text {
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "Bluetooth"
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.weight: root.textWeight
            color: root.textOnSurface
          }

          RadioPill {
            id: radioSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            on: !!root.adapter && root.adapter.enabled
            available: root.adapter !== null
            accent: root.accent
            track: root.containerHigh
            inkOn: root.textOnAccent
            inkOff: root.textOnSurface
            onToggled: root.setEnabled(!root.adapter.enabled)
          }
        }

        // ---------------------------------------------------------- status
        Text {
          width: parent.width
          text: {
            if (!root.adapter) return "No Bluetooth adapter"
            if (!root.adapter.enabled) return "Bluetooth is off"
            if (root.busyAddress !== "") return root.busyVerb + " " + root.busyName + "…"
            if (root.rows.length === 0) return "Scanning…"
            if (root.rows.length === 1) return "1 device"
            return root.rows.length + " devices"
          }
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: root.textWeight
          color: root.subdued
        }

        // ------------------------------------------------------------ list
        ListView {
          id: list
          width: parent.width
          height: Math.max(0, parent.height - y)
          clip: true
          spacing: Style.space(6)
          model: root.adapter && root.adapter.enabled ? root.rows : []
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: rowItem
            required property var modelData

            readonly property bool isExpanded: root.expandedAddress === rowItem.modelData.address
            readonly property bool isBusy: root.busyAddress === rowItem.modelData.address
            readonly property bool hasError: root.errorAddress === rowItem.modelData.address

            width: list.width
            height: Style.space(58)
                    + (rowItem.isExpanded ? Style.space(60) : 0)
                    + (rowItem.hasError ? Style.space(30) : 0)
            Behavior on height { NumberAnimation { duration: 120 } }
            radius: root.radiusCard
            color: rowItem.isExpanded ? root.containerHigh : root.container

            Item {
              id: rowHead
              width: parent.width
              height: Style.space(58)

              PressVeil {
                anchors.fill: parent
                radius: root.radiusCard
                on: headArea.pressed
              }

              Text {
                id: kindGlyph
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: root.deviceGlyph(rowItem.modelData.icon)
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: rowItem.modelData.connected ? root.accent : root.textOnSurface
              }

              Text {
                id: nameText
                anchors.left: kindGlyph.right
                anchors.leftMargin: Style.space(14)
                anchors.right: batteryText.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -Style.space(7)
                text: rowItem.modelData.name
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.weight: root.textWeight
                color: root.textOnSurface
              }

              Text {
                anchors.left: nameText.left
                anchors.right: nameText.right
                anchors.top: nameText.bottom
                anchors.topMargin: Style.space(2)
                text: rowItem.isBusy ? root.busyVerb + "…"
                    : rowItem.modelData.pairing ? "Pairing…"
                    : rowItem.modelData.blocked ? "Blocked"
                    : rowItem.modelData.connected ? "Connected"
                    : rowItem.modelData.known ? "Paired"
                    : "Available"
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: root.textWeight
                color: rowItem.modelData.connected ? root.accent : root.subdued
              }

              // S6d-5. The one thing the shade's tile cannot show. A number
              // rather than a glyph: a 12px icon with five levels says less
              // than "62%".
              Text {
                id: batteryText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                visible: rowItem.modelData.batteryAvailable
                width: visible ? implicitWidth : 0
                text: rowItem.modelData.battery + "%"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: root.textWeight
                color: root.subdued
              }

              MouseArea {
                id: headArea
                anchors.fill: parent
                onClicked: root.rowTapped(rowItem.modelData)
              }
            }

            Text {
              visible: rowItem.hasError
              anchors.top: rowHead.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              text: root.errorText
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: root.textWeight
              color: root.accent
            }

            // One row of verbs: at most two show at once, and they fit a line.
            Row {
              id: actionRow
              visible: rowItem.isExpanded
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)
              height: Style.space(44)

              // On visibility AND on completion: a delegate built with
              // `visible` already true never emits visibleChanged.
              onVisibleChanged: {
                if (visible) root.actionRowItem = actionRow
                else if (root.actionRowItem === actionRow) root.actionRowItem = null
              }
              Component.onCompleted: if (visible) root.actionRowItem = actionRow
              Component.onDestruction:
                if (root.actionRowItem === actionRow) root.actionRowItem = null

              Rectangle {
                visible: !rowItem.modelData.connected
                width: Style.space(110)
                height: parent.height
                radius: height / 2
                // A blocked device rejects every connection at the system
                // level, so offering the verb would be offering a failure.
                readonly property bool ready: !rowItem.modelData.blocked
                                              && root.busyAddress === ""
                color: ready ? root.accent : root.containerHigh
                opacity: ready ? 1 : 0.6
                PressVeil {
                  anchors.fill: parent
                  radius: parent.radius
                  ink: parent.ready ? root.textOnAccent : root.textOnSurface
                  on: connectArea.pressed
                }
                Text {
                  anchors.centerIn: parent
                  text: rowItem.modelData.known ? "Connect" : "Pair"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: root.textWeight
                  color: parent.ready ? root.textOnAccent : root.subdued
                }
                MouseArea {
                  id: connectArea
                  anchors.fill: parent
                  enabled: parent.ready
                  onClicked: root.connectRow(rowItem.modelData)
                }
              }

              Rectangle {
                visible: rowItem.modelData.connected
                width: Style.space(120)
                height: parent.height
                radius: height / 2
                color: root.containerHigh
                PressVeil { anchors.fill: parent; radius: parent.radius; on: disconnectArea.pressed }
                Text {
                  anchors.centerIn: parent
                  text: "Disconnect"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: root.textWeight
                  color: root.textOnSurface
                }
                MouseArea {
                  id: disconnectArea
                  anchors.fill: parent
                  onClicked: root.disconnectRow(rowItem.modelData)
                }
              }

              Rectangle {
                visible: rowItem.modelData.known
                width: Style.space(96)
                height: parent.height
                radius: height / 2
                color: root.containerHigh
                PressVeil { anchors.fill: parent; radius: parent.radius; on: forgetArea.pressed }
                Text {
                  anchors.centerIn: parent
                  text: "Forget"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: root.textWeight
                  color: root.textOnSurface
                }
                MouseArea {
                  id: forgetArea
                  anchors.fill: parent
                  onClicked: root.forgetRow(rowItem.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
