# PostgreSQL Zero-Trust Multi-Layer Access

## Principle

No single mechanism is trusted to enforce database access.
A connection must pass **four independent layers** before it can read or write data.

```
Tailscale ACL  →  network binding  →  pg_hba.conf  →  role privileges
```

If any one of these is bypassed by misconfiguration, the next still blocks.

## Layer 1 — Network identity (Tailscale ACL)

Only nodes carrying an explicit ACL rule may even *establish* a TCP connection
to the database port.

```jsonc
{
    "action": "accept",
    "src":    ["tag:ai-stack"],
    "dst":    ["tag:database:5432"]
}
```

- Tailscale ACLs are deny-by-default — an unlisted source cannot connect.
- A pre-existing WireGuard tunnel can mask a missing rule until the next
  connection reset. Always re-test ACLs after a container/Tailscale restart.

See: [Networking: Tailscale](../networking/tailscale.md)

## Layer 2 — Network binding

PostgreSQL listens *only* on the Tailscale interface, not on `0.0.0.0`:

```
# /etc/postgresql/<ver>/main/postgresql.conf
listen_addresses = '<tailscale-ip>'
```

| Bind | Effect |
|---|---|
| `0.0.0.0` | Listens on every interface — LAN, Tailscale, loopback. Risky. |
| `localhost` | Loopback only — no remote access. |
| `<tailscale-ip>` | Reachable only via Tailnet identity. Correct for platform DB. |

Even a LAN compromise cannot reach a Tailscale-bound listener — the LAN
interface has no listener to talk to.

## Layer 3 — Host-based authentication (pg_hba.conf)

Independent of the OS-level network controls. Enforced inside PostgreSQL.

```
# Local admin / maintenance — no password
local   all             postgres                                peer

# Per-service entry: TLS required, scoped to (DB, user, /32 client)
hostssl <svc>_db        <svc>_user      <client-tailscale-ip>/32   scram-sha-256

# Default deny
host    all             all             0.0.0.0/0                  reject
host    all             all             ::/0                       reject
```

| Type | Meaning |
|---|---|
| `local` | Unix socket only |
| `host` | TCP, no TLS requirement |
| `hostssl` | TCP with TLS required — connection refused without TLS |
| `hostnossl` | TCP without TLS (legacy / dev only) |

| Auth method | Use case |
|---|---|
| `trust` | No password — never use over network |
| `peer` | OS user name must match DB user — local socket admin |
| `scram-sha-256` | Modern password hashing — default for service users |
| `cert` | mTLS — service must present client cert |
| `reject` | Always deny |

`reject` lines as the final rules ensure that adding a new user without a
specific allow entry results in deny, not implicit allow via a permissive default.

## Layer 4 — Role privileges

Each service receives its own database and user. No shared superuser credentials.

```sql
CREATE DATABASE foo_db;
CREATE USER foo_user WITH PASSWORD '<strong>';
GRANT ALL PRIVILEGES ON DATABASE foo_db TO foo_user;

-- Strip the default public schema permissions
\c foo_db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO foo_user;
```

The `REVOKE ... FROM PUBLIC` step matters: by default any logged-in role can
create objects in the `public` schema of any database it can connect to.

## Service onboarding checklist

1. Create DB + user (Layer 4)
2. Add `pg_hba` line scoped to the new client `/32` (Layer 3)
3. `systemctl reload postgresql`
4. Add Tailscale ACL rule for `<tag>:5432` (Layer 1)
5. Verify with `psql -h <tailscale-ip-db> -U <user> -d <db>` from the new client
6. Document the tenant in a registry table (DB, user, ACL rule, hba entry)

## Backup separation as a failure-domain control

Runtime data lives on local block storage (no CIFS — see KE-1 / KE-5 patterns).
Backups live on SMB-mounted MergerFS storage:

```
Runtime data    → local block storage (low latency, file locking works)
Backup dumps    → SMB / network storage (different failure domain, write-once)
```

A failure of the database disk does not cost the backups; a failure of the
storage VM does not stop new backups from being written elsewhere.

## Verification commands

```bash
# Layer 1: ACL — from a node that should NOT have access
nc -zv <tailscale-ip-db> 5432   # expected: timeout / refused

# Layer 2: binding
ss -tlnp | grep 5432   # expected: only <tailscale-ip>:5432, no 0.0.0.0

# Layer 3: pg_hba (force a TCP connection to verify TLS requirement)
psql "host=<tailscale-ip> user=foo_user dbname=foo_db sslmode=disable"
# expected: rejected (because hostssl requires TLS)

# Layer 4: privileges
psql -U foo_user -d foo_db -c "SELECT current_user, current_database();"
# expected: returns the right tuple, cannot read other DBs
```

## Why centralize PostgreSQL at all

A single platform DB instance reduces:
- Patch drift (one PG version to keep current, not five)
- Backup inconsistency (one backup script, one schedule)
- Monitoring fragmentation (one `postgres_exporter`)
- Credential sprawl (one `pg_hba.conf` to audit)

Trade-off: shared dependency. The DB node becomes a SPOF — mitigated by
backups and a documented restore runbook, not by HA in a homelab context.

## Related

- [Database: PostgreSQL Operations](postgresql-ops.md)
- [Networking: Tailscale](../networking/tailscale.md)
- [Storage: CIFS Automount](../storage/cifs-automount.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
