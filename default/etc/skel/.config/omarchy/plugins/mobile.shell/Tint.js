// The colour the focused app states, from the screen that works it out to the
// bar that draws it.
//
//     import "Tint.js" as Tint
//
// ---------------------------------------------------------------------------
// Why this file exists at all
// ---------------------------------------------------------------------------
// Shell.qml knows which app is focused, which of this shell's own sheets are
// up, and what colour each entry states (appTint). Bar.qml draws the surface
// that has to take it. They are two entry points of one plugin, and there is
// no reference from one to the other: what a plugin is handed as `shell.bar`
// is the host's sandboxed bar-state object -- barHidden, barSize, fontFamily,
// position, and nothing else (shell.qml, pluginBarStateFor). A Binding aimed
// at it wrote `tint` into a property that was not there, silently, and the
// bottom band took the colour while the bar stayed in the theme's. That is
// what caught it.
//
// Both entry points are loaded into the same QML engine in the same process,
// and a `.pragma library` module is shared across that engine -- so this is an
// ordinary object both can see, and not an IPC, a file in the runtime
// directory, or a poll.
//
// What it is NOT is a property: a plain JS value has no change signal, so a
// binding on it would never update. Hence a listener list, which is the part
// that makes it useful.

.pragma library

// "" for "the theme's own colours", "#rrggbb" for a stated one.
var _value = ""
var _listeners = []

function value() { return _value }

// Iterated backwards and guarded, because a listener belongs to a QML object
// that may be gone: the shell reloads a plugin whose files change, and a
// callback into a destroyed Bar throws. One that does is dropped rather than
// taking the rest of the list with it.
function set(next) {
    var v = next ? String(next) : ""
    if (v === _value) return
    _value = v
    for (var i = _listeners.length - 1; i >= 0; i--) {
        try {
            _listeners[i](v)
        } catch (e) {
            _listeners.splice(i, 1)
        }
    }
}

function subscribe(fn) {
    _listeners.push(fn)
    return fn
}

function unsubscribe(fn) {
    var i = _listeners.indexOf(fn)
    if (i >= 0) _listeners.splice(i, 1)
}
