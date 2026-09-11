// The pressed state, drawn once (docs/spec/style.md H). Ported from
// moarchy.common/PressVeil.qml.
//
// A surface declares its own default ink once and its call sites say nothing:
//
//     component PressVeil: Veil { ink: root.textOnSurface }
//
// Not named PressVeil itself, because that is the name every surface gives
// its inline component, and an inline component named after the type it
// extends is a type that extends itself.
import QtQuick
import qs.Commons

Rectangle {
  id: pv

  // The control's own ink. No default worth having: a guessed one would paint
  // the wrong colour on the surface that forgot to pass it.
  property color ink

  property bool on: false

  // One blended quad, the control's own ink at 12% over whatever the resting
  // fill is, so a control whose colour already says something keeps saying it
  // while pressed. Both ends are one ink at two alphas, never "transparent",
  // which is #00000000 and fades through grey.
  //
  // Culled at rest rather than drawn transparent: nothing culls an alpha-0
  // rectangle, and the renderer here is llvmpipe.
  visible: pv.color.a > 0
  color: Util.alpha(pv.ink, pv.on ? 0.12 : 0)

  // Instant in, 120 out. A Behavior reads `enabled` at the moment of the
  // write, when the property still holds the *old* colour -- so this is false
  // arriving and true leaving.
  Behavior on color {
    enabled: pv.color.a > 0
    ColorAnimation { duration: 120 }
  }
}
