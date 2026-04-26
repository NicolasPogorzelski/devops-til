# Bash Scripting Patterns for Operations Scripts

## Strict mode header

Every operations script should start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

| Flag | Behavior | Why |
|---|---|---|
| `set -e` | Exit on any non-zero return code | Stop before doing more damage on failure |
| `set -u` | Treat unset variables as errors | Catch typos in variable names |
| `set -o pipefail` | Pipeline returns first non-zero exit, not last | `false | true` would otherwise look successful |

`#!/usr/bin/env bash` over `#!/bin/bash`: portable across systems where bash lives in different paths
(BSD, NixOS) and lets the user's `PATH` decide.

## Pre-flight checks

Validate everything that must be true before doing irreversible work.

```bash
# Required directory exists
if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: backup directory ${BACKUP_DIR} does not exist" >&2
  exit 1
fi

# Required tool is installed
if ! command -v snapraid &>/dev/null; then
  echo "ERROR: snapraid not found in PATH" >&2
  exit 1
fi

# Argument is one of the allowed values
case "${1:-}" in
  sync|scrub) MODE="$1" ;;
  *) echo "Usage: $0 sync|scrub" >&2; exit 1 ;;
esac
```

| Pattern | Purpose |
|---|---|
| `command -v <tool>` | Returns 0 if `<tool>` is found in `PATH`, 1 otherwise — POSIX-portable, faster than `which` |
| `>&2` | Redirect to stderr — error messages must not pollute stdout (which may be piped) |
| `${1:-}` | Default empty string if `$1` is unset — works under `set -u` |

## Post-action validation

After doing the work, confirm the result before declaring success.

```bash
pg_dumpall | gzip > "$DUMP_FILE"

if [ ! -s "$DUMP_FILE" ]; then
  echo "ERROR: dump file is empty: ${DUMP_FILE}" >&2
  exit 1
fi
```

| Test | Meaning |
|---|---|
| `[ -e "$f" ]` | Path exists |
| `[ -f "$f" ]` | Path is a regular file |
| `[ -d "$f" ]` | Path is a directory |
| `[ -s "$f" ]` | File exists AND is non-empty |
| `[ -r "$f" ]` | File is readable by current user |
| `[ -x "$f" ]` | File is executable |

## Safe file creation with `install`

Avoid the `touch` + `chmod` + `chown` dance:

```bash
# Less safe — file briefly exists with wrong perms between touch and chmod
touch /usr/local/sbin/myscript.sh
chmod 0750 /usr/local/sbin/myscript.sh
chown root:postgres /usr/local/sbin/myscript.sh

# Atomic — file is created with final mode/ownership in one syscall
install -m 0750 -o root -g postgres /dev/null /usr/local/sbin/myscript.sh
```

`install -m -o -g <source> <dest>` creates `<dest>` with the given mode/owner/group atomically.
Using `/dev/null` as source means "create the destination empty".

## HEREDOC for config and unit file generation

```bash
cat > /etc/systemd/system/myservice.service << UNIT
[Unit]
Description=My Service
After=network.target

[Service]
ExecStart=/usr/local/bin/myservice
User=myservice
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
```

| Variant | Behavior |
|---|---|
| `<< UNIT` | Variables in the body are expanded (`${VAR}` interpolated) |
| `<< 'UNIT'` | Single-quoted delimiter — no expansion, body is literal |
| `<<- UNIT` | Strip leading TABs (only TABs, not spaces) — useful for indented heredocs |

Pick the variant by intent: if the unit must contain a literal `$VAR`, quote the delimiter.

## Temporary files with cleanup

```bash
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
```

`mktemp` creates a unique temp file in `$TMPDIR` (or `/tmp`) with safe permissions.
`trap '<cmd>' EXIT` runs `<cmd>` when the script exits — including on errors with `set -e`.

For directories: `mktemp -d`. To clean up a tree: `trap 'rm -rf "${TMPDIR}"' EXIT`.

## Sub-commands via case on `$1`

```bash
case "${1:-}" in
  sync)
    snapraid sync
    write_metric "$TEXTFILE_DIR/sync.prom"
    ;;
  scrub)
    snapraid scrub
    write_metric "$TEXTFILE_DIR/scrub.prom"
    ;;
  *)
    echo "Usage: $0 sync|scrub" >&2
    exit 1
    ;;
esac
```

A single script with sub-commands is often cleaner than multiple separate scripts —
shared setup runs once, the dispatch is explicit, and one cron/systemd entry per command.

## Globs that may match nothing

```bash
shopt -s nullglob

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue
  do_something "$d"
done
```

Without `nullglob`: if `/mnt/smb/*` matches nothing, the loop runs once with `$d` set to the
literal string `/mnt/smb/*` — usually a bug. With `nullglob`, the loop simply doesn't execute.

## Bounded execution with `timeout`

```bash
timeout 3s ls -la "$d"/. >/dev/null 2>&1 || true
```

| Suffix | Meaning |
|---|---|
| `3s` | seconds |
| `5m` | minutes |
| `1h` | hours |

`timeout` kills the command after the duration. The trailing `|| true` swallows the timeout
exit code (124) so the outer script doesn't fail under `set -e`.

Use case: triggering an autofs mount where you want to fire-and-forget without blocking
indefinitely if the mount target is dead.

## Run as another user without a login shell

```bash
su -s /bin/bash -c '<command>' <user>
```

| Flag | Purpose |
|---|---|
| `-s /bin/bash` | Force a specific shell — works even if the user's login shell is `/usr/sbin/nologin` |
| `-c '<cmd>'` | Run `<cmd>` and exit, no interactive shell |
| `<user>` | Target user (must be after the flags) |

Use case: running `php occ` as `www-data` from a script that runs as root. The `www-data` user
often has `nologin` as login shell, so `su www-data -c '...'` fails — `su -s /bin/bash` works.

## Silent skip for optional work

```bash
some_command 2>/dev/null || true
```

| Component | Effect |
|---|---|
| `2>/dev/null` | Suppress stderr (the error message) |
| `\|\| true` | If the command fails, return 0 — don't abort the script under `set -e` |

Use case: a per-user loop where some users don't have the resource being processed.
The check would be more code than just trying and ignoring failure.

## Function pattern for cross-host deployment

```bash
apply_lxc() {
  local ctid="$1"
  local ip="$2"
  echo "==> LXC${ctid}"
  write_unit "$ip" | pct exec "$ctid" -- bash -c "cat > ${UNIT_PATH}"
  pct exec "$ctid" -- systemctl daemon-reload
  pct exec "$ctid" -- systemctl restart node_exporter
}

apply_ssh() {
  local host="$1"
  local ip="$2"
  echo "==> ${host}"
  write_unit "$ip" | ssh "$host" "cat > ${UNIT_PATH}"
  ssh "$host" "systemctl daemon-reload && systemctl restart node_exporter"
}

# Drive the deployment
apply_lxc 200 "<ip-200>"
apply_lxc 210 "<ip-210>"
apply_ssh "storage" "<ip-storage>"
```

Why functions: deploying the same change across LXCs (`pct exec`), VMs (`ssh`), and the host
(local execution) requires three different access methods. Functions abstract the access path
so the call sites stay readable.

`local` declares variables scoped to the function — without it, variables leak into the global scope.

## Idempotent loops

Running a script twice should not produce different state than running it once.

```bash
# Bad — appends every run, eventually duplicates the line
echo "0 3 * * * /usr/local/sbin/pg-backup.sh" >> /etc/cron.d/pg-backup

# Good — overwrites with current desired state
echo "0 3 * * * /usr/local/sbin/pg-backup.sh" > /etc/cron.d/pg-backup
```

For richer idempotency, check before acting:

```bash
if ! grep -q "pg-backup.sh" /etc/cron.d/pg-backup 2>/dev/null; then
  echo "0 3 * * * /usr/local/sbin/pg-backup.sh" >> /etc/cron.d/pg-backup
fi
```

This is also why Ansible exists: each module is idempotent by design.

## Timestamp-based naming

```bash
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/pg_dumpall_${TIMESTAMP}.sql.gz"
```

| Format | Result |
|---|---|
| `%Y%m%d` | `20260425` |
| `%Y%m%d_%H%M%S` | `20260425_140530` |
| `%Y-%m-%dT%H:%M:%S%z` | `2026-04-25T14:05:30+0200` (ISO 8601) |

Sortable by name (alphanumerical sort = chronological sort) — important for retention scripts
using `find -mtime` or `ls -t`.

## Human-readable size summary

```bash
SIZE="$(du -h "$FILE" | cut -f1)"
echo "wrote ${FILE} (${SIZE})"
```

| Component | Effect |
|---|---|
| `du -h` | Disk usage in human-readable units (K, M, G) |
| `cut -f1` | Take the first tab-separated field (the size) — drops the path |

## Nested grep + while read

For per-line processing where the inner work is more than a one-liner:

```bash
while read -r mdfile; do
    while read -r link; do
        # process each link
    done < <(grep -oP '\]\(\K[^)]+' "${mdfile}")
done < <(find . -name "*.md" -type f)
```

| Component | Effect |
|---|---|
| `read -r` | Don't interpret backslash escapes — preserves literal `\n`, `\t` in filenames |
| `< <(cmd)` | Process substitution — feed the output of `cmd` as stdin to the loop. Avoids subshell scoping issues that `cmd | while read` would create. |
| `grep -oP '...\K...'` | Perl regex with `\K`: discard everything before `\K` from the match — used to extract just the captured part |

Use process substitution (`< <(...)`) over piping (`| while`) when the loop modifies variables —
piping creates a subshell where modifications are lost.

## Related

- [Linux: systemd Basics](systemd-basics.md)
- [Linux: Cron & Scheduling](cron-and-scheduling.md)
- [Linux: Network Tools](network-tools.md)
