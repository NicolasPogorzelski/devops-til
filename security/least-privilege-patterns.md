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

## Related

- [Networking: Tailscale](../networking/tailscale.md)
- [Ansible: Privilege Escalation](../ansible/privilege-escalation.md)
