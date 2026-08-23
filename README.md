# FIDO2 Security Key Suite

One security key for the whole Omarchy machine: the lock screen, `sudo` and
polkit, your SSH keys and commit signatures — enrolled once, managed from a
panel in the shell.

<img src="preview.png" alt="The management panel" width="560">

## What it does

| | |
|---|---|
| Lock screen | Unlock with the key: touch, or PIN + touch where the key demands it. The password stays one `Tab` away. |
| `sudo` and polkit | A touch on the key instead of a typed password. |
| Management panel | Enrolled credentials, the attached key and its PIN retries, what the key unlocks, settings. |
| Bar widget | The key glyph, lit while a key is attached. Click opens the panel. |
| Lock on unplug | Opt-in: pulling the key out locks the session. |
| SSH keys | `ed25519-sk` keys whose private half lives on the authenticator, plus the commit-signing config. |
| Doctor | Checks every link in the chain and names each fix. |

Works with any FIDO2/U2F authenticator (YubiKey, Token2, Nitrokey, SoloKeys)
via `pam_u2f` — including CTAP 2.1 keys that enforce `alwaysUv`, which the
stock Omarchy flow cannot enroll correctly.

## Install

```bash
sudo pacman -S --needed pam-u2f libfido2
omarchy plugin add https://github.com/Erijl/omarchy-fido2-key-suite.git --enable
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-fido2-suite enroll
omarchy restart shell
```

`enroll` registers the key, writes the lock screen's PAM service, and offers
to put the key in front of `sudo` and polkit too. Enroll a second key while
you still have the first — losing your only credential takes all three with
it.

To remove: `omarchy plugin remove erijl.lock` puts the built-in lock screen
back; run `bin/omarchy-fido2-suite disable` first if you also want PAM
unwired.

## Use it

- **Panel** — click the key glyph on the bar, or
  `omarchy-shell shell summon erijl.lock '{}'`. Its buttons launch the
  commands below in a floating terminal; the shell itself never runs anything
  privileged, and never talks to the key.
- **Lock screen** — starts on the key when one is enrolled and plugged in.
  `Tab` or the pill under the field switches between key and password;
  `Enter` on an empty field tries the key again.
- **Command line** — everything the panel does is a command, and every
  command works on its own:

| Command | |
|---|---|
| `enroll [label]` | register a key (only one attached at a time) |
| `list` / `remove [n]` | what is enrolled; drop one credential |
| `enable` / `disable` | wire the key into `sudo` and polkit, or unwire it |
| `ssh [name] [--resident]` | mint an SSH key held on the authenticator |
| `repair` | fix an installation the stock Omarchy flow made |
| `doctor` | check every link in the chain and name each fix |

---

## The pieces, in detail

### Will it work with your key?

| Your authenticator | At the lock screen |
|---|---|
| No PIN required per assertion — most YubiKeys, Nitrokeys, SoloKeys as shipped | **Touch to unlock.** |
| CTAP 2.1 `alwaysUv` enforced — Token2, or any key you enabled it on | **PIN, then touch.** |

`enroll` reads what the key says about itself and records the matching
verification on the credential, so an `alwaysUv` key gets one it can actually
satisfy. Omarchy's own *Setup → Security → Fido2* passes no flags, which
produces a presence-only credential such a key rejects before it ever blinks;
`repair` fixes an installation made that way, and `doctor` says when you have
one.

And plainly: on an `alwaysUv` key, unlocking is *PIN, then touch* — not fewer
keystrokes than your password. What it buys is that the secret you type is a
device-bound PIN, worthless without the key in hand. A security gain, not a
convenience one.

### The panel and the bar widget

The panel shows the attached authenticator and the PIN attempts it has left,
every enrolled credential with its flags and enrolment date, and which of the
lock screen, `sudo` and polkit the key currently unlocks. Actions open a
floating terminal running `bin/omarchy-fido2-suite`, the same idiom Omarchy's
own Setup → Security entries use — you see the command, answer its prompts,
and type your own sudo password.

The bar widget is the same key glyph the lock screen uses: lit while a key is
attached, dim while none is, click to open the panel. `omarchy bar put
erijl.lock` adds it to an installation that predates it.

### When the key comes and goes

Two settings on this plugin's entry in `shell.json`, both off by default and
both toggleable from the panel:

| Setting | What it does |
|---|---|
| `"lockOnUnplug": true` | Locks the session the moment the key leaves the machine. |
| `"notifyOnKeyChange": true` | A notification when the key comes and goes. |

Either one — or the bar widget being on the bar — keeps the service watching
for the key while the session is unlocked; with all three off it only looks
while the lock screen is up, which is the only time it otherwise needs to know.

An unplug has to be seen twice before it counts. A key busy answering an
enrollment in a terminal can miss one enumeration, and that must not lock the
screen under you mid-PIN.

### SSH keys held on the key

`ssh [name]` mints an `ed25519-sk` key whose private half never leaves the
authenticator, then prints the three `git config` lines that sign your
commits with it. A resident key (`--resident`, or answer yes when asked) is
stored on the authenticator itself and can be pulled back out on another
machine with `ssh-keygen -K`; it costs one of the key's resident slots.

The same reading of the key's own CTAP options applies here: a key that
mandates user verification gets `verify-required` recorded on the credential,
so `ssh` never hands it an assertion it refuses.

### Using the lock screen

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

Optional `"defaultMode"` on the same `shell.json` entry: `auto` (default),
`password` to never start on the key, `security-key` to always.

### Why the key gets its own PAM service

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

### When it does not work

```bash
~/.config/omarchy/plugins/erijl.lock/bin/omarchy-fido2-suite doctor
```

Checks the whole chain — which lock service is actually running, the plugin's
surfaces, PAM, credentials, file ownership, what your attached key reports,
your SSH keys, and whether Omarchy's built-in lock plugin has moved since this
fork. Every failure names its own fix.

### Maintaining it

The lock screen is a fork of `omarchy.lock` (declared via the manifest's
`clonedFrom`, so enabling this plugin steps the built-in aside), and upstream
fixes do not arrive by themselves. `upstream/` holds the built-in's files at
the forked revision plus their hashes, making drift a hash compare and a
re-base a three-way merge:

```bash
bin/omarchy-fido2-suite doctor   # says when the built-in has moved
bin/omarchy-fido2-suite rebase   # merge onto the new built-in
./test/all                       # manifest, qmllint, behaviour, fork base
```

**Run `omarchy restart shell` after any `omarchy plugin update`.** The shell
hot-reloads a plugin's entry point but keeps the compiled component for its
other files, so an updated `LockView.qml` goes on drawing the old version —
with a log line claiming it reloaded, and no error anywhere.

## License

`Service.qml` and `LockView.qml` are derived from Omarchy's built-in lock
plugin, © David Heinemeier Hansson, MIT; the FIDO2 additions are MIT too.
See [LICENSE](LICENSE).
