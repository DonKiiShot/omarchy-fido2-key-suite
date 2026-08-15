import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Inline settings come from this plugin's own entry in shell.json --
  // `{ "id": "erijl.lock", "defaultMode": "security-key" }` -- which is where
  // the shell puts per-plugin configuration. shellConfig is reassigned on
  // reload, so this re-evaluates when the user edits the file.
  readonly property var settings: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    var id = manifest && manifest.id ? String(manifest.id) : "erijl.lock"
    var entries = config && Array.isArray(config.plugins) ? config.plugins : []

    for (var i = 0; i < entries.length; i++) {
      if (entries[i] && String(entries[i].id) === id) return entries[i]
    }
    return ({})
  }

  // "auto" starts on the key when one is enrolled and attached, "password"
  // never auto-selects it, "security-key" always does. Anything else is a typo
  // in shell.json and is treated as the default rather than as an instruction.
  readonly property string defaultMode: {
    var mode = String(settings.defaultMode || "auto")
    return ["auto", "password", "security-key"].indexOf(mode) !== -1 ? mode : "auto"
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  // FIDO2 is a third, explicitly-chosen flow rather than another `sufficient`
  // line inside omarchy-lock-password. Sharing the password service would
  // forward every mistyped password to the key as a PIN attempt, and a key has
  // only eight of those before it locks itself out and needs a factory reset
  // that destroys every credential on it. Separate services make it impossible
  // to spend a retry unless the user actually asked for the key.
  property string authMode: "password" // "password" | "fido2"
  property bool fido2PamConfigured: false
  property bool fido2Enrolled: false
  property bool fido2TokenPresent: false
  property bool fido2Authenticating: false
  property bool fido2NeedsPin: false
  property string fido2Status: ""
  property string pendingFido2Pin: ""
  // The factor is picked once per lock, then left alone. Without this the
  // auto-selection would fight the user every time a check re-ran.
  property bool authModeSettled: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating || fido2Authenticating
  readonly property bool fido2Configured: fido2PamConfigured && fido2Enrolled
  readonly property bool fido2Active: authMode === "fido2"

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function refreshFido2Status() {
    if (!fido2CheckProc.running) fido2CheckProc.running = true
  }

  // Presence is polled rather than watched: a key can be plugged in at any
  // point while the screen is locked, and the answer decides whether the UI
  // offers the key or says there is none to offer.
  function refreshFido2Token() {
    if (!fido2DetectProc.running) fido2DetectProc.running = true
  }

  // Pick the factor once per lock: by default the key if one is enrolled and
  // plugged in, the password otherwise. Driven from the check processes rather
  // than from beginLock(), because neither answer is known yet at the moment
  // the lock is requested -- both are subprocesses that have not returned.
  function settleAuthMode() {
    if (authModeSettled || !locked) return
    if (defaultMode === "password") return
    if (!fido2Configured) return
    // "security-key" means start there and say so when nothing is plugged in,
    // rather than quietly landing on the password.
    if (!fido2TokenPresent && defaultMode !== "security-key") return
    if (authenticatingPassword || enteredPassword.length > 0) return

    setAuthMode("fido2")
  }

  function setAuthMode(mode) {
    // Any deliberate choice -- by the user or by settleAuthMode -- ends the
    // auto-selection for this lock. A key plugged in later must never yank the
    // field out from under someone already typing their password.
    authModeSettled = true

    if (authMode === mode) return
    if (mode === "fido2" && !fido2Configured) return

    // Never leave a half-finished conversation behind when switching away.
    if (authMode === "fido2") abortFido2()
    else if (passwordPam.active) passwordPam.abort()

    authMode = mode
    failureMessage = ""
    enteredPassword = ""
    pendingPassword = ""
    logEvent("auth-mode=" + mode)

    if (mode === "fido2") {
      refreshFido2Token()
      startFido2()
    }
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
    abortFido2()
    authMode = "password"
    authModeSettled = false
  }

  function abortFido2() {
    fido2Authenticating = false
    fido2NeedsPin = false
    fido2Status = ""
    pendingFido2Pin = ""
    if (fido2Pam.active) fido2Pam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
      root.refreshFido2Token()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  function startFido2() {
    // Wait for the lock surface, exactly as startFingerprint does. Beginning a
    // conversation that can succeed before the screen is actually up would let
    // finishUnlock fire against a lock that never became secure.
    if (!lockRequested || !sessionLock.secure) return
    if (!fido2Active || !fido2Configured) return
    if (fido2Pam.active || fido2Authenticating) return
    if (!fido2TokenPresent) {
      fido2Status = "No security key detected"
      return
    }

    runWake()
    fido2NeedsPin = false
    pendingFido2Pin = ""
    fido2Status = "Waiting for your security key…"
    fido2Authenticating = true

    if (!fido2Pam.start()) {
      fido2Authenticating = false
      fido2Status = "Could not start security key check"
    }
  }

  // pam_u2f drives the conversation: it asks for the PIN with a prompt that
  // requires a response, and announces the touch with an informational message
  // that does not. Rendering whichever arrives keeps the UI honest without
  // hardcoding the module's wording or its ordering.
  function handleFido2Message() {
    if (!fido2Authenticating) return
    runWake()

    var text = String(fido2Pam.message || "")

    if (fido2Pam.responseRequired) {
      fido2NeedsPin = true
      fido2Status = text.length > 0 ? text : "Enter your security key PIN"
      // A PIN typed before the prompt arrived is still valid; send it now
      // rather than making the user type it twice.
      if (pendingFido2Pin.length > 0) submitFido2Pin(pendingFido2Pin)
      return
    }

    fido2NeedsPin = false
    if (text.length > 0) fido2Status = text
  }

  function submitFido2Pin(pin) {
    var value = String(pin || "")
    if (!fido2Active || value.length === 0) return

    pendingFido2Pin = value
    if (!fido2Pam.active || !fido2Pam.responseRequired) return

    fido2Pam.respond(value)
    pendingFido2Pin = ""
    fido2NeedsPin = false
    enteredPassword = ""
    fido2Status = "Checking…"
  }

  function handleFido2Finished(result) {
    fido2Authenticating = false
    fido2NeedsPin = false
    pendingFido2Pin = ""
    enteredPassword = ""

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
      return
    }

    // Deliberately no auto-retry, unlike the fingerprint flow. Every failed
    // attempt here may have cost one of the key's PIN retries, so restarting
    // is the user's call.
    failedAttempts += 1
    failureMessage = "Security key failed (" + failedAttempts + ")"
    fido2Status = ""
    runWake()
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
        root.startFido2()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        passwordText: root.enteredPassword
        fido2Configured: root.fido2Configured
        fido2Active: root.fido2Active
        fido2TokenPresent: root.fido2TokenPresent
        fido2NeedsPin: root.fido2NeedsPin
        fido2Status: root.fido2Status
        fido2Authenticating: root.fido2Authenticating
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onSubmitFido2Pin: function(pin) { root.submitFido2Pin(pin) }
        onToggleAuthMode: root.setAuthMode(root.fido2Active ? "password" : "fido2")
        onRetryFido2Requested: root.startFido2()
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
      fido2Configured: root.fido2Configured
      fido2Active: false
      fido2TokenPresent: root.fido2TokenPresent
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  PamContext {
    id: fido2Pam
    config: "omarchy-lock-fido2"
    user: root.userName

    onResponseRequiredChanged: root.handleFido2Message()
    onPamMessage: root.handleFido2Message()

    onCompleted: function(result) {
      root.handleFido2Finished(result)
    }

    onError: function(error) {
      root.handleFido2Finished(PamResult.Error)
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  // Only while the key is actually being offered: a key plugged in mid-lock
  // should light the UI up, but polling a hidraw enumeration forever behind a
  // password prompt nobody is looking at is pure waste.
  Timer {
    id: fido2DetectTimer
    interval: 2000
    repeat: true
    running: root.locked && root.fido2Configured
    onTriggered: root.refreshFido2Token()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  // Enrollment is read straight from the mapping file rather than by shelling
  // out to a helper, so the lock screen keeps working even where none is
  // installed. The file is world-readable by design (it holds a credential id
  // and a public key), which is what lets this run as the user.
  //
  // The two halves are reported separately -- "pam" without "enrolled" is a
  // wired-up service with no credential, the reverse is a credential with no
  // service -- because "it does not offer the key" is otherwise unanswerable
  // from `omarchy-shell lock status` alone.
  Process {
    id: fido2CheckProc
    command: ["bash", "-c",
      "pam=no; enrolled=no; "
      + "[[ -f /etc/pam.d/omarchy-lock-fido2 ]] && pam=yes; "
      + "grep -q \"^$USER:\" /etc/fido2/fido2 2>/dev/null && enrolled=yes; "
      + "echo \"$pam $enrolled\""]
    stdout: StdioCollector { id: fido2CheckStdout; waitForEnd: true }
    onExited: {
      var answer = String(fido2CheckStdout.text || "").trim().split(/\s+/)
      root.fido2PamConfigured = answer[0] === "yes"
      root.fido2Enrolled = answer[1] === "yes"
      if (!root.fido2Configured && root.fido2Active) root.setAuthMode("password")
      else root.settleAuthMode()
    }
  }

  Process {
    id: fido2DetectProc
    command: ["bash", "-c", "fido2-token -L 2>/dev/null | grep -q . && echo yes || echo no"]
    stdout: StdioCollector { id: fido2DetectStdout; waitForEnd: true }
    onExited: {
      var present = String(fido2DetectStdout.text || "").trim() === "yes"
      root.fido2TokenPresent = present

      if (!present) {
        if (root.fido2Active) {
          root.abortFido2()
          root.fido2Status = "No security key detected"
        }
        return
      }

      if (!root.locked || !root.fido2Configured) return

      // Already on the key: pick the conversation up now that one is attached.
      // Otherwise let settleAuthMode decide, which covers both a key present at
      // lock time and one plugged in later.
      if (root.fido2Active) {
        if (!root.fido2Authenticating) root.startFido2()
      } else {
        root.settleAuthMode()
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  // Enrolling or removing a key rewires PAM, so re-ask instead of trusting an
  // answer taken at shell start.
  FileView {
    path: "/etc/fido2/fido2"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshFido2Status()
    onLoadFailed: {
      root.fido2Enrolled = false
      if (root.fido2Active) root.setAuthMode("password")
    }
    onFileChanged: reload()
  }

  // Watched for the same reason, and so that running `omarchy-lock-fido2 setup`
  // takes effect on the running shell rather than at the next restart.
  FileView {
    path: "/etc/pam.d/omarchy-lock-fido2"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshFido2Status()
    onLoadFailed: {
      root.fido2PamConfigured = false
      if (root.fido2Active) root.setAuthMode("password")
    }
    onFileChanged: reload()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    refreshFido2Status()
    refreshFido2Token()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        fido2: root.fido2Configured,
        fido2Pam: root.fido2PamConfigured,
        fido2Enrolled: root.fido2Enrolled,
        fido2Token: root.fido2TokenPresent,
        authMode: root.authMode,
        authModeSettled: root.authModeSettled,
        defaultMode: root.defaultMode,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFido2Status()
      root.refreshFido2Token()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
