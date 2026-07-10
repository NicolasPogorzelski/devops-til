# Mount Existence vs Mount Identity

A guard that asks *"is something mounted here?"* answers a different question from
*"is the **right thing** mounted here?"* — and when a remote filesystem fails to mount, those two
questions give opposite answers.

This is a recurring bug class, not a one-off. On a single platform audit it appeared three times
independently, in three different tools, written by three different mechanisms.

## The failure shape

A CIFS/NFS share is mounted on a host at `/mnt/smb/books-rw`. Something else — an LXC bind mount,
a container volume, an application — consumes that path.

When the share is mounted, the consumer sees the share. When the mount **fails**, the consumer
does not see an error. It sees the **empty directory that the mountpoint was created from**, which
still exists on the local root filesystem, still has an inode, and is still a perfectly valid
directory.

Nothing crashes. Nothing is `ENOENT`. The path is there. It is just the wrong filesystem.

## Why the obvious guards do not catch it

| Guard | What it actually tests | Why it passes anyway |
|---|---|---|
| `[ -d "$DIR" ]` | The path is a directory | The empty mountpoint underneath *is* a directory |
| `mountpoint -q "$DIR"` | *A* mount exists at this path | An LXC bind mount is a mount. It is mounted — from `pve-root` |
| `mkdir 0` (Proxmox storage) | Refuse to create the directory | The directory already exists, so nothing is created and nothing is refused |

`mountpoint -q` is the seductive one. It looks like the correct tool, it is the tool everyone
reaches for, and inside a container it returns true for a bind mount whose *source* is the failed
mountpoint's empty directory. The guard tested that a mount existed. It never tested **which**.

## The correct test: assert the filesystem type

```bash
fstype="$(findmnt -no FSTYPE "$DIR" 2>/dev/null || true)"
if [ "$fstype" != "cifs" ]; then
    echo "$DIR is not a CIFS mount (fstype='${fstype:-none}')" >&2
    exit 1
fi
```

| Part | Why |
|---|---|
| `findmnt` | Reads the kernel's mount table, not the filesystem. `-n` drops the header, `-o FSTYPE` prints one column |
| `2>/dev/null \|\| true` | `findmnt` exits 1 when the path is not a mount at all. Under `set -euo pipefail` that aborts the script before the useful error message is printed |
| `!= "cifs"` | Identity, not existence. The local root filesystem is `ext4`; the share is `cifs`. They can never be confused |
| `exit 1`, not `exit 0` | See below |

Where a filesystem type is not distinctive enough, assert on the source instead:
`findmnt -no SOURCE "$DIR"` returns e.g. `//<storage-host>/Books-service` for CIFS versus
`/dev/mapper/pve-root[/mnt/smb/books-rw]` for the bind-to-empty-dir case. The `[...]` suffix on a
bind mount names the subtree of the source device — a strong tell on its own.

Confirming the diagnosis from inside the affected container:

```bash
findmnt -no FSTYPE,SOURCE /books-rw
# healthy:  cifs   //<storage-host>/Books-service
# broken:   ext4   /dev/mapper/pve-root[/mnt/smb/books-rw]
```

## The second half of the bug: `exit 0` on a failed guard

Several of these scripts, having failed their (weak) check, exited **0**. The reasoning at the
time was "nothing to do, that's not an error."

It is an error. A backup script that cannot see its backup target has not succeeded. Exiting 0
means:

- the systemd unit ends in `inactive (dead)`, not `failed`
- `node_systemd_unit_state{state="failed"}` never goes to 1
- the alert rule that exists specifically to catch this never fires
- the dashboard stays green while the job has not run for a month

**A precondition that is not met is a failure.** Exit non-zero and let the scheduler record it.
The whole value of moving a job from cron to a systemd timer is that a non-zero exit becomes
observable state; throwing that away with `exit 0` gives back everything the migration bought.

## Where else this shape appears

- **Proxmox storage definitions.** A directory storage without `is_mountpoint 1` is considered
  active whenever its path exists. If the backing disk fails to mount, Proxmox happily writes
  guest images into the empty mountpoint on the boot disk until it fills. `mkdir 0` does not
  prevent this — it only stops Proxmox from *creating* the directory, which already exists.
  `is_mountpoint 1` is the option that asserts identity.
- **Docker bind mounts.** A bind source that does not exist is silently created as an empty,
  root-owned directory. The container starts, sees an empty volume, and reinitialises its data.
- **`systemd` `RequiresMountsFor=`.** The correct declarative form of this guard: the unit will
  not start unless the named path is actually a mount. Prefer it to a shell check inside the
  script when the consumer is a systemd unit anyway.

## The general lesson

Any check of the form *"does the thing exist"* is weaker than *"is the thing what I think it is"*,
and the gap between them is exactly where a silent failure lives. When a resource can be
**shadowed** by something cheaper that looks like it — an empty directory under a mountpoint, a
localhost bind under a missing interface, a default config under a missing drop-in — existence
checks pass and the system does the wrong thing quietly.

Ask what the resource *is*, not whether it is *there*.

## Related

- [Linux: systemd Mount Units & the Network-Mount Boot-Race](systemd-mount-units.md)
- [Linux: Bash Scripting Patterns](bash-scripting-patterns.md)
- [Linux: Cron, systemd Timers & Scheduled Maintenance](cron-and-scheduling.md)
- [Proxmox: LXC Bindmount: CIFS via Host](../proxmox/lxc-bindmount-cifs.md)
- [Docker: Bind-Mount Pitfalls](../docker/bind-mount-pitfalls.md)
