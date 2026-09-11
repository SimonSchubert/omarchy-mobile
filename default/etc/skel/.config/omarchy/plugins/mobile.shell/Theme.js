// Colour arithmetic, shared by every surface in this plugin. Ported from
// moarchy.common/Theme.js.
//
//     import "Theme.js" as Theme
//
// `.pragma library` because these are pure: every input arrives as an
// argument and nothing here reads a property.
.pragma library

// WCAG 2.1 relative luminance and contrast, and a linear composite, so a
// secondary text colour can be computed per theme instead of guessed. A
// constant alpha cannot do this: moarchy measured foreground at 0.7 over a
// lifted card falling below AA in six of the 22 themes.
function luminance(c) {
    function chan(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
}

function contrastRatio(a, b) {
    var la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function mix(bg, fg, a) {
    return Qt.rgba(bg.r + a * (fg.r - bg.r),
                   bg.g + a * (fg.g - bg.g),
                   bg.b + a * (fg.b - bg.b), 1)
}

// Start quiet and walk toward the foreground only until the pair clears the
// ratio, so every theme ends up as quiet as it can afford.
function readableOn(bg, fg, from, minRatio) {
    for (var a = from; a < 1.0; a += 0.01) {
        var c = mix(bg, fg, a)
        if (contrastRatio(c, bg) >= minRatio) return c
    }
    return fg
}
