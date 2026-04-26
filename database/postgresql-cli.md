# PostgreSQL CLI Operations

## Why a separate file from `postgresql-ops.md`

`postgresql-ops.md` is about *configuring* PostgreSQL: `pg_hba.conf`, auth methods,
backup design. This file is about *operating* a running database from the shell —
the commands you run when you're investigating something or doing maintenance.

## psql meta-commands

`psql` has a parallel command set prefixed with `\`. They are not SQL; they are
psql client commands that often run a SQL query under the hood.

| Command       | What it does                                       | SQL equivalent                                  |
|---------------|----------------------------------------------------|--------------------------------------------------|
| `\l`          | List all databases                                 | `SELECT datname FROM pg_database;`              |
| `\du`         | List all roles (users)                             | `SELECT rolname FROM pg_roles;`                 |
| `\c <db>`     | Connect to a different database in the same session| (reconnect)                                     |
| `\dt`         | List tables in current schema                      | `SELECT ... FROM pg_class WHERE relkind='r';`   |
| `\d <table>`  | Describe a table (columns, indexes, constraints)   | (multiple system catalog queries)                |
| `\dn`         | List schemas                                       | `SELECT nspname FROM pg_namespace;`             |
| `\df`         | List functions                                     | `SELECT ... FROM pg_proc;`                      |
| `\timing on`  | Show execution time after every query              | (client-side toggle)                             |
| `\x`          | Toggle "expanded" output (one column per line)     | (client-side toggle)                             |
| `\q`          | Quit                                               | (client-side)                                    |

The `\d` family takes a pattern: `\dt nextcloud_*` lists all tables starting with
`nextcloud_`. Useful when a database has hundreds of tables across tenants.

## Inspecting active connections

`pg_stat_activity` is the single most useful operational view. It shows every
connection currently open, what it's doing, and how long it's been doing it.

```sql
SELECT pid, usename, datname, state, query_start, query
  FROM pg_stat_activity
 WHERE state != 'idle'
 ORDER BY query_start;
```

Key columns:

| Column        | Meaning                                                                                |
|---------------|----------------------------------------------------------------------------------------|
| `pid`         | Backend process ID — needed to terminate the connection                                |
| `state`       | `active` (running query), `idle in transaction` (open tx), `idle` (just sitting there) |
| `query_start` | When the current query started — long durations indicate stuck or expensive queries    |
| `wait_event`  | What the backend is waiting for (lock, I/O, etc.) — `NULL` means actively running      |

`idle in transaction` is the dangerous state: a client opened a transaction
and walked away, holding locks. Those connections must be terminated to unblock
DDL operations like `DROP DATABASE`.

## Terminating connections

Two functions, different semantics:

| Function                       | Effect                                                                  |
|--------------------------------|-------------------------------------------------------------------------|
| `pg_cancel_backend(pid)`       | Cancel the *current query* on this backend. The connection survives.    |
| `pg_terminate_backend(pid)`    | Force-close the entire connection. The client gets a connection error.  |

To forcibly close *all* non-superuser connections to a database (required before
`DROP DATABASE`):

```sql
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = 'olddb'
   AND pid != pg_backend_pid();
```

The `pid != pg_backend_pid()` clause excludes your own session — otherwise you
disconnect yourself and the next statement (the `DROP DATABASE`) never runs.

## Dropping a database, the right way

```bash
sudo -u postgres dropdb olddb
```

Why `dropdb` instead of `psql -c "DROP DATABASE olddb;"`:

- `dropdb` is a thin wrapper but it handles edge cases (existence check with `--if-exists`, force option `--force` in PG13+ that auto-terminates connections).
- Running as the `postgres` OS user via `sudo -u postgres` uses **peer authentication** (auth method `peer` in `pg_hba.conf`) — the OS user maps directly to the DB superuser, no password prompt.

```bash
sudo -u postgres dropdb --if-exists --force olddb
```

`--force` (PG13+) is the killer feature: it terminates active connections automatically
instead of failing with "database is being accessed by other users".

## Restoring from `pg_dumpall`

`pg_dumpall` produces a single SQL file containing roles, tablespaces, and all databases:

```bash
psql -U postgres -f /backups/pg-all-20260415.sql
```

You will see `ERROR: role "X" already exists` lines. **Normal.** The dump contains
unconditional `CREATE ROLE` statements; on a fresh restore those would create the
roles, on a partial restore they collide with existing ones. The data still
restores correctly because role creation is independent of data restoration.

To verify the dump file is non-empty before trusting it:

```bash
zcat /backups/pg-all-20260415.sql.gz | head -50
```

The header includes a `SET` block and `\connect` — if you see binary garbage or
nothing, the dump is corrupt and the file is unusable.

## Verification queries after restore

```sql
\l                                         -- did all databases come back?
\du                                        -- are all roles present?
SELECT count(*) FROM pg_stat_user_tables;  -- non-zero per restored DB
```

```sql
SELECT schemaname, relname, n_live_tup
  FROM pg_stat_user_tables
 WHERE relname IN ('users', 'documents')   -- known tables you expected
 ORDER BY n_live_tup DESC;
```

`n_live_tup` is an estimate (updated by autovacuum), but it's good enough to
distinguish "table is empty" from "table has data". Don't trust it for exact counts —
use `SELECT count(*)` for that.

## Connection-string format

PostgreSQL uses URI-style connection strings (RFC 3986):

```
postgresql://<user>:<password>@<host>:<port>/<database>?<param>=<value>
```

| Component   | Notes                                                                                        |
|-------------|----------------------------------------------------------------------------------------------|
| `user`      | URL-encode special characters (`@` → `%40`, `:` → `%3A`)                                     |
| `password`  | Same. Avoid passwords with reserved chars; use a `~/.pgpass` file when possible              |
| `host`      | Hostname, IP, or socket path. `host=/var/run/postgresql` for Unix-socket connections         |
| `port`      | Default 5432 — omit if standard                                                              |
| `database`  | Database name. Required for most clients                                                     |
| Parameters  | `sslmode=require`, `application_name=myapp`, `connect_timeout=10`                            |

Example for OpenWebUI pointing at a Tailnet PostgreSQL:

```
postgresql://owui:secret@100.x.y.z:5432/owui?sslmode=require&application_name=openwebui
```

`sslmode=require` is the minimum acceptable for cross-host connections. Use
`verify-full` if you want certificate-based identity verification too.

## Related

- [PostgreSQL Operations](postgresql-ops.md)
- [PostgreSQL Zero-Trust Access](postgres-zero-trust.md)
- [Bash Scripting Patterns](../linux/bash-scripting-patterns.md)
