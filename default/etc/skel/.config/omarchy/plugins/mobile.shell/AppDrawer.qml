// The app drawer: a full-screen grid of apps, raised by a drag up on the home
// screen (docs/spec/gestures.md D1) and put away by a drag down anywhere on it
// (H1).
//
// It no longer owns the bottom edge. moarchy's A5 is that no strip gesture
// ever opens the drawer -- the strip is the overview, the home screen is the
// launcher -- and until the carousel existed this surface held the edge as a
// toggle, because the edge had nothing else to mean. EdgeGestures.qml owns it
// now and writes this sheet's `progress` directly, the way it writes the
// carousel's.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui

Item {
  id: root

  property var host: null
  readonly property var apps: root.host ? root.host.apps : null

  // ------------------------------------------------------------- geometry
  readonly property int stripHeight: root.host ? root.host.stripHeight : Style.space(20)

  readonly property int columns: 4
  readonly property int iconSize: Style.space(42)

  // Written out rather than taken from Style.cornerRadius, which mirrors
  // Hyprland's decoration:rounding -- the right answer for tiled windows and
  // the wrong one for a sheet. Colours still come from the theme, so a theme
  // switch restyles all of this.
  readonly property int radiusSheet: Style.space(28)
  readonly property int radiusTile: Style.space(20)

  // ------------------------------------------------------------ drag contract
  //
  // 0 shut .. 1 open. A drag writes it directly, which is what makes the sheet
  // follow the finger rather than appear at a threshold; `dragging` turns the
  // animation off while it does, so writes track 1:1.
  property real progress: 0
  property bool dragging: false

  // Half-dragged is neither open nor shut, and calling it open would let a
  // summon try to close something still being pulled out.
  readonly property bool opened: root.progress >= 1 && !root.dragging

  Behavior on progress {
    enabled: !root.dragging
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  // D2a, H1. What one pixel of finger is worth to this sheet, in both
  // directions: its own height. 1:1 is not a preference -- the close drag's
  // handle is the sheet it moves, and at any other ratio it races out from
  // under the thumb. EdgeGestures reads this for the open drag so the two
  // directions cannot drift apart.
  readonly property real closeTravel: Math.max(1, drawerWindow.height)

  // One sample per frame of whichever drag is driving the sheet, the open one
  // from the home screen or its own close drag (D1, H1).
  property var dragTrace: []
  onDraggingChanged: if (root.dragging) root.dragTrace = []
  onProgressChanged: {
    if (!root.dragging) return
    var next = root.dragTrace.slice()
    if (next.length < 200) next.push(Math.round(root.progress * 100))
    root.dragTrace = next
  }

  // ------------------------------------------------- the on-screen keyboard
  readonly property int keyboardPanelHeight: root.host ? root.host.keyboardPanelHeight : 200

  // I5e. Is the keyboard up? Asked of the compositor's configure rather than
  // of the search field, because the two come apart: the keyboard can be up
  // with nothing here focused (I5d), and then the inset stays on with the
  // keyboard under it. The surface reserves nothing, so its height loses the
  // keyboard's zone when the keyboard rises -- a drop of the panel's height,
  // and the threshold sits at half of it, far from both heights and from the
  // strip the inset itself moves.
  readonly property bool keyboardUp: !!drawerWindow.screen
    && drawerWindow.height < drawerWindow.screen.height - root.keyboardPanelHeight / 2

  // I5d. Set for the length of a dismissal that exists to open something else,
  // and consumed by the dismiss() it guards. Without it the hide below would
  // fire on a launch too, and rob the app of a keyboard it asks for the moment
  // it maps -- a terminal does.
  property bool handingOff: false

  function open(): void {
    if (root.host) root.host.closeOthers("drawer")
    // A hand-off that never reached its dismiss must not spare the next one.
    root.handingOff = false
    // I5c, from the other side. The margin gate rests on "the field is focused
    // only while the keyboard is up", so the sheet asserts it on the way in
    // rather than trusting that every way out let go.
    sheet.forceActiveFocus()
    root.dragging = false
    root.progress = 1
  }

  function dismiss(): void {
    // I5c. Let go of the search field before the sheet goes, by handing active
    // focus to an item in the same surface. A field that keeps Qt's focus
    // across the close takes it back on the next open, a tap on it then
    // changes nothing and enables no text input, and the keyboard stops rising
    // for the rest of the session.
    sheet.forceActiveFocus()

    // I5d. Put the keyboard away on the way out. Letting go of the field is
    // not enough: once the drawer has been tapped it holds the seat's keyboard,
    // the window underneath loses it, and handing it back on the close
    // re-enters that window's text input and brings the keyboard up with it --
    // a keyboard nobody asked for, over whatever is on screen now. The handback
    // comes after this call, so the host keeps answering for a moment.
    if (!root.handingOff && root.host) root.host.retreatKeyboard()
    root.handingOff = false

    root.dragging = false
    root.progress = 0
    root.query = ""
    searchField.text = ""
  }

  IpcHandler {
    target: "drawer"

    // Exactly `open` or `closed`, because that is what every check in the spec
    // compares against. `status` carries the detail.
    function state(): string { return root.opened ? "open" : "closed" }

    function status(): string {
      return (root.opened ? "open" : (root.progress > 0 ? "dragging" : "closed"))
        + " progress=" + Math.round(root.progress * 100)
        + " apps=" + root.appRows.length
        + " query=" + JSON.stringify(root.query)
    }

    function dragTrace(): string { return root.dragTrace.join(" ") }

    // D2a. The divisor both drags use, so a check can compute what a drag of
    // n px should have left in dragTrace rather than assume a screen height.
    function geometry(): string {
      return "h=" + Math.round(drawerWindow.height)
        + " travel=" + Math.round(root.closeTravel)
        + " top=" + Math.round(drawerWindow.screen
                               ? drawerWindow.screen.height - drawerWindow.height + root.stripHeight
                               : 0)
        // I5-I5e. The inset in force, what it would be, how far the grid ends
        // above the surface's bottom -- at least a strip, keyboard up or down --
        // and whether the keyboard is up, as this surface reads it.
        + " margin=" + drawerWindow.margins.bottom
        + " strip=" + root.stripHeight
        + " gap=" + Math.round(drawerWindow.height - grid.mapToItem(null, 0, grid.height).y)
        + " kbd=" + (root.keyboardUp ? 1 : 0)
    }

    // I5, I5c. The search field's centre and whether it holds focus. In the
    // surface's own coordinates: where the surface starts on screen is the
    // compositor's to say, so a check adds the drawer layer's y from
    // `hyprctl layers` rather than trusting a number worked out here.
    function searchTarget(): string {
      var p = searchField.mapToItem(null, searchField.width / 2, searchField.height / 2)
      return Math.round(p.x) + " " + Math.round(p.y) + " focused=" + searchField.activeFocus
    }

    // H4. Where cell n is, and what it launches -- so a check can tap a real
    // icon rather than call launch() and prove nothing about the tap.
    //
    // In the surface's own coordinates, as searchTarget is. This used to add
    // a top worked out here as the screen's height less the surface's plus a
    // strip, which was 20px low at rest (46 against the 26 Hyprland reports)
    // and 240 low with the keyboard up, when the surface is 474 tall. A check
    // adds the drawer layer's y from `hyprctl layers` instead.
    function cellTarget(index: string): string {
      var item = grid.itemAtIndex(Number(index))
      if (!item || !item.entry || !root.apps) return "none"
      var p = item.mapToItem(null, item.width / 2, item.height / 2)
      return Math.round(p.x) + " " + Math.round(p.y) + " " + root.apps.entryName(item.entry)
    }

    function open(): string { root.open(); return "ok" }

    function close(): string { root.dismiss(); return "ok" }
  }

  // ---------------------------------------------------------------- the apps
  property string query: ""

  // Bumped by the library when desktop entries appear or vanish, so an app
  // installed while the shell is running shows up without a restart.
  property int appsRevision: 0

  readonly property var appRows: {
    var bump = root.appsRevision
    if (!root.apps) return []
    return root.apps.sortedEntries(root.query)
  }

  Connections {
    target: root.apps
    function onAppsChanged() { root.appsRevision++ }
  }

  function launch(entry): void {
    if (!entry || !root.apps) return
    root.apps.launch(entry.id, root.apps.entryName(entry))
    // A hand-off (I5d): the app being launched is the one that gets to say
    // whether it wants a keyboard.
    root.handingOff = true
    root.dismiss()
  }

  // ============================================================== the sheet
  PanelWindow {
    id: drawerWindow

    // Always mapped. A surface arriving mid-drag is the compositor re-deciding
    // what the pointer is over at exactly the wrong moment; mapped from the
    // start, the only thing that changes during a drag is what it draws.
    //
    // The cost is one transparent full-screen surface in the scene at rest:
    // the sheet is translated off the bottom and the scrim is at alpha 0.
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-drawer"
    WlrLayershell.layer: WlrLayer.Top

    // Reserve nothing, but be arranged into what the exclusive surfaces left.
    // That puts this under the bar and above the strip without a line of
    // geometry here, and it is what will let an on-screen keyboard coexist with
    // the search field when one lands.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    // Extend past the bottom of the usable area, back under the strip. Without
    // it the sheet stops at the top of the strip's band and a stripe of
    // wallpaper shows beneath it with the pill drawn on top (I1). A negative
    // margin is legal rather than a trick: layer-shell margins are int32 and
    // are subtracted with no clamping.
    //
    // I5a, I5e. Only while the on-screen keyboard is down. The margin extends
    // the surface past the bottom of the usable area, and what is there depends
    // on what else reserves: with the keyboard down it is the strip's band,
    // and the strip on Overlay draws over the sheet there as wanted; with it
    // up it is the
    // keyboard, and the sheet's last row would sit over its top row of keys.
    // Two signals, either one enough: the field's focus leads the raise, and
    // `keyboardUp` answers for a keyboard something else put up.
    margins.bottom: (searchField.activeFocus || root.keyboardUp) ? 0 : -root.stripHeight

    // The input region. Settled open, or while its own close drag runs, the
    // whole surface; otherwise nothing at all -- and "otherwise" includes the
    // open drag from the home screen. That drag is delivered to the home
    // surface underneath, and on this compositor a region opening under the
    // finger mid-drag is where the rest of the gesture would go: the sheet
    // would rise, take the pointer, and strand the drag that was raising it.
    readonly property bool inputFull: root.opened || root.sheetDragging

    // Two regions swapped, rather than one region whose geometry is bound. A
    // Region's own property changes do not re-apply the mask; assigning a
    // different Region object does.
    mask: drawerWindow.inputFull ? fullMask : emptyMask

    property Region fullMask: Region {
      width: drawerWindow.width
      height: drawerWindow.height
    }

    property Region emptyMask: Region {}

    // OnDemand, and NOT Exclusive -- which is what every other full-screen
    // overlay in the Omarchy shell uses, and what moarchy's drawer uses on
    // Sway. Hyprland routes every pointer event to a layer surface holding
    // exclusive keyboard focus, for as long as it holds it: measured, a press
    // on the bottom band while the drawer was up produced no press, no release
    // and no log line at all. The strip has to work over this sheet (A7), so
    // the sheet takes the keyboard only on a click.
    //
    // Keyed on the settled state rather than on `progress`, so keyboard focus
    // never changes in the middle of a gesture: a focus change moves the
    // pointer focus with it, and that cancels the drag being delivered.
    //
    // What it costs is that Escape does nothing on a freshly opened drawer and
    // works from the first tap on it onwards. On a phone that is nearly the
    // wanted behaviour anyway: opening the drawer must not raise the on-screen
    // keyboard.
    WlrLayershell.keyboardFocus: drawerWindow.inputFull ? WlrKeyboardFocus.OnDemand
                                                        : WlrKeyboardFocus.None

    // The sheet takes Qt's focus, not the search field: Escape has somewhere to
    // land once the drawer is focused, and the field stays unfocused until it
    // is tapped, which is what keeps the on-screen keyboard down.
    Component.onCompleted: sheet.forceActiveFocus()

    // Theme roles. `menu` rather than `popups`: this is the surface that
    // replaces the Omarchy menu on a phone, so a theme that styled the menu has
    // already styled this.
    readonly property color surface: Color.menu.background
    // NOT `onSurface`: QML reserves the `on<Uppercase>` prefix for signal
    // handlers, so the property would read as undefined -- which a `color`
    // renders as pure black with nothing logged.
    readonly property color textOnSurface: Color.menu.text
    readonly property color container: Util.alpha(Color.menu.text, 0.08)
    readonly property color subdued: Util.alpha(Color.menu.text, 0.55)

    // The scrim makes a half-open drawer read as half-open rather than as a
    // window that has not finished drawing. One blended quad with its alpha
    // bound to the drag -- not `opacity` on a subtree, which would composite
    // the whole sheet off-screen first on a GPU that is llvmpipe.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.6 * root.progress)
    }

    Rectangle {
      id: sheet

      width: parent.width
      height: parent.height
      // Rides up from below the bottom edge. Translation only: a `scale` on a
      // full-screen item costs a re-raster where a `y` costs nothing.
      y: parent.height * (1 - root.progress)
      color: drawerWindow.surface
      radius: root.radiusSheet
      focus: true

      // Escape clears the query first and closes second, so the way out of a
      // search is not the way out of the drawer.
      Keys.onEscapePressed: {
        if (root.query.length > 0 || searchField.text.length > 0) {
          searchField.text = ""
          root.query = ""
        } else {
          root.dismiss()
        }
      }

      // The radius rounds all four corners, so square the bottom two back off
      // rather than leave two notches over the strip.
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: root.radiusSheet
        color: drawerWindow.surface
      }

      // H1. A drag that starts on empty sheet. Declared before the content so
      // it sits under it: later siblings take input first, so this only ever
      // sees what nothing else claimed.
      MouseArea {
        anchors.fill: parent
        onPressed: mouse => root.sheetPress(this, mouse)
        onPositionChanged: mouse => root.sheetMove(this, mouse)
        onReleased: root.sheetRelease()
        onCanceled: root.sheetCancel()
      }

      // H6. The handle across the top. The visible bar is the affordance that
      // says the sheet is draggable at all.
      Item {
        id: handleStrip
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Style.space(26)

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(36)
          height: Math.max(2, Style.space(4))
          radius: height / 2
          color: Util.alpha(drawerWindow.textOnSurface, root.dragging ? 0.8 : 0.3)
          Behavior on color { ColorAnimation { duration: 140 } }
        }

        MouseArea {
          anchors.fill: parent
          onPressed: mouse => root.sheetPress(this, mouse)
          onPositionChanged: mouse => root.sheetMove(this, mouse)
          onReleased: root.sheetRelease()
          onCanceled: root.sheetCancel()
        }
      }

      Column {
        anchors {
          top: handleStrip.bottom
          left: parent.left
          right: parent.right
          bottom: parent.bottom
          leftMargin: Style.space(10)
          rightMargin: Style.space(10)
          bottomMargin: Style.space(10) + root.stripHeight
        }
        spacing: Style.space(10)

        // ---------------------------------------------------------- search
        //
        // A pill, because that is what a phone search field looks like and
        // because a fully rounded target is easier to hit than a rectangle of
        // the same area. The desktop Ui.TextField keeps its focus and IME
        // behaviour; only its chrome is replaced.
        Rectangle {
          id: searchPill
          width: parent.width
          height: Style.space(46)
          radius: height / 2
          color: drawerWindow.container

          Text {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            font.family: Style.font.family
            font.pixelSize: Style.font.icon
            color: drawerWindow.subdued
          }

          // Fills the pill, and the insets are padding rather than anchor
          // margins: padding is inside the hit area, so the magnifier answers a
          // tap instead of being chrome with nothing under it.
          Ui.TextField {
            id: searchField
            anchors.fill: parent
            leftPadding: searchGlyph.x + searchGlyph.width + Style.space(10)
            rightPadding: Style.space(16)
            // The control is taller than its line, so it has to be told where
            // that line goes; at the default the text renders against the top.
            verticalAlignment: TextInput.AlignVCenter
            placeholderText: "Search apps"
            background: null
            verticalPadding: 0
            foreground: drawerWindow.textOnSurface
            onTextChanged: queryDebounce.restart()
            // Enter launches the first match, which is the whole point of
            // typing a name you already know.
            onAccepted: if (root.appRows.length > 0) root.launch(root.appRows[0].entry)
          }

          Timer {
            id: queryDebounce
            interval: 80
            onTriggered: root.query = searchField.text
          }
        }

        // ------------------------------------------------------------ grid
        GridView {
          id: grid

          width: parent.width
          // Only as tall as it needs to be. Stretched to fill, the view covers
          // the empty sheet below the last row and swallows a drag that starts
          // there -- a Flickable takes the press whether or not it has anything
          // to show at that point. Capped, the sheet's own drag area gets
          // those touches.
          height: Math.min(parent.height - searchPill.height - Style.space(10),
                           Math.ceil(count / root.columns) * cellHeight)

          cellWidth: Math.floor(width / root.columns)
          cellHeight: root.iconSize + Style.space(38)

          clip: true
          boundsBehavior: Flickable.StopAtBounds
          // Say it explicitly rather than let a view that cannot scroll
          // silently swallow vertical drags that could have meant something.
          interactive: contentHeight > height
          // Virtualised on purpose: every entry instantiated is a decoded icon.
          cacheBuffer: cellHeight * 2

          model: root.appRows

          delegate: Item {
            id: cell
            required property var modelData
            // sortedEntries returns wrappers -- {entry, score, key, name} --
            // not entries. Reading `.icon` off the row yields undefined and a
            // grid of blank squares with no error anywhere.
            readonly property var entry: modelData ? modelData.entry : null

            width: grid.cellWidth
            height: grid.cellHeight

            // The press veil is the cell's only chrome, drawn at the size the
            // cell looks. Culled at rest rather than drawn transparent, and
            // both ends are one ink at two alphas -- "transparent" is
            // #00000000 and a ColorAnimation to it fades through grey.
            Rectangle {
              id: veil
              anchors.fill: parent
              anchors.margins: Style.space(3)
              radius: root.radiusTile
              visible: veil.color.a > 0
              color: Util.alpha(drawerWindow.textOnSurface,
                                cellArea.pressed && !root.dragging ? 0.12 : 0)
              // A Behavior reads `enabled` at the moment of the write, when the
              // property still holds the OLD colour -- so this is false arriving
              // and true leaving: instant in, 120 out.
              Behavior on color {
                enabled: veil.color.a > 0
                ColorAnimation { duration: 120 }
              }
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(6)
              spacing: Style.space(4)

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.iconSize
                height: root.iconSize
                // Without sourceSize an SVG rasterises at its natural size --
                // 512px squares held for every visible app.
                sourceSize: Qt.size(root.iconSize, root.iconSize)
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                source: root.apps && cell.entry
                        ? root.apps.iconSource(cell.entry.icon) : ""
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.apps && cell.entry ? root.apps.entryName(cell.entry) : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: drawerWindow.textOnSurface
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
              }
            }

            // The drag has to live here rather than only behind the grid,
            // because this MouseArea holds the grab for the whole gesture: a
            // press that starts on an icon and travels down would otherwise
            // move nothing. So it does both jobs -- a press that never travels
            // is a launch (H4), one that goes down past the slop drags the
            // sheet (H1).
            MouseArea {
              id: cellArea
              anchors.fill: parent
              onPressed: mouse => root.sheetPress(this, mouse)
              onPositionChanged: mouse => root.sheetMove(this, mouse)
              onReleased: root.sheetRelease()
              onCanceled: root.sheetCancel()
              onClicked: if (!root.sheetWasDrag) root.launch(cell.entry)
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(24)
          visible: root.query.length > 0 && root.appRows.length === 0
          text: "No apps match “" + root.query + "”"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          color: drawerWindow.subdued
        }
      }
    }

    // The input region is the whole surface for as long as a close drag runs,
    // so something has to end the drag if the release never comes.
    Timer {
      id: dragWatchdog
      interval: 2000
      onTriggered: {
        if (!root.sheetDragging) return
        root.sheetDragging = false
        root.dragging = false
        root.progress = root.progress >= root.closeCommit ? 1 : 0
      }
    }
  }

  // ------------------------------------------------------ the close drag
  readonly property real closeCommit: 0.7
  readonly property int dragSlop: Style.space(10)
  readonly property real sheetFling: 0.6
  readonly property int velocityFloor: 8

  // Scene coordinates, because every item on the sheet is a child of the
  // sheet: a delta measured in one moves as the sheet moves and feeds back
  // into itself.
  property real sheetPressY: 0
  property bool sheetDragging: false
  property real sheetVelocity: 0
  property real sheetLastY: 0
  property real sheetLastT: 0

  // Cleared on the next press, not on release, and that ordering is the whole
  // point (H4). Qt delivers `released` and *then* `clicked`, so a flag cleared
  // in the release handler is already false when the click arrives -- and the
  // delegate launches the app the drag happened to start on.
  property bool sheetWasDrag: false

  function sheetPress(item, mouse): void {
    root.sheetPressY = item.mapToItem(null, mouse.x, mouse.y).y
    root.sheetDragging = false
    root.sheetWasDrag = false
    root.sheetVelocity = 0
    root.sheetLastY = root.sheetPressY
    root.sheetLastT = Date.now()
  }

  function sheetMove(item, mouse): void {
    var y = item.mapToItem(null, mouse.x, mouse.y).y
    if (!root.sheetDragging) {
      // Downward only. An upward drag on the sheet means nothing here, and
      // claiming it would fight the grid the moment it has enough apps to
      // scroll (H5).
      if (y - root.sheetPressY <= root.dragSlop) return
      // sheetDragging first: it holds the input region open, and `dragging`
      // is about to make `opened` false.
      root.sheetDragging = true
      root.dragging = true
      dragWatchdog.restart()
    }
    var now = Date.now()
    var dt = now - root.sheetLastT
    if (dt >= root.velocityFloor) {
      // Positive is downward, which for this sheet is the closing direction.
      root.sheetVelocity = root.sheetVelocity * 0.6 + ((y - root.sheetLastY) / dt) * 0.4
      root.sheetLastY = y
      root.sheetLastT = now
    }
    root.progress = Math.max(0, Math.min(1, 1 - (y - root.sheetPressY) / root.closeTravel))
    dragWatchdog.restart()
  }

  // H3. Short of the commit it springs back and changes nothing.
  function sheetRelease(): void {
    dragWatchdog.stop()
    if (!root.sheetDragging) return
    root.sheetWasDrag = true
    root.sheetDragging = false
    root.dragging = false
    if (root.sheetVelocity >= root.sheetFling) root.dismiss()
    else if (root.sheetVelocity <= -root.sheetFling) root.progress = 1
    else if (root.progress <= root.closeCommit) root.dismiss()
    else root.progress = 1
  }

  function sheetCancel(): void {
    dragWatchdog.stop()
    if (!root.sheetDragging) return
    root.sheetDragging = false
    root.dragging = false
    root.progress = 1
  }
}
