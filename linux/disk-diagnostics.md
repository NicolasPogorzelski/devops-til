# Disk Diagnostics

## When to suspect a disk

Symptoms that should trigger disk investigation:
- I/O errors in `dmesg`
- Filesystem unexpectedly remounted read-only
- Application errors of the form "input/output error"
- SnapRAID hash mismatch during `scrub`
- Slow read/write performance that wasn't there before
- Reallocated sectors increasing over time

The order of investigation: kernel logs -> SMART -> block-level test.

## Step 1 - Kernel logs (`dmesg`)

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
| `Remounting filesystem read-only` | The kernel gave up on writes - usually after repeated I/O errors |

Note the device name (`sdX`) and the timestamps. A burst of errors at one moment is different
from a slow drip over weeks.

Use `dmesg -T` (`-T` = human-readable timestamps). Without it you get "seconds since boot" and
cannot tell whether the errors are from this morning or from a boot three weeks ago.

### Who reported the error? `hostbyte`, `driverbyte`, sense key

**An `I/O error` line alone does not tell you the disk is bad.** It tells you *some layer*
returned an error to the block layer. Which layer matters enormously: a bad sector means replace
the disk; a transport fault means check the cable, the controller, or the power supply.

The `I/O error` line is preceded by the SCSI result, and that is where the answer is. Always read
with `grep -B4` - the cause sits *above* the symptom:

```bash
dmesg -T | grep -B4 -A1 "I/O error, dev sdc"
```

Two very different results:

```
# Real media failure - the DRIVE says it cannot read the sector
sd 0:0:0:0: [sdc] tag#12 FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_SENSE
sd 0:0:0:0: [sdc] tag#12 Sense Key : Medium Error [current]
sd 0:0:0:0: [sdc] tag#12 Add. Sense: Unrecovered read error
```

```
# Transport fault - the HOST ADAPTER gave up; the drive never complained
sd 9:0:0:0: [sdc] tag#628 FAILED Result: hostbyte=DID_SOFT_ERROR driverbyte=DRIVER_OK cmd_age=19s
sd 9:0:0:0: [sdc] tag#628 CDB: Read(10) 28 00 07 7c 0e 60 00 00 18 00
```

| Field | Who sets it | Reading |
|---|---|---|
| `hostbyte=DID_OK` | host adapter | adapter is fine; look further down |
| `hostbyte=DID_SOFT_ERROR` | host adapter | transient adapter/link fault - retryable, **not** the media |
| `hostbyte=DID_BAD_TARGET` | host adapter | device is gone (expected right after a hot-unplug) |
| `driverbyte=DRIVER_SENSE` | driver | the drive returned sense data - read the sense key |
| `driverbyte=DRIVER_OK` | driver | **no sense data at all** - the drive said nothing |
| `Sense Key: Medium Error` | **the drive** | the authoritative "I cannot read this sector" |
| `cmd_age=19s` | kernel | the command sat 19 s before failing -> **timeout**, not a read failure |

Three tells that an error is *not* the media:

1. **No sense key.** A drive that cannot read a sector reports so explicitly. Silence means it
   was never asked, or never answered.
2. **`cmd_age` in whole seconds.** A failed read is reported in milliseconds. Seconds means a
   command timed out somewhere on the path.
3. **SMART counters do not move.** Cross-check immediately (Step 2). If the kernel logs errors and
   the drive's own counters and error log stay at zero, the fault is *between* them.

Also check which controller the disk is actually on before blaming the disk:

```bash
# ATA enumeration - every AHCI/SATA device shows up here
dmesg -T | grep -E "^\[.*\] ata[0-9]+(\.[0-9]+)?: "

# A SAS/SCSI HBA looks completely different: sas_address, phy(), enclosure, mpt3sas/mpt2sas
dmesg -T | grep -iE "mpt3sas|mpt2sas|sas_address"

# HBA identity
lspci -nn | grep -iE "sas|raid"
```

A disk that never appears in the `ata` enumeration is not on the SATA controller - it hangs off an
HBA, and the HBA's firmware, cabling and cooling are now suspects. For LSI SAS2008-class cards,
`FWVersion(20.00.07.00)` is the known-good P20 phase; 20.00.00.00-20.00.04.00 are the buggy ones.

### Is it every boot, or just this one?

`dmesg` only shows the *current* boot. To distinguish "one-off" from "every time", you need the
persistent journal:

```bash
journalctl --list-boots            # 0 = current, -1 = previous, ...
journalctl -k -b -2 | grep -ci "dev sdc"
```

`-k` restricts to kernel messages. Intermittent errors that appear on some boots and not others,
always in the same window, point at load-dependent behaviour (peak current draw during spin-up,
thermal ramp) rather than at a fixed bad sector.

## Step 2 - SMART (Self-Monitoring, Analysis and Reporting Technology)

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

### `SMART overall-health: PASSED` means almost nothing

`smartctl -H` asks the firmware whether any attribute has crossed its own failure threshold. A
drive can report `PASSED` while 7680 sectors are unreadable, because the vendor's thresholds are
set for warranty purposes, not for your data. Seen in the field:

```
SMART overall-health self-assessment test result: PASSED
197 Current_Pending_Sector   ...  -  7680
198 Offline_Uncorrectable    ...  -  7680
  5 Reallocated_Sector_Ct    ...  -  0
187 Reported_Uncorrect       ...  -  21
```

Never quote `-H` as evidence of health. Read `-A`.

### `Pending` high while `Reallocated` stays 0

Counter-intuitive, and it is the worse case, not the better one:

- A pending sector is one the drive **cannot read**.
- The spare pool is consumed on **write**, not on read. The drive only remaps a sector when
  something writes to it, because only then does it have valid data to put in the spare.
- So `Reallocated = 0` with `Pending = 7680` does not mean "the drive is coping". It means
  7680 sectors hold data that can never be read back, and nothing has overwritten them.

A pending count that *drops* without reallocations rising means those sectors were rewritten and
turned out fine. `Reported_Uncorrect` (attribute 187) is the honest counter: it only goes up, and
it counts errors the drive actually surfaced to the OS.

### The drive's own error log is the tiebreaker

```bash
smartctl -l error /dev/sdX      # errors the DRIVE recorded
smartctl -l selftest /dev/sdX   # self-test history
```

If the kernel logs I/O errors and this reads `No Errors Logged`, the drive never saw a problem.
The fault is on the path to it - cable, backplane, HBA, or power. Do not replace the disk.

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

Tests run in the background - the system stays usable. Results land in the SMART log.

```bash
# View test history
smartctl -l selftest /dev/sdX
```

## Step 3 - Block-level test (`badblocks`)

If SMART is silent but you still suspect issues, scan the raw blocks:

```bash
# Read-only test - safe on a mounted filesystem if you accept slow I/O
badblocks -sv /dev/sdX

# Destructive write+verify - wipes the disk! Only on unmounted, unused drives
badblocks -wsv /dev/sdX
```

| Flag | Effect |
|---|---|
| `-s` | Show progress |
| `-v` | Verbose - print each bad block |
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
repair, **investigate the disk that produced the mismatch** - silent corruption is a strong
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

Device names (`/dev/sda`, `/dev/sdb`) are not stable across reboots - they depend on
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
   ├── Read the SCSI result ABOVE the I/O error line (dmesg -T | grep -B4)
   │       │
   │       ├── driverbyte=DRIVER_SENSE + Sense Key: Medium Error
   │       │      └─-> the DRIVE says the sector is unreadable. Continue to SMART.
   │       │
   │       └── hostbyte=DID_SOFT_ERROR, no sense data, cmd_age in seconds
   │              └─-> TRANSPORT fault, not media. Do NOT buy a disk.
   │                  Check: which controller (ata* vs mpt3sas)? HBA firmware?
   │                  cable/backplane? HBA cooling? PSU rail under load?
   │                  Cross-check: smartctl -l error must read "No Errors Logged"
   │                  and every media counter must be zero.
   │
   ├── SMART (-A, never -H): reallocated/pending/Reported_Uncorrect increasing?
   │       │
   │       ├── yes ─-> replace disk; restore from parity (SnapRAID fix) or backup
   │       └── no  ─-> the drive disagrees with the kernel -> look at the path, not the disk
   │
   ├── Errors only in a specific window (e.g. boot)?
   │       └─-> load-dependent. Compare boots via journalctl -k -b -N.
   │           Peak current draw, thermal ramp, controller init - not a fixed bad sector.
   │
   ├── SnapRAID hash mismatch? ────yes─-> snapraid fix, then investigate the offending disk
   │
   └── Performance regression only? ────-> iostat, check %util and await
```

**The trap this tree exists to prevent:** "dmesg shows I/O errors on the disk holding everything"
reads like an emergency and invites an immediate replacement. Indication is not diagnosis. Read
the line above the symptom first.

## Related

- [Storage: SnapRAID + MergerFS](../storage/snapraid-mergerfs.md)
- [Linux: LVM Thin Provisioning](lvm-thin-provisioning.md)
- [Proxmox: Thin-Pool Recovery](../proxmox/thin-pool-recovery.md)
