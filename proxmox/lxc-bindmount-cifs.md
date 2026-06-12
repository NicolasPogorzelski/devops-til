# LXC Bindmount Architecture: CIFS via Host

## Key Insight

CIFS/SMB shares are not mounted inside the LXC — they are mounted on the **Proxmox host** and
then bindmounted into the container via `mp` entries in the LXC config.

This is why `mount` inside the LXC shows `type cifs` even though the LXC has no fstab entry
and no `cifs-utils` installed: the kernel mount object lives on the host, the container just
sees it propagated in.

## LXC Config (`/etc/pve/lxc/<id>.conf`)

```
mp0: /mnt/aux1TB/postgres,mp=/var/lib/postgresql   # local block → container path
mp1: /mnt/smb/postgres-backups,mp=/mnt/backups     # host CIFS mount → container path
```

- `mp<n>` — mount point index (0, 1, 2, …)
- First field — **host path** (must exist and be mounted on the host)
- `mp=` — **container path** where it appears inside the LXC

## Implication: CIFS mount changes happen on the host

To change the remote IP of a CIFS share that is bindmounted into an LXC:

1. Edit `/etc/fstab` on the **Proxmox host**
2. Stop the LXC (`pct stop <id>`)
3. Stop the automount unit: `systemctl stop $(systemd-escape -p --suffix=automount <mountpoint>)`
4. Unmount the old CIFS: `umount <mountpoint>`
5. Reload systemd: `systemctl daemon-reload`
6. Start the LXC (`pct start <id>`) — the automount triggers on first access

## systemd automount (`x-systemd.automount` in fstab)

With `x-systemd.automount`, the CIFS share is mounted on-demand (first filesystem access),
not at boot. Two units are created by systemd:

- `<path>.mount` — the actual CIFS mount
- `<path>.automount` — the trigger that fires the mount on access

The automount unit name is derived from the path using systemd escaping:
```bash
systemd-escape -p --suffix=automount /mnt/smb/postgres-backups
# → mnt-smb-postgres\x2dbackups.automount
```

### Stacked mount pitfall

If `mount <path>` is called **before** `systemctl daemon-reload` after an fstab change,
systemd mounts with the **old** cached config. After daemon-reload, the automount trigger
fires again on access → two CIFS mounts stacked on the same path (old IP + new IP).

Fix: stop the automount unit, unmount, reload, then let it remount via LXC start.

## Verification

```bash
# Check mount from Proxmox host
mount | grep <sharename>

# Check LXC config
cat /etc/pve/lxc/<id>.conf | grep ^mp

# Trigger automount manually (causes mount on first access)
ls <mountpoint>
mount | grep <sharename>   # should now show the CIFS entry
```

## Samba tooling (on the SMB server)

```bash
testparm -s              # dump active smb.conf (parsed, comments stripped)
sudo pdbedit -L          # list all Samba users (requires sudo — reads passdb.tdb)
sudo pdbedit -L -u <user>  # check specific user
getent passwd <user>     # verify Linux system user exists
```
