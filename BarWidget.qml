import QtQuick
import qs.Ui

// The lock screen's key glyph, on the bar: lit while an authenticator is
// attached, dim while none is, click to open the management panel.
//
// Presence is the service's answer rather than a second poller. The widget
// registers its interest while it is mounted, which is what makes the service
// keep looking for the key with the session unlocked -- the same mechanism
// lockOnUnplug and notifyOnKeyChange use, so however many of the three are on,
// there is still exactly one thing asking the key whether it is there.
BarWidget {
  id: root
  moduleName: "erijl.lock"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("erijl.lock")
    : null

  readonly property bool keyPresent: !!(service && service.fido2TokenPresent)
  readonly property bool configured: !!(service && service.fido2Configured)

  // A bar surface exists per monitor, so this runs once per screen; the
  // service counts watchers rather than holding a flag.
  property bool watching: false

  onServiceChanged: {
    if (!service || watching || typeof service.watchPresence !== "function") return
    service.watchPresence(true)
    watching = true
  }

  Component.onDestruction: if (watching && service) service.watchPresence(false)

  implicitWidth: keyButton.implicitWidth
  implicitHeight: keyButton.implicitHeight

  WidgetButton {
    id: keyButton
    anchors.fill: parent
    bar: root.bar
    // U+EB11, written as an escape: a Private Use Area codepoint survives no
    // round trip through anything that sanitises text, and this one went
    // missing exactly that way once.
    text: "\ueb11"
    dimmed: !root.keyPresent
    tooltipText: !root.configured
      ? "Security key not set up"
      : (root.keyPresent ? "Security key attached" : "No security key attached")
    onPressed: function(pressedButton) {
      if (root.bar) root.bar.run("omarchy-shell shell toggle erijl.lock '{}'")
    }
  }
}
