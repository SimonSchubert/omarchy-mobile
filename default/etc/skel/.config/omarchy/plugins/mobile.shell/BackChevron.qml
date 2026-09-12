// The back chevron every screen wears in its top-left (docs/spec/style.md
// E1, E2).
//
//     BackChevron {
//       id: backButton
//       anchors.left: parent.left
//       anchors.verticalCenter: parent.verticalCenter
//       fill: root.container
//       ink: root.textOnSurface
//       onActivated: root.dismiss()
//     }
//
// Wi-Fi, Bluetooth and Settings each carried their own copy of this, identical
// down to the -3px margin, and differing only in what the tap did. Two of the
// three wrote the glyph as an escape and the third as a literal -- and a
// literal is how this plugin lost its glyphs in transit once already, so the
// escape is the one that survives being the only copy.
//
// Not named BackButton: `Button` is a type in qs.Ui, and a name that reads like
// one invites the call site to reach for the wrong import.
//
// Anchors are the call site's, not this file's: the three headers place it
// against different parents, and a component that anchors itself to `parent`
// is a component that cannot be laid out any other way.
import QtQuick
import qs.Commons
import qs.Ui as Ui

Rectangle {
  id: chevron

  // The header's container fill and its ink. No defaults: a guessed pair would
  // paint a chevron nobody can see on the surface that forgot to pass them.
  property color fill
  property color ink

  signal activated()

  width: Style.space(38)
  height: width
  radius: width / 2
  color: chevron.fill

  Veil {
    anchors.fill: parent
    radius: parent.radius
    ink: chevron.ink
    on: chevronArea.pressed
  }

  // fa-angle-left, U+F104, centred on its ink rather than its advance.
  Ui.OpticalGlyph {
    anchors.fill: parent
    text: "\uF104"
    fontFamily: Style.font.family
    fontSize: Style.font.icon
    color: chevron.ink
  }

  // 38 drawn, 44 answering (docs/spec/style.md E1, E2).
  MouseArea {
    id: chevronArea
    anchors.fill: parent
    anchors.margins: -Style.space(3)
    onClicked: chevron.activated()
  }
}
