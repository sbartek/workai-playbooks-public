# workai-secret

One place for local secrets, the same command on every machine (card 01-146).
Instead of `.env` files, token files, keys on command lines and Claude allow
rules, a secret lives in the machine's own store and is read when needed.

```
workai-secret set myapp/database-url      # value from stdin or a hidden prompt, never argv
workai-secret get myapp/database-url      # print it (--copy: to the clipboard)
workai-secret list                             # names only
workai-secret rm myapp/database-url
workai-secret run -- python app.py             # every secret as an env var, no .env file
workai-secret run --only youtrack/api -- cmd   # only these
workai-secret backend                          # which store, and why
```

Installed into `~/.local/bin` by `install.sh claude` (or `--tools-only`).

## Where the values live

| Machine | Store | Chosen when |
|---|---|---|
| macOS | login keychain, service `workai/<name>`, account `workai` | always on macOS |
| Linux desktop | Secret Service (GNOME Keyring, KWallet) via `secret-tool`, attributes `app=workai name=<name>` | a D-Bus session with a Secret Service |
| Linux server or container | `pass`: one GPG file per secret in `~/.password-store/workai/` | otherwise, if `pass` is installed |
| systemd services | `systemd-creds`, encrypted to the host key | `workai-secret export-systemd <name> <unit>` |

`WORKAI_SECRET_BACKEND=keychain|secret-tool|pass` forces one.

Setting up `pass` on a headless box (once):
```
gpg --quick-gen-key "you <you@example.com>"    # or import an existing key
pass init you@example.com
```
`gpg-agent` then asks for the passphrase once per session.

For a cron or systemd job nobody unlocks a keyring, so give the unit an
encrypted credential instead:
```
sudo workai-secret export-systemd myapp/database-url factory-api.service
# then in the unit: LoadCredentialEncrypted=myapp-database-url:/etc/credstore.encrypted/myapp-database-url
# the service reads $CREDENTIALS_DIRECTORY/myapp-database-url
```
Root on that host can decrypt it; that is the protection, no more.

## Rules

- **Names**: lower case, digits and `. _ - /`, e.g. `cloudflare/games`.
- **Values**: one line of printable ASCII (a trailing newline from stdin is
  dropped). The macOS keychain returns other bytes as hex, so they are
  refused everywhere instead of behaving differently per machine.
- A value never goes into argv: the keychain is written through
  `security -i` on stdin (as hex), `secret-tool store` and `pass insert`
  read stdin. `tests/test-workai-secret.sh` checks this with a canary value
  against fake backends, and fails if the canary shows up in any argv or
  output.
- `run` names the variable after the secret in upper snake case
  (`myapp/database-url` -> `MYAPP_DATABASE_URL`); `env-map` (names
  only) overrides that, e.g. `myapp/database-url DATABASE_URL`.
- A variable set by `run` is visible to the child process and to the same
  user (`ps eww`, `/proc/<pid>/environ`). That is the trade against a `.env`
  file on disk.
- `get` prints the value: it is for scripts and pipes. Do not run it where
  the output lands in a log or an agent transcript; prefer `run` or `--copy`.
