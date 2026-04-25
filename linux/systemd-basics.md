# systemd Basics

## Units

Everything in systemd is a unit. The most common types:

| Unit type | Purpose | Example |
|---|---|---|
| `.service` | A process/daemon | `tailscaled.service` |
| `.mount` | A filesystem mount | `mnt-nextcloud.mount` |
| `.automount` | Mount on first access | `mnt-nextcloud.automount` |
| `.timer` | Scheduled execution (cron replacement) | `snapraid-sync.timer` |
| `.target` | Group of units (boot stage) | `multi-user.target` |

## Essential commands

```bash
# Status
systemctl status <unit>
systemctl is-active <unit>
systemctl is-enabled <unit>

# Control
systemctl start <unit>
systemctl stop <unit>
systemctl restart <unit>
systemctl reload <unit>     # reload config without restart (if supported)

# Enable/disable (autostart on boot)
systemctl enable <unit>
systemctl disable <unit>
systemctl enable --now <unit>   # enable + start immediately

# Reload systemd after editing unit files
systemctl daemon-reload
```

## Reading service status output

```
Active: active (running) since ...    → running normally
Active: activating (auto-restart)     → crashed, systemd is restarting it
Active: failed                        → crashed, not restarting
Loaded: loaded (...; disabled; ...)   → unit file exists but won't start on boot
```

`status=203/EXEC` in the status output means the binary could not be executed
(wrong permissions, corrupt file, or missing interpreter).

## Logs with journalctl

```bash
journalctl -u <unit>             # all logs for a unit
journalctl -u <unit> -n 50       # last 50 lines
journalctl -u <unit> -f          # follow (live tail)
journalctl -u <unit> --since "1 hour ago"
journalctl --no-pager -u <unit>  # don't paginate (useful in scripts)
```

## Cleaning up old logs

```bash
journalctl --vacuum-size=200M    # keep only 200 MB of logs
journalctl --vacuum-time=7d      # keep only last 7 days
```

## systemd mount units

Instead of `/etc/fstab`, mounts can be managed as `.mount` unit files.
systemd-fstab-generator auto-creates mount units from `/etc/fstab` entries.

Naming convention: the mount path `/mnt/nextcloud` becomes `mnt-nextcloud.mount`
(slashes replaced with dashes, leading slash removed).

Automount units (`mnt-nextcloud.automount`) mount on first access and unmount
after an idle timeout — useful for network shares that may be temporarily unavailable.

## Enable a unit at boot

```bash
systemctl enable tailscaled
# Creates symlink: /etc/systemd/system/multi-user.target.wants/tailscaled.service
```

If a unit is `active (running)` but `disabled`, it started manually or by dependency
but will not start automatically after reboot.

## Related

- [Proxmox: LXC & VM Management](../proxmox/lxc-vm-management.md)
