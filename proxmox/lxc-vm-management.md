# Proxmox: LXC & VM Management

## pct — LXC container management

```bash
pct status <ctid>          # running / stopped
pct start <ctid>
pct stop <ctid>
pct restart <ctid>
pct exec <ctid> -- <cmd>   # run a command inside the container
```

`pct exec` does not require SSH — it uses the Proxmox host's privileged access to
the container's namespaces. Useful when SSH is broken or Tailscale is down.

```bash
# Examples
pct exec 260 -- dpkg --configure -a
pct exec 230 -- systemctl status tailscaled
pct exec 200 -- df -h /
```

## qm — VM management

```bash
qm status <vmid>           # running / stopped / io-error
qm start <vmid>
qm stop <vmid>
qm reboot <vmid>
qm resume <vmid>           # resume from io-error or suspended state
```

`io-error` state means QEMU suspended the VM because a disk write failed
(typically: thin-pool full). Fix: free pool space, then `qm resume <vmid>`.

`qm guest exec` runs commands inside VMs — but requires qemu-guest-agent
to be installed and running. Without it, use the console instead.

```bash
# Run a command synchronously and get output + exit code
qm guest exec <vmid> --sync -- <command> [args]
```

| Flag | Meaning |
|---|---|
| `--sync` | Wait for the command to finish before returning (otherwise returns immediately with a PID) |
| `--` | Separates qm options from the command to execute |

Output is JSON:
```json
{
   "exitcode" : 0,
   "exited" : 1,
   "out-data" : "line1\nline2\n",
   "out-truncated" : 0
}
```

| Field | Meaning |
|---|---|
| `exitcode` | Return code of the command (0 = success) |
| `exited` | 1 = command has finished |
| `out-data` | stdout as a string (newlines as `\n`) |
| `out-truncated` | 1 if output was cut off due to length |

**`pct exec` vs `qm guest exec`:** The critical difference:

| | `pct exec` | `qm guest exec` |
|---|---|---|
| Target | LXC containers only | KVM VMs only |
| Requirement | None (uses namespace access) | qemu-guest-agent must be running |
| Syntax | `pct exec <ctid> -- <cmd>` | `qm guest exec <vmid> --sync -- <cmd>` |

Using `pct exec` on a VM VMID gives: `Configuration file 'nodes/server/lxc/<id>.conf' does not exist`.
Using `qm guest exec` on an LXC CTID gives a similar error. Know which type you're targeting.

## Console access

```bash
qm terminal <vmid>         # serial console (requires serial port configured in VM)
```

If `qm terminal` shows a blank screen with `grub>`, the GRUB shell loaded but
no getty is running on the serial port. Type `normal` to load the GRUB menu.

For VMs without serial console configured: use the Proxmox web UI
(noVNC console button in the VM view).

## lxc-info — LXC runtime info

```bash
lxc-info -n <ctid>         # state, PID, IPs, network stats
lxc-info -n 200 | awk '/^PID:/{print $2}'   # extract init PID (useful for nsenter)
```

## pvesm — storage management

```bash
pvesm status               # all storage backends and their utilization
```

## Differences: LXC vs VM

| Aspect | LXC | VM |
|---|---|---|
| Isolation | Namespace-based (shares host kernel) | Full hardware virtualization |
| Overhead | Low (no hypervisor layer) | Higher |
| fstrim | Blocked by LXC security profile, use nsenter from host | Works normally from inside |
| Console access | `pct exec` always works | Requires qemu-guest-agent or console |
| Root access | `pct exec` runs as root on host | Need SSH or console |
| Kernel | Host kernel | Own kernel |

## LXC unprivileged containers

Proxmox runs LXCs as unprivileged by default. UID/GID mapping shifts container
UIDs by 100000 — uid 0 inside the container = uid 100000 on the host.

This matters for bind mounts: a file owned by `root` (uid 0) inside the container
is actually owned by uid 100000 on the host. Use `chown 100000:100000` on the host
when preparing mounted directories for unprivileged LXCs.

## LXC config file — `/etc/pve/lxc/<ctid>.conf`

The container's full declarative state. Edit-and-restart is how most settings
change; `pct set` writes here too.

```ini
arch: amd64
hostname: lxc230-postgres
memory: 4096
cores: 4
ostype: debian
unprivileged: 1
features: nesting=1
onboot: 1
startup: order=3,up=30
rootfs: local-lvm:vm-230-disk-0,size=20G
mp0: storage:subvol-230-uploads,mp=/mnt/uploads,backup=0
mp1: local-lvm:vm-230-disk-1,mp=/var/lib/postgresql,size=50G
net0: name=eth0,bridge=vmbr0,ip=dhcp,firewall=1
```

| Directive          | Meaning                                                                  |
|--------------------|--------------------------------------------------------------------------|
| `unprivileged: 1`  | UID/GID-shifted container. Default and recommended.                      |
| `features: nesting=1` | Enable Docker-in-LXC. Required for any container running Docker        |
| `onboot: 1`        | Auto-start on host boot                                                  |
| `startup: order=N,up=M` | Boot order (lower=first). `up=M` is delay in seconds after this CT before starting the next |
| `mp0`, `mp1`, ...  | Mount points. Format: `<storage>:<volume>,mp=<path-inside-CT>,...`       |
| `mp<N>: backup=0`  | Exclude this mount from `vzdump` backups (use for shared/external storage)|

### Boot order modeling

`startup: order=3,up=30` reads as: "I'm in tier 3, and after I'm started,
wait 30 seconds before starting the next thing in line".

Set `startup: order=1` for storage and network foundation containers,
`order=2` for databases, `order=3` for application servers. The `up=30` delay
is for slow-starting services (databases) so app containers don't race them.

### `nesting=1` for Docker-in-LXC

Without `features: nesting=1`, Docker fails to start inside an unprivileged
LXC because it needs to mount cgroup hierarchies that LXC denies by default.
`nesting=1` permits mounting `/proc`, `/sys`, and cgroup subtrees from inside.

This is the *single* most common Docker-in-LXC issue. Set it at container
creation, or add to existing config and `pct stop && pct start` (not just restart —
config reload happens at start).

## VM config file — `/etc/pve/qemu-server/<vmid>.conf`

```ini
agent: 1
boot: order=scsi0
cores: 4
memory: 8192
onboot: 1
startup: order=1,up=60
ostype: l26
scsihw: virtio-scsi-single
scsi0: local-lvm:vm-100-disk-0,size=32G,iothread=1
scsi1: /dev/disk/by-id/ata-WDC_WD80EFAX-68KNBN0_VAGZSE0L,backup=0
net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0
```

| Directive                  | Why                                                                |
|----------------------------|--------------------------------------------------------------------|
| `agent: 1`                 | qemu-guest-agent enabled. Lets `qm shutdown` work cleanly          |
| `scsihw: virtio-scsi-single` | One virtio controller per disk. Best parallel I/O performance    |
| `iothread=1`               | Dedicated I/O thread per disk. Reduces VM CPU contention           |

### `/dev/disk/by-id/` for disk passthrough

Direct disk passthrough to a VM should use `/dev/disk/by-id/` paths, never
`/dev/sdX`:

```
scsi1: /dev/disk/by-id/ata-WDC_WD80EFAX-68KNBN0_VAGZSE0L
```

`/dev/sdX` numbering changes after reboots if hardware enumeration order shifts
(another disk added, controller reorder). `by-id` paths embed the model+serial
and are stable across reboots and hardware changes.

For SnapRAID/MergerFS storage VMs where disk identity matters: `by-id` is mandatory.

## Bind-mount propagation issue (KE)

**Symptom:** A bind-mount added to LXC config doesn't appear inside the running
container, even after `pct restart`.

**Cause:** `pct restart` is a soft restart that reuses the existing namespace.
LXC config changes affecting mounts only take effect on a fresh start.

**Fix:**

```bash
pct stop <ctid>
pct start <ctid>
```

The `stop` tears down namespaces; `start` recreates them with the current config.
This is also why `mp0`/`mp1` changes appear to "not work" until you do a stop+start.

## `run-rpc_pipefs.mount` failures (cosmetic)

**Symptom:** Inside an unprivileged LXC, `systemctl status` shows
`run-rpc_pipefs.mount` failed.

**Diagnosis:** `rpc_pipefs` is the in-kernel pipe filesystem used by NFS/RPC.
LXC blocks mounting it for security. The unit attempts to mount it on every
boot and fails.

**Fix:** None required if you're not using NFS. The failure is **cosmetic** —
nothing depends on rpc_pipefs unless you're an NFS client/server. Mask the unit
to keep status output clean:

```bash
pct exec <ctid> -- systemctl mask run-rpc_pipefs.mount
```

Document the mask in the container's runbook so future-you doesn't unmask it
out of curiosity and bring back the noise.

## Disk passthrough safety: one filesystem, one kernel

A raw disk passed into a VM (`scsiN: /dev/disk/by-id/…`) and simultaneously mounted on the
Proxmox host is a loaded gun. Both kernels can write; neither knows about the other. **ext4, xfs
and btrfs are not cluster filesystems — there is no locking across hosts.** The result of a
concurrent mount is metadata corruption, not a race you might win.

This survives reboots silently, because the danger only materialises when *something* mounts it in
the guest — an uncommented fstab line, a manual `mount`, a rebuild from an old fstab.

### Check what the running process actually has open

`qm config` shows the config file. It does not show what QEMU opened.

```bash
qm config 102 | grep -E '^(scsi|sata|virtio|ide)[0-9]'

# What the LIVE process holds — config and runtime can diverge
ps -o args= -C kvm | tr ',' '\n' | grep -i '<disk-serial>'
```

- `-o args=` — print only the command line; the `=` suppresses the column header.
- `-C kvm` — select processes named `kvm` (the running QEMU).
- `tr ',' '\n'` — QEMU's command line is one enormous comma-separated string; without splitting it,
  `grep` returns the whole thing and you see nothing.

Then correlate host and guest by **filesystem UUID**, not by device name (`sdX` is not stable):

```bash
# on the host
findmnt /mnt/<mountpoint>                 # source device + mount options (is it rw?)
dmesg -T | grep 'EXT4-fs.*mounted filesystem'   # prints the UUID

# in the guest
blkid -s UUID -o value /dev/sdX
```

Same UUID on both sides = same filesystem = one of them must go.

### Detaching safely

```bash
# 1. Prove the guest is not using it
findmnt /dev/sdX ; grep -c sdX /proc/mounts ; pvs | grep -c sdX ; grep -c sdX /proc/mdstat

# 2. Detach (hot-unplug with virtio-scsi-single)
qm set <vmid> --delete scsi8

# 3. Reversal — write the exact line down BEFORE you delete it
qm set <vmid> --scsi8 /dev/disk/by-id/<id>,size=<size>
```

`qm set --delete scsiN` on a **raw device path** simply removes the config line: no `unusedN` entry
appears and no data is touched, because a device path is not a storage-managed volume. (Data
destruction requires `qm disk unlink --force` / `destroy-unreferenced-disks`.)

The guest will log `Synchronize Cache(10) failed … hostbyte=DID_BAD_TARGET` — expected. The kernel
tried to flush the device's write cache after QEMU already removed it. Harmless if nothing was
mounted.

Afterwards, replace the guest's commented fstab line with an explicit warning. A bare `#`
documents nothing; the next person tidying up will uncomment it.

### `is_mountpoint 1` for directory storages

```
dir: appdata_aux1tb
	path /mnt/aux1TB
	content images
	mkdir 0
	is_mountpoint 1
```

- `mkdir 0` — do not *create* the path. It does **not** stop Proxmox from *writing into* an
  existing empty mountpoint.
- `is_mountpoint 1` — treat the storage as offline unless something is actually mounted there.

Without it, a disk that fails to mount at boot leaves an empty directory behind, Proxmox considers
the storage active, and VM disks get written into the host's **root filesystem** until it fills.

## Related

- [Thin-Pool Recovery](thin-pool-recovery.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
- [Tailscale TUN in Unprivileged LXCs](lxc-tailscale-tun.md)
- [Linux: Disk Diagnostics](../linux/disk-diagnostics.md)
