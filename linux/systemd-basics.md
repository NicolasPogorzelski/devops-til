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

## Persistent journald storage (or: where did my logs go?)

A nasty discovery during the KE-8 incident investigation: the journal for the days
around the incident was **simply gone**. `journalctl --list-boots` jumped straight from
an old boot to the current one — the boots in between had no logs at all. Forensics
fell back to `wtmp`, `apt`/`dpkg` text logs, Docker JSON logs, and Prometheus instead.

Root cause to check: journald's storage mode.

```bash
journalctl --list-boots          # do past boots even exist in the journal?
cat /etc/systemd/journald.conf   # what is Storage= set to?
journalctl --disk-usage          # how much is the journal actually keeping?
```

The `Storage=` directive in `/etc/systemd/journald.conf` decides where logs live:

| `Storage=` | Behavior |
|---|---|
| `volatile` | Logs only in `/run/log/journal` (RAM) — **wiped on every reboot** |
| `persistent` | Logs in `/var/log/journal` (disk) — survive reboots |
| `auto` (default) | Persistent **only if** `/var/log/journal/` already exists; otherwise volatile |

The trap is `auto`: people assume "auto = it figures it out and keeps my logs." It does
**not** — if the `/var/log/journal` directory is missing, `auto` silently behaves like
`volatile` and every reboot throws the logs away. The directory's mere existence is the
switch.

Make it persistent explicitly:

```bash
mkdir -p /var/log/journal                 # the directory IS the trigger under auto
# or be explicit and unambiguous:
# set Storage=persistent in /etc/systemd/journald.conf
systemd-tmpfiles --create --prefix /var/log/journal   # apply correct ownership/perms
systemctl restart systemd-journald
```

- `mkdir -p /var/log/journal` — creating the directory flips `auto` into persistent
  mode; `-p` is harmless if it already exists.
- `systemd-tmpfiles --create --prefix /var/log/journal` — sets the
  systemd-mandated ownership (`root:systemd-journal`) and permissions; doing it by hand
  risks journald refusing to use a wrongly-owned directory.
- `systemctl restart systemd-journald` — reloads the daemon so it picks up the new
  storage location.

Also relevant to "logs vanished": even with persistent storage, retention is bounded by
`SystemMaxUse=` (default ~10% of the filesystem) and `MaxRetentionSec=`. Logs can be
persistent yet still rotated out faster than you expect on a busy node — worth checking
both `Storage=` *and* the size caps when logs are missing.

> Lesson logged as tech debt: vm100/vm102 had `/var/log/journal` present yet still lost
> boots — so the next step is to confirm `Storage=` and the `SystemMaxUse=`/retention
> caps, not assume the directory alone is sufficient.

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

## Service `Type=` — what "started" actually means

The `[Service]` `Type=` directive tells systemd how to detect that a unit is
running. This affects `After=` ordering — a dependent unit starts only when
this one is "active".

| `Type=`     | "Active" means                                                       | Use for                              |
|-------------|----------------------------------------------------------------------|--------------------------------------|
| `simple`    | Main process forked. Default. Often premature for daemons            | Foreground processes                 |
| `forking`   | Parent exited (classic daemon double-fork)                          | Legacy daemons that fork themselves  |
| `notify`    | Process called `sd_notify(READY=1)`                                 | Modern daemons (sshd, postgresql)    |
| `oneshot`   | Process ran and exited                                              | Boot scripts, maintenance jobs       |
| `idle`      | Like `simple`, but waits for active jobs to complete                | Last-thing-on-tty loggers            |

For boot-time scripts that do work and exit:

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-thing.sh
RemainAfterExit=yes
```

`RemainAfterExit=yes` is the subtle part. Without it, a successful oneshot exits
to "inactive" and `WantedBy=multi-user.target` may re-trigger it later. With it,
the unit stays "active" after exit, marking "this work is done".

## `WantedBy=` — what "enabled" hooks into

```ini
[Install]
WantedBy=multi-user.target
```

`WantedBy=` declares which target this unit attaches to when enabled.
`systemctl enable foo.service` creates a symlink:

```
/etc/systemd/system/multi-user.target.wants/foo.service
   → /etc/systemd/system/foo.service
```

When `multi-user.target` is reached during boot, every `.service` in its
`.wants` directory is started.

| Common targets       | When reached                                                       |
|----------------------|--------------------------------------------------------------------|
| `multi-user.target`  | System ready for non-graphical login. Server-typical "fully booted" |
| `graphical.target`   | Multi-user + display manager started                                |
| `network-online.target` | Network has at least one routable address                       |

For server services: `WantedBy=multi-user.target` is right. For services that
need network: also `After=network-online.target` + `Wants=network-online.target`
in `[Unit]` — `WantedBy` and `After` solve different problems (hook-point vs ordering).

## Drop-in overrides — `/etc/systemd/system/<unit>.d/*.conf`

The right way to modify a packaged unit: drop-in files. They merge with the
upstream unit at runtime; you never touch `/lib/systemd/system/<unit>.service`.

```bash
systemctl edit ssh.service
# Opens an editor for /etc/systemd/system/ssh.service.d/override.conf
```

```ini
[Service]
Restart=on-failure
RestartSec=15s
```

Inspect the result:

```bash
systemctl cat ssh.service        # upstream + every drop-in concatenated
systemctl show ssh.service       # effective resolved values, one per line
```

`systemctl edit --full` is the wrong default — it copies the entire upstream
unit to `/etc`, breaking future package upgrades that update the upstream file.
Use it only when reordering or removing existing directives makes a drop-in
impossible.

For deeper restart-policy and race-condition handling, see
[systemd Service Hardening](systemd-service-hardening.md).

## `RestartPreventExitStatus=` — when restart policies seem ignored

A common surprise: `Restart=on-failure` is set, but the unit doesn't restart
after a failure. Cause: the upstream unit ships a `RestartPreventExitStatus=`
that lists the exit code your service is producing.

```bash
systemctl show ssh.service -p RestartPreventExitStatus
# RestartPreventExitStatus=255
```

To **re-enable restart on all exit codes**, set the directive to empty:

```ini
[Service]
RestartPreventExitStatus=
```

The empty value overrides the upstream non-empty list. Do this only when you
*want* restart on every failure — for race-condition-vulnerable services,
this is correct.

## When the running process does not match the unit file

A diagnosis that keeps going wrong: reading a config file and concluding what is
running. The config is a statement of *intent*. Only the process tells you what
is actually in effect, and the two drift apart more often than expected — a unit
edited without `daemon-reload`, a service started by hand, or a second unit
nobody remembers enabling.

Seen 2026-07-28: `/etc/default/tailscaled` read `FLAGS=""` and the packaged unit
was untouched, yet `ps` showed a daemon running with a flag that appears in
neither. The flag came from a second, hand-written unit file that was `enabled`
alongside the stock one, so both started at boot.

Work from the process backwards, not from the config forwards:

```bash
ps -o pid,ppid,lstart,args -C <name>   # what is REALLY running, and since when
systemctl status <pid>                 # map a PID back to its owning unit
systemctl show <unit> -p MainPID       # what systemd thinks it owns
systemctl cat <unit>                   # effective unit + all drop-ins, in order
systemctl list-unit-files | grep -i <name>   # every unit, enabled or not
```

- `ps -C <name>` selects by process name; `-o` picks the columns. `lstart` gives
  the absolute start time, which is what lets you compare a process against the
  mtime of the config that supposedly produced it.
- `systemctl status <pid>` accepts a PID as well as a unit name and resolves it
  to the owning unit — the fastest way to identify a process you did not expect.
- `systemctl cat` is the honest view of a unit: the file plus every drop-in,
  concatenated with `# /path` markers. Guessing which files exist is how drop-ins
  get missed.
- A process whose PID is *not* the unit's `MainPID` and that sits outside the
  unit's `ControlGroup` was not started by that unit. That is the signature of a
  stray daemon.

`systemctl disable --now <unit>` stops it and removes the `WantedBy` symlink, but
leaves the unit file in place. That is reversible on purpose — and it means a
later `enable` brings the problem back. Delete the file when the decision is
final.

## Related

- [Proxmox: LXC & VM Management](../proxmox/lxc-vm-management.md)
- [systemd Service Hardening](systemd-service-hardening.md)
- [Cron and Scheduling](cron-and-scheduling.md)
- [Proxmox: Tailscale in unprivileged LXCs](../proxmox/lxc-tailscale-tun.md) — where this bit
