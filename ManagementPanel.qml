import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// Management surface for the FIDO2 suite: what is enrolled, what is plugged
// in, what PAM is wired to, and the buttons that start the flows which change
// any of that.
//
// The panel itself is read-only. Everything that touches /etc runs in a
// floating terminal through `bin/omarchy-fido2-suite`, the same idiom
// Omarchy's own Setup > Security entries use -- the user sees the command,
// answers its prompts, and types their own sudo password. No privileged work
// happens inside the shell process, and nothing here ever talks to the
// authenticator directly.
//
// Summon it with:
//   omarchy-shell shell summon erijl.lock '{}'
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  //
  // `manifest` carries __sourceDir, which is how the panel finds its own
  // bin/ without hardcoding ~/.config/omarchy/plugins. `service` is this
  // plugin's own Service.qml instance -- unused here, wired for WS3.
  property var shell: null
  property var manifest: null
  property var service: null

  // ---- plugin lifecycle ---------------------------------------------------
  //
  // The payload is accepted and ignored: there is one thing to show and no
  // sub-view worth deep-linking to yet.
  function open(payloadJson) {
    window.visible = true
    refresh()
    Qt.callLater(function() {
      if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  // Host-initiated close (`shell hide`); the host already knows.
  function close() {
    window.visible = false
  }

  // User-initiated close (Esc, a click outside the card). Route it through the
  // shell so its openPanelIds map stays consistent and `toggle` works next
  // time.
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("erijl.lock")
    else window.visible = false
  }

  // ---- theme --------------------------------------------------------------
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(Color.foreground, 1.5)
  readonly property string fontFamily: Style.font.family

  // ---- suite state --------------------------------------------------------
  //
  // Named suiteState, not state: Item.state is QML's own string property.
  property var suiteState: null
  property bool stateLoaded: false
  property string stateError: ""

  readonly property string suiteDir: {
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (dir === "") dir = String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
    return dir.replace(/\/$/, "")
  }
  readonly property string suiteBin: suiteDir + "/bin/omarchy-fido2-suite"

  // ---- bounds on untrusted input ------------------------------------------
  //
  // `state` already caps what it emits, but the panel does not take that on
  // trust: a plugin directory is a checkout the user can edit, and a stale or
  // swapped script must not be able to hand the shell a million delegates to
  // instantiate. These are the numbers the UI will actually build.
  readonly property int maxRows: 64
  readonly property int maxLabelChars: 64
  readonly property int maxErrorChars: 512

  // Every string that came from a device, the mapping file or a command's
  // stderr passes through here before it is bound to anything. Control
  // characters are dropped -- they have no business in a label, and U+2028 and
  // friends break layout -- and the result is clipped. Rich text is refused
  // separately, by textFormat on each Text.
  function safeText(value, limit) {
    var out = String(value === undefined || value === null ? "" : value)
      .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
    return out.length > limit ? out.slice(0, limit) + "…" : out
  }

  readonly property var credentials: suiteState && suiteState.credentials
    ? suiteState.credentials.slice(0, maxRows) : []
  readonly property var tokens: suiteState && suiteState.tokens
    ? suiteState.tokens.slice(0, maxRows) : []

  // What the producer says it found, so a clipped list can say so out loud
  // rather than passing itself off as the whole picture.
  readonly property int credentialsTotal: suiteState && suiteState.counts
    && typeof suiteState.counts.credentials === "number"
    ? suiteState.counts.credentials : credentials.length
  readonly property int tokensTotal: suiteState && suiteState.counts
    && typeof suiteState.counts.tokens === "number"
    ? suiteState.counts.tokens : tokens.length
  readonly property bool rowsTruncated: credentialsTotal > credentials.length
    || tokensTotal > tokens.length
  readonly property var wiring: suiteState && suiteState.wiring ? suiteState.wiring : null
  readonly property bool lockWired: !!(wiring && wiring.lockScreen)
  readonly property bool sudoWired: !!(wiring && wiring.sudo)
  readonly property bool polkitWired: !!(wiring && wiring.polkit)
  readonly property bool fullyWired: lockWired && sudoWired && polkitWired
  // Presence settings live on the service, which reads them from this
  // plugin's inline entry in shell.json. Reading them there rather than
  // re-parsing the file keeps one owner for the answer.
  readonly property bool lockOnUnplug: !!(service && service.lockOnUnplug)
  readonly property bool notifyOnKeyChange: !!(service && service.notifyOnKeyChange)
  readonly property bool canEditSettings: !!(service && shell && typeof shell.updateEntryInline === "function")

  readonly property bool authfileOwned: !suiteState || String(suiteState.authfileOwner || "") === "root:root"

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // ---- launching flows ----------------------------------------------------

  // Single-quote for bash. The launcher takes one command string, so the
  // path has to survive as a word even if the plugin lives somewhere with
  // spaces in the name.
  function shellQuote(text) {
    return "'" + String(text).replace(/'/g, "'\\''") + "'"
  }

  // Every mutating command goes out through the same floating terminal
  // wrapper Omarchy uses for its own setup flows, so the user reads the
  // command, answers its prompts, and owns the sudo password.
  function launch(argv) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             shellQuote(root.suiteBin) + " " + argv])
    // This overlay draws above every normal window, so the terminal it just
    // opened would be stuck behind it. Step aside, like the Omarchy menu
    // does when it runs a command; summon the panel again to see the result.
    requestClose()
  }

  // ---- settings -----------------------------------------------------------

  // updateEntryInline rewrites the plugin's shell.json entry from what it is
  // handed, so the whole entry has to go back or a toggle here would erase
  // defaultMode. The service re-reads shellConfig when it is persisted, and
  // the toggles below follow from there.
  function setSetting(name, value) {
    if (!canEditSettings) return
    var current = service.settings || ({})
    var next = {}
    for (var key in current) if (key !== "id") next[key] = current[key]
    next[name] = value
    shell.updateEntryInline("erijl.lock", next)
  }

  // ---- cursor model -------------------------------------------------------
  //
  // The shared panel recipe: focusSection + selectedIndex drive one
  // highlight, j/k walks it, h/l acts within a horizontal row, Enter
  // activates, Esc closes. Mouse hover writes the same state, so keyboard
  // and pointer never show two cursors.
  property bool cursorActive: false
  property string focusSection: "actions"
  property int selectedIndex: 0

  // Credentials are only a section when there are any; the action row is
  // always there.
  readonly property var visibleSections: {
    var sections = []
    if (credentials.length > 0) sections.push("credentials")
    if (canEditSettings) sections.push("settings")
    sections.push("actions")
    return sections
  }

  // The action row is built from state: wiring toggles between enable and
  // disable, and with nothing enrolled there is nothing to wire yet.
  readonly property var actions: {
    var list = [{ id: "enroll", label: "Enroll a key", icon: "\ueb11" },
                { id: "ssh", label: "SSH key", icon: "\uf120" }]
    if (credentials.length > 0) {
      if (fullyWired) list.push({ id: "disable", label: "Unwire PAM", icon: "\uf00d" })
      else list.push({ id: "enable", label: "Wire up PAM", icon: "\uf00c" })
      list.push({ id: "repair", label: "Repair", icon: "\uf0ad" })
    }
    list.push({ id: "doctor", label: "Doctor", icon: "\uf0f0" })
    return list
  }

  function sectionCount(section) {
    if (section === "credentials") return credentials.length
    if (section === "settings") return 2
    if (section === "actions") return actions.length
    return 0
  }

  function sectionIsHorizontal(section) {
    return section === "actions"
  }

  // The kit convention: no highlight until the keyboard or the mouse asks
  // for one, and the first key press reveals it where it already sits rather
  // than moving it.
  function revealCursor() {
    if (cursorActive) return false
    cursorActive = true
    return true
  }

  function moveCursor(delta) {
    if (revealCursor()) return
    var sections = visibleSections
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = 0
      return
    }
    if (sectionIsHorizontal(focusSection) || sectionCount(focusSection) <= 1) {
      if (delta > 0 && sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
      } else if (delta < 0 && sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = Math.max(0, sectionCount(sections[sIdx - 1]) - 1)
      }
      return
    }
    var next = selectedIndex + delta
    if (next < 0) {
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = Math.max(0, sectionCount(sections[sIdx - 1]) - 1)
      }
    } else if (next >= sectionCount(focusSection)) {
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
      }
    } else {
      selectedIndex = next
    }
  }

  function moveCursorH(delta) {
    if (revealCursor()) return
    if (!sectionIsHorizontal(focusSection)) return
    var max = sectionCount(focusSection) - 1
    selectedIndex = Math.max(0, Math.min(max, selectedIndex + delta))
  }

  function activateCursor() {
    if (revealCursor()) return
    if (focusSection === "credentials") {
      removeCredential(selectedIndex)
      return
    }
    if (focusSection === "settings") {
      if (selectedIndex === 0) setSetting("lockOnUnplug", !lockOnUnplug)
      else setSetting("notifyOnKeyChange", !notifyOnKeyChange)
      return
    }
    if (focusSection === "actions") {
      var action = actions[selectedIndex]
      if (action) root.launch(action.id)
    }
  }

  function removeCredential(listIndex) {
    var cred = credentials[listIndex]
    if (!cred) return
    // `remove` confirms in the terminal before it rewrites the mapping file,
    // so Enter here starts a conversation, it does not delete anything.
    root.launch("remove " + cred.index)
  }

  function deleteSelected() {
    if (revealCursor()) return
    if (focusSection === "credentials") removeCredential(selectedIndex)
  }

  function setCursor(section, index) {
    cursorActive = true
    focusSection = section
    selectedIndex = index
  }

  function clampCursor() {
    var sections = visibleSections
    // Until the cursor is revealed it has no position worth preserving, so it
    // parks on the first section -- which is the credential list as soon as
    // `state` reports one, not the action row it starts on.
    if (!cursorActive) {
      focusSection = sections[0]
      selectedIndex = 0
      return
    }
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[sections.length - 1]
      selectedIndex = 0
      return
    }
    if (selectedIndex < 0) selectedIndex = 0
    var max = Math.max(0, sectionCount(focusSection) - 1)
    if (selectedIndex > max) selectedIndex = max
  }

  // ---- state process ------------------------------------------------------

  // `state` interrogates whatever is plugged into the USB port, so it is the
  // one thing here that a device can hold open: libfido2 blocks on a key that
  // has wedged its HID endpoint. Three bounds, because the panel polls and a
  // stuck refresh must not become a pile of stuck refreshes:
  //
  //   timeout(1)  a hard deadline, SIGTERM then SIGKILL two seconds later
  //   head -c     a ceiling on each stream, so neither StdioCollector can
  //               grow without limit no matter what the child decides to say
  //   PIPESTATUS  so the pipeline still reports the producer's exit code
  //               rather than head's
  readonly property int stateDeadlineSeconds: 15
  readonly property int stateStdoutLimit: 262144
  readonly property int stateStderrLimit: 4096

  Process {
    id: stateProc
    command: ["bash", "-c",
              "timeout -k 2 \"$2\" \"$1\" state 2> >(head -c \"$4\" >&2) | head -c \"$3\"; exit \"${PIPESTATUS[0]}\"",
              "omarchy-fido2-suite-state",
              root.suiteBin,
              String(root.stateDeadlineSeconds),
              String(root.stateStdoutLimit),
              String(root.stateStderrLimit)]
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onRunningChanged: {
      if (running) stateWatchdog.restart()
      else stateWatchdog.stop()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.stateError = exitCode === 124 || exitCode === 137
          ? "`omarchy-fido2-suite state` timed out -- a security key may not be answering"
          : (root.safeText(stateErr.text, root.maxErrorChars).trim()
             || ("omarchy-fido2-suite state exited " + exitCode))
        root.stateLoaded = true
        return
      }
      try {
        root.suiteState = JSON.parse(String(stateOut.text || ""))
        root.stateError = ""
      } catch (e) {
        // Also the path a clipped stdout takes: truncated JSON does not parse,
        // so an over-long answer fails closed instead of half-rendering.
        root.stateError = "could not parse the output of `omarchy-fido2-suite state`"
      }
      root.stateLoaded = true
      root.clampCursor()
    }
  }

  // Belt to timeout(1)'s braces: if the child is never reaped at all -- a
  // process stuck in uninterruptible IO on the USB stack does that -- the
  // panel still stops waiting, and the next poll is free to try again.
  Timer {
    id: stateWatchdog
    interval: (root.stateDeadlineSeconds + 5) * 1000
    repeat: false
    onTriggered: {
      if (!stateProc.running) return
      stateProc.running = false
      root.stateError = "`omarchy-fido2-suite state` did not return; giving up on this refresh"
      root.stateLoaded = true
    }
  }

  // Polled so that plugging the key in with the panel open is visible without
  // pressing anything. Only while the panel is open, which is never while a
  // launched flow is running: `state` reads the authenticator with
  // fido2-token, and enroll needs that authenticator to itself.
  Timer {
    interval: 5000
    repeat: true
    running: window.visible
    onTriggered: root.refresh()
  }

  // A layer-shell overlay rather than a FloatingWindow: a summoned Omarchy
  // surface belongs above the desktop as a centred, themed card -- the way
  // the menu and the OSD do it -- not tiled into the layout as if it were an
  // application window.
  PanelWindow {
    id: window
    // The plugin is keepLoaded (its service must be), so this window is
    // constructed at shell startup rather than on first summon -- it has to
    // start hidden or every login would open it.
    visible: false
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-fido2-suite"
    WlrLayershell.layer: WlrLayer.Overlay

    // Prime with Exclusive so the panel owns the keyboard the moment it maps,
    // then settle on OnDemand so a click can hand focus elsewhere. The same
    // recipe qs.Ui.KeyboardPanel uses, and the reason Esc works without
    // clicking the card first.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

    onVisibleChanged: {
      focusPrimed = false
      if (visible) focusPrimeTimer.restart()
      else focusPrimeTimer.stop()
    }

    Timer {
      id: focusPrimeTimer
      interval: 75
      onTriggered: window.focusPrimed = true
    }

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    // Click anywhere off the card to dismiss, like every other summoned
    // surface in the shell.
    MouseArea {
      anchors.fill: parent
      onClicked: root.requestClose()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(640), window.width - Style.space(48))
      // Sized to its content, capped by the screen. The content column takes
      // its width from the card rather than from ScrollView.availableWidth,
      // so a scrollbar appearing cannot feed back into the height.
      height: Math.min(window.height - Style.space(48),
                       contentColumn.implicitHeight + card.contentTopInset + card.contentBottomInset)
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: Style.spacing.popupPadding

      // Swallow clicks on the card so they never reach the dismissal area
      // behind it.
      MouseArea {
        anchors.fill: parent
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent

        onMoveRequested: function(dx, dy) {
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveCursorH(dx)
        }
        onActivateRequested: root.activateCursor()
        onDeleteRequested: root.deleteSelected()
        onCloseRequested: root.requestClose()
        onTextKey: function(text) {
          if (text === "r" || text === "R") root.refresh()
        }

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            id: contentColumn
            width: scrollArea.width - Style.space(12)
            spacing: Style.space(18)

            // ---- header ---------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(4)

              Row {
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "\ueb11"
                  color: root.tokens.length > 0 ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "FIDO2 security key suite"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

            }

            // ---- the state command failed ---------------------------------
            Notice {
              width: parent.width
              visible: root.stateError !== ""
              tone: root.urgent
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: root.stateError === "" ? ""
                : ("Could not read the suite state: " + root.safeText(root.stateError, root.maxErrorChars))
            }

            // ---- attached authenticators ----------------------------------
            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "ATTACHED AUTHENTICATOR"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.tokens.length === 0
                wrapMode: Text.WordWrap
                text: root.stateLoaded ? "None attached" : "Reading"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.tokens

                delegate: Item {
                  id: tokenRow
                  required property var modelData

                  // Below 4 attempts the key is close enough to the factory
                  // reset that the number stops being trivia.
                  readonly property bool lowRetries: typeof modelData.pinRetries === "number" && modelData.pinRetries <= 3

                  width: contentColumn.width
                  implicitHeight: tokenCol.implicitHeight

                  Column {
                    id: tokenCol
                    width: parent.width
                    spacing: Style.space(2)

                    Row {
                      width: parent.width
                      spacing: Style.space(8)

                      Text {
                        textFormat: Text.PlainText
                        text: root.safeText(tokenRow.modelData.name || "Security key", root.maxLabelChars)
                        elide: Text.ElideRight
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: typeof tokenRow.modelData.pinRetries === "number"
                          ? "· " + tokenRow.modelData.pinRetries + " PIN attempts left"
                          : ""
                        visible: text !== ""
                        color: tokenRow.lowRetries ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: {
                        var parts = [root.safeText(tokenRow.modelData.device, root.maxLabelChars)]
                        if (String(tokenRow.modelData.alwaysUv) === "true") parts.push("alwaysUv")
                        if (String(tokenRow.modelData.clientPin) === "true") parts.push("PIN set")
                        else parts.push("no PIN set")
                        return parts.join("  ·  ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Notice {
                width: parent.width
                visible: {
                  for (var i = 0; i < root.tokens.length; i++) {
                    var t = root.tokens[i]
                    if (typeof t.pinRetries === "number" && t.pinRetries <= 3) return true
                  }
                  return false
                }
                tone: root.urgent
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: "Few PIN attempts left. At zero the key locks itself out and only a factory reset brings it back."
              }
            }

            // Bounded lists are only honest if they admit it.
            Notice {
              width: parent.width
              visible: root.rowsTruncated
              tone: root.urgent
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Showing " + root.credentials.length + " of " + root.credentialsTotal
                + " credentials and " + root.tokens.length + " of " + root.tokensTotal
                + " authenticators. The rest are not displayed."
            }

            // ---- enrolled credentials -------------------------------------
            Column {
              id: credentialsColumn
              width: parent.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "ENROLLED CREDENTIALS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.stateLoaded && root.credentials.length === 0
                wrapMode: Text.WordWrap
                text: "None enrolled"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.credentials

                delegate: CursorSurface {
                  id: credRow
                  required property var modelData
                  required property int index

                  width: credentialsColumn.width
                  implicitHeight: Math.max(Style.spacing.controlHeight, credCol.implicitHeight + Style.spacing.md * 2)
                  foreground: root.foreground
                  accent: root.accent
                  hasCursor: root.cursorActive && root.focusSection === "credentials" && root.selectedIndex === credRow.index

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor("credentials", credRow.index)
                    onClicked: root.removeCredential(credRow.index)
                  }

                  Column {
                    id: credCol
                    anchors.left: parent.left
                    anchors.right: removeButton.left
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: root.safeText(credRow.modelData.index, 8) + ".  "
                        + root.safeText(credRow.modelData.label || "unlabelled", root.maxLabelChars)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      width: parent.width
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      elide: Text.ElideRight
                      text: {
                        var parts = [root.safeText(credRow.modelData.flags, root.maxLabelChars)]
                        var date = root.safeText(credRow.modelData.enrolled, root.maxLabelChars)
                        if (date !== "") parts.push("enrolled " + date)
                        return parts.join("  ·  ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    id: removeButton
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\uf1f8"
                    tooltipText: "Remove this credential"
                    foreground: root.foreground
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.removeCredential(credRow.index)
                  }
                }
              }

              Notice {
                width: parent.width
                visible: root.credentials.length === 1
                tone: root.accent
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: "Only one credential enrolled. A second key is the way back in if this one is lost."
              }

              Notice {
                width: parent.width
                visible: root.stateLoaded && !root.authfileOwned
                tone: root.urgent
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: root.suiteState
                  ? "The mapping file is owned by " + String(root.suiteState.authfileOwner) + ", not root:root. Run Repair."
                  : ""
              }
            }

            // ---- wiring ---------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "WHAT THE KEY UNLOCKS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              WiringRow {
                width: parent.width
                label: "Lock screen"
                wired: root.lockWired
                foreground: root.foreground
                dim: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
              }

              WiringRow {
                width: parent.width
                label: "sudo"
                wired: root.sudoWired
                foreground: root.foreground
                dim: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
              }

              WiringRow {
                width: parent.width
                label: "polkit"
                wired: root.polkitWired
                foreground: root.foreground
                dim: root.dim
                accent: root.accent
                fontFamily: root.fontFamily
              }
            }

            // ---- presence settings ----------------------------------------
            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(6)
              visible: root.canEditSettings

              PanelSeparator { foreground: root.foreground }
              PanelSectionHeader {
                text: "WHEN THE KEY COMES AND GOES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Toggle {
                width: parent.width
                label: "Lock when the key is removed"
                description: "Locks the session when the key leaves"
                checked: root.lockOnUnplug
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "settings" && root.selectedIndex === 0
                onHovered: function(isHovered) { if (isHovered) root.setCursor("settings", 0) }
                onClicked: root.setSetting("lockOnUnplug", !root.lockOnUnplug)
              }

              Toggle {
                width: parent.width
                label: "Notify on plug and unplug"
                description: "A notification when the key comes and goes"
                checked: root.notifyOnKeyChange
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "settings" && root.selectedIndex === 1
                onHovered: function(isHovered) { if (isHovered) root.setCursor("settings", 1) }
                onClicked: root.setSetting("notifyOnKeyChange", !root.notifyOnKeyChange)
              }

            }

            // ---- actions --------------------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.foreground }

              Flow {
                width: parent.width
                spacing: Style.spacing.controlGap

                Repeater {
                  model: root.actions

                  delegate: Button {
                    id: actionButton
                    required property var modelData
                    required property int index

                    text: String(actionButton.modelData.label)
                    iconText: String(actionButton.modelData.icon)
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === actionButton.index
                    onHovered: function(isHovered) {
                      if (isHovered) root.setCursor("actions", actionButton.index)
                    }
                    onClicked: root.launch(String(actionButton.modelData.id))
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "j/k move  ·  Enter act  ·  x remove  ·  r refresh  ·  Esc close"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
