# Least-Privilege Patterns

## Core principle

Every process, user, and service should have the minimum permissions needed to
function — nothing more. This limits blast radius when something is compromised.

## File permissions for SMB shares

```bash
# Force all files created in a share to be owned by a specific user/group
force user = jellyfin
force group = media
create mask = 0660    # files: rw for owner and group, nothing for others
directory mask = 0770  # directories: rwx for owner and group
```

Read-only vs read-write by consumer type:
- **Read-only** (`read only = yes`): Jellyfin, Audiobookshelf, Calibre-Web
- **Read-write** (`read only = no`): Nextcloud, Paperless (they need to write)

## Credentials files

SMB credentials should never be in `/etc/fstab` in plaintext:

```
/etc/fstab:
//server/share /mnt/point cifs credentials=/etc/smb-credentials,... 0 0
```

```
/etc/smb-credentials:
username=serviceuser
password=secret
```

```bash
chmod 600 /etc/smb-credentials   # only root can read
```

## .env files

- Never commit `.env` files to git — they contain secrets
- Always commit `.env.example` with placeholder values
- Each Docker Compose directory with a `docker-compose.yml` must have a `.env.example`

```bash
# .gitignore
.env
```

## Service isolation

Each service gets its own database user and database — not a shared superuser:

```sql
CREATE USER nextcloud WITH PASSWORD 'secret';
CREATE DATABASE nextcloud OWNER nextcloud;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
```

## Sanitization rules for public repos

IPs and identifiers that must never appear in the repo:
- Tailscale IPs (`100.x.y.z`) → use `<tailscale-ip-nodename>`
- Tailnet ID (`*.ts.net` domain) → use `<tailnet-id>`
- Real passwords → use `<password>` or `<your-password>`
- Private keys / certificates → never commit

## Sudoers — NOPASSWD scoping

```bash
# Minimal: only specific commands
gpu ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt

# Broad: all commands (for Ansible — it needs to sudo Python, not just apt)
gpu ALL=(root) NOPASSWD: ALL
```

For Ansible-managed nodes, `NOPASSWD: ALL` is the practical choice because
Ansible sudo's the Python interpreter, not individual commands.

The dedicated `ansible` service account pattern is cleaner: create a user
with no other purpose, give it `NOPASSWD: ALL`, and use it for all automation.

## sudoers.d file requirements

Files in `/etc/sudoers.d/` must:
- Be owned by root (`chown root:root`)
- Have mode 440 (`chmod 440`)
- Have no syntax errors

sudo ignores or rejects files that don't meet these requirements.

## NOPASSWD helpers — the binary is the boundary

When NOPASSWD can't be scoped to fixed arguments (the argument is dynamic — a
device id, a path resolved at runtime), the sudoers line necessarily allows the
binary with *any* arguments:

```
user ALL=(root) NOPASSWD: /usr/local/bin/my-helper
```

The sudoers rule then protects almost nothing on its own — the **helper binary
becomes the actual security boundary**. That shifts the requirements onto it:

- **Not user-writable.** Root-owned, mode `0755`, in a root-owned directory. If
  the caller can edit the binary (or its dir), NOPASSWD = instant root.
- **Validate every input against an allowlist**, not a denylist. Refuse anything
  that isn't a known-good target (e.g. a device-vendor allowlist).
- **No path traversal.** Reject `/` in identifiers used to build paths, and
  reject `.` / `..`; build paths only from validated components.
- **Match literally, not as a pattern.** Use fixed-string compares (`grep -F`) —
  a value with regex metacharacters (`.`, `*`) must not be interpreted.
- **Fail closed.** On any doubt, exit non-zero and touch nothing.

Rule of thumb: assume the caller is hostile and passes arbitrary arguments,
because the NOPASSWD grant lets them. The binary must be safe under that
assumption — not just under the arguments your own code happens to send.

## Secret generation

When a service needs a random secret (signing key, admin token, encryption key),
do not invent one. Use a CSPRNG:

```bash
openssl rand -hex 32       # 256 bits, 64 hex chars — most env vars
openssl rand -base64 32    # 256 bits, 44 base64 chars — denser
openssl rand -base64 48    # 384 bits — when you want extra margin
```

| Property                | `-hex`            | `-base64`           |
|-------------------------|-------------------|---------------------|
| Charset                 | `[0-9a-f]`         | `[A-Za-z0-9+/=]`   |
| URL/env-safe out of box | Yes               | Mostly (watch `+`, `/`, `=`) |
| Length per byte         | 2 chars           | ~1.33 chars        |

For Argon2id-stored admin tokens (e.g., Vaultwarden):

```bash
echo -n "your-very-long-secret" | argon2 "$(openssl rand -base64 32)" -e -id -t 3 -m 16 -p 4
```

The hash, not the secret, goes in the env file. An attacker with read access
to `.env` cannot directly use the secret — they would have to crack the hash.

### Rotation

Every secret should have a documented rotation procedure:

| Secret type           | Rotation cadence                                                  |
|-----------------------|-------------------------------------------------------------------|
| Service-to-service tokens (DB passwords, API keys) | When personnel changes, suspected leak |
| Admin/root credentials | Quarterly (or after personnel changes)                          |
| TLS certificates      | Automatic via ACME / `tailscale cert`                              |
| SSH keys              | When a host is decommissioned, on suspected key theft             |

A secret that has never been rotated is a secret you don't know how to rotate.
The first rotation reveals every place the secret is hardcoded.

## Defense in depth — multiple independent layers

Single-mechanism security is brittle. Pattern: stack independent controls so
defeating any one of them is not sufficient:

```
Network layer:  Tailscale ACL (only specific tags reach this port)
Bind layer:     Service binds to specific IP only
Auth layer:     Service requires credential
Authz layer:    Credential limited to specific scope
Audit layer:    Access logged for review
```

A compromised credential doesn't grant network access; a compromised network
ACL doesn't bypass auth; auth doesn't grant scope it shouldn't have. Each layer
is independently configured and independently auditable.

See [PostgreSQL Zero-Trust](../database/postgres-zero-trust.md) for a worked
example of this pattern.

## Related

- [Networking: Tailscale](../networking/tailscale.md)
- [Ansible: Privilege Escalation](../ansible/privilege-escalation.md)
- [PostgreSQL Zero-Trust](../database/postgres-zero-trust.md)
- [Samba Server Config](../storage/samba-server-config.md)
