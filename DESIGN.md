# A FIDO2 lock screen for Omarchy, as a plugin

Omarchy Quattro locks the session with a Quickshell plugin that speaks two PAM
services: a password and, when a sensor is enrolled, a fingerprint. There is no
third one for a security key. This repo adds it, as a drop-in plugin rather than
a patch to Omarchy, so it can be installed today and removed in one command.

Read this before changing anything here. It is the reasoning; the code is only
the conclusion.

---

## Part 1 — What is missing, and the trap next to it

`omarchy system lock` calls `omarchy-shell lock lock`, an IPC handler inside
`$OMARCHY_PATH/shell/plugins/lock/Service.qml`. That plugin authenticates
through `Quickshell.Services.Pam`:

```qml
PamContext { id: passwordPam;    config: "omarchy-lock-password" }
PamContext { id: fingerprintPam; config: "omarchy-lock-fingerprint" }
```

Two independent PAM services racing to unlock, one interactive and one
hands-off. That is exactly the shape a security key needs. There simply is no
third context, and `/etc/pam.d/omarchy-lock-password` contains `pam_faillock`
and `pam_unix` and nothing else.

**The shortcut to avoid.** The obvious move is to prepend `auth sufficient
pam_u2f.so` to `omarchy-lock-password` and change no QML. It appears to work,
because the plugin answers every prompt from the same buffer:

```qml
function respondToPasswordPrompt() {
  if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
  passwordPam.respond(pendingPassword)
}
```

Type the key's PIN and `pam_u2f` succeeds. Type your account password and
`pam_u2f` fails, `pam_unix` gets the same string, and you are in. Both paths
unlock, so it looks correct.

It is not. On the second path your account password was just spent as a PIN
attempt against the key, and `pin retries` went from 8 to 7. Eight
absent-minded unlocks and the authenticator locks itself out permanently: the
recovery is a factory reset that destroys every credential on it. A lock screen
that silently burns a finite, destructive budget on ordinary typos is not
something to ship.

So the design constraint that drives everything else: **a PIN is only ever sent
to the key when the user explicitly chose the key.** That means a separate PAM
service, a separate `PamContext`, and a visible mode in the UI.

## Part 2 — Why a plugin, and why that is not a compromise

Omarchy's plugin system is not an escape hatch here, it is the supported path.
`PluginRegistry.setEnabled()` reads `manifest.omarchy.clonedFrom` on *any*
third-party plugin, not only on folders produced by `omarchy plugin clone`:

- enabling `erijl.lock` adds `omarchy.lock` to `disabledPlugins[]` in
  `shell.json` and records a restore crumb in `cloneSourceRestores[]`
- disabling `erijl.lock` removes it from `plugins[]` **and** re-enables the
  built-in, undoing both edits
- `resolveEnabledId()` routes anything addressed to `omarchy.lock` to this
  plugin, and the `lock` IPC target moves with the service, so
  `omarchy system lock`, the idle daemon and `omarchy-shell lock status` all
  keep working with no caller changes

The install is therefore `omarchy plugin add <url> --enable` — a git clone, a
manifest validation, and one flipped bit over IPC. No sudo, no source edits,
nothing written outside `~/.config`. The uninstall is
`omarchy plugin remove erijl.lock`, which puts the stock lock screen back.

The one thing the plugin cannot do is write `/etc/pam.d/`. Plugin installs
never run code and never ask for privileges, by design. That step is a script
in `bin/`, run deliberately by the user, and it is the only part that touches
the system.

## Part 3 — The design

### The PAM service

```
auth       required    pam_u2f.so authfile=/etc/fido2/fido2 cue [cue_prompt=Touch your security key]
account    include     system-local-login
```

`required`, not `sufficient`, and with no `pam_unix` fallback: this service has
exactly one job, and the way back to a password is the UI's mode switch, not a
silent fall-through that would resurrect the retry-burning problem.

No `pam_faillock` either. The key already enforces its own attempt budget in
firmware; adding the account's lockout on top would mean a lost key can lock
the account as well.

Note what is *not* here: no `pinverification=1`. `pam_u2f` ORs the module option
with the per-credential flag, so setting it module-wide forces a PIN onto keys
registered without one. Verification requirements belong on the credential, in
`/etc/fido2/fido2`, where enrollment put them.

### Choosing the factor

The mode is settled once per lock, by `settleAuthMode()`, and never again by
anything except the user:

- a key enrolled and attached at lock time starts the screen in key mode
- otherwise the screen starts on the password, with the key still one Tab away
- a key plugged in *while* locked switches modes, unless a password is already
  half-typed or an attempt is in flight

The reason this is a function of state rather than of an edge: both facts
arrive from subprocesses that have not returned when `beginLock()` runs. An
earlier version keyed off a transition (`present && !wasPresent`) and therefore
never fired, because the key was already plugged in when the screen locked.

`defaultMode` in `shell.json` overrides the first rule: `auto` (default),
`password` to never auto-select the key, `security-key` to always start there
even with nothing plugged in.

### Gating the input

In key mode the field is inert until `pam_u2f` actually asks for something. It
is not merely disabled: it stays focused and readOnly, so it still receives
keystrokes, which is what makes the keyboard shortcuts below possible. A PIN
therefore cannot be typed into the void before the conversation starts, and can
never leak into the password flow.

Everything on screen in key mode is `pam_u2f`'s own text, rendered from the PAM
message rather than hardcoded — its PIN prompt when a response is required, its
touch cue when one is not. A key with no PIN (a stock Omarchy enrollment) never
produces the first message, so that flow is simply: plug in, touch, unlocked.

### Getting out

A failed key attempt does **not** auto-retry, unlike the fingerprint flow. Each
attempt may cost one of the eight PIN retries, so a retry is a deliberate act.
And the way back to the password is always on screen, because a key that is
lost, dead, or refusing its PIN must never be the only way into the session.

Three affordances, because a lock screen is the worst possible place to
discover that the only one you knew about does not apply:

| Input | In password mode | In key mode |
|---|---|---|
| `Tab` | switch to the key | switch to the password |
| a printable key, while the field is inert | — | switch to the password, keeping the character |
| `Enter` on an empty field | — | retry the key |

plus the pill under the field and the key glyph inside it, for the mouse.

## Part 4 — Fork drift, and what is done about it

This plugin is a fork of `omarchy.lock`. Omarchy's own clone warning applies:
overwritten code does not receive upstream fixes. That matters more here than
for a bar widget — the lock screen is a security boundary, and the built-in has
had real robustness work (stranded-lock recovery, screen stabilisation,
suspend-aware blanking) that a stale fork would miss.

Hiding from that is not an option, so the repo makes it mechanical instead.
`upstream/` holds pristine copies of the built-in's files at the exact revision
this fork was taken from, plus their hashes in `upstream/BASE`:

- `bin/omarchy-lock-fido2 doctor` compares those hashes against the installed
  `$OMARCHY_PATH/shell/plugins/lock/` and says plainly when upstream has moved
- `bin/omarchy-lock-fido2 rebase` runs a three-way `git merge-file` — fork,
  fork base, new upstream — so an upstream change arrives as a normal merge
  with conflict markers rather than as an invisible divergence

This is the strongest argument for getting the work upstream rather than
carrying it forever, which is the point of the plugin: it is a working proof to
point at, available to people now, while the upstream sequence proceeds.

## Part 5 — Scope

**In:** the lock screen, its PAM service, and a doctor that explains what is
wrong when the key does not work.

**Out, deliberately:**

- **Enrollment.** Writing credentials to `/etc/fido2/fido2` belongs to
  `omarchy setup security fido2`, and the fix that makes it work with
  `alwaysUv` authenticators is a separate upstream change. Duplicating it here
  would be a second copy of logic already in flight. The doctor diagnoses a
  missing or unusable credential precisely and names the remedy; it does not
  write one.
- **`sudo` and `polkit`.** Same enrollment story, different PAM files.
- **LUKS**, which is a different mechanism (`systemd-cryptenroll`, initramfs)
  and a different blast radius.

### The `alwaysUv` case, stated honestly

An authenticator that enforces CTAP 2.1 `alwaysUv` requires user verification
for every assertion, so unlocking becomes *type PIN, then touch*. That is not
fewer keystrokes than typing your password. What it buys is that the secret you
type at the lock screen is a device-bound PIN, worthless to anyone without the
physical key in their hand, instead of your account password. A security gain,
not a convenience one — worth knowing before installing.

On a key without `alwaysUv`, and with a credential registered without a PIN
requirement, it *is* a convenience gain: touch to unlock.

## Part 6 — Plan

1. `manifest.json` — id `erijl.lock`, `kinds: ["service"]`, `keepLoaded`,
   `omarchy.clonedFrom: "omarchy.lock"`, MIT, marketplace-required fields.
2. `Service.qml` / `LockView.qml` — the fork: third `PamContext`, mode state
   machine, key detection, gated input, keyboard affordances, `defaultMode`.
3. `upstream/` + `upstream/BASE` — fork provenance.
4. `bin/omarchy-lock-fido2` — `setup`, `remove`, `doctor`, `rebase`.
5. `test/all` — `omarchy plugin validate`, `qmllint` against the installed
   shell, JSON checks, upstream hash sanity.
6. `README.md`, `LICENSE` (MIT; the derived files are © David Heinemeier
   Hansson and stay so).
7. Install it the way a downloader would, and exercise it against real
   hardware: enrolled + attached, enrolled + unplugged, not enrolled, wrong
   PIN, cancelled touch, fallback to password.

## Status

**Designed. Nothing built yet.** This section gets rewritten with what was
actually built, what was verified against hardware, and what was left undone.
