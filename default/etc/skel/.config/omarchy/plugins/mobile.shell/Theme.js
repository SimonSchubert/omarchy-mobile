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

// ---------------------------------------------------------------------------
// The roles every surface was deriving for itself
// ---------------------------------------------------------------------------
// Six surfaces -- the shade, the drawer, the carousel, the bar, Settings and
// the two radio screens -- each drew secondary text, and each worked out its
// own colour for it. Three used this file's recipe; four used a constant alpha
// -- 0.55 on the drawer and the bar, 0.6 on the carousel, 0.62 on Wi-Fi -- which
// is exactly what the measurement above rules out. Checked against the 22
// themes as shipped, against the fill each one is actually drawn on: the drawer
// was below AA on 18 of them, the bar on 15, Wi-Fi and the carousel on 11 each,
// all four worst on rose-pine, the drawer's detail line there at 2.36:1. The
// recipe clears 4.5:1 on all 22 in every one of those four places. It belongs
// here, once, so a surface asks for "secondary ink on this background" instead
// of picking a number.
//
// `bg` arrives as the colour actually under the text -- a card's fill, not the
// surface beneath the card -- because contrast is against what is painted.

// A theme may set a surface below alpha 1. Contrast against a colour you can
// see through is contrast against nothing, so composite it onto itself first:
// the alpha belongs to what the compositor blends, not to this arithmetic.
function opaque(c) { return Qt.rgba(c.r, c.g, c.b, 1) }

// The opaque colour a `container` fill paints: the 0.08 ink these surfaces lift
// their cards with, composited onto the surface under it.
function containerOn(surface, ink) { return mix(opaque(surface), ink, 0.08) }

// Secondary ink for text drawn straight onto a surface.
function subduedOn(bg, ink) { return readableOn(opaque(bg), ink, 0.55, 4.5) }

// Secondary ink for text on a container card -- the common case, and the one
// the constant alphas got wrong, because the card is lighter than the surface
// and the eye compares against the card.
function subduedOnContainer(surface, ink) {
  return subduedOn(containerOn(surface, ink), ink)
}

// ---------------------------------------------------------------------------
// Ink on a colour the theme did not choose
// ---------------------------------------------------------------------------
// The status bar and the bottom band take the colour the focused app states
// (Shell.qml, `appTint`), and that colour is the site's, not the theme's: X
// says #000000 and YouTube says #0f0f0f, but a site is equally free to say
// #ffffff. The bar's own text colour is right for one of those and invisible
// on the other.
//
// So the ink is chosen rather than assumed, out of the theme's own pair --
// whichever of the two clears the higher ratio against the fill actually
// painted. Not a luminance threshold: a threshold answers "is this dark", and
// the question here is "which of these two can be read on it", which is the
// same arithmetic the rest of this file already does.
function inkOn(bg, a, b) {
  var fill = opaque(bg)
  return contrastRatio(a, fill) >= contrastRatio(b, fill) ? a : b
}
