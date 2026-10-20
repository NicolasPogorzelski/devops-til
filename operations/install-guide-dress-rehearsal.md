# Dress Rehearsal of an Install Guide: Following It Literally

## What happened

The application project's `install.md` promises one linear path from an empty
workstation and an empty server to a working stack (reverse proxy, lldap,
GitLab, OpenProject, XWiki, encrypted backup). The evening before it was to be
followed together with a reviewer, it was run once more, literally, on a fresh
Debian 13 server and a workstation that had never run it - typed by hand,
with a second pair of eyes reading a live terminal recording (`script -f`).

Sections 1 to 5.16 passed in about three and a half hours, including
questions and repairs. A clean run would take roughly two. Every failure on
the way belonged to one of a few classes, and none of them produced an error
at the moment it happened.

## The failure classes

| Class | What happened | Why it was silent |
|---|---|---|
| Write to the wrong target | `echo … \| sudo tee -a /srv/xwiki/da` - the path was cut off when the line was selected in a GitHub code block that scrolls sideways | `tee` creates the file it is given and prints what it wrote; the output looked right, the config file was untouched |
| First match wins | `Host lab` appended to `~/.ssh/config` behind an older `Host lab` would have kept `ssh lab` on the old server | `ssh` uses the first matching block and does not warn about a second one |
| Placeholder left in | `install -o <admin> …`, `scp lab:…/<stamp>.tar.age` | the shell reads `<admin` as an input redirection: `admin: No such file or directory`, and the command never runs |
| Wrong machine | two `# workstation` checks run in the server shell returned `000` | the names exist only in the workstation's `/etc/hosts`; `curl -s` hides "could not resolve" |
| Half a step | the backup key was generated on the workstation, but the host's recipient file was never replaced | the backup ran, `==> done`, a normal-looking `.tar.age` - encrypted to the reference build's key |
| Same name, other key | the browser showed "invalid signature" after the CA import | it still resolved the hostname to the previous server, whose CA has the same subject; the issuer is looked up by name |
| Tool missing on this distro | `docker --version` on Fedora, `script` not in the base install | the guide's check block ends with a command the distro does not have |

## Why it matters

The common pattern: **the output of a command is not evidence of its
effect.** `tee`, `>`, `install` and `echo` all report success whether they wrote
where you meant or somewhere new. What proves a step is a read of the target
afterwards - `grep` for the line, `ls -l` for the mode, `getent` for the name,
and, for the backup, a real decryption on the workstation. Section 5.16 of the
guide exists for exactly this: the first backup passed every visible check and
failed only when it was opened.

A test that can fail is worth more than one that cannot. The decryption test
failed for the right reason (`no identity matched any of the recipients`),
which is what told the operator that 4.1 was incomplete.

## Doing it right

- **Copy with the code block's copy button**, not with the mouse. It takes the
  whole block, including what is scrolled out of view.
- **Read the prompt before Enter.** `user@workstation` and `user@host` look
  alike; every block in the guide starts with `# workstation` or `# host` for
  this reason.
- **Verify the target, not the output** - after every write, the check the
  guide lists (`cat`, `grep -n '^key'`, `ls -l`, `getent hosts`).
- **`000` from curl against `*.lab.test` means "am I on the workstation?"**
  before anything else.
- **Start the workstation empty.** Leftovers from a rehearsal break the next
  run: an existing clone stops `git clone`, an existing `ca.key` stops
  `make-ca.sh`, an old SSH alias wins over the new one, an old CA with the
  same name confuses the browser.

Findings for the guide itself, proposed rather than applied: wrap long
commands with `\` so no line scrolls; recommend the copy button in "How to
read this guide"; make the host half of 4.1 impossible to overlook; say which
branch the clone is meant to check out.

## Related

- [umask Is Shell State](../linux/umask-shell-state.md) - why `.env` files are
  created with `install -m 600 /dev/null` first
- [Runbook Methodology](runbook-methodology.md) - verification log and
  layer-by-layer checks
- Glossary: [shell redirection](../glossary.md#shell-redirection---and-sudo-tee),
  [HTTP status codes](../glossary.md#http-status-codes-and-curls-000),
  [age](../glossary.md#age-file-encryption-and-recipients),
  [CA and trust store](../glossary.md#ca-certificate-authority-and-trust-store),
  [session cookie](../glossary.md#session-cookie-and-private-windows)
