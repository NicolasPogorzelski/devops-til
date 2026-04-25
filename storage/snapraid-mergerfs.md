# SnapRAID + MergerFS — Homelab Storage Stack

## Architecture overview

```
Physical disks (individual ext4)
        ↓
    MergerFS         ← pooled virtual filesystem (/mnt/pool)
        ↓
    SnapRAID         ← parity protection (not RAID, not real-time)
        ↓
   Samba shares      ← network access for service LXCs
```

## MergerFS

MergerFS pools multiple disks into a single virtual filesystem. Files are stored
on individual disks — MergerFS presents them as one unified path.

Key property: **files are not split across disks**. Each file lives entirely on one disk.
If a disk fails, only the files on that disk are at risk.

```bash
# Typical fstab entry
/mnt/disk1:/mnt/disk2:/mnt/disk3 /mnt/pool fuse.mergerfs \
  defaults,allow_other,use_ino,cache.files=off,moveonenospc=true \
  0 0
```

`moveonenospc=true`: if a disk fills up during a write, MergerFS moves the file
to another disk automatically.

## SnapRAID

SnapRAID calculates parity data across all pooled disks and writes it to a
dedicated parity disk. It is **not real-time** — parity is only updated when `snapraid sync` runs.

**Consequence:** Files written after the last sync are unprotected. If a disk fails
before sync, those files are unrecoverable.

```bash
snapraid sync    # update parity (run after writes)
snapraid scrub   # verify data integrity (run periodically)
snapraid status  # check for unsynced files, errors
```

### Sync schedule

- Daily at 02:00 (automated via systemd timer)
- Run manually after large writes

### Scrub schedule

- Monthly on the 1st at 03:00 (automated)
- Verifies a percentage of data blocks each time

## Content files

SnapRAID writes a `content` file to each data disk and the parity disk. This file
contains the file catalog (names, sizes, hashes). Having multiple copies
(one per disk) improves recovery reliability.

## Operational discipline

**Before a sync:** Verify all data disks and parity disk are mounted:
```bash
snapraid status
lsblk
```

**Never use `--force-deletions`** unless you have verified that the missing files
are actually deleted (not just unmounted).

## Stable disk references

Use `/dev/disk/by-id/` instead of `/dev/sda`, `/dev/sdb`, etc. Device names can
change between reboots. By-ID paths are stable and tied to the physical device.

```bash
ls -la /dev/disk/by-id/   # shows stable symlinks to /dev/sdX
```

## Samba shares

SnapRAID/MergerFS storage is exposed to services over SMB via Tailscale.
Service LXCs mount the shares as CIFS network mounts.

Access is least-privilege:
- Read-only for consumers (Jellyfin, Calibre-Web, Audiobookshelf)
- Read-write for producers (Nextcloud, Paperless)
- Never use SMB for database files (SQLite locking breaks over CIFS)

## Related

- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
