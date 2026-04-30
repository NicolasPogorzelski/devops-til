# Docker Data Root Migration

## What it is

Docker and containerd store their engine data in two separate default locations on the root disk:

| Component | Default path | What's stored |
|---|---|---|
| containerd | `/var/lib/containerd` | Image layers, snapshots, content blobs (~5–7 GB per service stack) |
| Docker | `/var/lib/docker` | Named volumes, network metadata, container configs (~few hundred MB) |

These paths are configurable. Moving them off the root disk prevents SSD thin-pool pressure
from image accumulation — especially relevant on Proxmox LXCs where root disks are small (8–16 GB).

## Configuration

### Docker (`/etc/docker/daemon.json`)

Create or edit the file:

```json
{"data-root": "/path/to/aux/docker-data"}
```

`data-root`: tells Docker where to store all engine data. If the file does not exist,
Docker uses `/var/lib/docker`.

### containerd (`/etc/containerd/config.toml`)

Set or uncomment the `root` field:

```toml
root = "/path/to/aux/containerd"
```

`root`: the base directory for containerd's persistent state. Default is `/var/lib/containerd`.

Both config files are read at daemon startup — changes require a service restart.

## Migration procedure

This procedure has zero data loss risk: old data is only deleted after the new location
is verified and the service stack is confirmed healthy.

```bash
# 1. Create target directories
mkdir -p /var/lib/<service>/containerd /var/lib/<service>/docker-data

# 2. Stop service stack
docker stop <container1> <container2> ...

# 3. Stop Docker and containerd
systemctl stop docker docker.socket containerd

# 4. Copy data — use -aH to preserve hard links (containerd uses them internally)
rsync -aH /var/lib/containerd/ /var/lib/<service>/containerd/
rsync -aH /var/lib/docker/     /var/lib/<service>/docker-data/

# 5. Verify sizes match
du -sh /var/lib/containerd/ /var/lib/<service>/containerd/
du -sh /var/lib/docker/     /var/lib/<service>/docker-data/

# 6. Apply new config (daemon.json + config.toml)

# 7. Start services
systemctl start containerd docker

# 8. Verify images are visible from new location
docker images

# 9. Start service stack
docker start <container1> <container2> ...

# 10. Wait for healthy status
docker ps

# 11. Only after confirmed healthy: delete old directories
rm -rf /var/lib/containerd /var/lib/docker
```

## Why `rsync -aH` and not just `rsync -a`

containerd uses hard links extensively for image layer deduplication. Without `-H`
(preserve hard links), `rsync` copies each hard-linked file as an independent copy.
This doubles (or more) the storage used and can cause containerd state inconsistencies.

Symptom of missing `-H`: `du` on the destination reports significantly more than the source.

## Boot-time dependency

After migration, Docker depends on the target mount being available at startup.

**In Proxmox LXCs:** mount points (`mp0`, `mp1`) are applied by the LXC runtime *before*
the container's init process starts. The mount is always available before systemd — no
additional configuration needed.

**In VMs:** if the target path is on a separate disk, Docker's systemd unit needs an
explicit `After=` dependency on the mount unit to prevent a race condition.

## Reclaiming SSD thin-pool blocks

Deleting the old directories frees filesystem space but does not immediately reclaim
thin-pool blocks. Run `fstrim` from the Proxmox host after deletion:

```bash
# Single LXC
PID=$(lxc-info -n <ctid> | awk '/^PID:/{print $2}')
nsenter -t $PID --mount -- fstrim -v /

# Multiple LXCs at once
for ctid in 211 230 200 220; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  nsenter -t "$PID" --mount -- fstrim -v /
done
```

## When to do this

Configure Docker data root on Aux1TB **from the start** when onboarding a new Docker-based LXC.
Set `data-root` in `daemon.json` and `root` in `config.toml` before pulling the first image.
Retroactive migration works but requires a planned service downtime window.

## Related

- [LVM Thin Provisioning](../linux/lvm-thin-provisioning.md)
- [Daemon Recovery](daemon-recovery.md)
- [Bind-Mount Pitfalls](bind-mount-pitfalls.md)
