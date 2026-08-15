# Lock Screen + Security Key

An Omarchy Quattro lock screen that can unlock with a FIDO2 security key.

Omarchy's built-in lock screen speaks two PAM services: your password, and your
fingerprint if you have one enrolled. This plugin adds a third for a security
key, on its own PAM service, with a visible mode switch — so a mistyped
password is never sent to your key as a PIN attempt.

```bash
omarchy plugin add https://github.com/Erijl/omarchy-fido2-lockscreen-plugin.git --enable
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-lock-fido2 setup
omarchy restart shell
```

That is the whole install. Enabling the plugin steps the built-in lock screen
aside; `omarchy plugin remove erijl.lock` puts it back exactly as it was.

## What you get

- **Touch to unlock**, if your key holds a credential registered without a PIN
  requirement — which is what `omarchy setup security fido2` produces.
- **PIN, then touch**, if your key or your credential requires user
  verification (see [the `alwaysUv` note](#a-word-to-alwaysuv-owners)).
- The screen **starts on the key** when one is enrolled and plugged in, and on
  the password otherwise. Plug a key in while locked and it switches, unless
  you have already started typing.
- The password is **always one keystroke away**. A key that is lost, dead, or
  refusing its PIN must never be the only way into your session.

## Requirements

| | |
|---|---|
| Omarchy | Quattro (4.x), which locks with the Quickshell `omarchy.lock` plugin |
| Packages | `pam-u2f`, `libfido2` — `sudo pacman -S --needed pam-u2f libfido2` |
| A credential | at least one key enrolled in `/etc/fido2/fido2` for your user |

If you have never enrolled a key, do that first with Omarchy's own setup
(*Setup → Security → Fido2*, or `omarchy setup security fido2`). This plugin
deliberately does not enroll keys — see [Scope](#scope).

## Using it

| Input | Password mode | Key mode |
|---|---|---|
| `Tab` | switch to the key | switch to the password |
| type a letter, while the key is waiting | — | switch to the password, keeping the character |
| `Enter` on an empty field | — | try the key again |
| the pill under the field | switch to the key | switch to the password |
| the key glyph inside the field | switch to the key | try again |

While the key is waiting, the field is inert: it does not accept text until
`pam_u2f` actually asks for a PIN. So a PIN cannot be typed into the void, and
cannot leak into the password flow.

A failed key attempt does **not** retry by itself, unlike the fingerprint flow.
Each attempt can cost one of the key's PIN retries, so retrying is deliberate.

## Settings

Optional, in `~/.config/omarchy/shell.json`, on this plugin's own entry:

```json
{ "plugins": [ { "id": "erijl.lock", "defaultMode": "auto" } ] }
```

| `defaultMode` | Behaviour |
|---|---|
| `auto` *(default)* | start on the key when one is enrolled and attached |
| `password` | never start on the key; `Tab` still gets you there |
| `security-key` | always start on the key, and say so when none is attached |

## When it does not work

```bash
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-lock-fido2 doctor
```

It checks every link in the chain — the plugin is installed and enabled, the
running shell is actually this one, the PAM service is present and sane, a
credential exists for your user, the file is owned by root, what your attached
authenticator reports, and whether Omarchy's built-in lock plugin has changed
since this fork was taken. Each failure names its own fix.

The single most common one it catches: a key that enforces `alwaysUv` against a
credential registered without PIN verification. `pam_u2f` then asks for an
assertion with verification off, the key refuses it before it ever lights up,
and the unlock fails without a single blink.

## Why the key gets its own PAM service

The shortcut is to add `auth sufficient pam_u2f.so` to `omarchy-lock-password`
and change no code. It appears to work: the built-in plugin answers every PAM
prompt from the same buffer, so typing your PIN satisfies `pam_u2f`, and typing
your password fails `pam_u2f` and then satisfies `pam_unix`. Both unlock.

But on that second path your account password was just spent as a PIN attempt,
and the key's retry counter went from 8 to 7. Eight absent-minded unlocks and
the authenticator locks itself out permanently — recovery is a factory reset
that destroys every credential on it.

So this plugin gives the key its own service, `/etc/pam.d/omarchy-lock-fido2`,
its own `PamContext`, and an explicit mode in the UI. A PIN is only ever sent
to the key when you asked for the key. That constraint is the reason the plugin
exists at all, rather than a PAM one-liner.

The service it writes:

```
auth       required    pam_u2f.so authfile=/etc/fido2/fido2 cue [cue_prompt=Touch your security key]
account    include     system-local-login
```

`required`, with no `pam_unix` fallback, and no `pinverification=1` — that
module option is ORed with the per-credential flag, so setting it would force a
PIN onto keys registered without one.

## A word to `alwaysUv` owners

An authenticator that enforces CTAP 2.1 `alwaysUv` requires user verification
for every assertion, so unlocking is *type PIN, then touch*. That is not fewer
keystrokes than typing your password.

What it buys is that the secret you type at the lock screen is a device-bound
PIN, worthless to anyone without the physical key, instead of your account
password. A security gain, not a convenience one. Worth knowing before you
install it.

## Scope

**In:** the lock screen and its PAM service.

**Out:** enrolling credentials, and `sudo` / `polkit` / LUKS. Enrollment
belongs to Omarchy's own setup command, and making it record the right
verification flags for `alwaysUv` authenticators is a change in flight
upstream. Duplicating it here would be a second copy of the same logic. The
doctor diagnoses a bad or missing credential precisely; it does not write one.

## Staying current with Omarchy

This is a fork of `omarchy.lock`, so it does not automatically receive upstream
fixes to the lock screen. That is a real cost — the lock screen is a security
boundary, and the built-in has had genuine robustness work.

The fork's base is therefore kept in `upstream/`: pristine copies of Omarchy's
files at the revision this was taken from, plus their hashes in `upstream/BASE`.

```bash
bin/omarchy-lock-fido2 doctor    # says plainly when the built-in has moved
bin/omarchy-lock-fido2 rebase    # three-way merge onto the new built-in
./test/all                       # manifest, qmllint, and fork-base checks
```

Worth doing after any `omarchy update` that touches the lock plugin. The real
fix is upstreaming the feature; until then this keeps the gap visible instead
of silent.

## Uninstall

```bash
omarchy plugin remove erijl.lock                                  # built-in lock screen returns
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-lock-fido2 remove  # if it still exists: drop the PAM service
```

`omarchy plugin remove` also re-enables `omarchy.lock` in `shell.json`, so the
uninstall leaves no trace of this plugin behind.

## Credits

`Service.qml` and `LockView.qml` are derived from Omarchy's built-in lock
plugin, © David Heinemeier Hansson, MIT. The FIDO2 additions are MIT too. See
[LICENSE](LICENSE), and [DESIGN.md](DESIGN.md) for why every piece is the way it is.
