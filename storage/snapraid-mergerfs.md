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

## fstab tuning — `noatime`

ext4 by default updates each file's *access time* on every read (`atime`).
For a media or archive disk that is mostly read, this is pure write amplification:
every read causes a tiny metadata write.

```
UUID=... /mnt/disk1 ext4 defaults,noatime 0 2
```

| Mount option  | Effect                                                                  |
|---------------|-------------------------------------------------------------------------|
| `noatime`     | Don't update access time on read. Big win for read-heavy filesystems    |
| `relatime`    | Update atime only when mtime is newer (default since 2.6.30). Better than nothing, worse than `noatime` |
| `nodiratime`  | Skip atime updates on directories. Subset of `noatime`                  |

`noatime` implies `nodiratime`. Use `noatime` for media disks, archive disks,
and anything where atime semantics aren't needed (i.e., almost everywhere).

The trailing `0 2` is `<dump>` and `<fsck-pass>`:

| Field              | Meaning                                                            |
|--------------------|--------------------------------------------------------------------|
| `<dump>` (0 or 1)  | Used by the (deprecated) `dump` command. `0` always.               |
| `<fsck-pass>`      | `0` skip, `1` root, `2` other. Disks at `2` are checked in parallel |

For data disks: `0 2`. For system root: `0 1`. Don't mix `1` for non-root —
fsck passes are ordered, and pass 1 should be reserved for root.

## SnapRAID `excludes` — what not to protect

```
exclude *.tmp
exclude *.bak
exclude /lost+found/
exclude /.snapraid.content*
```

Directives:

| Pattern                | Why exclude                                                        |
|------------------------|--------------------------------------------------------------------|
| `*.tmp`, `*.bak`       | Transient. Already-protected files don't need duplicate protection |
| `/lost+found/`         | fsck-recovery dir. Volatile, never real data                       |
| `/.snapraid.content*`  | SnapRAID's own metadata. Excluded by default in newer versions     |

Excluded files are not parity-protected. If you exclude something important by
accident, a disk failure means losing those files. Test exclude patterns:

```bash
snapraid status              # shows excluded file count per disk
snapraid diff | head -50     # what changed since last sync, after exclusions
```

## Multiple `content` files — robustness

SnapRAID's `content` file is the catalog of every file's hash. Lose all copies
and you cannot verify integrity or recover. Configure multiple copies (one per
data disk + one per parity disk):

```
content /var/snapraid/snapraid.content
content /mnt/disk1/.snapraid.content
content /mnt/disk2/.snapraid.content
content /mnt/disk3/.snapraid.content
content /mnt/parity/.snapraid.content
```

Why one per disk: any single disk failure leaves all other content files intact.
Why one outside the array (`/var`): protects against a corrupt-everything-
on-the-pool scenario.

The first listed `content` file is the *primary* — SnapRAID writes it most
aggressively. Make it the most reliable disk (often `/var` on the system SSD).

## MergerFS create policy — `category.create=mfs`

MergerFS decides which underlying disk a new file goes to via a *create policy*:

```
defaults,category.create=mfs
```

| Policy         | Behavior                                                            |
|----------------|---------------------------------------------------------------------|
| `mfs`          | Most free space. New file goes to disk with the most free bytes     |
| `epmfs`        | Existing-path most-free. Prefer disks where the parent dir exists   |
| `lus`          | Least-used space. Prefer the most-empty disk                        |
| `rand`         | Random                                                              |

`mfs` is the right default for media storage: it spreads load evenly. `epmfs`
keeps related files together (good for "all of season 1 on one disk"), at the
cost of imbalanced fill. Pick one and stay with it — switching later does
not redistribute existing files.

## Anti-pattern: `--force-deletions`

When SnapRAID detects that many files have disappeared since the last sync,
it refuses to update parity (in case a disk silently un-mounted and you'd
lose protection for files that didn't actually disappear).

```bash
snapraid sync
# > too many deleted files, use --force-deletions to override
```

**Do not blindly add `--force-deletions`**. The error means: verify first.

Verification:

```bash
snapraid diff                   # shows what changed
findmnt -t ext4 /mnt/disk*      # are all data disks really mounted?
df -h /mnt/disk*                # if a disk shows unexpectedly empty, it's not mounted
```

If the disks are mounted and the deletions are real (you actually deleted
those files), then `--force-deletions` is correct. If a disk is unmounted,
fix that first.

## Hash mismatch during scrub — critical signal

```
snapraid scrub
# > WARNING! Hash mismatch in file '...'
```

A hash mismatch means SnapRAID expected one hash, computed another. Cause is
**always** one of:

1. Bit rot on the disk (silent corruption since last sync)
2. Hardware failure (RAM, controller, disk)
3. The file was modified without `snapraid sync` being aware (rare)

Recovery:

```bash
snapraid -e fix /<path/to/file>     # restore from parity
snapraid scrub --plan=full          # re-verify entire array
```

`smartctl -a /dev/sdX` and `dmesg` for the affected disk are mandatory follow-ups.
Hash mismatches are rarely isolated; if SMART shows growing reallocated sectors,
plan the disk replacement before the next scrub.

## `snapraid fix` — parity-based recovery

When a disk fails entirely or files are corrupted, `snapraid fix` rebuilds them
from parity:

```bash
snapraid fix -d <disk-name>       # restore one disk to a fresh replacement
snapraid fix -e                   # repair only files with errors detected by scrub
snapraid fix -f /path/to/file     # repair specific file
```

Time to fix scales with array size. For a 50TB array with a single failed disk,
expect 8–24h of read+write across all surviving disks. During this time,
**no further sync should run** — the array is in a degraded state.

## Live disk expansion without remounting (mergerfs xattr)

MergerFS exposes a control interface via extended attributes on the hidden
`.mergerfs` file at the mountpoint root. This allows adding or removing disks
at runtime without unmounting — and without interrupting services that are
currently reading or writing through the pool.

```bash
# Read current branches
getfattr -n user.mergerfs.branches /mnt/pool/.mergerfs

# Add a new disk live ('+' prefix = append)
setfattr -n user.mergerfs.branches -v '+/mnt/new-disk' /mnt/pool/.mergerfs

# Verify
getfattr -n user.mergerfs.branches /mnt/pool/.mergerfs
```

After adding live, update `/etc/fstab` so the change persists after reboot:

```
/mnt/disk1:/mnt/disk2:/mnt/disk3:/mnt/new-disk  /mnt/pool  fuse.mergerfs  defaults,...  0 0
```

Note: `mergerfs.ctl` (a helper binary) is not installed by default. The xattr
approach works on all mergerfs versions that support the control interface
(verified on 2.33.5).

## Adding an empty disk to SnapRAID

When adding a new, empty disk to the SnapRAID data pool, the sync is fast.

**Why:** SnapRAID parity = XOR across all data disks. An empty disk contains
only zeros. `data XOR 0 = data` — parity is unchanged. SnapRAID only needs to
register the new disk in its content files and scan the empty disk (instant).

Procedure:
1. Add `data <diskname> /mnt/<diskname>` to `snapraid.conf`
2. Add `content /mnt/<diskname>/snapraid.content` to `snapraid.conf`
3. Run `snapraid sync` — completes in minutes (scan + content file writes)

Contrast: removing a disk **with data** requires moving files off it first,
then syncing. Removing an already-empty disk is equally fast (XOR with zeros
again leaves parity unchanged).

## `snapraid status` — output interpretation

Key fields in the status report:

| Field | Meaning |
|-------|---------|
| Free GB | Based on last sync state — may differ from `df` if files were added since last sync |
| Scrub graph (`*`) | Blocks scrubbed most recently. `o` = older. Sparse graph = scrub hasn't covered the full array yet |
| `X% not scrubbed` | Normal after monthly partial scrubs — each run covers a fraction of the array |
| `N files with zero sub-second timestamp` | Files copied without sub-second precision; fix with `snapraid touch` → `snapraid sync` |

**Free space discrepancy (snapraid vs df):** If snapraid reports more free space
than `df`, files were written to the pool since the last sync. Those files exist
on disk but snapraid doesn't know about them yet — they are unprotected.
Run `snapraid sync` to close the gap.

## Related

- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
- [Disk Diagnostics](../linux/disk-diagnostics.md)
- [Samba Server Config](samba-server-config.md)
