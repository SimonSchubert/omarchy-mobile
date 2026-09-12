// Settings, as a phone screen: a stack of pages over Omarchy's menu
// (docs/spec/settings.md).
//
// Ported from moarchy.settings. A screen that is a window (gestures.md K), the
// third beside Wi-Fi and Bluetooth: it maps as an ordinary toplevel, so the
// window rule gives it a workspace, the carousel a card, and the strip's
// sideways swipe a way back to it.
//
// The screens are data, in Pages.js. This file is the machinery that renders
// them, and Guards.js is the one bash per page that answers their questions.
//
// What changed on the way, and why:
//
//   one plugin    moarchy.settings is a plugin of its own and reaches the other
//                 screens through shell.summon(). Omarchy 4.0.3's sandbox lets
//                 a plugin summon and hide only its own id, so here it is a
//                 screen inside mobile.shell and talks to the host directly
//                 (Shell.qml, "Why one plugin").
//   the palette   Color.popups, as Wi-Fi and Bluetooth use, not moarchy's
//                 Color.menu: three screens of one app should read as one app.
//   choices       A choice's write runs as a process and the page re-reads when
//                 it exits. moarchy re-read straight after starting the write,
//                 which races it; omarchy-theme-set takes seconds, and the tick
//                 stayed on the old theme.
//   hidden rows   Hidden rows take no space. moarchy's list kept its spacing
//                 for every row a guard hid, so a page with three offers
//                 withdrawn had three gaps in it.
//   the keyboard  No squeekboard here to put away on close.
//   the drawer    Search from the drawer (settings.md O) is not ported, and
//                 with it the quiet open and `runRow`.
//
// Three things here are load-bearing and look optional, all three moarchy's:
//
// 1. open() does no reading. It sets the page and returns; the guard batch
//    runs from Qt.callLater. open() is called from inside IPC handlers, and
//    anything that spins a nested event loop there maps a window that never
//    paints (A5).
//
// 2. Row visibility is a property looked up per row, not a filter over the
//    model. A ListView whose model array is replaced tears down and recreates
//    its delegates, and a delegate recreated under a finger eats the tap.
//
// 3. No property here is named on<Uppercase>. QML reserves that prefix for
//    signal handlers, so such a property reads back undefined, and undefined
//    as a colour renders pure black with nothing logged (I3).
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Pages.js" as Pages
import "Guards.js" as Guards
import "Theme.js" as Theme

Item {
  id: root

  property var host: null
  readonly property var shell: root.host ? root.host.shell : null

  // Printed by `recents list` in place of the shell's own app id (E1, K9).
  readonly property string screenId: "mobile.settings"

  // Whether the window is mapped. Read off the window, never assigned
  // (MobileAppWindow.qml says why). There is no "hidden": going to another
  // workspace leaves the window mapped, and closing it unmaps it (K4, K6).
  readonly property bool opened: settingsWindow.visible

  // How the carousel finds this screen from its window (Shell.qml).
  readonly property var appWindow: settingsWindow

  // Where the root page's back chevron goes: whatever opened this, when it
  // asked to be returned to. Empty means nowhere -- the window just closes.
  property string returnTo: ""

  // ------------------------------------------------------------- the stack
  property var stack: ["root"]
  readonly property string currentPage: root.stack.length
                                        ? root.stack[root.stack.length - 1] : "root"

  // Answers from the last guard batch, keyed by row id.
  property var whenMap: ({})
  property var valueMap: ({})
  property string pageValue: ""

  // Rows a provider or text page built for itself. `dynamicLoaded` is separate
  // from the length because a provider may legitimately return nothing -- a
  // theme with no extra wallpapers -- and keying off the length re-ran it
  // forever.
  property var dynamicRows: []
  property bool dynamicLoaded: false

  // Bumped on every page change and every refresh. A batch that comes back
  // carrying an older number is answering for a page already left, and
  // applying it would paint one page with another's state.
  property int generation: 0

  // `settings dryRun 1` records what would have run instead of running it,
  // which is what lets a check exercise a row that reboots the phone.
  property bool dryRun: false
  property string lastLaunch: ""

  property string confirmText: ""
  property var confirmRow: null

  // `input` row text, keyed by row id. Reassigned wholesale, never mutated in
  // place: a member write on a `var` emits no change, so every binding reading
  // it -- the Set row's enabled state, the command it builds -- would keep the
  // old value. Cleared with the page, so nothing typed outlives it (J12).
  property var inputMap: ({})
  property string focusedInput: ""

  function inputValue(id) {
    var v = root.inputMap[id]
    return v === undefined ? "" : String(v)
  }

  function setInput(id, value) {
    var next = ({})
    for (var k in root.inputMap) next[k] = root.inputMap[k]
    next[id] = String(value)
    root.inputMap = next
  }

  // --------------------------------------------------------------- palette
  readonly property int radiusCard: Style.space(18)
  readonly property int textWeight: Font.DemiBold
  readonly property color surface: Color.popups.background
  readonly property color textOnSurface: Color.popups.text
  readonly property color container: Util.alpha(Color.popups.text, 0.08)
  readonly property color accent: Color.accent

  // The detail line is computed per theme rather than fixed, against the card
  // as composited rather than the surface under it (Theme.js says why).
  readonly property color subdued: Theme.subduedOnContainer(root.surface,
                                                            root.textOnSurface)

  component PressVeil: Veil { ink: root.textOnSurface }

  readonly property var pageDef: Pages.page(root.currentPage)
  readonly property string pageTitle: root.pageDef ? root.pageDef.title : "Settings"

  // Stable identity for an ordinary page: the same array object comes back from
  // Pages.js every time, so the ListView keeps its delegates.
  readonly property var currentRows: {
    var p = root.pageDef
    if (!p) return []
    if (!p.provider && !p.text) return p.rows
    // `before`: the list a provider builds goes above the rows the page
    // declares, so opening Reminders is the whole of showing them (J1).
    if (p.provider && p.provider.before) return root.dynamicRows.concat(p.rows)
    return root.dynamicRows
  }

  function rowsTsv(pageId) {
    if (!Pages.exists(pageId)) return "unknown page: " + pageId
    var live = (pageId === root.currentPage)
    var rows = live ? root.currentRows : Pages.page(pageId).rows
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      out.push([r.id, r.type, r.label,
                live ? (root.rowVisible(r) ? "1" : "0") : "?",
                live ? (root.rowChecked(r) ? "1" : "0") : "?",
                live ? root.rowDetail(r) : "",
                live ? (root.rowEnabled(r) ? "1" : "0") : "?"].join("\t"))
    }
    return out.join("\n")
  }

  // A deep link arrives as one page id, but back has to walk up from it. Page
  // ids are dotted the way upstream's menu ids are, so the ancestors are the
  // prefixes: system.power -> root, system, system.power. Without this, back
  // from the shade's power glyph would close Settings rather than go up.
  function stackFor(pageId) {
    if (pageId === "root") return ["root"]
    var parts = String(pageId).split(".")
    var out = ["root"]
    var acc = ""
    for (var i = 0; i < parts.length; i++) {
      acc = acc ? acc + "." + parts[i] : parts[i]
      if (Pages.exists(acc)) out.push(acc)
    }
    return out
  }

  function rowByValue(value) {
    var rows = root.currentRows
    for (var i = 0; i < rows.length; i++)
      if (rows[i].type === "choice" && String(rows[i].value) === String(value))
        return rows[i]
    return null
  }

  function rowById(id) {
    var rows = root.currentRows
    for (var i = 0; i < rows.length; i++) if (String(rows[i].id) === String(id)) return rows[i]
    return null
  }

  // A row with no `when` is visible. One with a `when` is visible only on an
  // explicit pass, so a guard that fails, hangs or is missing hides its row
  // rather than showing it wrongly (F6).
  function rowVisible(row) {
    if (!row) return false
    if (!row.when) return true
    return root.whenMap[row.id] === true
  }

  // Drawn but not yet able to act: Set reminder before a duration is typed.
  // Not the same question as visibility -- a row that vanished while a field
  // was empty would move the list under a thumb (J8).
  function rowEnabled(row) {
    if (!row) return false
    if (!row.requires) return true
    return root.inputValue(String(row.requires)) !== ""
  }

  // ------------------------------------------------- a row's own palette
  //
  // The theme picker's rows arrive carrying the colours they name
  // (omarchy-mobile-themes), and are drawn in them: the card is the theme's
  // background, the label its foreground, the tick its accent. That is
  // moarchy's tile flattened into a row, and it is what makes this a picker of
  // colours rather than a column of names.
  //
  // Decided here rather than in SettingsRow, which takes every colour as a
  // property precisely so the list can decide the palette once per row. A row
  // with no swatch answers the page's own colours, which is every other row on
  // every other page.
  function rowSwatch(row) {
    return (row && row.swatch) ? row.swatch : null
  }

  function rowFill(row) {
    var sw = root.rowSwatch(row)
    return sw ? sw.background : root.container
  }

  function rowInk(row) {
    var sw = root.rowSwatch(row)
    return sw ? sw.foreground : root.textOnSurface
  }

  // Measured against the theme's own ground, which is the point of computing it
  // rather than reaching for one alpha: a flat 0.6 falls below AA on a third of
  // these palettes, and this list now paints all 22 of them.
  //
  // Through Qt.color first, and that is not decoration. A swatch arrives as
  // JSON, so its colours are strings, and Theme.readableOn does channel
  // arithmetic -- it reads `.r` off its arguments. Handed the string it reads
  // undefined, the luminance is NaN, the comparison is false for every step of
  // the walk and the function returns the foreground unchanged. The symptom
  // would be a second line at full strength on 22 rows and no error anywhere.
  // Every other swatch colour here is assigned to a `color` property, which
  // coerces on its own; this one is the exception because it is arithmetic.
  function rowSubdued(row) {
    var sw = root.rowSwatch(row)
    return sw ? Theme.readableOn(Qt.color(sw.background), Qt.color(sw.foreground),
                                 0.55, 4.5)
              : root.subdued
  }

  function rowAccent(row) {
    var sw = root.rowSwatch(row)
    return sw ? sw.accent : root.accent
  }

  // A swatched row needs an edge and no other row does: a theme whose
  // background is the page's own -- the one in use, always -- would otherwise
  // have no boundary at all and read as a gap in the list.
  function rowBorder(row) {
    var sw = root.rowSwatch(row)
    return sw ? Util.alpha(sw.foreground, 0.25) : "transparent"
  }

  function rowChips(row) {
    var sw = root.rowSwatch(row)
    return (sw && sw.chips) ? sw.chips : []
  }

  function rowChecked(row) {
    if (!row) return false
    if (row.type === "switch") {
      // Unknown is not "off inverted". Before the first read there is no
      // answer, and an inverted switch would otherwise paint ON for a frame and
      // then flip -- which reads as the tap having done something.
      var raw = root.valueMap[row.id]
      // A provider that built this row already knows: one listing answers for
      // every plugin, where a `read` per row is a fork per row (M3). The guard
      // batch still wins when there is one.
      if (raw === undefined && row.state !== undefined) raw = row.state
      if (raw === undefined) return false
      var v = String(raw).toLowerCase()
      var on = (v === "true" || v === "1" || v === "on" || v === "enabled")
      return row.invert ? !on : on
    }
    if (row.type === "choice")
      return root.pageValue !== "" &&
             root.pageValue === String(row.readValue || row.value)
    return false
  }

  // `detail` is prose carried by the row; `read` and `detailCmd` are shell
  // expressions the guard batch answers. Two kinds of field rather than one
  // guessed apart at runtime, and keyed off the command fields rather than the
  // row type: the keybindings page builds info rows that carry their second
  // column inline and ask nothing.
  function rowDetail(row) {
    if (!row) return ""
    // The write this row asked for is still running. Ahead of everything else:
    // the row is the only place that can say so, and what it would otherwise
    // show is a value that has not changed yet.
    if (row.type === "choice" && root.applyingValue !== ""
        && root.applyingValue === String(row.value !== undefined ? row.value : ""))
      return "Applying\u2026"
    // A switch's `read` answers `checked`, not the second line.
    if (row.type === "switch") return String(row.detail || "")
    if (row.read || row.detailCmd) return String(root.valueMap[row.id] || "")
    return String(row.detail || "")
  }

  // ----------------------------------------------------------- the quiet open
  //
  // O4. A row activated from the drawer's search runs without this screen ever
  // appearing. "Not appearing" and not "appearing briefly": Screenshot is one
  // of those rows, and the surface it would photograph is the one the drawer
  // was just on.
  //
  // So the page is stood up, its guards are read, the row is fired -- and only
  // then is it decided whether there is anything to look at. A row that ran
  // somewhere else leaves nothing (dropQuiet); one that pushed a page, armed a
  // question or is a kind whose whole answer is its own screen leaves the
  // screen up (showQuiet).
  property bool quietOpen: false

  // The stack and the mapping this open found, so a quiet one that leaves
  // nothing can put both back. A quiet open from the drawer must not close a
  // Settings that was sitting on another workspace, nor move it off its page.
  property var quietStack: []
  property bool quietWasMapped: false

  // The row to fire once the page it lives on has answered. Cleared by
  // settlePending, which is the only thing that reads it.
  property string pendingRow: ""

  // There is something to look at after all.
  function showQuiet() {
    if (!root.quietOpen) return
    root.quietOpen = false
    // A2, deferred from open(): the sheets are put away by the screen that
    // actually appears, not by one that was only ever going to run a command.
    if (root.host) root.host.hideSheets()
    settingsWindow.show()
  }

  // Nothing to look at: the row is already running somewhere else. Put back the
  // stack the open found, and leave the window as mapped or unmapped as it was.
  function dropQuiet() {
    if (!root.quietOpen) return
    root.quietOpen = false
    root.stack = root.quietStack
    root.resetReadState()
    root.resetFields()
    if (root.quietWasMapped) return
    root.close()
  }

  // After activating this row from a quiet open, is there a screen worth
  // showing? Derived from the row rather than from what activate() did, because
  // under `dryRun` it does nothing and the answer must be the same either way.
  //
  // `inline` counts as nothing to show even though it keeps the screen up
  // normally: what it keeps up is the page you were standing on, and from a
  // quiet open you were not standing anywhere. The command is running and the
  // notification is the feedback.
  function quietLeavesNothing(row) {
    if (!row) return false
    if (row.type === "plugin") return true
    return row.type === "action" || row.type === "link"
  }

  // A quiet open holds a window the user cannot see. Every path out of
  // settlePending() ends it, but a guard batch that never answers is a path out
  // of nothing -- and the symptom would be a drawer tap that appears to do
  // nothing at all, which is worse than either outcome it is choosing between.
  // So the wait has a floor: give up and show the page.
  Timer {
    id: quietTimeout
    interval: 3000
    onTriggered: {
      if (!root.quietOpen) return
      root.pendingRow = ""
      root.showQuiet()
    }
  }

  // O4-O9. Called once the page the row lives on has answered its guards, from
  // every path that ends a refresh: the batch's own handler, and the early
  // return refresh() takes on a page with nothing to ask.
  function settlePending() {
    if (!root.pendingRow) return
    quietTimeout.stop()
    var id = root.pendingRow
    root.pendingRow = ""

    var row = root.rowById(id)
    // Gone, hidden by its guard, or not ready. The drawer offered it, so doing
    // nothing at all would be exactly the silent failure O9 exists to stop:
    // show the page and let the screen explain itself.
    if (!row || !root.rowVisible(row) || !root.rowEnabled(row)) {
      root.showQuiet()
      return
    }

    root.activate(row)

    // A question was armed rather than answered. Arming one is only worth
    // anything if somebody sees it (O8).
    if (root.confirmText !== "") { root.showQuiet(); return }

    if (root.quietLeavesNothing(row)) { root.dropQuiet(); return }

    root.showQuiet()
  }

  // ------------------------------------------------------------ lifecycle
  //
  // Payload fields, all optional: `page` opens at that page, `returnTo` names
  // the surface the root page's back chevron hands back to, `resume` asks for
  // the screen as it was left, and `activate` names a row to fire once the page
  // has answered -- with `quiet`, without showing the screen to do it (O4).
  function open(payloadJson) {
    root.returnTo = ""
    var start = "root"
    var named = false
    var resume = false
    var pending = ""
    var quiet = false
    try {
      var payload = JSON.parse(String(payloadJson || "{}")) || ({})
      if (payload.returnTo) root.returnTo = String(payload.returnTo)
      if (payload.page && Pages.exists(String(payload.page))) {
        start = String(payload.page)
        named = true
      }
      resume = payload.resume === true
      if (payload.activate) pending = String(payload.activate)
      // `quiet` with no row to fire is a window that would never map and never
      // do anything, so the two are one option.
      quiet = payload.quiet === true && pending !== ""
    } catch (e) {
      // A malformed payload is not worth refusing to open over.
    }

    // A2. Sheets only: Wi-Fi and Bluetooth are windows on their own workspaces,
    // and putting them away would be closing them. Held back for a quiet open,
    // which has no screen to make room for -- showQuiet() does it if one turns
    // out to be needed.
    if (!quiet && root.host) root.host.hideSheets()

    // Read before the stack is rebuilt below, so the way back is the state this
    // open found rather than the one it made.
    root.quietWasMapped = root.opened
    root.quietStack = root.stack
    root.quietOpen = quiet
    root.pendingRow = pending

    // A7, K12. A summon that names no page and finds the window already mapped
    // is somebody asking for the screen they were on -- the gear tapped from
    // another workspace, the drawer's tile, Wi-Fi's back chevron -- and an app
    // answers that by coming back where it was. Naming a page still navigates,
    // which is what the shade's power glyph depends on.
    //
    // `opened` is read before anything below maps, so a close (K6) makes this
    // false and the next open rebuilds at the root: A6, and why it says
    // *closing* and reopening.
    if (named || !(resume || root.opened)) {
      root.stack = root.stackFor(start)
      root.resetFields()
    }
    // Always, even on a resume. refresh() runs a provider only while
    // `dynamicLoaded` is false, so an open onto a provider page painted the
    // rows the *last* provider page built -- "No reminders set" under a "Font"
    // header (B9).
    root.resetReadState()
    root.confirmText = ""
    root.confirmRow = null
    // show() focuses the window when it is already mapped (K12).
    if (!quiet) settingsWindow.show()
    if (quiet) quietTimeout.restart(); else quietTimeout.stop()
    // Deferred, always. See note 1 in the header.
    Qt.callLater(root.refresh)
  }

  // K6. Unmapping the window is closing the app. The reset is on the unmap and
  // not here, because here is not the only way out: the carousel's card flick
  // sends xdg_toplevel.close and Qt takes the window down without anything in
  // this file being called.
  function close() { settingsWindow.hide() }

  // The name the back gesture will ask for (K7).
  function quit(): void { root.close() }

  // The root page's back chevron: close, and hand back to whatever opened this.
  function dismiss() {
    var back = root.returnTo
    root.returnTo = ""
    root.close()
    if (back && root.host) root.host.open(JSON.stringify({ surface: back }))
  }

  // ---------------------------------------------------------- navigation
  function push(pageId) {
    if (!Pages.exists(pageId)) return false
    if (pageId === root.currentPage) return true   // B6: pushing the top is a no-op
    var next = root.stack.slice()
    next.push(pageId)
    root.stack = next
    root.afterPageChange()
    return true
  }

  function pop() {
    if (root.stack.length <= 1) return false
    var next = root.stack.slice()
    next.pop()
    root.stack = next
    root.afterPageChange()
    return true
  }

  // What the back gesture will call (K7). True means consumed; false means
  // there is nothing left to go back to, so the caller closes the screen.
  function goBack() {
    if (root.confirmText !== "") { root.confirmText = ""; root.confirmRow = null; return true }
    return root.pop()
  }

  // What a page answered: its guards, its reader, and the rows a provider built
  // for it. Every arrival on a page clears this, because keeping any of it is
  // showing the page you came from.
  function resetReadState() {
    root.whenMap = ({})
    root.valueMap = ({})
    root.pageValue = ""
    root.dynamicRows = []
    root.dynamicLoaded = false
  }

  function resetFields() {
    root.inputMap = ({})
    root.focusedInput = ""
  }

  function afterPageChange() {
    root.resetReadState()
    root.resetFields()
    root.refresh()
  }

  // Re-run a page's provider as well. `refresh` alone will not: it runs the
  // provider only while `dynamicLoaded` is false, which is what stops it
  // looping -- and on a provider page that left the list as it was built
  // while the guards above it moved (J13).
  function reloadDynamic() {
    var p = root.pageDef
    if (p && (p.provider || p.text)) root.dynamicLoaded = false
    root.refresh()
  }

  // ------------------------------------------------------ reading a page
  //
  // One bash for the whole page. A provider or text page needs its rows before
  // there is anything to ask about, so that runs first and calls back here.
  function refresh() {
    var p = root.pageDef
    if (!p) return
    if ((p.provider || p.text) && !root.dynamicLoaded) {
      root.generation += 1
      dynamicProc.wanted = root.generation
      // `running = true` is a no-op on a process already running, so a new
      // command set while the last is in flight would never run.
      if (dynamicProc.running) dynamicProc.running = false
      var command = p.provider ? (p.provider.json || p.provider.list) : p.text
      dynamicProc.command = ["bash", "-lc", String(command || "")]
      dynamicProc.running = true
      return
    }
    var script = Guards.build(root.currentRows, p.reader || "")
    // A page with nothing to ask has already answered, so a quiet open's row
    // settles here rather than waiting for a batch that will never run.
    if (!script) { root.settlePending(); return }
    root.generation += 1
    guardProc.wanted = root.generation
    if (guardProc.running) guardProc.running = false
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: dynamicProc
    property int wanted: 0
    stdout: StdioCollector {
      onStreamFinished: {
        if (dynamicProc.wanted !== root.generation) return
        var p = root.pageDef
        if (!p) return
        // A `provider.json` answers with whole rows, each carrying the command
        // that acts on it -- a reminder's `cancel <unit>`, a device's
        // `set-output <name>` -- which one value per line cannot express. JSON
        // and not TSV: a label is a message somebody typed.
        if (p.provider && p.provider.json) {
          var rows = []
          try {
            var parsed = JSON.parse(String(text || "[]"))
            if (parsed && parsed.length !== undefined) rows = parsed
          } catch (e) {
            // Half a page is worse than an empty one.
            rows = []
          }
          root.dynamicRows = rows
          root.dynamicLoaded = true
          Qt.callLater(root.refresh)
          return
        }

        var lines = String(text || "").split("\n")
        var built = []
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (!line || !line.trim()) continue
          if (p.text) {
            // omarchy-menu-keybindings --print: the keys, padding, an arrow,
            // and what they do. What they do is the label -- it is what a
            // person reading a list looks for -- and the keys are the detail.
            var parts = line.indexOf("→") >= 0
                        ? line.split(/\s*→\s*/) : line.split(/\s{2,}/)
            var keys = (parts[0] || "").trim()
            var action = (parts.slice(1).join(" ") || "").trim()
            built.push({ id: "k" + i, type: "info",
                         label: action || keys, detail: action ? keys : "" })
          } else {
            var value = line.trim()
            var label = value
            // "Europe/Berlin" -> "Berlin", "America/New_York" -> "New York".
            // The value stays the whole zone, which is what timedatectl takes
            // and what the reader answers (L2).
            if (p.provider.label === "city")
              label = value.replace(/^.*\//, "").replace(/_/g, " ")
            // The transform omarchy-theme-bg-current applies, so the ticked row
            // reads the way Appearance's detail line does: "Sunset Lake", not
            // "3-sunset-lake.png" (D7).
            else if (p.provider.label === "background")
              label = value.replace(/^.*\//, "").replace(/\.[^.]+$/, "")
                           .replace(/^\d+-/, "").replace(/-/g, " ")
                           .replace(/\b\w/g, function (c) { return c.toUpperCase() })
            built.push({ id: "p" + i, type: "choice", label: label, value: value,
                         write: p.write + " " + root.shellQuote(value) })
          }
        }
        root.dynamicRows = built
        root.dynamicLoaded = true
        Qt.callLater(root.refresh)
      }
    }
  }

  // The ticked row on a choice page is scrolled into view once, when the page
  // first answers. The theme in use sat below the fold of a 22-row list, and a
  // city below it on a 64-row one, so the page's one answer -- which is current
  // -- was the thing you could not see. Once per page, so a refresh never
  // moves the list under a thumb that has scrolled it since.
  property string scrolledPage: ""

  function revealChecked() {
    if (root.scrolledPage === root.currentPage) return
    root.scrolledPage = root.currentPage
    var rows = root.currentRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].type === "choice" && root.rowChecked(rows[i])) {
        rowList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  Process {
    id: guardProc
    property int wanted: 0
    stdout: StdioCollector {
      onStreamFinished: {
        if (guardProc.wanted !== root.generation) return
        var parsed = Guards.parse(String(text || ""))
        root.whenMap = parsed.when
        root.valueMap = parsed.value
        root.pageValue = parsed.value["__page"] !== undefined
                         ? String(parsed.value["__page"]) : ""
        root.revealChecked()
        root.settlePending()
      }
    }
  }

  // ------------------------------------------------------------ activating
  //
  // Single quotes, not JSON. A double-quoted argument still expands $ and `,
  // and a wallpaper path or a font family is user data.
  function shellQuote(value) {
    return "'" + String(value).split("'").join("'\\''") + "'"
  }

  function commandFor(row) {
    if (!row) return ""
    if (row.type === "link")
      return "omarchy-launch-webapp " + root.shellQuote(String(row.url))
    if (row.type === "choice") return String(row.write || "")
    if (row.launch === "tui")
      return "omarchy-launch-floating-terminal-with-presentation " + String(row.run)
    var cmd = String(row.run || "")
    // Every named field is appended, shell-quoted, even when empty: the
    // script's argument positions are fixed, and dropping an empty message
    // would make the next argument the message.
    if (row.argsFrom)
      for (var i = 0; i < row.argsFrom.length; i++)
        cmd += " " + root.shellQuote(root.inputValue(String(row.argsFrom[i])))
    return cmd
  }

  function runCommand(cmd) {
    if (!cmd) return
    root.lastLaunch = cmd
    if (root.dryRun) return
    Quickshell.execDetached(["bash", "-lc", cmd])
  }

  function setSwitch(row, on) {
    if (!row) return
    var cmd = on ? row.on : row.off
    if (!cmd) return
    root.lastLaunch = String(cmd)
    if (root.dryRun) return
    // A process rather than execDetached: the write is only half of it, and
    // onExited is what says to read the state back (C3). Stopped first,
    // because `running = true` on a running process is a no-op.
    if (switchProc.running) switchProc.running = false
    switchProc.command = ["bash", "-lc", String(cmd)]
    switchProc.running = true
  }

  Process {
    id: switchProc
    // reloadDynamic, not refresh: a switch whose state came from a provider --
    // a plugin's -- would otherwise flip back to the state it was built with
    // (M4). Off a provider page the two are the same call.
    onExited: Qt.callLater(root.reloadDynamic)
  }

  // D4. The tick moves when the reader says so, after the write has finished.
  // A second tap while a write is still running waits for it rather than
  // killing it: a theme stopped halfway through omarchy-theme-set is a theme
  // half applied.
  property string pendingChoice: ""

  // Which row's write is in flight, by value, so the row can say so. A theme
  // costs several seconds -- omarchy-theme-set regenerates every app's
  // template -- and for that whole time the tick is still on the old theme,
  // correctly (D4), with nothing to say the tap landed.
  //
  // The rows around it are deliberately NOT dimmed or disabled, which is where
  // this parts company with moarchy's picker. Dimming is what moarchy does
  // because it refuses a second tap while a write runs; this queues it instead
  // (the note above), and a row that is still going to act must not look like
  // one that cannot.
  property string applyingValue: ""
  property string queuedValue: ""

  function writeChoice(row) {
    var cmd = root.commandFor(row)
    if (!cmd) return
    root.lastLaunch = cmd
    if (root.dryRun) return
    var value = String(row.value !== undefined ? row.value : "")
    if (choiceProc.running) {
      root.pendingChoice = cmd
      root.queuedValue = value
      return
    }
    root.applyingValue = value
    choiceProc.command = ["bash", "-lc", cmd]
    choiceProc.running = true
  }

  Process {
    id: choiceProc
    onExited: {
      if (root.pendingChoice !== "") {
        var next = root.pendingChoice
        root.pendingChoice = ""
        root.applyingValue = root.queuedValue
        root.queuedValue = ""
        choiceProc.command = ["bash", "-lc", next]
        choiceProc.running = true
        return
      }
      root.applyingValue = ""
      root.queuedValue = ""
      Qt.callLater(root.refresh)
    }
  }

  // Separate from the processes above so a write and a native action cannot
  // cancel each other.
  Process {
    id: inlineProc
    onExited: Qt.callLater(root.reloadDynamic)
  }

  // `confirmed` is a parameter, not a reading of confirmText: Continue clears
  // confirmText before calling this, and reading it instead re-armed the very
  // sheet being dismissed -- a Continue button that looked dead.
  function activate(row, confirmed) {
    if (!row) return
    // Before the confirm sheet: a row that cannot act must not be able to ask
    // a question either.
    if (!root.rowEnabled(row)) return
    if (row.confirm && !confirmed) {
      root.confirmText = String(row.confirm)
      root.confirmRow = row
      return
    }
    root.confirmText = ""
    root.confirmRow = null

    if (row.type === "nav") { root.push(row.page); return }

    // Another surface, and Settings stays where it is. One of this shell's
    // screens by name, with its back chevron coming back here (returnTo) --
    // and since Settings is still running, "here" is the page you left (A7).
    // Anything else is another plugin, through the host's summon.
    if (row.type === "plugin") {
      var target = String(row.plugin || "")
      root.lastLaunch = "plugin:" + target
      if (root.dryRun) return
      if (root.host && root.host.openScreen(target, "settings")) return
      if (root.shell && typeof root.shell.summon === "function")
        root.shell.summon(target, "{}")
      return
    }

    if (row.type === "switch") {
      root.setSwitch(row, !root.rowChecked(row))
      return
    }

    if (row.type === "choice") {
      root.writeChoice(row)
      return
    }

    if (row.type === "info" || row.type === "input") return

    var cmd = root.commandFor(row)

    // `inline` is a native action: it runs where it stands and the page reads
    // itself again when the command exits (J6). `back` pops first, so the tap
    // is answered now rather than when the script finishes.
    if (row.launch === "inline") {
      root.lastLaunch = cmd
      if (root.dryRun) return
      if (inlineProc.running) inlineProc.running = false
      inlineProc.command = ["bash", "-lc", cmd]
      inlineProc.running = true
      if (row.back) root.pop()
      return
    }

    // action, link. Settings stays exactly where it is (K8, E6). A terminal
    // is a window: tiled, the window rule moves it to a free workspace and
    // focuses it; floating, it maps above this one. A vendored picker is a
    // layer surface and draws over every window. Nothing needs to get out of
    // anything's way.
    root.runCommand(cmd)
  }

  // ------------------------------------------------------------------ IPC
  //
  // docs/spec/settings.md, "The IPC surface". Quickshell's typed IPC has no
  // optional arguments -- a declared parameter is required -- so the no-
  // argument and one-argument forms are separate verbs.
  IpcHandler {
    target: "settings"

    function state(): string { return root.opened ? "open" : "closed" }

    // Kept because the spec cites it; a window cannot disagree with `state`.
    function running(): string { return root.opened ? "running" : "stopped" }

    // K1, K9. Whether the toplevel handle was found at all: a card with no
    // glyph is this answering `none`.
    function window(): string {
      return (settingsWindow.visible ? "mapped" : "unmapped")
           + " title=" + settingsWindow.title
           + " toplevel=" + (settingsWindow.toplevel
               ? (settingsWindow.toplevel.appId + " "
                  + (settingsWindow.toplevel.activated ? "active" : "inactive"))
               : "none")
    }

    function open(): string { root.open("{}"); return "ok" }

    function openAt(page: string): string {
      if (!Pages.exists(page)) return "unknown page: " + page
      root.open(JSON.stringify({ page: page }))
      return "ok"
    }

    // The root page's back chevron: hands back to whatever opened this.
    // `quit` just closes, which is what a check tidying up wants.
    function close(): string { root.dismiss(); return "ok" }
    function quit(): string { root.quit(); return "ok" }

    function page(): string { return root.currentPage }

    function stack(): string { return root.stack.join("\n") }

    // Every page id, so a check can walk the whole tree (H1).
    function pages(): string { return Pages.ids().join("\n") }

    function goto(page: string): string {
      if (!Pages.exists(page)) return "unknown page: " + page
      root.push(page)
      return "ok"
    }

    function back(): string {
      if (root.goBack()) return root.currentPage
      root.dismiss()
      return "closed"
    }

    // TSV: rowId, type, label, visible, checked, detail, enabled. State is only
    // real for the page that is open; another page answers `?`, because its
    // guards have not been run and `0` would read as "hidden".
    function rows(): string { return root.rowsTsv(root.currentPage) }

    function rowsOn(page: string): string { return root.rowsTsv(page) }

    // A row id, or the id of the open choice page -- "what is the DNS set to"
    // is a question about the page, not about one of its rows.
    function value(rowId: string): string {
      if (rowId === root.currentPage && root.pageDef && root.pageDef.reader)
        return root.pageValue
      var row = root.rowById(rowId)
      if (!row) return "unknown row"
      if (row.type === "switch") return root.rowChecked(row) ? "on" : "off"
      if (row.type === "choice") return root.pageValue
      if (row.type === "input") return root.inputValue(rowId)
      if (row.value !== undefined && !row.read && !row.detailCmd) return String(row.value)
      return String(root.valueMap[rowId] || "")
    }

    function set(rowId: string, value: string): string {
      var row = root.rowById(rowId)
      // Setting the page sets whichever of its rows carries that value.
      if (!row && rowId === root.currentPage && root.pageDef && root.pageDef.reader)
        row = root.rowByValue(value)
      if (!row) return "unknown row"
      if (!root.rowVisible(row)) return "hidden"
      if (row.type === "switch") {
        root.setSwitch(row, value === "on" || value === "true" || value === "1")
        return "ok"
      }
      if (row.type === "choice") { root.writeChoice(row); return "ok" }
      // The only way to put text in a field without a finger, which is what
      // makes J7 to J9 checkable over ssh at all.
      if (row.type === "input") { root.setInput(rowId, value); return "ok" }
      return "not settable"
    }

    function activate(rowId: string): string {
      var row = root.rowById(rowId)
      if (!row) return "unknown row"
      if (!root.rowVisible(row)) return "hidden"
      if (!root.rowEnabled(row)) return "not ready"
      root.activate(row)
      return "ok"
    }

    function confirmText(): string { return root.confirmText }

    function confirm(): string {
      var row = root.confirmRow
      if (root.confirmText === "" && !row) return "nothing to confirm"
      root.confirmText = ""
      root.confirmRow = null
      if (row) root.activate(row, true)
      return "ok"
    }

    function focused(): string { return root.focusedInput }

    function guards(): string {
      var out = []
      var rows = root.currentRows
      for (var i = 0; i < rows.length; i++)
        out.push(rows[i].id + "\t" + (root.rowVisible(rows[i]) ? "1" : "0"))
      return out.join("\n")
    }

    function refresh(): string { root.reloadDynamic(); return "ok" }

    function dryRun(on: string): string {
      root.dryRun = (on === "1" || on === "true" || on === "on")
      return "ok"
    }

    // Readable, because every check that activates a row without wanting it
    // to happen rests on it, and a verb that can only be written cannot be
    // asserted before it is relied on.
    function dryRunState(): string { return root.dryRun ? "1" : "0" }

    function lastLaunch(): string { return root.lastLaunch }

    // Where a row is, in WINDOW coordinates -- this is a window, and a Wayland
    // client does not know where the compositor put it. Add the window's
    // position from `hyprctl clients` to aim a tap.
    function rowTarget(rowId: string): string {
      var rows = root.currentRows
      for (var i = 0; i < rows.length; i++) {
        if (String(rows[i].id) !== rowId) continue
        rowList.positionViewAtIndex(i, ListView.Contain)
        var item = rowList.itemAtIndex(i)
        if (!item || !item.visible) return "none"
        var p = item.mapToItem(null, item.width / 2, Style.space(29))
        return Math.round(p.x) + " " + Math.round(p.y)
      }
      return "none"
    }

    // What the compositor granted the window, and how far the last content
    // pixel comes to rest above its bottom edge.
    function geometry(): string {
      var gap = Math.round(settingsWindow.height - rowList.mapToItem(null, 0, rowList.height).y)
      return "w=" + settingsWindow.width
           + " h=" + settingsWindow.height
           + " gap=" + gap
           + " toplevel=" + (settingsWindow.toplevel ? "yes" : "no")
           + " screen=" + (settingsWindow.screen
               ? settingsWindow.screen.width + "x" + settingsWindow.screen.height : "?")
    }

    // Emitted from Pages.js, which is what makes coverage a bash assertion
    // rather than a promise: upstreamId, class, pageId, rowId.
    function coverage(): string {
      var rows = Pages.coverage()
      var out = []
      var names = { N: "Native", B: "Bridged", S: "Shade" }
      for (var i = 0; i < rows.length; i++)
        out.push([rows[i][0], names[rows[i][1]] || rows[i][1],
                  rows[i][2], rows[i][3]].join("\t"))
      return out.join("\n")
    }
  }

  // ---------------------------------------------------------------- window
  MobileAppWindow {
    id: settingsWindow

    host: root.host
    appName: "Settings"
    // K5: at the root the card's title line is absent, as it is for a window
    // whose title is its own name.
    pageTitle: root.currentPage === "root" ? "" : root.pageTitle
    screenId: root.screenId
    // The gear the shade opens this by, U+E615.
    glyph: ""
    color: root.surface

    // A6, K6. The page stack resets here, and here is the only place it can:
    // the card flick closes this window without calling anything in this file.
    onUnmapped: {
      root.stack = ["root"]
      root.confirmText = ""
      root.confirmRow = null
      root.pendingChoice = ""
      root.resetFields()
    }

    Rectangle {
      anchors.fill: parent
      color: root.surface

      focus: true
      Keys.onEscapePressed: { if (!root.goBack()) root.dismiss() }

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
            onActivated: if (!root.goBack()) root.dismiss()
          }

          Text {
            anchors.left: backButton.right
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.pageTitle
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.weight: root.textWeight
            color: root.textOnSurface
            elide: Text.ElideRight
          }
        }

        // ------------------------------------------------------------ rows
        ListView {
          id: rowList
          width: parent.width
          height: Math.max(0, parent.height - y)
          clip: true
          model: root.currentRows
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          cacheBuffer: Style.space(64) * 4

          // The gap belongs to the slot rather than to the ListView's
          // `spacing`, so a row its guard hides takes its gap with it.
          delegate: Item {
            id: slot
            required property var modelData

            width: rowList.width
            visible: root.rowVisible(slot.modelData)
            height: slot.visible ? Style.space(58) + Style.space(6) : 0

            SettingsRow {
              width: parent.width
              height: Style.space(58)
              color: root.rowFill(slot.modelData)
              rowType: slot.modelData.type
              glyph: slot.modelData.glyph || ""
              label: slot.modelData.label || ""
              detail: root.rowDetail(slot.modelData)
              checked: root.rowChecked(slot.modelData)
              rowEnabled: root.rowEnabled(slot.modelData)
              placeholder: slot.modelData.placeholder || ""
              numeric: slot.modelData.numeric === true
              inputText: slot.modelData.type === "input"
                         ? root.inputValue(slot.modelData.id) : ""
              textColor: root.rowInk(slot.modelData)
              subduedColor: root.rowSubdued(slot.modelData)
              accentColor: root.rowAccent(slot.modelData)
              borderColor: root.rowBorder(slot.modelData)
              chips: root.rowChips(slot.modelData)
              onActivated: root.activate(slot.modelData)
              onEdited: function (value) { root.setInput(slot.modelData.id, value) }
              // The id, not a bool: two fields on one page, and clearing the
              // flag on the one that just lost focus to the other would drop it
              // for a frame.
              onFocusTaken: function (has) {
                if (has) root.focusedInput = slot.modelData.id
                else if (root.focusedInput === slot.modelData.id) root.focusedInput = ""
              }
            }
          }
        }
      }

      // ------------------------------------------------------- confirm
      Rectangle {
        anchors.fill: parent
        visible: root.confirmText !== ""
        color: Util.alpha(root.surface, 0.92)

        // No press state (style.md H7): a tap swallower behind a modal.
        MouseArea { anchors.fill: parent }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width - Style.space(48)
          height: confirmCol.implicitHeight + Style.space(32)
          radius: root.radiusCard
          color: root.container

          Column {
            id: confirmCol
            anchors.centerIn: parent
            width: parent.width - Style.space(32)
            spacing: Style.space(16)

            Text {
              width: parent.width
              text: root.confirmText
              wrapMode: Text.WordWrap
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.weight: root.textWeight
              color: root.textOnSurface
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(12)

              Rectangle {
                width: Style.space(110); height: Style.space(44)
                radius: height / 2
                color: Util.alpha(root.textOnSurface, 0.10)
                PressVeil { anchors.fill: parent; radius: parent.radius; on: cancelArea.pressed }
                Text {
                  anchors.centerIn: parent; text: "Cancel"
                  font.family: Style.font.family; font.pixelSize: Style.font.body
                  font.weight: root.textWeight
                  color: root.textOnSurface
                }
                MouseArea {
                  id: cancelArea
                  anchors.fill: parent
                  onClicked: { root.confirmText = ""; root.confirmRow = null }
                }
              }

              Rectangle {
                width: Style.space(110); height: Style.space(44)
                radius: height / 2
                color: root.accent
                // The label's own ink, which is the surface colour (H4).
                PressVeil {
                  anchors.fill: parent
                  radius: parent.radius
                  ink: root.surface
                  on: continueArea.pressed
                }
                Text {
                  anchors.centerIn: parent; text: "Continue"
                  font.family: Style.font.family; font.pixelSize: Style.font.body
                  font.weight: root.textWeight
                  color: root.surface
                }
                MouseArea {
                  id: continueArea
                  anchors.fill: parent
                  onClicked: {
                    var row = root.confirmRow
                    root.confirmText = ""
                    root.confirmRow = null
                    if (row) root.activate(row, true)
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
