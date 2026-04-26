# Vaultwarden Deployment

## What Vaultwarden is

Vaultwarden is a Rust re-implementation of the Bitwarden server API. It is
API-compatible with the official Bitwarden clients (browser extensions, mobile
apps, desktop apps) but has a fraction of the resource footprint — making it
the right choice for self-hosting.

Default storage is SQLite. PostgreSQL and MySQL are supported but require
compile-time feature flags or a different image.

## Hardening: signups, invitations, admin token

The first thing to lock down on any password manager: who can register an account.

```yaml
environment:
  ADMIN_TOKEN: "<argon2-hash-of-secret>"
  SIGNUPS_ALLOWED: "false"
  INVITATIONS_ALLOWED: "false"
  WEBSOCKET_ENABLED: "true"
  DOMAIN: "https://vault.<tailnet-id>.ts.net"
```

| Variable                | What it does                                                                          |
|-------------------------|---------------------------------------------------------------------------------------|
| `ADMIN_TOKEN`           | Hash of the password for `/admin` console. Required to manage users post-disable      |
| `SIGNUPS_ALLOWED=false` | Disables public signup. New users only via `/admin` invite                            |
| `INVITATIONS_ALLOWED=false` | Disables user-to-user invitations. Tightens further in single-user installs       |
| `WEBSOCKET_ENABLED=true`| Enables real-time vault sync. Important for multi-device usage                        |
| `DOMAIN`                | Canonical URL. Required for emails and CORS                                           |

For `ADMIN_TOKEN`, **store the hash, not the secret**. Generate with:

```bash
echo -n "your-very-long-secret" | argon2 "$(openssl rand -base64 32)" -e -id -t 3 -m 16 -p 4
```

| Argon2 flag | Meaning                                                                |
|-------------|------------------------------------------------------------------------|
| `-e`        | Encoded output (the format Vaultwarden expects)                        |
| `-id`       | Use Argon2id (memory-hard + side-channel-resistant variant)            |
| `-t 3`      | 3 iterations                                                           |
| `-m 16`     | 64 MiB memory cost (`2^16`)                                            |
| `-p 4`      | 4 parallel threads                                                     |

These match the OWASP-recommended Argon2id parameters for password storage.

Storing only the hash means even reading the env file does not directly leak
the admin password — an attacker would have to crack it.

## Generating other secrets

Single command for any random secret needed by Vaultwarden or other services:

```bash
openssl rand -hex 32         # 64-character hex string (256 bits)
openssl rand -base64 32      # 44-character base64 string (256 bits)
```

| Variant   | Length | When to use                                                    |
|-----------|--------|----------------------------------------------------------------|
| `-hex`    | 64 chars | When the consumer requires URL-safe ASCII (most env vars)    |
| `-base64` | 44 chars | When length matters less and you want denser characters     |

Don't reuse secrets between services. If one leaks, only that service is compromised.

## Non-root container user

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    user: "1000:1000"
```

The `user:` directive overrides the image's default user. Vaultwarden's image
runs as root by default; pinning to `1000:1000` reduces the privilege of the
container process to a normal user.

This requires the bind-mounted `/data` directory to be owned by UID 1000:GID 1000
on the host. The container will fail to start otherwise (sqlite cannot write to
its DB).

## Healthcheck

Vaultwarden's `/alive` endpoint returns 200 when the API is responsive:

```yaml
healthcheck:
  test: ["CMD", "curl", "-fsS", "http://localhost:80/alive"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

| Field          | Why                                                                        |
|----------------|----------------------------------------------------------------------------|
| `interval`     | How often to run the check                                                 |
| `timeout`      | Per-check timeout. Fail-fast: 5s is plenty for a local HTTP request        |
| `retries`      | Consecutive failures before container is marked unhealthy                  |
| `start_period` | Grace period during startup. SQLite migrations can take a few seconds      |

`-fsS`: `-f` fail on HTTP error, `-s` silent (no progress), `-S` show errors despite silent.

## SQLite on CIFS — known tech debt

Vaultwarden defaults to SQLite. The DB file lives in the bind-mounted `/data`.
If `/data` is on a CIFS/SMB share (e.g., to consolidate backups), you will
hit `database is locked` errors under any concurrent access.

**Architectural rule:** the SQLite file *must* be on local block storage.
Backups can be on CIFS — they are write-once snapshots, not concurrent reads/writes.

```yaml
volumes:
  - /var/lib/vaultwarden/data:/data           # local — DB lives here
  - /mnt/smb/backups/vaultwarden:/backups:ro  # CIFS — read-only backup target
```

If you have an existing install with the DB on CIFS, the migration is:

```bash
docker compose stop vaultwarden
rsync -av /mnt/smb/.../data/ /var/lib/vaultwarden/data/
# update compose volumes to local path
docker compose up -d
```

See [CIFS Automount](../storage/cifs-automount.md) for the general "no databases on CIFS" rule.

## Backup strategy

Vaultwarden's `/data` contains everything: SQLite DB, attachments, config.

```bash
docker compose stop vaultwarden
tar czf /backups/vaultwarden-$(date +%Y%m%d).tgz -C /var/lib/vaultwarden data
docker compose start vaultwarden
```

The stop-during-backup ensures SQLite isn't mid-write. For an active multi-user
install you'd use SQLite's online backup API instead, but for a homelab single-user
install the brief downtime is acceptable.

## Related

- [Docker Compose Patterns](../docker/compose-patterns.md)
- [CIFS Automount](../storage/cifs-automount.md)
- [Least-Privilege Patterns](../security/least-privilege-patterns.md)
