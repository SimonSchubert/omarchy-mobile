// The radio switch at the top-right of Wi-Fi and Bluetooth (docs/spec/shade.md
// S6, S6c).
//
//     RadioPill {
//       anchors.right: parent.right
//       anchors.verticalCenter: parent.verticalCenter
//       on: root.adapter && root.adapter.enabled
//       available: root.adapter !== null
//       accent: root.accent
//       track: root.containerHigh
//       inkOn: root.textOnAccent
//       inkOff: root.textOnSurface
//       onToggled: root.setEnabled(!root.adapter.enabled)
//     }
//
// A pill rather than a checkbox, because it is the one control on those screens
// that is not a list row and has to read as a switch at a glance. Not qs.Ui's
// ToggleSwitch: that one is sized for a pointer on a desktop panel, and the
// 44px target below is what makes this one answer a finger.
//
// Bluetooth's copy of this carried the comment "drawn exactly as Wi-Fi's: the
// two screens have to read as one app", which is true and was being maintained
// by hand in two places. They now read as one app because they are one type.
import QtQuick
import qs.Commons

Rectangle {
  id: pill

  // Whether the radio is on. This means on AND present: with no device there
  // is nothing switched on, and Wi-Fi's copy drove its knob from one condition
  // and its press veil from the other, so a phone with no Wi-Fi device drew a
  // knob to the left in the colour of a switch that was to the right.
  property bool on: false

  // Whether there is a device to switch at all. No device is not "off" -- it is
  // nothing to press -- so the pill dims and stops answering.
  property bool available: true

  property color accent
  property color track
  property color inkOn
  property color inkOff

  readonly property color ink: pill.on ? pill.inkOn : pill.inkOff

  signal toggled()

  width: Style.space(52)
  height: Style.space(30)
  radius: height / 2
  opacity: pill.available ? 1 : 0.4
  color: pill.on ? pill.accent : pill.track
  Behavior on color { ColorAnimation { duration: 120 } }

  Veil {
    anchors.fill: parent
    radius: parent.radius
    ink: pill.ink
    on: pillArea.pressed
  }

  Rectangle {
    width: parent.height - Style.space(6)
    height: width
    radius: width / 2
    y: Style.space(3)
    x: pill.on ? parent.width - width - Style.space(3) : Style.space(3)
    color: pill.ink
    Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
  }

  // 30 tall is what a switch looks like, and 30 is not a target: the 7px
  // reaches the 44px header it sits in (docs/spec/style.md E1).
  MouseArea {
    id: pillArea
    anchors.fill: parent
    anchors.margins: -Style.space(7)
    enabled: pill.available
    onClicked: pill.toggled()
  }
}
