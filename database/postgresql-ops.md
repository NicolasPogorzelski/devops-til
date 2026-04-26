# PostgreSQL Operations

## Backup

### pg_dumpall — full cluster backup

```bash
pg_dumpall -U postgres > /backup/postgres_full_$(date +%Y%m%d).sql
```

Dumps all databases, roles, and global objects in a single SQL file.
Use for complete cluster backups.

### pg_dump — single database backup

```bash
pg_dump -U postgres -d mydb > /backup/mydb_$(date +%Y%m%d).sql
```

Use for selective restores of a single database.

### Backup retention

```bash
# Delete backups older than 7 days
find /backup/ -name "*.sql" -mtime +7 -delete
```

## Restore

```bash
# Restore full cluster
psql -U postgres < /backup/postgres_full_20260425.sql

# Restore single database
psql -U postgres -d mydb < /backup/mydb_20260425.sql
```

## Health check

```bash
pg_isready -U postgres -h localhost
# Output: localhost:5432 - accepting connections
```

Used in scripts and Docker healthchecks to verify PostgreSQL is ready before
running queries.

## Authentication — pg_hba.conf

`pg_hba.conf` controls who can connect, from where, and with what authentication method.

| Method | Meaning |
|---|---|
| `trust` | No password required |
| `peer` | OS user must match database user (local socket only) |
| `md5` / `scram-sha-256` | Password required |
| `reject` | Always deny |

Example entry:
```
local   all   postgres   peer   # local socket, postgres user, no password
host    all   all        scram-sha-256  # TCP connections require password
```

`peer` authentication: the OS username of the connecting process must match the
PostgreSQL username. Used for local administrative access (`sudo -u postgres psql`).

## Hardening principles

- Services connect over TCP with unique credentials per database
- Admin access only via local socket (peer auth) from the host
- No external port exposure — PostgreSQL is accessed via Tailscale IP only
- Each service has its own database and user — no shared credentials

## Staleness monitoring with textfile collector

Write a timestamp after each successful backup:

```bash
echo "pg_backup_last_success_timestamp $(date +%s)" \
  > /var/lib/node_exporter/textfile_collector/pg_backup.prom
```

Alert in Prometheus if the timestamp is older than 25 hours.

## Backup script — robust file creation with `install`

Inside backup scripts, `install` creates files atomically with permissions:

```bash
install -m 600 -o postgres -g postgres /dev/null /backup/pg_backup.sql.gz
pg_dumpall -U postgres | gzip > /backup/pg_backup.sql.gz
```

| Flag             | Why                                                           |
|------------------|---------------------------------------------------------------|
| `-m 600`         | Set file mode at creation. No race with `chmod` afterward     |
| `-o postgres`    | Owner — the user the dump must be readable by                 |
| `-g postgres`    | Group                                                         |

`install /dev/null <file>` is a one-line "create empty file with these
attributes". Equivalent to `touch && chown && chmod` but atomic — the file
never exists with wrong permissions, which matters when other processes
might try to read it during creation.

## `crontab -u` — per-user crontabs

The `postgres` user's cron jobs should run as `postgres`, not root, so that
peer authentication works without password prompts:

```bash
crontab -u postgres -e         # edit postgres user's crontab
crontab -u postgres -l         # list it
```

Alternative: drop a file in `/etc/cron.d/` with explicit user column:

```cron
# /etc/cron.d/postgres-backup
0 2 * * * postgres /usr/local/sbin/pg-backup.sh
```

| Approach                | Pro                                | Con                                 |
|-------------------------|-------------------------------------|-------------------------------------|
| `crontab -u <user>`     | User's own jobs visible via `crontab -l`  | Edit-via-vipw, harder to versioncontrol |
| `/etc/cron.d/<service>` | File-based — version controllable, deployable via Ansible | Slightly less discoverable |

For homelab IaC: `/etc/cron.d/<service>` is the right pattern — the cron job
is part of the service's config and gets deployed alongside the binary.

## Pre-flight checks in backup scripts

Backup scripts that fail silently are worse than no backups. Add pre-flight
checks at the top:

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/backup"
[[ -d "$BACKUP_DIR" ]] || { echo "ERROR: $BACKUP_DIR missing" >&2; exit 1; }
[[ -w "$BACKUP_DIR" ]] || { echo "ERROR: $BACKUP_DIR not writable" >&2; exit 1; }
command -v pg_dumpall >/dev/null || { echo "ERROR: pg_dumpall not found" >&2; exit 1; }
pg_isready -U postgres -h localhost >/dev/null || { echo "ERROR: PG not ready" >&2; exit 1; }

# ... actual dump ...

# Post-flight: was anything actually written?
[[ -s "$OUTFILE" ]] || { echo "ERROR: output file empty" >&2; exit 1; }
```

`-s` checks "exists and non-empty". Critical: a 0-byte `.sql.gz` *looks* like
a successful backup until you try to restore.

## `pg_monitor` role — for postgres_exporter

PostgreSQL ships a built-in `pg_monitor` role with read-only access to
monitoring views (`pg_stat_*`). For Prometheus scraping:

```sql
CREATE ROLE monitor LOGIN PASSWORD '...';
GRANT pg_monitor TO monitor;
```

Why `pg_monitor` instead of giving exporter superuser access:

- `pg_monitor` cannot read user data — only stat views and admin functions
- A compromised exporter cannot exfiltrate application data
- Future PG versions extend `pg_monitor` automatically; you don't have to grant
  individual `pg_stat_*` permissions

`postgres_exporter` documentation may suggest superuser; resist. `pg_monitor`
covers everything the exporter actually needs.

## Dump validation

A backup file is not a backup until you've confirmed it's parseable:

```bash
zcat /backup/pg_backup.sql.gz | head -50
zcat /backup/pg_backup.sql.gz | tail -5
```

| Check          | What it tells you                                                  |
|----------------|--------------------------------------------------------------------|
| Header (first 50 lines) | `SET` directives, `\connect`, role definitions — dump is intact |
| Tail (last 5 lines)     | Should end with `--` comment block. If truncated, dump aborted    |
| `gzip -t file` | Verify gzip integrity without decompressing                       |

For deeper validation: restore to a scratch host and run `\dt` on each database.
That's a quarterly task, not per-backup — but per-backup `head/tail` catches
80% of corruption fast and cheap.

## Related

- [Monitoring: Prometheus Stack](../monitoring/prometheus-stack.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
- [PostgreSQL CLI](postgresql-cli.md)
- [PostgreSQL Zero-Trust](postgres-zero-trust.md)
- [Bash Scripting Patterns](../linux/bash-scripting-patterns.md)
- [Backup Strategy](../operations/backup-strategy.md)
