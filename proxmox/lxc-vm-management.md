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

## Related

- [Thin-Pool Recovery](thin-pool-recovery.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
