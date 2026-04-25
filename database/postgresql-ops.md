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

## Related

- [Monitoring: Prometheus Stack](../monitoring/prometheus-stack.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
