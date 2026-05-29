# CIFS via systemd Automount (Reboot-Safe Network Mounts)

## The problem

Hard-mounting a network share at boot via `/etc/fstab` blocks startup if the share
is temporarily unavailable. On a Proxmox host where storage runs in its own VM,
this creates a chicken-and-egg dependency: the host won't finish booting until
the storage VM (which the host is supposed to start) is up.

`systemd automount` solves this: the mount unit is only activated when the
mountpoint is first accessed.

## How automount works

```
A process accesses /mnt/smb/foo
        ↓
systemd-automount intercepts
        ↓
Triggers <mountpoint>.mount unit
        ↓
Process gets the mounted filesystem
```

Two units cooperate per mountpoint:
- `mnt-smb-foo.mount` — the actual mount
- `mnt-smb-foo.automount` — the trigger that activates the mount on access

The automount unit is enabled at boot. The mount unit is started lazily.

## fstab syntax for automount

```
//<server>/<share> /mnt/smb/<name> cifs \
  credentials=/etc/smb-credentials,\
  x-systemd.automount,\
  x-systemd.idle-timeout=600,\
  noauto,\
  uid=1000,gid=1000,\
  vers=3.0 \
  0 0
```

| Option | Purpose |
|---|---|
| `x-systemd.automount` | systemd-fstab-generator creates an `.automount` unit alongside the `.mount` unit |
| `x-systemd.idle-timeout=600` | Unmount after 10 minutes of inactivity |
| `noauto` | Don't mount at boot — wait for first access |
| `credentials=<path>` | Path to a credentials file (chmod 600, contains username/password) |
| `vers=3.0` | Force SMB3 (avoid SMB1, deprecated and insecure) |
| `uid=1000,gid=1000` | Map share ownership to a specific local UID/GID |

## Inspecting mount state

```bash
findmnt -t cifs                    # all CIFS mounts
findmnt -T /mnt/smb/foo            # which mount covers this path
systemctl list-units --type=mount  # all currently active mount units
systemctl list-units --type=automount  # active automount triggers
```

## The boot-trigger pattern

Some services access bind-mounted CIFS paths during their own startup —
*before* anything else triggers the automount. The result is a service starting
against an empty directory.

Solution: a oneshot systemd unit that touches every `/mnt/smb/*` after
`network-online.target`, forcing early activation.

`/usr/local/sbin/trigger-smb-automounts.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

for d in /mnt/smb/*; do
  [[ -d "$d" ]] || continue
  timeout 3s ls -la "$d"/. >/dev/null 2>&1 || true
done
```

`/etc/systemd/system/trigger-smb.mounts.service`:
```ini
[Unit]
Description=Trigger all SMB automounts (boot stabilization)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/trigger-smb-automounts.sh

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
systemctl daemon-reload
systemctl enable --now trigger-smb.mounts.service
```

| Why a script + unit instead of inline ExecStart? |
|---|
| Avoids fragile shell quoting in unit files |
| Script is testable standalone (`bash -x trigger-smb-automounts.sh`) |
| Unit stays stable while logic can evolve |

## Hard rule: no databases on CIFS

SQLite (and any other DB relying on POSIX file locking semantics) is unreliable
on CIFS/SMB mounts. Symptom: `database is locked` errors under concurrent access.

Architectural rule: no SQLite/PostgreSQL data directories on automount-backed
network shares. Use local block storage for runtime; CIFS is fine for *backups*
since they are write-once + read-on-restore.

## App-state vs uploads — a generalizable split

The "no DBs on CIFS" rule generalizes:

| Data class                            | Storage tier                  | Why                                       |
|---------------------------------------|-------------------------------|-------------------------------------------|
| Application state (DBs, runtime locks) | Local block storage           | POSIX semantics, low-latency, exclusive   |
| User uploads / large files             | CIFS-mounted shared storage   | Capacity, central backup, multi-host read |
| Cached/derived data                    | Local SSD                     | Speed; regeneratable on loss              |
| Backups                                | CIFS / off-site               | Write-once, occasional read on restore    |

A service like Nextcloud hits this split directly: the SQLite/MariaDB DB lives
on local storage, while user files live on the CIFS-mounted media pool. Nextcloud's
external storage feature is the integration point.

Encoding this split per service in the runbook prevents future "we moved everything
to the NAS to save space and now Vaultwarden is broken" incidents.

## Inspection toolkit

```bash
findmnt -t cifs                    # all current CIFS mounts on this host
findmnt -T /mnt/smb/foo            # which mount unit covers this path
findmnt --target /mnt/smb/foo --json   # parseable for scripts
mount | grep cifs                  # legacy form, less structured
systemctl list-units --type=mount  # active mount units, includes auto-generated
systemctl list-units --type=automount  # active automount triggers
systemctl status mnt-smb-foo.automount # detailed state of a specific automount
```

`findmnt` is the most useful single tool. Unlike `mount`, it understands
mount-point hierarchy and unit naming, and `--json` makes scripted health
checks straightforward.

## Desktop fstab (no automount)

On a desktop/gaming PC, the server-side automount complexity is not needed.
A simple fstab entry with `_netdev,nofail` is sufficient.

### KIO/GVfs is not a real mount

KDE Dolphin mounts network shares on-demand via KIO/GVfs. These are not real
filesystem mounts — they live under `/run/user/1000/gvfs/smb-share:...` and
are invisible to applications. ES-DE, RetroArch, and any other app that needs
a stable path cannot use them.

Verify: `gio mount -l` (GVfs mounts) vs `mount | grep cifs` (real CIFS mounts).
If only GVfs shows it, applications cannot use it.

### Credentials file

Never put passwords in fstab (world-readable). Use a credentials file:

```
/etc/samba/credentials/<name>
---
username=<user>
password=<password>
```

```bash
sudo chmod 600 /etc/samba/credentials/<name>
sudo chown root:root /etc/samba/credentials/<name>
```

### fstab entry

```
//<server>/<share>  /mnt/<name>  cifs  credentials=/etc/samba/credentials/<name>,uid=1000,gid=1000,iocharset=utf8,_netdev,nofail  0  0
```

| Option | Purpose |
|---|---|
| `credentials=` | Path to credentials file (chmod 600) |
| `uid=1000,gid=1000` | Map share to local user — required for apps to read/write |
| `iocharset=utf8` | Unicode filenames (game titles with special characters) |
| `_netdev` | Tell systemd this mount needs the network — delays it until network is up |
| `nofail` | Boot succeeds even if the share is unreachable |

Test without reboot: `sudo mount -a`

Verify: `findmnt /mnt/<name>`

### Arch/CachyOS: install cifs-utils

```bash
paru -S cifs-utils
```

## Related

- [Linux: systemd Basics](../linux/systemd-basics.md)
- [Storage: SnapRAID + MergerFS](snapraid-mergerfs.md)
- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
