# Rescuing Data From a Failing Disk (Read-Only First)

[Disk Diagnostics](disk-diagnostics.md) ends at "replace the disk; restore from
parity or backup". But what if the dying disk has **no** parity and **no** backup —
a non-parity auxiliary disk holding local app state? Then you have to get the data
off it yourself, and the order of operations decides whether you keep it.

## The one rule: rescue before repair

**Never run `fsck`, a read-write mount, or anything that writes to a disk with
pending/uncorrectable sectors until the data is safely copied off.**

Two reasons:

1. A read-write `fsck` *writes* to dying media. Writing near worn sectors can
   trigger reallocation storms or push a marginal drive over the edge mid-repair.
2. `fsck` can "repair" damaged metadata by **deleting** what it can't reconcile.
   On a disk you haven't copied yet, a successful `fsck` can mean data loss.

A successful `fsck` also does not make the disk usable again — it fixes the
*filesystem*, not the thousands of bad sectors. The SMART verdict still stands:
that is a decommission, not a revival.

## Is it the disk or the cable?

Decide this before anything else — they look similar but mean opposite things
(see [Disk Diagnostics](disk-diagnostics.md) for the attribute table):

| dmesg / SMART signal | Source | Implication |
|---|---|---|
| `Medium Error` / `Unrecovered read error`, `Current_Pending_Sector` rising | the platter itself | the drive is dying — rescue + decommission |
| `UDMA_CRC_Error_Count` rising, link resets, `DID_ERROR`, no medium errors | the cable / controller | reseat the SATA cable; the drive may be fine |

A medium error is the drive reporting "I physically cannot read this sector." A
cable problem never produces that — it produces transport resets.

## Step 1 — Read-only mount without journal replay

A normal mount of a dirty ext4 **replays the journal**, which is a *write*. To read
without writing a single byte:

```bash
mount -o ro,noload UUID=<fs-uuid> /mnt/rescue
```

- `ro` — read-only.
- `noload` — do **not** load/replay the journal. This is the part that keeps the
  mount truly write-free; plain `-o ro` still replays a dirty journal.

If this succeeds and the tree is visible, the metadata survived and **file-level
rescue is possible** — the bad sectors are somewhere you haven't read yet. If it
fails, the metadata itself is damaged → jump to ddrescue (Step 4).

## Step 2 — Copy off, preserving ownership, most-valuable-first

Stream each directory as a `tar` to a healthy host. Run it **from the rescue
target**, pulling over SSH:

```bash
for d in postgres paperless monitoring; do
  ssh root@<dying-host> "tar -C /mnt/rescue --numeric-owner --ignore-failed-read -cf - $d" \
    > "$d.tar" 2> "$d.err"
done
```

Why `tar` and not file-level `rsync`:

| Concern | How tar handles it |
|---|---|
| Ownership/permissions | Stored **inside** the archive — the receiver needs no root, and exact UIDs restore later |
| Container-mapped UIDs (e.g. `100103`) don't exist on the rescue host | `--numeric-owner` stores numbers, not names |
| One unreadable file shouldn't abort the whole copy | `--ignore-failed-read` logs it to stderr and continues |
| Ordering | Copy databases/configs first, media/regenerable caches last, so an interruption can't lose the irreplaceable data |

`rsync -aHAX` is the alternative, but it needs **root on the receiver** to restore
ownership, and it copies loose files (ownership lost if the target is NTFS). The
tar-stream lands one opaque, ownership-complete blob on any Linux target.

## Step 3 — Separate real read errors from noise

```bash
grep -v 'socket ignored' *.err     # what's left is the real damage
```

`tar` prints `socket ignored` for Unix sockets (runtime IPC endpoints, e.g. inside
containerd snapshot dirs) — these are **not** data and are recreated at runtime.
Only lines like `Input/output error` are sectors the disk could not return. A
rescue that shows only `socket ignored` lost nothing.

Verify every archive lists cleanly:

```bash
for t in *.tar; do tar -tf "$t" >/dev/null && echo "$t OK" || echo "$t CORRUPT"; done
```

## Step 4 — When the metadata is damaged: ddrescue

If `ro,noload` won't mount (filesystem structures are in the bad region), do **not**
`fsck` the disk. Image it first with `ddrescue`, then repair the *image*:

```bash
apt install gddrescue
ddrescue --no-scrape /dev/sdX rescue.img rescue.map   # first pass: easy reads
ddrescue --retrim -r3 /dev/sdX rescue.img rescue.map  # retry the hard sectors
fsck -y rescue.img                                    # repair the COPY, never the disk
mount -o ro,loop rescue.img /mnt/rescue
```

`ddrescue` reads the good sectors first, keeps a **map file** of what's done, and
retries the bad regions last — so a disk that dies mid-rescue still yields
everything readable up to that point. The map makes it resumable.

## Sparse images: "allocated" lies, "live" is the truth

A VM disk stored as a sparse `.raw` shows two very different sizes:

- **allocated** (`du` / `df` on the *host*): the high-water mark of every block ever
  written — never shrinks, even after the guest deletes files (no auto-discard).
- **live** (`df` *inside* the guest, or a loop-mount): what is actually in use now.

A 300 GB image with 18 GB live can occupy 106 GB allocated. **File-level rescue
(tar the contents) sheds the dead space automatically**; imaging the raw disk
(ddrescue) copies the allocated high-water mark. Prefer file-level unless the
metadata is too damaged to mount.

## Decision flow

```
Disk has medium errors, no parity/backup for its data
   │
   ├─ ro,noload mount works? ──yes─→ tar contents off (Step 2), verify, decommission
   │
   └─ no ─→ ddrescue to an image (Step 4) → fsck the image → mount → tar contents off
```

Only after the data is verified off the disk should any repair attempt or
decommission proceed.

## Related

- [Disk Diagnostics](disk-diagnostics.md) — dmesg/SMART/badblocks, the diagnosis side
- [systemd Mount Units & the Network-Mount Boot-Race](systemd-mount-units.md) — `nofail` keeps a failed mount from blocking boot
- [Storage: SnapRAID + MergerFS](../storage/snapraid-mergerfs.md) — when parity *does* exist, restore instead
