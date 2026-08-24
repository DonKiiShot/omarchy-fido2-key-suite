import QtQuick
import qs.Commons

// One line of "what the key currently unlocks". Not a cursor target: the
// wiring is written by `enable` / `disable` / `repair` as a set, so there is
// nothing to toggle per row -- this only reports.
Item {
  id: root

  property string label: ""
  property bool wired: false
  property color foreground: Color.foreground
  property color dim: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  implicitHeight: row.implicitHeight

  Row {
    id: row
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      // U+F00C check / U+F00D times, written as escapes: these are Private
      // Use Area codepoints and do not survive every round trip as literals.
      text: root.wired ? "\uf00c" : "\uf00d"
      color: root.wired ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      text: root.label
      color: root.wired ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: root.wired ? "" : "not wired"
      visible: !root.wired
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
