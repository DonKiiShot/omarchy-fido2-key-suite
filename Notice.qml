import QtQuick
import qs.Ui
import qs.Commons

// A tinted paragraph the panel uses to say something the state alone cannot:
// a backup key is missing, the PIN budget is nearly spent, the mapping file
// has the wrong owner. `tone` carries the meaning -- accent for advice,
// urgent for something already wrong.
BorderSurface {
  id: root

  property string text: ""
  property color tone: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitHeight: body.implicitHeight + Style.spacing.md * 2
  radius: Style.cornerRadius
  color: Qt.rgba(tone.r, tone.g, tone.b, 0.10)
  borderSpec: Border.flat(Qt.rgba(tone.r, tone.g, tone.b, 0.35), 1)

  Text {
    textFormat: Text.PlainText
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    text: root.text
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }
}
