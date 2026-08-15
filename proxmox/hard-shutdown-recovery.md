# Proxmox Hard Shutdown Recovery

## What happens after a forced power-off

An unclean shutdown (power loss, forced power-off) leaves filesystems unmounted
without sync. On reboot, Proxmox starts normally but LXC containers may fail to
start automatically due to two independent issues.

## LXC boot failure: SMB mount dependency (exit 19)

**Symptom:**

```
lxc_init: Failed to run lxc.hook.pre-start for container "260"
TASK ERROR: startup for container '260' failed
```

**Cause:** A container has a bind mount (`mp1`, `mp2`, ...) pointing to an SMB path
on the Proxmox host. If the storage VM/LXC that provides the SMB mount is still
booting, the path doesn't exist yet. The LXC pre-start hook checks all mount
points - if one is missing, it exits with code 19 (`ENODEV` = "No such device").

**Fix:**

```bash
# On Proxmox host: verify the SMB path exists before starting the container
ls /mnt/smb/postgres-backups

# If it's there, start the container manually
pct start 260
```

**Prevention:** Increase the `up` delay in the container's startup order config
(Proxmox WebUI -> container -> Options -> Start/Shutdown Order).

## SSH unreachable after reboot (Tailscale race condition)

**Symptom:** SSH to an LXC times out or refuses connection immediately after boot,
even though the container is running.

**Cause:** The sshd_config contains `ListenAddress <tailscale-ip>`. sshd starts
before Tailscale connects (~30-60 s). During that window, sshd has no address to
bind to - connections are refused.

**Fix:**

```bash
# From Proxmox host: check Tailscale status inside the container
pct exec 250 -- tailscale status

# If Tailscale is stuck, restart it
pct exec 250 -- systemctl restart tailscaled

# Once Tailscale is up, SSH works normally via the Tailscale IP
```

**Note:** This is intentional hardening (SSH not exposed on LAN). It is a known
tradeoff, not a misconfiguration.

## Access hierarchy after hard shutdown

Use the first available method:

| Priority | Method | Requires |
|---|---|---|
| 1 | Proxmox WebUI via Tailscale | Tailscale on host connected |
| 2 | Proxmox WebUI via LAN | `https://<proxmox-lan-ip>:8006` |
| 3 | SSH to Proxmox host (LAN) | `ssh root@<proxmox-lan-ip>` |
| 4 | LXC console (WebUI) | Proxmox WebUI accessible |

**Finding the Proxmox LAN IP:** Fritz!Box -> Heimnetz -> Netzwerk, or `arp -n` from
any device on the LAN.

## Starting all containers after recovery

```bash
# List container states
pct list

# Start in dependency order (storage-dependent containers last)
pct start 200 && pct start 210 && pct start 211 && pct start 220
pct start 230 && pct start 240 && pct start 250
# Start postgres last - depends on SMB from storage VM
ls /mnt/smb/postgres-backups && pct start 260

# Verify all Ansible-managed nodes are reachable
cd ~/git/homelab-server-architecture/ansible
ansible all -m ping
```

## Diagnosing why a container failed to start

```bash
journalctl -u pve-container@260.service --no-pager -n 30
```

Common exit codes:
- `19` (`ENODEV`): bind-mount path not found - storage not ready
- `1`: generic failure - read the full journal output
