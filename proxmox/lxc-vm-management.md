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

## Related

- [Thin-Pool Recovery](thin-pool-recovery.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
- [Tailscale TUN in Unprivileged LXCs](lxc-tailscale-tun.md)
