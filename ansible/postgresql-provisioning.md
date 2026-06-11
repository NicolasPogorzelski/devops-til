# Provisioning PostgreSQL Tenants with Ansible

Codifying the manual "create a database + user + grants + `pg_hba` line" checklist
into an idempotent role, using the `community.postgresql` collection. Two of the
lessons here are not Postgres-specific and recur with any role that becomes an
unprivileged user or loops over secrets.

## Connecting: peer auth, no password

The database host trusts the local OS user via a `pg_hba.conf` line:
`local all postgres ... peer`. Peer auth maps the *operating-system* identity to
the database role: if you are the Linux `postgres` user on the Unix socket,
Postgres lets you in as the `postgres` superuser without a password. So the role
runs as `become_user: postgres` and connects locally — no admin password to store
or leak. The `community.postgresql` modules pick up that local connection
automatically.

## Each manual step is one module

| Manual SQL / action | Module |
|---|---|
| `CREATE DATABASE` | `postgresql_db` |
| `CREATE USER ... PASSWORD` | `postgresql_user` |
| `GRANT ALL ON DATABASE` | `postgresql_privs` (`type: database`) |
| `REVOKE ALL ON SCHEMA public FROM PUBLIC` | `postgresql_privs` (`type: schema`, `state: absent`, `roles: PUBLIC`) |
| `GRANT ALL ON SCHEMA public TO <user>` | `postgresql_privs` (`type: schema`) |
| `pg_hba.conf` line | `postgresql_pg_hba` |
| `systemctl reload postgresql` | a handler, notified on a `pg_hba` change |

A tenant is one entry in a `postgres_tenants` list var; every task loops over it.
The schema-level `postgresql_privs` tasks must set `database: <name>` so the module
connects *into* that database to touch its `public` schema.

`postgresql_pg_hba` edits the file directly (no DB connection); `reload` (SIGHUP),
not restart, is enough for Postgres to re-read `pg_hba.conf`.

## Lesson 1 (transferable): becoming an unprivileged user needs `acl`

`become: true` then `become_user: postgres` is "become an *unprivileged* user"
(postgres is neither the login user nor root). Ansible has to hand its temp files
to that user, and its clean mechanism is a POSIX ACL via `setfacl`. If the `acl`
package is missing on the target, Ansible falls back to a method that fails on
Linux:

```
chmod: invalid mode: 'A+user:postgres:rx:allow'
Failed to set permissions on the temporary files Ansible needs to create when
becoming an unprivileged user
```

That ACL-mode string is Solaris/NFSv4 syntax — a sign the `setfacl` path wasn't
available. The fix is to make the role self-sufficient: install `acl` (and here
`python3-psycopg2`, which the modules import) as a prerequisite task **before** the
`become_user` block runs. Verify the root cause rather than guessing —
`command -v setfacl` on the target returned nothing.

This applies to *any* role that becomes a service account (postgres, a deploy
user, …), not just databases.

## Lesson 2 (transferable): don't co-locate a secret with the loop variable

First cut put the password inside each tenant dict:

```yaml
postgres_tenants:
  - { name: test_db, user: test_user, password: "{{ vault_test_dbpass }}" }
```

with `no_log: true` only on the user-creation task. When an *earlier* task failed,
Ansible printed the failed item — the whole dict, password in clear:

```
failed: [lxc260] (item={"name": "test_db", "password": "9b8c...", ...})
```

The loop variable `item` is passed to **every** task in the loop, and Ansible dumps
it on failure regardless of which fields a given task references. `no_log` on one
task doesn't help the others. Two fixes, used together:

1. **Keep secrets out of the loop item.** Put only non-secret fields in
   `postgres_tenants`; look the password up from a separate dict keyed by user:

   ```yaml
   postgres_tenants:
     - { name: test_db, user: test_user, consumer_cidr: 127.0.0.1/32 }
   postgres_tenant_passwords:
     test_user: "{{ vault_test_dbpass }}"
   ```

   Now any task's `item` is secret-free, so a failure anywhere can't leak it.
2. **`no_log: true`** on the one task that *does* read the password (user
   creation). Belt and suspenders.

And: a password that has appeared in a log is burned — rotate it
(`ansible-vault encrypt_string` a fresh value), even for a throwaway.

## Test-tenant-first, then tear down

`postgresql_user` re-asserts the password on every run. Declaring a *live* tenant
with the wrong password would silently rotate it and break that service's login.
So the role was proven against a throwaway `test_db`/`test_user` (a loopback-only
`pg_hba` source, `127.0.0.1/32`), verified by querying `pg_database`/`pg_roles` and
grepping `pg_hba.conf`, then torn down with the same modules at `state: absent`
plus a reload. Live tenants are adopted as a separate, deliberate step. The
committed `host_vars` ends at `postgres_tenants: []` with a commented example, so
the repo matches reality.

## Related

- [Walkthrough: Items #9 & #10](walkthrough-items-9-10.md)
- [Privilege Escalation](privilege-escalation.md) — `become`, `become_user`
- [Ansible Vault](ansible-vault.md) — `encrypt_string`, secret hygiene
- [Roles](roles.md) — defaults, handlers, safe defaults
