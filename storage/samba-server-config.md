# Samba Server Configuration

## What `smb.conf` controls

`smb.conf` is the entire configuration surface for `smbd`. It has two kinds of
sections:

1. `[global]` — server-wide settings (auth, protocol versions, listening interfaces)
2. `[<sharename>]` — per-share settings (path, who can read/write, behavior)

Edit, then `testparm` to validate, then `systemctl reload smbd` to apply.

## `[global]` — minimum hardened baseline

```ini
[global]
   workgroup = HOMELAB
   server role = standalone server
   security = user

   server min protocol = SMB3_00
   client min protocol = SMB3_00
   smb ports = 445

   server signing = mandatory
   client signing = mandatory

   bind interfaces only = yes
   interfaces = lo eth0

   load printers = no
   disable spoolss = yes
   printcap name = /dev/null

   log file = /var/log/samba/log.%m
   max log size = 10000
   log level = 1

   server string = %h
```

### Auth & protocol

| Setting                    | Why                                                                       |
|----------------------------|---------------------------------------------------------------------------|
| `server role = standalone` | No domain controller. Authenticate against local users. Right for homelab |
| `security = user`          | Auth via username + password (vs. `share`/`server`/`domain`)              |
| `server min protocol = SMB3_00` | Reject SMB1/SMB2 clients. SMB1 is wormable; SMB2 lacks signing       |
| `client min protocol = SMB3_00` | Same for outbound (when smbd acts as a client)                       |
| `smb ports = 445`          | TCP/445 only. Drops NetBIOS over TCP/139 — legacy and unnecessary         |

### Signing — mandatory, not optional

```ini
server signing = mandatory
client signing = mandatory
```

| Value         | Meaning                                                              |
|---------------|----------------------------------------------------------------------|
| `disabled`    | Never sign. Vulnerable to relay attacks.                            |
| `auto`        | Sign if the client requests it. Default — clients decide.           |
| `mandatory`   | Always sign. Reject unsigned connections.                           |

`mandatory` is the security-correct choice. Performance cost is negligible
on modern hardware (AES-NI). The only reason to weaken this is supporting
ancient clients — which you shouldn't be supporting anyway.

### Bind interfaces

```ini
bind interfaces only = yes
interfaces = lo eth0
```

Without these two together, `smbd` listens on every interface including any
Tailscale or Docker network. With them, only the named interfaces. Listing
interfaces lets you keep SMB on the LAN while Tailscale runs separately on
`tailscale0`.

The convention "bind interfaces only without an interfaces list does nothing"
is a common gotcha — both must be set.

### Disable printing

```ini
load printers = no
disable spoolss = yes
printcap name = /dev/null
```

Samba historically integrates with CUPS for print sharing. For a file-only
server, every line of printing-related code is unused attack surface.
`disable spoolss = yes` turns off the print-spooler service entirely.

### Logging

```ini
log file = /var/log/samba/log.%m
max log size = 10000
log level = 1
```

`%m` is per-client log files (one per connecting NetBIOS name). `max log size`
is in **kilobytes** (10000 = ~10 MB). `log level = 1` is enough for normal
operations; raise to `3` only when debugging a specific client.

## Per-share configuration

A read-write share for a specific user:

```ini
[<username>]
   path = /mnt/storage/users/<username>
   valid users = <username>
   force user = <username>
   force group = <username>
   read only = no
   create mask = 0640
   directory mask = 0750
   browseable = yes
```

### `valid users` and `force user`

| Setting           | Effect                                                                    |
|-------------------|---------------------------------------------------------------------------|
| `valid users`     | Only these users may connect to this share                                |
| `force user`      | Files written via this share are owned by this user, regardless of who connected |
| `force group`     | Same for group                                                            |

`force user` is critical for service shares. Imagine a Paperless inbox share:
multiple humans drop documents in via SMB, but the Paperless container expects
ownership `paperless:paperless`. `force user = paperless` makes every file land
with the right owner regardless of who uploaded it.

### Read-only consumer shares

```ini
[media]
   path = /mnt/storage/media
   valid users = jellyfin, audiobookshelf
   read only = yes
   browseable = no
```

| Setting           | Why                                                                         |
|-------------------|-----------------------------------------------------------------------------|
| `read only = yes` | Consumers cannot mutate the source                                          |
| `browseable = no` | Hide from share listings (`smbclient -L`). Connect by knowing the name only |

`browseable = no` is mild obscurity, not security. It keeps service shares from
showing up in user-facing browsers. Real protection is `valid users`.

### Ingest shares — write path with dedicated user

```ini
[paperless-inbox]
   path = /mnt/storage/paperless/consume
   valid users = scanner-user
   force user = paperless
   force group = paperless
   read only = no
   create mask = 0660
   directory mask = 0770
   browseable = no
```

Pattern: a *dedicated* SMB user (`scanner-user`) has write access via this share.
Files land owned by `paperless:paperless` (the service consuming them). The
human credentials and the service identity are separated.

If `scanner-user` is compromised, the blast radius is "can drop arbitrary files
into Paperless inbox" — bad, but limited. The Paperless container's data
directory (`force user` = paperless) is unaffected because it's reachable only
through Paperless itself.

### `create mask` / `directory mask`

These set the maximum permission bits on files/dirs created via SMB:

```
create mask = 0640        # rw- r-- ---
directory mask = 0750     # rwx r-x ---
```

The mask is **AND'd** with the mode the client requests. A client requesting
`0777` gets `0640` because the mask removes the extra bits.

For service-scoped shares, use the most restrictive mask compatible with the
service's needs. `0660`/`0770` (group-writable) is right when multiple service
users share a group; `0640`/`0750` is right when only the service writes.

## User management — separate from system users

Samba users are separate from Linux users. A Linux user must exist before they
can become a Samba user, but there's an additional `smbpasswd` step:

```bash
useradd -M -s /usr/sbin/nologin scanner-user
smbpasswd -a scanner-user
```

| Step                       | Why                                                                |
|----------------------------|--------------------------------------------------------------------|
| `useradd -M -s nologin`    | Create the Linux user with no home directory and no login shell    |
| `smbpasswd -a scanner-user`| Set the Samba password (separate from the Linux password)         |

`-M` (no home) and `-s /usr/sbin/nologin` (no shell) ensure the user can
authenticate to Samba but cannot log in via SSH or any other Linux service.

## Validation

```bash
testparm                                # syntax + effective settings
testparm --section-name=paperless-inbox # specific share
smbclient -L //localhost -U <username>              # list shares as a user
smbclient //localhost/<username> -U <username>      # interactive client session
```

`testparm` is mandatory after any edit. It catches typos that would otherwise
cause silent fallback to defaults.

## `access based share enum` vs `browseable = no`

`browseable = no` is an absolute switch — the share disappears from listings for
*everyone*, regardless of whether they have access. It is blunt and breaks
legitimate workflows (e.g. file manager navigation).

`access based share enum = yes` (set in `[global]`) filters the share listing
*per user*: a share only appears if the connecting user would actually be allowed
in. Real access protection remains with `valid users`.

```ini
[global]
   access based share enum = yes
```

| | `browseable = no` (global) | `access based share enum` |
|---|---|---|
| User with access sees share | No | Yes |
| User without access sees share | No | No |
| File manager navigation works | Broken | Works |
| Protection mechanism | Obscurity | Identity |

Use `browseable = no` *per share* only for shares that should never appear in any
listing (e.g. service-to-service shares that clients connect to by known path).
Use `access based share enum` for the global default.

## Mixed read-write share: `read only` + `write list`

When one share needs RO for most users and RW for specific users:

```ini
[roms]
   path = /mnt/mergerfs/roms
   valid users = roms, storage
   read only = yes
   write list = storage
   force group = roms
   create mask = 0664
   directory mask = 0775
```

`write list` overrides `read only = yes` for named users. Users in `valid users`
but NOT in `write list` get read-only access. Users in `write list` get full
write access regardless of `read only`.

`testparm` will not show `read only = Yes` — it is Samba's compiled-in default
and is omitted from the output. Absence of `read only = No` means it is active.

## Shared-group share with Setgid

When multiple users need to write to a share and all files must be readable by a
group:

```bash
groupadd roms
useradd --no-create-home --shell /usr/sbin/nologin --gid roms roms
useradd --no-create-home --shell /usr/sbin/nologin --gid roms roms-admin
```

```bash
chown -R roms-admin:roms /mnt/mergerfs/roms
find /mnt/mergerfs/roms -type d -exec chmod 2775 {} \;
```

The `2` in `2775` sets the **Setgid bit** on directories. New files and
subdirectories inherit the group `roms` automatically, regardless of which user
created them. Without Setgid, new files inherit the creator's primary group —
breaking read access for other group members.

```ini
[roms]
   force group = roms
   create mask = 0664
   directory mask = 0775
```

`force group` enforces the group at the Samba layer as a second guarantee.

## Related

- [SnapRAID + MergerFS](snapraid-mergerfs.md)
- [CIFS Automount](cifs-automount.md) (the client side)
- [Least-Privilege Patterns](../security/least-privilege-patterns.md)
