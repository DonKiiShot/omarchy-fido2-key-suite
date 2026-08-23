# Lock Screen with FIDO2 Security Key

Unlock Omarchy Quattro with a FIDO2 security key. The built-in lock screen
speaks two PAM services — password and fingerprint — this adds a third for the
key, on its own service, with a visible mode switch.

```bash
omarchy plugin add https://github.com/Erijl/omarchy-fido2-lockscreen-plugin.git --enable
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-fido2-suite setup   # writes the PAM service
omarchy restart shell
```

Enabling it steps the built-in lock screen aside; `omarchy plugin remove
erijl.lock` puts it back. Credentials come from `/etc/fido2/fido2`, which
Omarchy's own *Setup → Security → Fido2* writes — no other tooling needed.

## Will it work with your key?

| Your authenticator | At the lock screen |
|---|---|
| No PIN required per assertion — most YubiKeys, Nitrokeys, SoloKeys as shipped | **Touch to unlock.** Works with a stock Omarchy enrollment. |
| CTAP 2.1 `alwaysUv` enforced — Token2, or any key you enabled it on | **PIN, then touch**, but only after enrolling by hand — see below. |

> **Disclaimer for `alwaysUv` keys.** Such a key refuses any assertion without
> user verification, and `pamu2fcfg` records that requirement *on the
> credential*. Omarchy's setup command passes no flags, so a stock enrollment
> produces a presence-only credential your key rejects before it ever lights up
> — the unlock fails without a blink. That is an enrollment gap this plugin
> cannot fix from the lock screen; a fix is in flight upstream. Until then:
>
> ```bash
> cred=$(pamu2fcfg -N -n)                              # touch + PIN
> sudo sed -i "s|^$USER:.*|&$cred|" /etc/fido2/fido2   # adds to your line
> ```
>
> `doctor` (below) detects this mismatch and prints the right command for your
> case. And plainly: on an `alwaysUv` key, unlocking is *PIN, then touch* — not
> fewer keystrokes than your password. What it buys is that the secret you type
> is a device-bound PIN, worthless without the key in hand. A security gain,
> not a convenience one.

## Using it

Starts on the key when one is enrolled and plugged in, on the password
otherwise. A key plugged in while locked switches modes, unless you have
started typing.

| Input | Password mode | Key mode |
|---|---|---|
| `Tab`, or the pill under the field | switch to the key | switch to the password |
| `Enter` on an empty field | — | try the key again |
| the key glyph in the field | switch to the key | try again |

In key mode the field is inert until `pam_u2f` asks for a PIN, so a PIN cannot
be typed into the void or leak into the password flow. A failed attempt never
retries by itself — each one can cost one of the key's PIN retries.

Optional `"defaultMode"` on this plugin's entry in `shell.json`: `auto`
(default), `password` to never start on the key, `security-key` to always.

## Why the key gets its own PAM service

The shortcut is `auth sufficient pam_u2f.so` in `omarchy-lock-password`, with
no code changes. It appears to work: the lock plugin answers every PAM prompt
from the same buffer, so your PIN satisfies `pam_u2f`, while your password
fails `pam_u2f` and then satisfies `pam_unix`. Both unlock.

But on that second path your password was just spent as a PIN attempt, and the
key's retry counter went 8 → 7. Eight absent-minded unlocks and the key locks
itself out permanently — recovery is a factory reset that destroys every
credential on it. Hence its own service, its own `PamContext`, and an explicit
mode: a PIN is only ever sent when you asked for the key.

```
auth       required    pam_u2f.so authfile=/etc/fido2/fido2 cue [cue_prompt=Touch your security key]
account    include     system-local-login
```

`required` with no `pam_unix` fallback — the way back to a password is the mode
switch, not a silent fall-through. No `pinverification=1`: that module option
is ORed with the per-credential flag, so it would force a PIN onto keys
enrolled without one.

## When it does not work

```bash
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-fido2-suite doctor
```

Checks the whole chain — plugin enabled, the right lock service running, PAM,
credentials, file ownership, what your attached key reports, and whether
Omarchy's built-in lock plugin has moved since this fork. Every failure names
its own fix. `remove` drops the PAM service; `omarchy plugin remove erijl.lock`
restores the built-in lock screen.

## Maintaining it

A fork of `omarchy.lock`, so upstream fixes do not arrive by themselves.
`upstream/` holds the built-in's files at the forked revision plus their
hashes, making drift a hash compare and a re-base a three-way merge:

```bash
bin/omarchy-fido2-suite doctor   # says when the built-in has moved
bin/omarchy-fido2-suite rebase   # merge onto the new built-in
./test/all                      # manifest, qmllint, fork-base checks
```

**Run `omarchy restart shell` after any `omarchy plugin update`.** The shell
hot-reloads a plugin's entry point but keeps the compiled component for its
other files, so an updated `LockView.qml` goes on drawing the old version — with
a log line claiming it reloaded, and no error anywhere.

`Service.qml` and `LockView.qml` are derived from Omarchy's built-in lock
plugin, © David Heinemeier Hansson, MIT; the FIDO2 additions are MIT too.
See [LICENSE](LICENSE).
