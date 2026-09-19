# umask Is Shell State, Not a Per-Command Option

## What happened

To create an `.env` file with mode 600 in one line, the command was
`umask 077 && printf '...' > .env`. It worked. An hour later, in the same
interactive shell, `git switch`/`git pull` updated the repository clone on
the host — and every file git (re)wrote came out as mode `600`, including a
`Caddyfile` that is bind-mounted into the reverse-proxy container. The proxy
runs as an unprivileged UID inside the container; the file belongs to the
admin user, an *unmapped* UID under `userns-remap`, so the container saw it
as `nobody` with no read bit. Result after the next `docker compose restart
caddy`: a restart loop with `open /etc/caddy/Caddyfile: permission denied`,
and every hostname behind the proxy refused connections.

## Why

`umask` sets a mask on the calling **process** — the shell — and every
child inherits it. `umask 077 && cmd` is not "run `cmd` with umask 077"; it
is "change the shell's umask, then run `cmd`". Nothing resets it afterwards.
`umask` belongs to the same family as `cd`, `export`, `set -e`, `ulimit`:
state that outlives the line it was typed on.

Diagnosis path that found it: proxy log → `ls -l` on the mounted file (600)
→ `find <clone> -type f ! -perm -o=r` (every file git touched after a
certain time) → `umask` in a fresh login shell (0002) versus the working
shell (077).

## Doing it right

Create the file with the intended mode first, then write into it — no shell
state involved and no window in which the file is world-readable:

```bash
install -m 600 /dev/null .env && printf 'KEY=%s\n' "$(openssl rand -hex 32)" > .env
```

`install -m 600 /dev/null .env` copies the empty `/dev/null` to `.env` and
sets the mode atomically at creation. Equivalent alternatives:
`touch .env && chmod 600 .env && printf ... > .env`, or — if the umask
approach is wanted — scope it in a subshell: `( umask 077 && printf ... > .env )`.
The parentheses fork a child shell; its umask dies with it.

Repair after the fact (restore git's expected modes for tracked files,
leave untracked secrets alone):

```bash
umask 0002
git ls-files -s | awk '$1=="100755"{print $4}' | xargs -r chmod 755
git ls-files -s | awk '$1=="100644"{print $4}' | xargs -r chmod 644
```

## Lessons

- Any command that changes shell state must be scoped: subshell, `env`,
  a one-shot flag of the tool itself (`install -m`, `mktemp`, `cp --mode`).
- Bind-mounted configuration files are the one place where host file modes
  meet container UIDs; under `userns-remap` the container can only rely on
  the *other* bits of a file owned by an unmapped host user.
- When suggesting commands to run in someone else's interactive shell (or
  taking them from an assistant), read for words like "this shell", "for
  the session", "inherited": that is where the side effect hides. The rule
  "explain every part of a command before running it" exists for exactly
  this class of bug.
