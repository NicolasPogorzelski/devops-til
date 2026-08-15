# LVM Thin Provisioning

## What it is

Thin provisioning lets you allocate more virtual disk space to VMs and containers than physically
exists on the storage pool. The pool only grows when data is actually written - not when the
disk is created.

Proxmox uses a LVM thin-pool (`local-lvm`) for all VM and LXC disks by default.

## Why `df` lies inside a container

`df -h /` inside an LXC container reports the size of the virtual disk (e.g. 8G), not the
thin-pool utilization. A container can show 4G free while the underlying pool is at 100%.

Always check pool utilization on the Proxmox host:

```bash
lvs -o lv_name,lv_size,data_percent
```

## What happens when the pool is full

- QEMU VMs enter `io-error` state and suspend (all writes fail)
- LXC containers keep running but all writes fail silently
- In-progress package downloads are truncated -> corrupt `.deb` archives
- Binaries being written mid-upgrade are truncated -> corrupt ELF files

## How to reclaim space (fstrim)

Deleting files inside a container does not automatically free blocks in the thin-pool.
The pool needs to be told that those blocks are free - this is done with `fstrim`.

### Inside VMs (works normally via SSH)

```bash
sudo fstrim -v /
```

### Inside LXC containers (blocked - must use nsenter from Proxmox host)

`fstrim` inside an LXC fails with `FITRIM ioctl failed: Operation not permitted` because
the FITRIM ioctl is blocked by the LXC security profile.

Workaround - run from the Proxmox host using the container's PID namespace:

```bash
PID=$(lxc-info -n 200 | awk '/^PID:/{print $2}')
nsenter -t $PID --mount -- fstrim -v /
```

Loop over all containers:

```bash
for ctid in 200 210 211 220 230 240 260; do
  PID=$(lxc-info -n "$ctid" 2>/dev/null | awk '/^PID:/{print $2}')
  nsenter -t "$PID" --mount -- fstrim -v /
done
```

## Investigating what fills a root disk

### `df -h` vs `du -xh` discrepancy

`df -h /` shows the filesystem size and usage. `du` without flags crosses into submounts
and inflates numbers. Always use `-x` (one filesystem only):

```bash
sudo du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20
```

`-x` / `--one-file-system`: do not cross filesystem boundaries (ignores bind mounts, SMB
mounts, Docker volumes on different partitions). Without `-x`, `du /var/lib` in an LXC
with a bind-mount at `/var/lib/paperless` will include the full Aux1TB disk in the total.

### Checking Proxmox storage pools

```bash
pvesm status          # all pools: type, total, used, available, %
pvesm list local-lvm  # all volumes in the thin-pool with nominal sizes
```

Nominal size (from `pvesm list`) != actual thin-pool consumption (from `pvesm status`).
A 64 GB nominal disk only consumes thin-pool blocks for data actually written.

## Key commands

```bash
# Check pool utilization
lvs -o lv_name,lv_size,data_percent

# Check if VG has free space to extend the pool
vgdisplay pve | grep "Free PE"

# Check discard/passdown is enabled on the pool
lvdisplay pve/data | grep -i discard

# Enable passdown if not set
lvchange --discards passdown pve/data
```

## Related

- [Namespaces & nsenter](namespaces-nsenter.md)
- [Proxmox: Thin-Pool Recovery](../proxmox/thin-pool-recovery.md)
