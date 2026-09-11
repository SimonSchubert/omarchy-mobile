// One row on a Settings page. Ported from moarchy.settings/SettingsRow.qml.
//
// Every row type is the same card -- glyph, label, optional second line -- and
// differs only in the ~24px at the trailing edge: a chevron, a switch, a tick,
// or nothing. Three separate components would be three copies of the card, so
// this takes a `rowType` instead.
//
// Colours come in as properties rather than being read from Color here, so the
// screen that draws the list decides the palette once, for every row.
import QtQuick
import qs.Commons
import qs.Ui as Ui

Rectangle {
  id: card

  property string rowType: "nav"
  property string glyph: ""
  property string label: ""
  property string detail: ""
  property bool checked: false

  // `input` only. `inputText` is the value the page holds, pushed in; `edited`
  // is the value the field holds, pushed back. Two directions and not one
  // property, because a delegate is not where a page's state can live -- a row
  // scrolled out of the cache buffer is destroyed with whatever was typed in it.
  property string inputText: ""
  property string placeholder: ""
  property bool numeric: false

  // Dimming is for a row that exists but cannot act (J8). Deliberately NOT
  // wired to "is this tappable": an info row is not tappable and must still
  // look like ordinary text, or About renders as though it were disabled.
  property bool rowEnabled: true

  property color textColor: "white"
  property color subduedColor: "grey"
  property color accentColor: "white"

  component PressVeil: Veil { ink: card.textColor }

  // Matches the bar and the other screens (Bar.qml carries the measurements
  // behind DemiBold rather than Medium).
  property int textWeight: Font.DemiBold

  // A fixed square slot for the leading glyph, rather than each glyph's own
  // advance width. Nerd Font advances differ per glyph, and with an intrinsic
  // width every label started at a different x and the list read as ragged
  // down its left edge.
  readonly property int glyphSlot: Math.round(Style.font.iconLarge * 1.35)

  readonly property int radiusCard: Style.space(18)

  signal activated()
  signal edited(string value)
  // Not `focusChanged`: Item already has one, and shadowing it silently breaks
  // every focus binding on the card.
  signal focusTaken(bool has)

  height: Style.space(58)
  radius: card.radiusCard
  opacity: card.rowEnabled ? 1 : 0.45

  // The card's first child, so it sits over the fill and under everything the
  // row draws (docs/spec/style.md H8).
  PressVeil {
    anchors.fill: parent
    radius: card.radiusCard
    on: rowArea.pressed
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(16)
    anchors.rightMargin: Style.space(14)
    spacing: Style.space(14)

    Ui.OpticalGlyph {
      anchors.verticalCenter: parent.verticalCenter
      visible: card.glyph !== ""
      width: card.glyphSlot
      height: card.glyphSlot
      text: card.glyph
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: card.textColor
    }

    // input. The placeholder is the label -- a 58px row has no room for both.
    //
    // Behind a Loader: this is the delegate for every row on every page, and an
    // always-built TextField would be a Control, a background and a validator
    // per row, whose `text` binding fires `edited` once on construction -- so
    // every nav and switch row would write an empty string into the page's
    // field map on its way past.
    Loader {
      id: fieldSlot
      active: card.rowType === "input"
      visible: active
      width: parent.width - (card.glyph !== "" ? card.glyphSlot + Style.space(14) : 0)
             - trailing.width
      height: parent.height
      sourceComponent: fieldComponent
    }

    Column {
      visible: card.rowType !== "input"
      anchors.verticalCenter: parent.verticalCenter
      // Exact rather than estimated: a label that runs under the switch reads
      // as a layout bug even when the elide is doing its job.
      width: parent.width - (card.glyph !== "" ? card.glyphSlot + Style.space(14) : 0)
             - trailing.width
      spacing: 0

      Text {
        width: parent.width
        text: card.label
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.weight: card.textWeight
        color: card.textColor
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: card.detail
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: card.textWeight
        color: card.subduedColor
        elide: Text.ElideRight
      }
    }
  }

  // No background and no vertical padding: the card is already the field's
  // surface. The Loader gives it the row's full height, so the whole card takes
  // the tap that focuses it (docs/spec/style.md F1-F3).
  Component {
    id: fieldComponent

    Ui.TextField {
      background: null
      verticalPadding: 0
      // leftPadding/rightPadding directly, not horizontalPadding: the base type
      // adds the border width to that one, and there is no border here.
      leftPadding: 0
      rightPadding: 0
      verticalAlignment: TextInput.AlignVCenter
      foreground: card.textColor
      accent: card.accentColor
      placeholderText: card.placeholder
      inputMethodHints: card.numeric ? Qt.ImhDigitsOnly : Qt.ImhNone
      validator: card.numeric ? digitsOnly : null
      text: card.inputText
      onTextChanged: card.edited(text)
      onActiveFocusChanged: card.focusTaken(activeFocus)
      // A delegate destroyed while focused never reports losing it.
      Component.onDestruction: if (activeFocus) card.focusTaken(false)

      RegularExpressionValidator { id: digitsOnly; regularExpression: /[0-9]{0,5}/ }
    }
  }

  // ------------------------------------------------------------- trailing
  Item {
    id: trailing
    anchors.right: parent.right
    anchors.rightMargin: Style.space(14)
    anchors.verticalCenter: parent.verticalCenter
    // Explicit per type rather than childrenRect, which counts invisible
    // children too -- every label would be short by the switch's width.
    width: card.rowType === "switch" ? Style.space(44)
           : (card.rowType === "info" || card.rowType === "action"
              || card.rowType === "input") ? 0
           : Style.space(20)
    height: parent.height

    // nav, plugin. fa-angle-right, U+F105: the Material chevron is drawn small
    // and light inside its em box and read as a stray `>` in the text.
    Ui.OpticalGlyph {
      anchors.fill: parent
      visible: card.rowType === "nav" || card.rowType === "plugin"
      text: ""
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: card.subduedColor
    }

    // link: md-open-in-new, U+F03CC.
    Ui.OpticalGlyph {
      anchors.fill: parent
      visible: card.rowType === "link"
      text: "\u{F03CC}"
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: card.subduedColor
    }

    // choice: md-check, U+F012C.
    Ui.OpticalGlyph {
      anchors.fill: parent
      visible: card.rowType === "choice"
      text: card.checked ? "\u{F012C}" : ""
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: card.accentColor
    }

    // switch
    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      visible: card.rowType === "switch"
      width: Style.space(44)
      height: Style.space(26)
      radius: height / 2
      color: card.checked ? card.accentColor : Util.alpha(card.textColor, 0.22)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        width: Style.space(20)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: card.checked ? parent.width - width - Style.space(3) : Style.space(3)
        // The card's own fill, not white: on a light theme a white knob on a
        // pale track is invisible.
        color: card.color
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }
  }

  // Not over an input row: a MouseArea filling the card takes the press before
  // the field under it ever sees one.
  MouseArea {
    id: rowArea
    anchors.fill: parent
    visible: card.rowType !== "input"
    enabled: card.rowEnabled && card.rowType !== "input"
    onClicked: card.activated()
  }
}
