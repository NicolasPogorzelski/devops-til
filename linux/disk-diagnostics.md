# Disk Diagnostics

## When to suspect a disk

Symptoms that should trigger disk investigation:
- I/O errors in `dmesg`
- Filesystem unexpectedly remounted read-only
- Application errors of the form "input/output error"
- SnapRAID hash mismatch during `scrub`
- Slow read/write performance that wasn't there before
- Reallocated sectors increasing over time

The order of investigation: kernel logs → SMART → block-level test.

## Step 1 — Kernel logs (`dmesg`)

The kernel logs every block-level error. Look for I/O errors first:

```bash
# All errors and warnings
dmesg --level=err,warn

# Live tail
dmesg -w

# Filter for disk-related lines
dmesg | grep -iE 'i/o error|sector|ata[0-9]|scsi|sd[a-z]'
```

| Pattern in dmesg | Means |
|---|---|
| `Buffer I/O error on dev sdX` | Block read/write failed at OS level |
| `ata1.00: failed command: READ FPDMA QUEUED` | SATA-level error (cable, controller, or disk) |
| `Medium error` | SCSI-level: the disk says this sector is unreadable |
| `Remounting filesystem read-only` | The kernel gave up on writes — usually after repeated I/O errors |

Note the device name (`sdX`) and the timestamps. A burst of errors at one moment is different
from a slow drip over weeks.

## Step 2 — SMART (Self-Monitoring, Analysis and Reporting Technology)

Modern HDDs and SSDs continuously self-monitor and expose the data via SMART.

```bash
# Full SMART report
smartctl -a /dev/sdX

# Just the overall health verdict
smartctl -H /dev/sdX
# Expected: "SMART overall-health self-assessment test result: PASSED"

# List all detected drives
smartctl --scan
```

`smartctl` requires root. Install via `apt install smartmontools` (Debian) or
`pacman -S smartmontools` (Arch).

### Critical attributes to check

```bash
smartctl -A /dev/sdX
```

| Attribute | What it means | Threshold for concern |
|---|---|---|
| `Reallocated_Sector_Ct` | Sectors that failed and were remapped to spares | Any value > 0; rate of change is the real signal |
| `Current_Pending_Sector` | Sectors that the drive can't read; will be remapped on next write | > 0 = imminent reallocation |
| `Offline_Uncorrectable` | Sectors the offline scan couldn't recover | > 0 = data corruption likely |
| `Temperature_Celsius` | Drive temperature | > 50°C sustained = airflow problem |
| `Power_On_Hours` | Total runtime hours | Useful for warranty claims and end-of-life planning |
| `Reallocated_Event_Count` | How many times reallocation happened | Increasing = drive is failing actively |
| `Spin_Retry_Count` (HDD) | Failed spin-up attempts | > 0 = motor/bearing issue |
| `UDMA_CRC_Error_Count` | Cable-level errors | > 0 = bad SATA cable, not the drive |

Key insight: **a single bad sector isn't a death sentence; a growing count is.** Run smartctl
periodically and watch the trend, not the absolute value.

### Run a self-test

The drive can run its own diagnostic without the OS reading every sector:

```bash
# Short test (~2 minutes, basic checks)
smartctl -t short /dev/sdX

# Long test (hours, reads every sector)
smartctl -t long /dev/sdX

# Estimate completion time + monitor progress
smartctl -a /dev/sdX | grep -A1 "self-test"
```

Tests run in the background — the system stays usable. Results land in the SMART log.

```bash
# View test history
smartctl -l selftest /dev/sdX
```

## Step 3 — Block-level test (`badblocks`)

If SMART is silent but you still suspect issues, scan the raw blocks:

```bash
# Read-only test — safe on a mounted filesystem if you accept slow I/O
badblocks -sv /dev/sdX

# Destructive write+verify — wipes the disk! Only on unmounted, unused drives
badblocks -wsv /dev/sdX
```

| Flag | Effect |
|---|---|
| `-s` | Show progress |
| `-v` | Verbose — print each bad block |
| `-w` | Destructive write-mode test (4 patterns: 0xaa, 0x55, 0xff, 0x00) |

Read-only `badblocks` reads every sector and reports unreadable ones. Destructive mode is the
gold standard for proving a disk is healthy before putting it into production but takes hours
to days for large drives.

## SnapRAID-specific: `snapraid fix`

If `snapraid scrub` reports a hash mismatch, the parity disk holds the correct data:

```bash
# Check what's broken
snapraid status

# Repair using parity (run as root, requires all data + parity disks online)
snapraid fix
```

`fix` reads parity, reconstructs the affected sectors, and writes them back. After successful
repair, **investigate the disk that produced the mismatch** — silent corruption is a strong
signal that the drive is degrading.

## `iostat` for performance

Slow disks show up as high I/O wait:

```bash
# Show every 2 seconds, with extended stats
iostat -x 2

# Watch a specific device
iostat -x 2 /dev/sdX
```

| Column | Meaning | Concerning when... |
|---|---|---|
| `%util` | % of time the device was busy | Sustained near 100% |
| `await` | Avg time per I/O request (ms) | HDD: > 50ms, SSD: > 5ms |
| `r/s`, `w/s` | Reads/writes per second | Use for capacity planning |
| `rkB/s`, `wkB/s` | Throughput | Compare against drive spec |

`iostat` is part of `sysstat`. The first sample is always cumulative-since-boot; the second
onward is actual interval data.

## Stable disk references

Device names (`/dev/sda`, `/dev/sdb`) are not stable across reboots — they depend on
detection order. Use `/dev/disk/by-id/` for any persistent reference:

```bash
ls -la /dev/disk/by-id/
# lrwxrwxrwx 1 root root  9 Apr 25 10:00 ata-WDC_WD80EFAX-68LHPN0_VAGV1XXX -> ../../sda
# lrwxrwxrwx 1 root root 10 Apr 25 10:00 ata-WDC_WD80EFAX-68LHPN0_VAGV1XXX-part1 -> ../../sda1
```

The by-id path includes the make and serial number, so it survives any reordering. Use it in:
- `/etc/fstab` (or use UUID for filesystems)
- Proxmox VM disk passthrough config
- SnapRAID `disk` directives
- Anything that needs to point at a specific physical drive

## UUID for filesystems

```bash
# Show all filesystem UUIDs
blkid

# UUID for a specific device
blkid /dev/sda1

# fstab entry using UUID
UUID=abc123-... /mnt/disk01 ext4 defaults,noatime 0 2
```

Filesystem UUIDs are written into the filesystem itself (set at `mkfs` time). They survive
moving the disk to a different controller. Prefer UUID for filesystems, by-id for raw disk references.

## Decision tree

```
I/O error symptom
   │
   ├── dmesg shows hardware errors? ────yes─→ Step 2 (SMART), then plan replacement
   │
   ├── SMART shows reallocated/pending sectors increasing?
   │       │
   │       ├── yes ─→ replace disk; restore from parity (SnapRAID fix) or backup
   │       └── no  ─→ Step 3 (badblocks read-only) to confirm
   │
   ├── SnapRAID hash mismatch? ────yes─→ snapraid fix, then investigate the offending disk
   │
   └── Performance regression only? ────→ iostat, check %util and await
```

## Related

- [Storage: SnapRAID + MergerFS](../storage/snapraid-mergerfs.md)
- [Linux: LVM Thin Provisioning](lvm-thin-provisioning.md)
- [Proxmox: Thin-Pool Recovery](../proxmox/thin-pool-recovery.md)
