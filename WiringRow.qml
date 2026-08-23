import QtQuick
import qs.Commons

// One line of "what the key currently unlocks". Not a cursor target: the
// wiring is written by `enable` / `disable` / `repair` as a set, so there is
// nothing to toggle per row -- this only reports.
Item {
  id: root

  property string label: ""
  property string detail: ""
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
      text: root.label
      color: root.wired ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.wired ? root.detail : "not wired"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      width: Math.max(0, row.width - x)
    }
  }
}
