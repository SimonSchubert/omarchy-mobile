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
import "Theme.js" as Theme

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
  // The long-press card (L5). Tighter than the sheet it sits on, because a
  // card as round as the surface behind it stops reading as a separate thing.
  readonly property int radiusCard: Style.space(18)

  // The pressed state, declared once for the card's controls (style.md H2-H5),
  // the way every other surface in this plugin declares it. The grid cell
  // predates Veil.qml and still draws its own; it is one veil and moving it is
  // a change to H4's ink on the one control this file already measured.
  component PressVeil: Veil { ink: drawerWindow.textOnSurface }

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
    // L5. The drawer opens on the grid, never on somebody's half-read card.
    root.closeDetail()
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

    // The store's Open (windows.md L9, L9a). moarchy-store hands the launch to
    // the shell -- `omarchy-shell drawer launch <bare id>` -- rather than
    // starting the app itself, so that installing something and opening it
    // goes down the path a tap on the grid does. Without this function the
    // call fails and the store falls back to Gio, which starts the app as the
    // store's own child and tells the shell nothing.
    //
    // That makes this a contract with a consumer outside this repo: renaming
    // it breaks Open in the store. "ok" when the id is an entry the grid
    // lists; "no-entry" when it is not, after launching it through the
    // library anyway, as moarchy's drawer does.
    function launch(desktopId: string): string {
      var id = String(desktopId || "").replace(/\.desktop$/, "")
      if (!id) return "no id"
      if (!root.apps) return "no shell"
      // Rows, not entries: sortedEntries returns {entry, ...} wrappers.
      var rows = root.apps.sortedEntries("") || []
      for (var i = 0; i < rows.length; i++) {
        var entry = rows[i] && rows[i].entry
        if (entry && String(entry.id).replace(/\.desktop$/, "") === id) {
          root.launch(entry)
          return "ok"
        }
      }
      root.apps.launch(id, id)
      return "no-entry"
    }

    // ----------------------------------------------- the long-press card (L)
    //
    // The card as the shell sees it: which entry, which stage, whether a
    // script is in flight, and every key the script answered with its fork as
    // a prefix. One function rather than six, because "did the plan land" and
    // "what did info say" are two questions about one state.
    function detail(): string {
      if (!root.detailEntry) return ""
      var out = ["id\t" + String(root.detailEntry.id),
                 "stage\t" + root.detailStage,
                 "busy\t" + (root.detailBusy ? "1" : "0")]
      var k
      for (k in root.detailInfo) out.push("info." + k + "\t" + root.detailInfo[k])
      for (k in root.detailPlan) out.push("plan." + k + "\t" + root.detailPlan[k])
      return out.join("\n")
    }

    // Opens the card on an id, down the same function the hold timer calls --
    // for the checks that are about the card rather than about the gesture.
    // Keyed the way `launch` is, and for the same reason: callers pass the
    // bare id with no .desktop suffix.
    function hold(desktopId: string): string {
      var id = String(desktopId || "").replace(/\.desktop$/, "")
      if (!id) return "no id"
      if (!root.apps) return "no shell"
      var rows = root.apps.sortedEntries("") || []
      for (var i = 0; i < rows.length; i++) {
        var entry = rows[i] && rows[i].entry
        if (entry && String(entry.id).replace(/\.desktop$/, "") === id) {
          root.openDetail(entry)
          return "ok"
        }
      }
      return "no entry"
    }

    // Arms the plan, which is what Uninstall does. Asynchronous on purpose --
    // it is a pacman transaction -- so a caller reads `detail` back until
    // `busy` is 0 rather than being handed an answer that was guessed at.
    function uninstall(): string {
      if (!root.detailEntry) return "no card"
      if (root.detailProtected) return "protected"
      root.planRemoval()
      return "ok"
    }

    // L8, as a yes/no. `pending` is not `no`: a check that treated "the plan
    // has not landed yet" as "cannot remove" would pass against a shell that
    // never answers, which is the one failure this is worth asserting against.
    function canRemove(): string {
      if (!root.detailEntry) return "no card"
      if (root.detailProtected) return "no"
      if (root.detailStage !== "plan") return "unasked"
      if (root.detailBusy) return "pending"
      if (!root.detailPlanReady) return "no"
      return root.detailBlocked === "" ? "yes" : "no"
    }

    // The Remove button. Named for what it does rather than `remove`, because
    // this one uninstalls a package and the noise of the name is the point --
    // the default selftest suite never calls it, and nothing should reach it
    // by completing a shorter word.
    function removeConfirm(): string {
      if (!root.detailEntry) return "no card"
      if (root.detailStage !== "plan") return "unasked"
      if (root.detailBlocked !== "") return "blocked"
      if (!root.detailPlanReady) return "no plan"
      root.removeApp()
      return "ok"
    }

    function detailClose(): string { root.closeDetail(); return "ok" }

    // G3, L5. Back walks the levels one at a time: from the plan to the card,
    // from the card to the grid, and only then out of the drawer. The
    // left-edge gesture that will drive this is not built yet (G); when it is,
    // it calls root.goBack() and closes the overlay on false, which is this
    // function with the last step spelled out.
    function back(): string {
      if (root.goBack()) return root.detailEntry ? root.detailStage : "grid"
      root.dismiss()
      return "closed"
    }
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

  // ------------------------------------------------------- the hold (L1-L4)
  //
  // The same MouseArea that launches an app and drags the sheet also has to
  // answer a long press, and it has to do that without taking anything from
  // either. It cannot be a TapHandler alongside: that handler would only ever
  // get a passive grab -- the delegate's MouseArea holds the exclusive one --
  // so the press it saw would end wherever the MouseArea decided the gesture
  // was over.
  //
  // A timer armed on `pressed` and cancelled by everything that means "this
  // was not a hold" has no grab of its own to lose.
  readonly property int holdDelay: 500

  // The cell under the finger, or null. Held rather than passed to the timer,
  // because a Timer has no payload and a second finger on a second cell must
  // not be able to open the first one's card.
  property var holdEntry: null

  // L2. True from the moment the card opens until the next press, so the click
  // Qt delivers after the finger lifts does not also launch the app. Cleared
  // on the next press and never on release, exactly as `sheetWasDrag` is and
  // for the same reason.
  property bool holdFired: false

  function armHold(entry): void {
    root.holdEntry = entry || null
    if (root.holdEntry) holdTimer.restart()
  }

  function cancelHold(): void {
    holdTimer.stop()
    root.holdEntry = null
  }

  // L3, L4. Travel cancels the hold, in either direction and on either axis.
  //
  // sheetMove cannot do this job: it latches only on *downward* travel past
  // the slop, deliberately (H5), so an upward drag on a grid that fits its
  // view -- which is what this phone's app count gives -- moves nothing,
  // latches nothing, and would leave the timer running under a finger that has
  // already travelled half the sheet. A scroll on a grid that does not fit
  // cancels through onCanceled instead, when the Flickable steals the grab.
  function holdMove(item, mouse): void {
    if (!holdTimer.running) return
    var p = item.mapToItem(null, mouse.x, mouse.y)
    if (Math.abs(p.y - root.sheetPressY) > root.dragSlop
        || Math.abs(p.x - root.sheetPressX) > root.dragSlop)
      root.cancelHold()
  }

  Timer {
    id: holdTimer
    interval: root.holdDelay
    onTriggered: {
      if (!root.holdEntry) return
      root.holdFired = true
      root.openDetail(root.holdEntry)
      root.holdEntry = null
    }
  }

  // -------------------------------------------------- the app detail card (L)
  //
  // Everything the card knows comes from `omarchy-mobile-app-remove`, which is
  // where the pacman reasoning lives (L11, L12). Nothing here decides what may
  // be removed; this file decides what the card looks like while the script is
  // deciding, and that separation is the point -- a rule about dependencies
  // written in QML is a rule nothing can run from a terminal to check.
  //
  // The entry itself, or null. One property rather than a bool and a payload:
  // "card up with no entry" is not a state this screen has, and two properties
  // that must agree are two properties that can stop agreeing.
  property var detailEntry: null

  //   info      what the app is
  //   plan      what removing it would take -- L7, never skipped
  //   working   the removal is running
  property string detailStage: "info"

  property var detailInfo: ({})
  property var detailPlan: ({})

  // True while a script is in flight. The card draws a line of its own rather
  // than an empty one: the `info` fork is three greps and a `pacman -Qi`, and
  // the `plan` fork is a pacman transaction, which on this VM is not instant.
  property bool detailBusy: false

  // An answer for a card that has since been closed, or opened on something
  // else, is not a late answer -- it is the wrong one.
  //
  // Moved by openDetail and closeDetail ONLY. Arming a plan is not a new card
  // and must not invalidate one: `info` and `plan` are two forks about the
  // same entry, and a generation bumped on the tap would throw away an `info`
  // still in flight -- which is the card losing the line that says what the
  // app is, at the moment it is being asked about removing it.
  property int detailGeneration: 0

  function parseKv(text) {
    var out = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].indexOf("\t")
      if (t <= 0) continue
      out[lines[i].slice(0, t)] = lines[i].slice(t + 1)
    }
    return out
  }

  // argv and not `bash -lc`, so nothing here has to quote a desktop id. They
  // contain spaces on this phone -- "Disk Usage.desktop" is upstream's own --
  // and a quoting bug in a command whose verb is `remove` is not a bug worth
  // being one shell metacharacter away from. Which is also why the script sits
  // in /usr/local/bin rather than beside the rest of this shell's helpers in
  // ~/.local/bin: the latter is on PATH only through /etc/profile.d, so a
  // caller that skips the login shell has to name a path, and a path here is
  // a second place the script's location is written down.
  function detailRun(proc, verb, extra) {
    if (!root.detailEntry) return
    var argv = ["omarchy-mobile-app-remove", verb, String(root.detailEntry.id)]
    if (extra) argv.push(extra)
    root.detailBusy = true
    proc.wanted = root.detailGeneration
    if (proc.running) proc.running = false
    proc.command = argv
    proc.running = true
  }

  function openDetail(entry): void {
    if (!entry) return
    root.detailGeneration += 1
    root.detailEntry = entry
    root.detailStage = "info"
    root.detailInfo = ({})
    root.detailPlan = ({})
    root.detailRun(infoProc, "info", "")
  }

  // L7. Uninstall does not remove; it asks the question and shows the answer.
  function planRemoval(): void {
    root.detailStage = "plan"
    root.detailPlan = ({})
    root.detailRun(planProc, "plan", "")
  }

  function removeApp(): void {
    if (!root.detailEntry) return
    root.detailStage = "working"
    root.detailRun(removeProc, "remove",
                   root.apps ? String(root.apps.entryName(root.detailEntry)) : "")
  }

  function closeDetail(): void {
    root.detailGeneration += 1
    root.detailEntry = null
    root.detailStage = "info"
    root.detailInfo = ({})
    root.detailPlan = ({})
    root.detailBusy = false
  }

  // L8. What the plan settled: a package with a blocker has no Remove button
  // at all, rather than one that fails when pressed.
  readonly property string detailBlocked: String(root.detailPlan.blocked || "")

  // L8, from the other end: an answer that says nothing is not permission.
  //
  // The empty plan is a real state and not a hypothetical -- a guest whose
  // overlay predates /usr/local/bin/omarchy-mobile-app-remove runs this card
  // with no script behind it, so the Process exits immediately, the collector
  // hands back "", and `blocked` is empty because nothing said anything. Read
  // as "not blocked" that draws a Remove button over a command that does not
  // exist, which is a control that silently does nothing -- the exact failure
  // style.md E exists to prevent, arrived at from the opposite direction.
  //
  // Every kind the script can report emits `count`, including the ones with no
  // package to count, so its absence means the script did not answer.
  readonly property bool detailPlanReady: String(root.detailPlan["count"] || "") !== ""

  // L6. Where the app came from, in one line. "No package" is an answer and a
  // blank line is not, so every kind the script can report has a phrase here --
  // including the one that means the script could not tell.
  //
  // Bracketed reads throughout: `package` is a future reserved word, and the
  // dotted form is legal in ES5 but not worth depending on in a file that is
  // parsed by whatever qmllint the next Qt ships.
  readonly property string detailOrigin: {
    var kind = String(root.detailInfo["kind"] || "")
    if (kind === "package") {
      var name = String(root.detailInfo["package"] || "")
      var version = String(root.detailInfo["version"] || "")
      return version ? name + " " + version : name
    }
    if (kind === "user") return "Personal entry"
    if (kind === "webapp") return "Web app"
    if (kind === "tui") return "Terminal app"
    if (kind === "flatpak") return "Flatpak"
    if (kind === "") return ""
    return "Unknown origin"
  }

  // L7. The count and the weight, in the card's words rather than pacman's.
  // A launcher that belongs to no package has no packages to count, so it says
  // what it does take instead -- the script's own `note`.
  readonly property string detailPlanSummary: {
    if (String(root.detailPlan["kind"] || "") !== "package")
      return String(root.detailPlan["note"] || "")
    var count = parseInt(String(root.detailPlan["count"] || "0"))
    if (!count) return ""
    var head = count === 1 ? "Removes 1 package" : "Removes " + count + " packages"
    var size = String(root.detailPlan["size"] || "")
    return size ? head + ", " + size : head
  }

  // L11, L12, as the script answered them: the shell's own packages and the
  // session tier, which have no Uninstall button rather than one that leads to
  // a refusal. Bracketed, not dotted: `protected` is a future reserved word,
  // and a dotted read of it is legal in ES5 but not in every parser this file
  // passes through.
  readonly property bool detailProtected: String(root.detailInfo["protected"] || "") === "1"

  // G3, L5. The card is a screen inside this surface, so back leaves it before
  // it leaves the drawer -- and from the plan it steps back to the detail
  // rather than out, because that is the step that was taken to get there.
  // Returning false is what tells a caller to close the whole overlay.
  function goBack(): bool {
    if (!root.detailEntry) return false
    // Mid-removal there is nothing to go back to and the pacman transaction
    // does not stop for a gesture. Consumed rather than obeyed.
    if (root.detailStage === "working") return true
    if (root.detailStage === "plan") { root.detailStage = "info"; return true }
    root.closeDetail()
    return true
  }

  Process {
    id: infoProc
    property int wanted: 0
    stdout: StdioCollector {
      onStreamFinished: {
        if (infoProc.wanted !== root.detailGeneration) return
        root.detailInfo = root.parseKv(String(text || ""))
        root.detailBusy = false
      }
    }
  }

  Process {
    id: planProc
    property int wanted: 0
    stdout: StdioCollector {
      onStreamFinished: {
        if (planProc.wanted !== root.detailGeneration) return
        root.detailPlan = root.parseKv(String(text || ""))
        root.detailBusy = false
      }
    }
  }

  Process {
    id: removeProc
    property int wanted: 0
    // L9. The outcome is a notification, sent by the script, so nothing here
    // has to stay on screen to report it -- which is what lets the card close
    // on exit rather than turning into a result screen nobody asked for. The
    // grid drops the app on its own (L10): removing a package takes its
    // .desktop file with it, the library notices, and appsChanged() is already
    // wired to appRows.
    onExited: {
      if (removeProc.wanted !== root.detailGeneration) return
      root.closeDetail()
    }
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
    readonly property color containerHigh: Util.alpha(Color.menu.text, 0.14)
    readonly property color subdued: Util.alpha(Color.menu.text, 0.55)

    // The long-press card (L5), which is the one thing on this surface that is
    // drawn over an opaque fill of its own rather than straight on the sheet.
    // So its secondary text is computed against that fill rather than taken at
    // a constant alpha: moarchy measured a 0.7 foreground over a lifted card
    // falling below AA in six of the 22 themes, and this card's plan is three
    // lines of exactly that text.
    readonly property color cardFill: Theme.mix(drawerWindow.surface,
                                                drawerWindow.textOnSurface, 0.08)
    readonly property color cardSubdued: Theme.readableOn(drawerWindow.cardFill,
                                                          drawerWindow.textOnSurface,
                                                          0.55, 4.5)

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

      // Escape walks out one level at a time, the way back does (G3, L5): the
      // card before the search, the search before the drawer. So the way out
      // of a plan is not the way out of the drawer.
      Keys.onEscapePressed: {
        if (root.goBack()) return
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
            // move nothing. So it does all three jobs -- a press that never
            // travels is a launch (H4), one that goes down past the slop drags
            // the sheet (H1), and one that stays put for 500ms opens the card
            // (L1).
            MouseArea {
              id: cellArea
              anchors.fill: parent
              onPressed: mouse => { root.sheetPress(this, mouse); root.armHold(cell.entry) }
              onPositionChanged: mouse => root.sheetMove(this, mouse)
              onReleased: root.sheetRelease()
              onCanceled: root.sheetCancel()
              // L2. The hold's own click is swallowed here: the app you asked
              // about is not the app that starts.
              onClicked: if (!root.sheetWasDrag && !root.holdFired) root.launch(cell.entry)
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

      // ------------------------------------------------ the app detail (L)
      //
      // A card over the sheet and not a surface of its own (L5). The drawer
      // keeps its keyboard focus, its scroll position and its progress, so
      // closing this leaves the grid exactly where the hold found it -- and a
      // second layer-shell surface for a card would have to be arranged,
      // focused and dismissed against the keyboard and the strip, which is
      // three problems this screen has already solved once.
      //
      // Declared after the content column, so it takes input ahead of the grid.
      Rectangle {
        id: detailScrim
        anchors.fill: parent
        visible: root.detailEntry !== null
        color: Util.alpha(drawerWindow.surface, 0.92)
        // The sheet's own shape, because a child is not clipped by its
        // parent's radius: a square scrim over the rounded sheet paints four
        // corners of surface back in, and the drawer reads as a rectangle for
        // as long as a card is up.
        radius: root.radiusSheet

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: root.radiusSheet
          color: detailScrim.color
        }

        MouseArea {
          // no press state (style.md H7): a scrim that dismisses. A tap
          // outside the card is the way out that needs no control of its own,
          // and it is also the swallower that keeps the tap off the icon
          // underneath -- which would otherwise launch the app whose card is
          // being closed.
          anchors.fill: parent
          onClicked: if (root.detailStage !== "working") root.closeDetail()
        }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width - Style.space(48)
          height: detailCol.implicitHeight + Style.space(32)
          radius: root.radiusCard
          color: drawerWindow.cardFill

          MouseArea {
            // no press state (style.md H7): a tap swallower behind a modal.
            // Declared before the content so the content still takes its own
            // taps; without it every gap between the controls is a hole
            // through to the scrim, and the card closes when you meant to read
            // it.
            anchors.fill: parent
          }

          Column {
            id: detailCol
            anchors.centerIn: parent
            width: parent.width - Style.space(32)
            spacing: Style.space(14)

            // --- what it is (L6) -------------------------------------------
            //
            // An Item with anchors rather than a Row: a Row refuses horizontal
            // anchors on its children, and the label block has to be "whatever
            // is left after the icon" rather than a width computed here.
            Item {
              width: parent.width
              height: Math.max(root.iconSize, detailHeadText.height)

              Image {
                id: detailIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconSize
                height: root.iconSize
                // Same reason as the grid's: without this an SVG rasterises at
                // its natural 512.
                sourceSize: Qt.size(root.iconSize, root.iconSize)
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                source: root.apps && root.detailEntry
                        ? root.apps.iconSource(root.detailEntry.icon) : ""
              }

              Column {
                id: detailHeadText
                anchors.left: detailIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.apps && root.detailEntry
                        ? root.apps.entryName(root.detailEntry) : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  color: drawerWindow.textOnSurface
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text.length > 0
                  text: String(root.detailInfo.comment || "")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: drawerWindow.cardSubdued
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
              }
            }

            // --- where it came from (L6) -----------------------------------
            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.detailStage === "info"

              Text {
                width: parent.width
                text: root.detailBusy && root.detailOrigin === ""
                      ? "Looking it up" : root.detailOrigin
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: drawerWindow.textOnSurface
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: text.length > 0
                text: String(root.detailInfo.size || "")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: drawerWindow.cardSubdued
              }

              Text {
                width: parent.width
                visible: text.length > 0
                text: String(root.detailInfo.id || "")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: drawerWindow.cardSubdued
                elide: Text.ElideMiddle
              }
            }

            // --- the plan (L7, L8) -----------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.detailStage === "plan"

              Text {
                width: parent.width
                text: root.detailBusy ? "Working out what that takes"
                    : root.detailBlocked !== "" ? "This one cannot be removed"
                    : root.detailPlanReady ? root.detailPlanSummary
                    : "Nothing answered for this one"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: drawerWindow.textOnSurface
                wrapMode: Text.Wrap
              }

              // L8's reason, in the script's own words -- which for a
              // dependency is pacman's. Three lines of a dependency message is
              // a lot of card, so it elides: what matters is that it names
              // something, and the name is in the first line of every one.
              Text {
                width: parent.width
                visible: text.length > 0 && !root.detailBusy
                text: root.detailBlocked
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: drawerWindow.cardSubdued
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              // Every package the removal takes, named. The count above is the
              // number; this is the answer to "which ones".
              Text {
                width: parent.width
                visible: text.length > 0 && !root.detailBusy && root.detailPlanReady
                text: String(root.detailPlan.names || "").split(" ").join(", ")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: drawerWindow.cardSubdued
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
              }
            }

            // --- the removal running ---------------------------------------
            Text {
              width: parent.width
              visible: root.detailStage === "working"
              text: "Removing"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: drawerWindow.textOnSurface
            }

            // --- L11, L12, said rather than left as a missing button --------
            //
            // In the script's words and not this file's, because the two rules
            // that lead here are different facts about the app: the phone's
            // terminal is protected without being part of omarchy-mobile, and
            // one sentence for both would be wrong about one of them.
            Text {
              width: parent.width
              visible: root.detailStage === "info" && root.detailProtected
              text: String(root.detailInfo["guard"] || "")
                    || "This one cannot be removed."
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: drawerWindow.cardSubdued
              wrapMode: Text.Wrap
            }

            // --- Uninstall (L7) --------------------------------------------
            //
            // Full width, because it is the only control on this stage and a
            // 110px button centred under a 312px card reads as an afterthought.
            Rectangle {
              width: parent.width
              height: Style.space(44)
              radius: height / 2
              color: drawerWindow.containerHigh
              visible: root.detailStage === "info" && !root.detailProtected
                       && !root.detailBusy
              // Guarded like every other press on this sheet (style.md H6),
              // and the guard is a surface-wide invariant rather than a
              // condition this control can actually meet: the scrim above
              // covers the grid and the handle, so nothing can be dragging the
              // sheet while this button exists. Spelled anyway, because "on
              // the drawer, no press lights during a sheet drag" is the rule,
              // and a control exempt by accident of layout is one that stops
              // being exempt the day the layout moves.
              PressVeil {
                anchors.fill: parent
                radius: parent.radius
                on: uninstallArea.pressed && !root.dragging
              }
              Text {
                anchors.centerIn: parent
                text: "Uninstall"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: drawerWindow.textOnSurface
              }
              MouseArea {
                id: uninstallArea
                anchors.fill: parent
                onClicked: root.planRemoval()
              }
            }

            // --- Cancel / Remove (L7, L8) -----------------------------------
            Item {
              id: detailActions
              width: parent.width
              height: Style.space(44)
              visible: root.detailStage === "plan" && !root.detailBusy

              // Two halves of the card's width with one gap between them, so
              // both clear E1 by a wide margin and neither has to grow into
              // the other (E3).
              readonly property int gap: Style.space(12)
              readonly property int half: Math.floor((width - gap) / 2)
              // Alone when there is nothing to confirm: a blocked plan has one
              // way out and it is not called Cancel.
              readonly property bool paired: root.detailBlocked === "" && root.detailPlanReady

              Rectangle {
                anchors.left: parent.left
                width: detailActions.paired ? detailActions.half : detailActions.width
                height: parent.height
                radius: height / 2
                color: drawerWindow.container
                PressVeil {
                  anchors.fill: parent
                  radius: parent.radius
                  on: detailBackArea.pressed && !root.dragging
                }
                Text {
                  anchors.centerIn: parent
                  text: detailActions.paired ? "Cancel" : "Back"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: drawerWindow.textOnSurface
                }
                MouseArea {
                  id: detailBackArea
                  anchors.fill: parent
                  onClicked: root.detailStage = "info"
                }
              }

              Rectangle {
                anchors.right: parent.right
                width: detailActions.half
                height: parent.height
                radius: height / 2
                color: drawerWindow.containerHigh
                // L8. Not disabled -- absent. A button that is drawn and
                // refuses is a button that has to explain itself twice.
                visible: detailActions.paired
                PressVeil {
                  anchors.fill: parent
                  radius: parent.radius
                  on: detailRemoveArea.pressed && !root.dragging
                }
                Text {
                  anchors.centerIn: parent
                  text: "Remove"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: drawerWindow.textOnSurface
                }
                MouseArea {
                  id: detailRemoveArea
                  anchors.fill: parent
                  onClicked: root.removeApp()
                }
              }
            }
          }
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
  // Only the hold reads it (L3): the sheet itself is a one-axis gesture, and a
  // press that wanders sideways is still a press to it.
  property real sheetPressX: 0
  property bool sheetDragging: false
  property real sheetVelocity: 0
  property real sheetLastY: 0
  property real sheetLastT: 0

  // Cleared on the next press, not on release, and that ordering is the whole
  // point (H4). Qt delivers `released` and *then* `clicked`, so a flag cleared
  // in the release handler is already false when the click arrives -- and the
  // delegate launches the app the drag happened to start on. `holdFired` (L2)
  // is cleared in the same place for the same reason.
  property bool sheetWasDrag: false

  function sheetPress(item, mouse): void {
    var p = item.mapToItem(null, mouse.x, mouse.y)
    root.sheetPressY = p.y
    root.sheetPressX = p.x
    root.sheetDragging = false
    root.sheetWasDrag = false
    root.holdFired = false
    root.sheetVelocity = 0
    root.sheetLastY = root.sheetPressY
    root.sheetLastT = Date.now()
  }

  function sheetMove(item, mouse): void {
    var y = item.mapToItem(null, mouse.x, mouse.y).y
    root.holdMove(item, mouse)
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
    // Before the early return: a press that never moved is the case the hold
    // timer is still armed in, and it is the only case, so a cancel placed
    // after the guard would never run.
    root.cancelHold()
    if (!root.sheetDragging) return
    root.sheetWasDrag = true
    root.sheetDragging = false
    root.dragging = false
    if (root.sheetVelocity >= root.sheetFling) root.dismiss()
    else if (root.sheetVelocity <= -root.sheetFling) root.progress = 1
    else if (root.progress <= root.closeCommit) root.dismiss()
    else root.progress = 1
  }

  // L4. The grid's own scroll arrives here: a Flickable steals the grab and Qt
  // clears `pressed` before it emits `canceled()`, so a thumb resting mid-scroll
  // leaves by the same door a press veil does.
  function sheetCancel(): void {
    dragWatchdog.stop()
    root.cancelHold()
    if (!root.sheetDragging) return
    root.sheetDragging = false
    root.dragging = false
    root.progress = 1
  }
}
