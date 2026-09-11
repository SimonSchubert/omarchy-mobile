// The recents carousel: what a swipe up from the bottom strip raises while an
// app is open (docs/spec/gestures.md A, E).
//
// Ported from moarchy.recents. The drag contract is unchanged -- `progress`,
// `dragging` and `homeHint`, written by EdgeGestures.qml as the finger moves
// -- and so are the thresholds:
//
//   0 ---- 40% -------- 75% ---- 100%   of a 0.45 * screen-height travel
//   app    RECENTS       HOME
//
// Two things are not ported yet. Shell apps (K) do not exist here, so a card
// is a window and nothing else. And the still of the app being put away (J)
// is left for later: it is decoration on A1-A4, and J8 says the gesture must
// do the same thing without it.
//
// Cards are icons, not thumbnails, and on this compositor that is a choice
// rather than a constraint. moarchy could not have them: Sway implements no
// per-window capture and does not render a hidden workspace. Hyprland
// implements hyprland-toplevel-export-v1, which is the protocol Quickshell's
// ScreencopyView takes a Toplevel through -- unmeasured here, and the cost has
// to be measured before a card grows a picture.
//
// ToplevelManager, not hyprctl: zwlr-foreign-toplevel-management-v1 gives the
// app id, the title, which window is active, a closed() signal, and the two
// verbs a card needs, activate() and close(). No fork and no polling.
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

  // ------------------------------------------------------------ drag contract
  //
  // The same names the drawer uses, so EdgeGestures drives both sheets through
  // one writer. 0 shut, 1 open; `dragging` turns the animation off while the
  // finger owns the value, so writes track 1:1.
  property real progress: 0
  property bool dragging: false

  // Honest mid-gesture: a half-pulled carousel is not open, so the next swipe
  // still means "open" rather than toggling it shut.
  readonly property bool opened: root.progress >= 1 && !root.dragging

  Behavior on progress {
    enabled: !root.dragging
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  // How close the finger is to the home band, 0..1, written once the carousel
  // is fully up. The cards fade and slide with it so the second stop announces
  // itself before you let go.
  property real homeHint: 0

  // F4. Retires on the same terms as `progress`. Three things read this -- the
  // scrim, the cards' opacity and the row's y -- and every one of them is at
  // its thinnest in the home band, which is the cue that letting go returns to
  // the wallpaper. Zeroed instantly while `progress` was still animating out,
  // moarchy's carousel flashed to full strength on its way home.
  Behavior on homeHint {
    enabled: !root.dragging
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  // One sample per frame while a drag is in flight, read back over IPC. A drag
  // that jumped straight to open leaves two or three samples; one that
  // followed the finger leaves a ramp (A1).
  property var dragTrace: []
  // F4. What the release left behind, as `progress:homeHint` pairs. A homeHint
  // that snapped leaves a step here; one that retires leaves a ramp.
  property var retireTrace: []

  function noteRetire(): void {
    if (root.dragging) return
    if (root.progress <= 0 && root.homeHint <= 0) return
    var next = root.retireTrace.slice()
    if (next.length < 200)
      next.push(Math.round(root.progress * 100) + ":" + Math.round(root.homeHint * 100))
    root.retireTrace = next
  }

  onHomeHintChanged: root.noteRetire()
  onDraggingChanged: if (root.dragging) { root.dragTrace = []; root.retireTrace = [] }
  onProgressChanged: {
    root.noteRetire()
    if (!root.dragging) return
    var next = root.dragTrace.slice()
    if (next.length < 200) next.push(Math.round(root.progress * 100))
    root.dragTrace = next
  }

  // ----------------------------------------------------------------- palette
  //
  // NOT named `onSurface`: QML reserves the `on<Uppercase>` prefix for signal
  // handlers, so a property spelled that way reads as undefined, and undefined
  // assigned to a colour is #000000 with nothing logged.
  readonly property color surface: Color.menu.background
  readonly property color textOnSurface: Color.menu.text

  // A card is a raised surface, built as one. Forced opaque first -- a theme
  // may set the menu background below alpha 1, and a card you can see the app
  // through is not a card -- then lifted off the scrim. moarchy measured the
  // flat version: the scrim is that same colour over a dark app, so an
  // unfocused card matched the space beside it to the byte and the carousel
  // looked like it held one app when it held three.
  readonly property color cardSurface: Qt.tint(
    Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
    Util.alpha(root.textOnSurface, 0.06))
  readonly property color subdued: Util.alpha(root.textOnSurface, 0.6)

  readonly property int radiusTile: Style.space(20)
  readonly property int iconSize: Style.space(56)

  // Travel a card has to be dragged up before releasing closes it. Short
  // enough to flick, long enough that a sloppy tap cannot reach it (E3).
  readonly property int dismissTravel: Style.space(90)

  // --------------------------------------------------------------- the model
  //
  // E1. Most-recently-used first: the app you just left is under your thumb.
  // ToplevelManager hands them over in creation order, so the order is kept
  // here, and rebuilt rather than mutated because a `var` holding an array
  // only notifies on assignment.
  property var mru: []

  function indexOfToplevel(list, tl): int {
    for (var i = 0; i < list.length; i++) if (list[i] === tl) return i
    return -1
  }

  function activeToplevel() {
    if (ToplevelManager.activeToplevel) return ToplevelManager.activeToplevel
    var live = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < live.length; i++)
      if (live[i] && live[i].activated) return live[i]
    return null
  }

  function rebuildMru(): void {
    var live = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var next = []

    // Anything already ranked keeps its rank, as long as it still exists.
    for (var i = 0; i < root.mru.length; i++)
      if (root.indexOfToplevel(live, root.mru[i]) >= 0) next.push(root.mru[i])

    // A window that just mapped is the most recent thing there is.
    for (var j = 0; j < live.length; j++)
      if (root.indexOfToplevel(next, live[j]) < 0) next.unshift(live[j])

    // And the active one leads, so card 0 is the app the swipe came out of.
    var active = root.activeToplevel()
    if (active) {
      var at = root.indexOfToplevel(next, active)
      if (at > 0) { next.splice(at, 1); next.unshift(active) }
    }
    root.mru = next
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.rebuildMru() }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.rebuildMru() }
  }

  Component.onCompleted: root.rebuildMru()

  // ------------------------------------------------- appId -> desktop entry
  //
  // appLibrary turns an icon name into a source but has no lookup by id, so
  // the index is built once and rebuilt when the app list moves -- scanning
  // sortedEntries() inside a delegate would be O(apps) per card per frame.
  property var appIdIndex: ({})

  function buildIndex(): void {
    var map = ({})
    if (!root.apps) { root.appIdIndex = map; return }
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
    root.appIdIndex = map
  }

  Connections {
    target: root.apps
    function onAppsChanged() { root.buildIndex() }
  }

  onAppsChanged: root.buildIndex()

  function entryFor(appId) {
    if (!appId) return null
    var e = root.appIdIndex[String(appId).toLowerCase()]
    return e === undefined ? null : e
  }

  // K5, K9. A screen this shell draws is a window like any other and gets a
  // card on the same terms, but its app id is the shell process's own, so
  // there is no desktop entry to take an icon or a name from. The screen
  // carries both.
  function screenFor(app) {
    return root.host ? root.host.screenForToplevel(app) : null
  }

  function iconFor(app): string {
    if (root.screenFor(app)) return ""
    var entry = root.entryFor(app ? app.appId : "")
    return entry && root.apps ? root.apps.iconSource(entry.icon) : ""
  }

  function glyphFor(app): string {
    var own = root.screenFor(app)
    return own ? String(own.appWindow.glyph || "") : ""
  }

  // The third line: the page a screen is on, which its window already carries,
  // and the window title for anything else.
  function titleFor(app): string {
    if (!app) return ""
    var own = root.screenFor(app)
    if (own) return String(own.appWindow.pageTitle || "")
    return String(app.title || "")
  }

  function nameFor(app): string {
    if (!app) return ""
    var own = root.screenFor(app)
    if (own) return String(own.appWindow.appName || "")
    var entry = root.entryFor(app.appId)
    if (entry && root.apps) return root.apps.entryName(entry)
    return app.appId || app.title || "Window"
  }

  // ------------------------------------------------------------------ actions
  //
  // E2. Focus the app and put the carousel away.
  function focusApp(app): void {
    if (!app) return
    root.host.focusToplevel(app)
    root.close()
  }

  // E3. close() is xdg_toplevel.close -- a close *request*, so an editor with
  // unsaved work prompts rather than dies. That is what makes firing it from a
  // flick acceptable.
  function closeApp(app): void {
    if (!app) return
    app.close()

    // Dropped from the order now rather than on closed(): an app that refuses
    // to quit would otherwise leave a card that has already animated away.
    var next = []
    for (var i = 0; i < root.mru.length; i++)
      if (root.mru[i] !== app) next.push(root.mru[i])
    root.mru = next

    // E6. An empty carousel is not a screen worth standing on, and with A9 this
    // is the only way it could ever have no cards -- so its empty state is not
    // built at all. There is deliberately no "clear all" either (E7).
    if (next.length === 0) {
      root.close()
      root.host.goHome()
    }
  }

  // ------------------------------------------------------------ open / close
  function open(): void {
    if (root.host) root.host.closeOthers("recents")
    root.rebuildMru()
    root.buildIndex()
    root.dragging = false
    root.homeHint = 0
    root.progress = 1
    cards.positionViewAtBeginning()
  }

  // E5. Dismissing changes nothing about focus: this surface never takes the
  // keyboard, so there is no focus to hand back.
  function close(): void {
    root.dragging = false
    root.homeHint = 0
    root.progress = 0
  }

  IpcHandler {
    target: "recents"

    function state(): string { return root.opened ? "open" : "closed" }

    function progress(): string {
      return Math.round(root.progress * 100) + (root.dragging ? " dragging" : "")
    }

    function homeHint(): string {
      return Math.round(root.homeHint * 100) + (root.dragging ? " dragging" : "")
    }

    // The samples the last drag produced. Polling `progress` over IPC cannot
    // see a 300ms gesture; this is the record it left behind.
    function dragTrace(): string { return root.dragTrace.join(" ") }

    function retireTrace(): string { return root.retireTrace.join(" ") }

    // One line per card, so a dismissal is assertable by counting (E1, E3). A
    // screen prints its own id rather than its app id, which names the shell
    // process and not the screen (K9).
    function list(): string {
      var out = []
      for (var i = 0; i < root.mru.length; i++) {
        var app = root.mru[i]
        if (!app) continue
        var own = root.screenFor(app)
        out.push((own ? own.screenId : (app.appId || "?")) + " " + root.titleFor(app))
      }
      return out.join("\n")
    }

    function open(): string {
      if (!root.host.hasApps()) return "nothing (no apps open)"
      root.open()
      return "ok"
    }

    function close(): string { root.close(); return "ok" }

    // Where card n sits on screen -- centre, then its left and right edges --
    // so a check can aim a real tap or flick at it (E2, E3), and can see the
    // next card peeking in at the edge (E4). The surface ignores exclusive
    // zones, so surface coordinates are screen coordinates.
    function cardTarget(index: string): string {
      var item = cards.itemAtIndex(Number(index))
      if (!item) return "none"
      var c = item.mapToItem(null, item.width / 2, item.height / 2)
      var half = cards.cardWidth / 2
      return Math.round(c.x) + " " + Math.round(c.y)
        + " " + Math.round(c.x - half) + " " + Math.round(c.x + half)
    }

    // Test hooks for E2 and E3 that skip the aiming: tap card n, or flick it
    // away, through the same functions the gestures call.
    function tap(index: string): string {
      var app = root.mru[Number(index)]
      if (!app) return "no card " + index
      root.focusApp(app)
      return "ok"
    }

    function dismiss(index: string): string {
      var app = root.mru[Number(index)]
      if (!app) return "no card " + index
      root.closeApp(app)
      return "ok"
    }
  }

  PanelWindow {
    id: recentsWindow

    // Mapped only while there is something to show. Keeping it mapped, like
    // the drawer, was tried to win back the frames a per-gesture map costs: it
    // won none -- the trace stayed at 5 samples -- and a card from an earlier
    // gesture showed through the shade in the next screenshot. Hyprland's own
    // fade on map, the other cost, is off for this namespace (hypr/mobile.lua).
    visible: root.progress > 0 || root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-mobile-recents"
    WlrLayershell.layer: WlrLayer.Top

    // Ignore, not the drawer's zero-zone Normal. A switcher has no text field,
    // so reflowing above an on-screen keyboard buys it nothing -- moarchy's
    // measured cost was the carousel squashed into the top two thirds whenever
    // the app behind had a field focused. The strip stays live over it
    // regardless: the edge surface is Overlay, above every Top surface.
    exclusionMode: ExclusionMode.Ignore

    // None, permanently. A carousel has no text input, and holding the
    // keyboard would make this compositor route every pointer event here --
    // including the strip's, which is exactly the gesture that has to keep
    // working while this is up.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // No input while a drag is driving it: the finger is on the edge surface,
    // and a region opening underneath mid-drag is where this compositor would
    // send the rest of the gesture. Settled open, the whole surface.
    mask: root.opened ? fullMask : emptyMask

    property Region fullMask: Region {
      width: recentsWindow.width
      height: recentsWindow.height
    }

    property Region emptyMask: Region {}

    // One blended quad, its alpha bound straight to the drag -- not `opacity`
    // on a subtree, which would composite the whole sheet off-screen first on
    // a renderer that is llvmpipe. Translucent for the whole drag, so seeing
    // the app through it says the sheet is still moving; opaque once up; and
    // thinning again in the home band, the cue that letting go goes home.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, root.progress * (1 - 0.6 * root.homeHint))
    }

    // Tapping the space around the cards puts the carousel away and leaves the
    // app you came from focused, the way tapping outside any sheet does (E5).
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: sheet
      anchors.fill: parent
      // Rides up from below, and keeps travelling up in the home band.
      // Translation only: a `scale` on a subtree of glyphs and icons re-rasters
      // every one of them, where a `y` costs nothing.
      y: parent.height * (1 - root.progress) - Style.space(80) * root.homeHint

      ListView {
        id: cards

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -Style.space(14)
        height: Math.round(recentsWindow.height * 0.56)

        orientation: ListView.Horizontal
        model: root.mru
        clip: false
        opacity: 1 - 0.55 * root.homeHint

        // E4. A pager, not a free scroll: one card is always centred, so a
        // flick lands somewhere definite instead of between two apps.
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        boundsBehavior: Flickable.StopAtBounds

        readonly property int cardWidth: Math.round(recentsWindow.width * 0.62)
        readonly property int gap: Style.space(12)
        // The delegate is one *pitch* wide -- card plus gap -- with the card
        // centred in it. Centring the end cards with leftMargin/rightMargin
        // instead fights StrictlyEnforceRange, and moarchy measured the view
        // settling with one card filling the screen. A pitch-wide delegate and
        // a pitch-wide range agree on one position per card, which is what
        // makes the next app peek in at the edge (E4).
        readonly property int pitch: cardWidth + gap

        preferredHighlightBegin: (width - pitch) / 2
        preferredHighlightEnd: (width + pitch) / 2
        spacing: 0

        delegate: Item {
          id: cardSlot
          required property var modelData
          required property int index

          width: cards.pitch
          height: cards.height

          Rectangle {
            id: card
            width: cards.cardWidth
            anchors.horizontalCenter: parent.horizontalCenter
            height: parent.height
            radius: root.radiusTile
            color: root.cardSurface

            // Every card needs an edge: it is the only thing separating the
            // one at the screen edge from the space beside it. The app you
            // just left gets the accent and a heavier line (E1).
            border.width: cardSlot.index === 0 ? Math.max(2, Style.space(2))
                                               : Math.max(1, Style.space(1))
            border.color: cardSlot.index === 0 ? Color.accent
                                               : Util.alpha(root.textOnSurface, 0.22)

            // Lit while pressed; not once the card is following the finger,
            // where the movement is the feedback.
            // Named, because a Behavior is not an Item: `parent` inside one
            // does not reach this Rectangle, and reading `.color.a` off it
            // threw on every card.
            Rectangle {
              id: veil
              anchors.fill: parent
              radius: parent.radius
              visible: veil.color.a > 0
              color: Util.alpha(root.textOnSurface,
                                dismissArea.pressed && !dismissArea.drag.active ? 0.10 : 0)
              Behavior on color {
                enabled: veil.color.a > 0
                ColorAnimation { duration: 120 }
              }
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(28)
              spacing: Style.space(12)

              Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.iconSize
                height: root.iconSize

                readonly property string glyph: root.glyphFor(cardSlot.modelData)

                Image {
                  anchors.fill: parent
                  visible: parent.glyph === ""
                  // Without sourceSize an SVG rasterises at its natural size --
                  // 512px squares held for every card.
                  sourceSize: Qt.size(root.iconSize, root.iconSize)
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectFit
                  source: root.iconFor(cardSlot.modelData)
                }

                // K5. A screen wears the glyph the control that opens it wears,
                // centred on its ink like every glyph in this shell.
                Ui.OpticalGlyph {
                  anchors.fill: parent
                  visible: parent.glyph !== ""
                  text: parent.glyph
                  fontFamily: Style.font.family
                  fontSize: root.iconSize
                  color: root.textOnSurface
                }
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nameFor(cardSlot.modelData)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
                color: root.textOnSurface
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.titleFor(cardSlot.modelData)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.subdued
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
                visible: text.length > 0 && text !== root.nameFor(cardSlot.modelData)
              }
            }

            Behavior on y {
              enabled: !dismissArea.drag.active
              SpringAnimation { spring: 4; damping: 0.4 }
            }
          }

          // Dismiss is vertical and paging is horizontal, so the two axes never
          // arbitrate for meaning. `preventStealing` stays false, which is what
          // lets the ListView take a horizontal drag off this MouseArea once it
          // passes its own threshold while a vertical one stays here.
          MouseArea {
            id: dismissArea
            anchors.fill: parent
            preventStealing: false
            drag.target: card
            drag.axis: Drag.YAxis
            // Up only. A downward drag on a card means nothing, and allowing it
            // would let a card be parked below the row.
            drag.minimumY: -cardSlot.height
            drag.maximumY: 0

            onClicked: root.focusApp(cardSlot.modelData)

            onReleased: {
              if (card.y <= -root.dismissTravel) dismissOut.start()
              else card.y = 0
            }

            onCanceled: card.y = 0
          }

          // Let the card leave before the model drops it, so the row closing
          // the gap reads as a consequence rather than a glitch.
          SequentialAnimation {
            id: dismissOut
            ParallelAnimation {
              NumberAnimation { target: card; property: "y"; to: -cardSlot.height
                                duration: 140; easing.type: Easing.OutCubic }
              NumberAnimation { target: card; property: "opacity"; to: 0; duration: 140 }
            }
            ScriptAction {
              script: {
                root.closeApp(cardSlot.modelData)
                card.y = 0
                card.opacity = 1
              }
            }
          }
        }
      }
    }
  }
}
