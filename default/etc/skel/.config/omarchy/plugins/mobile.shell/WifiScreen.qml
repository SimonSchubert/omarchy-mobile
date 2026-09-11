// Joining a Wi-Fi network, with a finger (docs/spec/shade.md S6, S6a, S6b).
//
// Ported from moarchy.wifi. A screen that is a window (gestures.md K): it maps
// as an ordinary toplevel, so the window rule gives it a workspace, the
// carousel a card, and the strip's sideways swipe a way back to it.
//
// Not the TUI: nmtui never asks for mouse reporting, so its buttons are drawn
// text that a tap cannot press. Not upstream's network panel either: that is a
// bar widget's popup, and this phone's bar hosts no widgets (Bar.qml).
//
// Nothing talks to nmcli. Quickshell.Networking exposes the model and the
// verbs -- connect(), connectWithPsk(), disconnect(), forget() -- as methods.
// Enterprise (802.1X) networks are out of scope, as they are in moarchy: they
// need an identity as well as a passphrase, and a two-field form nobody can
// test here would be worse than not offering one.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Networking
import qs.Commons
import qs.Ui as Ui

Item {
  id: root

  property var host: null

  readonly property string screenId: "mobile.wifi"

  // Whether the window is mapped. Read off the window, never assigned
  // (MobileAppWindow.qml says why).
  readonly property bool opened: wifiWindow.visible

  // How the carousel finds this screen from its window (Shell.qml).
  readonly property var appWindow: wifiWindow

  // K5. The card shows the network you are on, and says so when there is none.
  readonly property string pageTitle: {
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].connected) return root.rows[i].ssid
    if (!root.wifiDevice) return "No Wi-Fi"
    return Networking.wifiEnabled ? "Not connected" : "Off"
  }

  // Where the back chevron goes: the shade, when the shade's long press is what
  // opened this. Empty means nowhere -- the window just closes.
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
  readonly property color subdued: Util.alpha(Color.popups.text, 0.62)

  component PressVeil: Veil { ink: root.textOnSurface }

  // ------------------------------------------------------------------ data
  readonly property var wifiDevice: {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].type === DeviceType.Wifi) return devices[i]
    return null
  }

  // PRIMITIVES ONLY in this list. A WifiNetwork in delegate data leaves a live
  // QObject wrapper in every delegate, and a scan that drops an access point
  // can destroy it while a delegate is still incubating -- which segfaults
  // quickshell rather than throwing. Actions resolve the object again, by
  // ssid, at the moment they run. Upstream's Model.js carries the same warning.
  //
  // And frozen while a row is open: reassigning a ListView's model rebuilds its
  // delegates, the focused passphrase field is destroyed with them, and the
  // on-screen keyboard retracts mid-passphrase.
  property var frozenRows: []
  readonly property bool listFrozen: root.expandedSsid !== "" || root.busySsid !== ""
  readonly property var rows: root.listFrozen ? root.frozenRows : root.liveRows

  onListFrozenChanged: if (root.listFrozen) root.frozenRows = root.liveRows

  // The expanded row's passphrase pill and field, registered by the delegate
  // that owns them, so the IPC below can report their rects.
  property var passPillItem: null
  property var passFieldItem: null

  readonly property var liveRows: {
    var objs = root.wifiDevice && root.wifiDevice.networks
             ? root.wifiDevice.networks.values : []
    var out = []
    for (var i = 0; i < objs.length; i++) {
      var n = objs[i]
      if (!n || !n.name) continue
      out.push({
        ssid: String(n.name),
        signal: Math.round((n.signalStrength || 0) * 100),
        security: n.security,
        known: !!n.known,
        connected: !!n.connected
      })
    }
    out.sort(function(a, b) {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      if (a.known !== b.known) return a.known ? -1 : 1
      return b.signal - a.signal
    })
    return out
  }

  // Any secured network that is not connected offers a passphrase field,
  // INCLUDING a saved one: saved-but-wrong is the ordinary case after a typo,
  // and NetworkManager will replace the stored secret.
  function offersPassphrase(row) {
    return !row.connected && root.needsPassphrase(row.security)
  }

  function networkForSsid(ssid) {
    var objs = root.wifiDevice && root.wifiDevice.networks
             ? root.wifiDevice.networks.values : []
    for (var i = 0; i < objs.length; i++)
      if (objs[i] && String(objs[i].name) === String(ssid)) return objs[i]
    return null
  }

  // OWE encrypts without authenticating, so it has no credentials to ask for.
  // Anything unrecognised stays credentialed: a needless prompt beats a silent
  // failure.
  function needsPassphrase(security) {
    return security !== WifiSecurityType.Open && security !== WifiSecurityType.Owe
  }

  function isEnterprise(security) {
    return security === WifiSecurityType.Wpa2Eap || security === WifiSecurityType.WpaEap
  }

  // U+F092F, U+F091F, U+F0922, U+F0925, U+F0928 -- upstream's own ramp.
  // Written as escapes: this file's glyphs have been lost in transit once.
  function signalGlyph(strength) {
    var icons = ["\u{F092F}", "\u{F091F}", "\u{F0922}", "\u{F0925}", "\u{F0928}"]
    return icons[Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))]
  }

  // ----------------------------------------------------------- interaction
  // One row expanded at a time, into a passphrase field or into
  // Disconnect/Forget, so the list never grows two drawers on a screen this
  // size.
  property string expandedSsid: ""
  property string passphrase: ""

  // The join in flight, held by ssid for the same reason the rows are
  // primitives.
  property string busySsid: ""

  property bool passphraseFocused: false

  // Off by default; the eye turns it on. A phone keyboard has no key feedback
  // worth the name, and a wrong character is otherwise found 25 seconds later.
  property bool showPassphrase: false
  property string errorSsid: ""
  property string errorText: ""

  onExpandedSsidChanged: if (root.expandedSsid === "") root.passphraseFocused = false

  function rowTapped(row) {
    if (root.busySsid !== "") return          // one join at a time
    root.errorSsid = ""
    root.errorText = ""

    if (root.isEnterprise(row.security)) {
      root.errorSsid = row.ssid
      root.errorText = "Enterprise networks need the terminal"
      return
    }
    // An open network nobody has joined is the one case with nothing to ask,
    // so it connects on the tap. Everything else opens its drawer.
    if (!row.connected && !row.known && !root.needsPassphrase(row.security)) {
      root.join(row.ssid, "")
      return
    }
    root.passphrase = ""
    root.showPassphrase = false
    root.expandedSsid = root.expandedSsid === row.ssid ? "" : row.ssid
  }

  function joinRow(row) {
    if (root.offersPassphrase(row) && root.passphrase.length >= 8)
      root.join(row.ssid, root.passphrase)
    else if (row.known || !root.needsPassphrase(row.security))
      root.join(row.ssid, "")
  }

  function join(ssid, psk) {
    var net = root.networkForSsid(ssid)
    if (!net) return
    root.busySsid = ssid
    root.errorSsid = ""
    root.errorText = ""
    joinTimeout.restart()
    if (psk === "") net.connect()
    else net.connectWithPsk(psk)
  }

  function disconnectSsid(ssid) {
    var net = root.networkForSsid(ssid)
    if (net) net.disconnect()
    root.expandedSsid = ""
  }

  function forgetSsid(ssid) {
    var net = root.networkForSsid(ssid)
    if (net) net.forget()
    root.expandedSsid = ""
  }

  // Success is observed rather than reported: the network we asked for coming
  // up connected is the only signal that means it worked. liveRows, NOT rows --
  // rows are frozen while a join is in flight, so watching them the success
  // could never arrive and a join that worked would time out.
  onLiveRowsChanged: {
    if (root.busySsid === "") return
    for (var i = 0; i < root.liveRows.length; i++) {
      if (root.liveRows[i].ssid === root.busySsid && root.liveRows[i].connected) {
        joinTimeout.stop()
        root.busySsid = ""
        root.expandedSsid = ""
        root.passphrase = ""
        return
      }
    }
  }

  // No failure reason is exposed that is worth trusting, so this reports what
  // it knows: it did not come up in time. Guessing "wrong password" at a
  // network that was out of range sends someone to retype one that was right.
  Timer {
    id: joinTimeout
    interval: 25000
    onTriggered: {
      if (root.busySsid === "") return
      root.errorSsid = root.busySsid
      root.errorText = "Could not join — check the passphrase, or move closer"
      root.expandedSsid = root.busySsid
      root.passphrase = ""
      root.showPassphrase = false
      root.busySsid = ""
    }
  }

  // Scan only while the screen is up: a scan left running costs radio time and
  // battery for a list nobody is reading.
  function setScanning(on) {
    if (root.wifiDevice) root.wifiDevice.scannerEnabled = on
  }
  onOpenedChanged: root.setScanning(root.opened)
  onWifiDeviceChanged: root.setScanning(root.opened)

  // ------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    if (root.host) root.host.hideSheets()
    wifiWindow.show()
    root.returnTo = ""
    root.expandedSsid = ""
    root.passphrase = ""
    root.errorSsid = ""
    root.errorText = ""
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      if (payload && payload.returnTo) root.returnTo = String(payload.returnTo)
    } catch (e) {
      // A malformed payload is not worth refusing to open over.
    }
  }

  function close() { wifiWindow.hide() }

  // The name the back gesture will ask for (K7). Unmapping the window is
  // closing the app; there is no gentler thing it could mean.
  function quit(): void { root.close() }

  // The back chevron: close, and hand back to whatever opened this.
  function dismiss() {
    var back = root.returnTo
    root.passphrase = ""
    root.close()
    if (back && root.host) root.host.open(JSON.stringify({ surface: back }))
  }

  IpcHandler {
    target: "wifi"

    function state(): string { return root.opened ? "open" : "closed" }
    function open(): string { root.open("{}"); return "ok" }
    // `close` is the back chevron -- it hands back to whatever opened this.
    // `quit` just closes, which is what a check tidying up wants.
    function close(): string { root.dismiss(); return "ok" }
    function quit(): string { root.quit(); return "ok" }
    function enabled(): string {
      if (!root.wifiDevice) return "no-device"
      return Networking.wifiEnabled ? "on" : "off"
    }

    // One line per network, so a check can assert the list without a
    // screenshot.
    function list(): string {
      var out = []
      for (var i = 0; i < root.rows.length; i++) {
        var r = root.rows[i]
        out.push([r.ssid, r.signal,
                  root.needsPassphrase(r.security) ? "secured" : "open",
                  r.known ? "known" : "new",
                  r.connected ? "connected" : "-"].join("\t"))
      }
      return out.join("\n")
    }

    // Where a network's row is, in WINDOW coordinates -- this is a window, and
    // a Wayland client does not know where the compositor put it. Add the
    // window's position from `hyprctl clients` to aim a tap.
    function rowTarget(ssid: string): string {
      for (var i = 0; i < root.rows.length; i++) {
        if (root.rows[i].ssid !== ssid) continue
        var item = list.itemAtIndex(i)
        if (!item) return "none"
        var p = item.mapToItem(null, item.width / 2, Style.space(29))
        return Math.round(p.x) + " " + Math.round(p.y)
      }
      return "none"
    }

    function passTarget(): string {
      if (!root.passPillItem || !root.passFieldItem) return ""
      var box = it => {
        var p = it.mapToItem(null, 0, 0)
        return Math.round(p.x) + "," + Math.round(p.y)
             + " " + Math.round(it.width) + "x" + Math.round(it.height)
      }
      return "pill=" + box(root.passPillItem)
           + " field=" + box(root.passFieldItem)
           + " focused=" + root.passphraseFocused
           + " revealed=" + root.showPassphrase
    }

    // Test hooks through the screen's own functions, for a check that cannot
    // type on this VM's keyboard: expand a row, and join with a passphrase.
    function tap(ssid: string): string {
      for (var i = 0; i < root.rows.length; i++)
        if (root.rows[i].ssid === ssid) { root.rowTapped(root.rows[i]); return "ok" }
      return "none"
    }

    function joinWith(ssid: string, psk: string): string {
      root.join(ssid, psk)
      return "ok"
    }

    function status(): string {
      return "busy=" + JSON.stringify(root.busySsid)
           + " expanded=" + JSON.stringify(root.expandedSsid)
           + " error=" + JSON.stringify(root.errorText)
           + " title=" + JSON.stringify(root.pageTitle)
    }
  }

  // ----------------------------------------------------------------- window
  //
  // The passphrase field needs no arrangement of its own: a focused window
  // holds the seat's keyboard by being focused, which is what activates
  // text-input-v3 and raises an on-screen keyboard, whose exclusive zone then
  // shrinks this window so the field reflows clear of it.
  MobileAppWindow {
    id: wifiWindow

    host: root.host
    appName: "Wi-Fi"
    pageTitle: root.pageTitle
    screenId: root.screenId
    glyph: "\u{F092F}"
    color: root.surface

    onUnmapped: {
      root.expandedSsid = ""
      root.passphrase = ""
      root.showPassphrase = false
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

          Rectangle {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(38)
            height: width
            radius: width / 2
            color: root.container

            PressVeil { anchors.fill: parent; radius: parent.radius; on: backArea.pressed }

            Ui.OpticalGlyph {
              anchors.fill: parent
              text: "\uF104"
              fontFamily: Style.font.family
              fontSize: Style.font.icon
              color: root.textOnSurface
            }
            // 38 drawn, 44 answering (docs/spec/style.md E1, E2).
            MouseArea {
              id: backArea
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              onClicked: root.dismiss()
            }
          }

          Text {
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "Wi-Fi"
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.weight: root.textWeight
            color: root.textOnSurface
          }

          // The radio switch: a pill rather than a checkbox, because it is the
          // one control here that is not a list row and has to read as a switch
          // at a glance.
          Rectangle {
            id: radioSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(52)
            height: Style.space(30)
            radius: height / 2
            // No device is not "off" -- there is nothing to switch.
            opacity: root.wifiDevice ? 1 : 0.4
            color: root.wifiDevice && Networking.wifiEnabled ? root.accent : root.containerHigh
            Behavior on color { ColorAnimation { duration: 120 } }

            PressVeil {
              anchors.fill: parent
              radius: parent.radius
              ink: Networking.wifiEnabled ? root.textOnAccent : root.textOnSurface
              on: radioArea.pressed
            }

            Rectangle {
              width: parent.height - Style.space(6)
              height: width
              radius: width / 2
              y: Style.space(3)
              x: root.wifiDevice && Networking.wifiEnabled
                 ? parent.width - width - Style.space(3) : Style.space(3)
              color: root.wifiDevice && Networking.wifiEnabled ? root.textOnAccent : root.textOnSurface
              Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
            // 30 tall is what a switch looks like, and 30 is not a target: the
            // 7px reaches the 44px header it sits in.
            MouseArea {
              id: radioArea
              anchors.fill: parent
              anchors.margins: -Style.space(7)
              enabled: !!root.wifiDevice
              onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
            }
          }
        }

        // ---------------------------------------------------------- status
        Text {
          width: parent.width
          text: {
            if (!root.wifiDevice) return "No Wi-Fi device"
            if (!Networking.wifiEnabled) return "Wi-Fi is off"
            if (root.busySsid !== "") return "Joining " + root.busySsid + "…"
            if (root.rows.length === 0) return "Scanning…"
            return root.rows.length + (root.rows.length === 1 ? " network" : " networks")
          }
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
          model: root.wifiDevice && Networking.wifiEnabled ? root.rows : []
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: rowItem
            required property var modelData

            readonly property bool isExpanded: root.expandedSsid === rowItem.modelData.ssid
            readonly property bool isBusy: root.busySsid === rowItem.modelData.ssid
            readonly property bool hasError: root.errorSsid === rowItem.modelData.ssid

            width: list.width
            // Tall enough for a finger, and taller again when a drawer is open.
            height: Style.space(58)
                    + (rowItem.isExpanded
                       ? Style.space(60)
                         + (root.offersPassphrase(rowItem.modelData) ? Style.space(52) : 0)
                       : 0)
                    + (rowItem.hasError ? Style.space(30) : 0)
            Behavior on height { NumberAnimation { duration: 120 } }
            radius: root.radiusCard
            color: rowItem.isExpanded ? root.containerHigh : root.container

            Item {
              id: rowHead
              width: parent.width
              height: Style.space(58)

              // Sized to the head, not the delegate: the head is what the
              // finger is on, and an expanded row is up to 170 tall.
              PressVeil {
                anchors.fill: parent
                radius: root.radiusCard
                on: headArea.pressed
              }

              Text {
                id: sig
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: root.signalGlyph(rowItem.modelData.signal)
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: rowItem.modelData.connected ? root.accent : root.textOnSurface
              }

              Text {
                id: ssidText
                anchors.left: sig.right
                anchors.leftMargin: Style.space(14)
                anchors.right: lock.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -Style.space(7)
                text: rowItem.modelData.ssid
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.weight: root.textWeight
                color: root.textOnSurface
              }

              Text {
                anchors.left: ssidText.left
                anchors.right: ssidText.right
                anchors.top: ssidText.bottom
                anchors.topMargin: Style.space(2)
                text: rowItem.isBusy ? "Joining…"
                    : rowItem.modelData.connected ? "Connected"
                    : rowItem.modelData.known ? "Saved"
                    : root.needsPassphrase(rowItem.modelData.security) ? "Secured"
                    : "Open"
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: root.textWeight
                color: rowItem.modelData.connected ? root.accent : root.subdued
              }

              Text {
                id: lock
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: root.needsPassphrase(rowItem.modelData.security) ? "\u{F033E}" : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.subdued
              }

              MouseArea {
                id: headArea
                anchors.fill: parent
                onClicked: root.rowTapped(rowItem.modelData)
              }
            }

            // ------------------------------------------------- error line
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

            // ----------------------------------------------------- drawer
            // Two rows, not one: at 360px a passphrase field, a Join and a
            // Forget do not fit on a line, and the field is the wrong thing to
            // shrink.
            Column {
              visible: rowItem.isExpanded
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(8)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Rectangle {
                id: passPill
                visible: root.offersPassphrase(rowItem.modelData)
                width: parent.width
                height: Style.space(44)
                radius: height / 2
                color: root.surface

                // On visibility, not completion: every row builds one of these
                // and only the expanded row shows it.
                onVisibleChanged: {
                  if (visible) {
                    root.passPillItem = passPill
                    root.passFieldItem = passField
                  } else if (root.passPillItem === passPill) {
                    root.passPillItem = null
                    root.passFieldItem = null
                  }
                }
                Component.onDestruction: if (root.passPillItem === passPill) {
                  root.passPillItem = null
                  root.passFieldItem = null
                }

                // Padding rather than anchor margins, so the whole drawn field
                // takes a tap (docs/spec/style.md F1-F3).
                Ui.TextField {
                  id: passField
                  anchors.left: parent.left
                  anchors.right: revealButton.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  leftPadding: Style.space(16)
                  rightPadding: Style.space(4)
                  verticalAlignment: TextInput.AlignVCenter
                  password: !root.showPassphrase
                  placeholderText: rowItem.modelData.known ? "New passphrase" : "Passphrase"
                  background: null
                  verticalPadding: 0
                  text: root.passphrase
                  onTextChanged: root.passphrase = text
                  onAccepted: root.joinRow(rowItem.modelData)
                  onActiveFocusChanged: root.passphraseFocused = activeFocus
                  Component.onDestruction: if (activeFocus) root.passphraseFocused = false
                }

                Item {
                  id: revealButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(44)
                  height: width

                  PressVeil { anchors.fill: parent; radius: width / 2; on: eyeArea.pressed }
                  Ui.OpticalGlyph {
                    anchors.fill: parent
                    text: root.showPassphrase ? "\u{F06D0}" : "\u{F06D1}"   // eye / eye-off
                    fontFamily: Style.font.family
                    fontSize: Style.font.icon
                    color: root.showPassphrase ? root.accent : root.subdued
                  }
                  MouseArea {
                    id: eyeArea
                    anchors.fill: parent
                    onClicked: root.showPassphrase = !root.showPassphrase
                  }
                }
              }

              Row {
                anchors.right: parent.right
                spacing: Style.space(8)
                height: Style.space(44)

                Rectangle {
                  visible: !rowItem.modelData.connected
                  width: Style.space(96)
                  height: parent.height
                  radius: height / 2
                  // A saved network can be rejoined with no passphrase typed.
                  readonly property bool ready:
                    rowItem.modelData.known
                    || !root.offersPassphrase(rowItem.modelData)
                    || root.passphrase.length >= 8
                  color: ready ? root.accent : root.containerHigh
                  opacity: ready ? 1 : 0.6
                  PressVeil {
                    anchors.fill: parent
                    radius: parent.radius
                    ink: parent.ready ? root.textOnAccent : root.textOnSurface
                    on: joinArea.pressed
                  }
                  Text {
                    anchors.centerIn: parent
                    text: "Join"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.weight: root.textWeight
                    color: parent.ready ? root.textOnAccent : root.subdued
                  }
                  MouseArea {
                    id: joinArea
                    anchors.fill: parent
                    enabled: parent.ready
                    onClicked: root.joinRow(rowItem.modelData)
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
                    onClicked: root.disconnectSsid(rowItem.modelData.ssid)
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
                    onClicked: root.forgetSsid(rowItem.modelData.ssid)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
