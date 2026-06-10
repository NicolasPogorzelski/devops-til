# systemd Mount Units, `nofail`, and the Network-Mount Boot-Race

How a network share (CIFS/NFS) mounted via `/etc/fstab` becomes a systemd
`.mount` unit, why it can silently end up `failed` after a reboot, and why a
re-mount on the host is *not* visible inside an already-running LXC container.

## fstab entries become `.mount` units

systemd generates a transient `.mount` unit for every `/etc/fstab` line at boot
(`systemd-fstab-generator`). The unit name is the mount path, escaped:

- `/mnt/smb/books-rw` → `mnt-smb-books\x2drw.mount`
- get the exact name with: `systemd-escape -p --suffix=mount /mnt/smb/books-rw`

So `mount /mnt/smb/books-rw`, `systemctl start 'mnt-smb-books\x2drw.mount'`, and
the fstab line all drive the *same* unit. `systemctl status <unit>` /
`journalctl -u <unit>` work on fstab mounts, not just hand-written units.

## `_netdev` and `nofail` — what they actually do

- `_netdev` — orders the mount *after* the network is up (pulls in
  `network-online.target`). Without it, systemd may try to mount a network share
  before the NIC has an address.
- `nofail` — if the mount fails, **boot continues anyway** (no emergency shell).

The trap: `nofail` does **not** retry. If the mount fails once at boot, the unit
is left in state `failed` and simply stays that way until something re-triggers
it. The system looks healthy; the share is just silently absent.

### The boot-race (observed 2026-06-10, LXC220 books share)

```
mnt-smb-books\x2drw.mount: failed
mount error(113): could not connect to 192.168.0.154 — Unable to find suitable address.
```

`113` = `EHOSTUNREACH`. The mount fired before the route to the SMB server was
ready. A *sibling* share to the **same** server was mounted and healthy — proof
it was a timing race at that one attempt, not a server/network defect. `nofail`
let boot proceed; nothing retried, so the share stayed gone for ~12h until a
manual `mount`.

This is the same fault class as a service binding a not-yet-assigned IP (see
[systemd Service Hardening](systemd-service-hardening.md) — `ExecStartPre`
readiness gates): *ordering says "after network", but "network up" ≠ "this
specific peer reachable".*

Durable fixes (pick per criticality):
- `x-systemd.automount` + `x-systemd.idle-timeout` — mount lazily on first
  access instead of at boot, so a slow peer doesn't matter.
- `x-systemd.mount-timeout=` and/or an explicit `After=`/`Wants=` on the unit
  that actually carries the route (e.g. `tailscaled.service`).
- A readiness gate that polls until the peer answers before mounting.

`nofail` alone is "don't block boot" — it is **not** "make the mount eventually
appear".

## Diagnosis cheatsheet

```bash
mountpoint -q /path && echo MOUNTED || echo NOT-MOUNTED   # is it mounted?
findmnt /path                                             # what is mounted there
systemctl --failed | grep -i <share>                      # failed mount units
journalctl -b -u 'mnt-...\x2d....mount'                    # why it failed this boot
grep <share> /etc/fstab                                   # the source-of-truth options
```

`mountpoint -q` returns true for **any** mount — including a *bind* mount that
fell through to an empty directory (below). "It's a mountpoint" ≠ "the right
filesystem is there"; confirm the backing device with `findmnt` / `/proc/mounts`.

## LXC gotcha: a host re-mount does not propagate into a running container

Proxmox LXC bind mounts (`mpN: /host/path,mp=/ctr/path`) are established **at
container start**. If the host path was an *empty, unmounted* directory at that
moment, the container's bind captured that empty directory.

Mounting the share on the host *afterwards* does **not** appear inside the
already-running container: mount propagation across the LXC boundary is
`private`/`slave`, not `shared`, so new mount events don't cross into it.

Symptom seen: inside the container, `/books-rw` showed
`/dev/mapper/pve-root … ext4`, owner `nobody (65534)`, empty — i.e. the bind had
fallen through to the host's local root fs where the unmounted CIFS target dir
lives. The fix sequence:

1. `mount /mnt/smb/books-rw` on the **host** (verify with `findmnt` + `ls`).
2. `pct reboot <ctid>` — only a container restart re-establishes the bind onto
   the now-populated mount.

## Bonus: POSIX mode is cosmetic on CIFS

A CIFS mount with `uid=/gid=/forceuid/forcegid/file_mode=/dir_mode=` *displays*
those owners/permissions, but access is really decided by the SMB server ACLs
for the mount's credential user. So `root` can be shown as "other" with no
write bit yet still create files (and an existing file may refuse an overwrite
while a sibling allows it). Don't reason about CIFS access from `ls -l` alone —
test the actual operation. Corollary: `cp -a` (preserve owner/mode) often fights
`forceuid`; plain `cp` and letting the mount force the metadata is more robust.

See also: [systemd Basics](systemd-basics.md),
[LXC/VM Management](../proxmox/lxc-vm-management.md).
