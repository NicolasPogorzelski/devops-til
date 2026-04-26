# Cron, systemd Timers & Scheduled Maintenance

## The two scheduling worlds

| Tool | Strengths | Weaknesses |
|---|---|---|
| `cron` | Universally available, simple, well-known | No structured logging, no dependency handling, missed runs are lost |
| `systemd timer` | Structured logs via journalctl, can depend on units, handles missed runs (`Persistent=true`) | More verbose to set up, two unit files per job |

For homelab maintenance: cron is fine for simple periodic jobs. Switch to systemd timers when
you need missed-run catchup or dependency on other units.

## Crontab format

```
*  *  *  *  *  command
│  │  │  │  │
│  │  │  │  └── day of week (0-7, where 0 and 7 are Sunday)
│  │  │  └───── month (1-12)
│  │  └──────── day of month (1-31)
│  └─────────── hour (0-23)
└────────────── minute (0-59)
```

Common shortcuts:
- `*/15 * * * *` — every 15 minutes
- `0 * * * *` — every hour, on the hour
- `0 2 * * *` — daily at 02:00
- `0 3 * * 0` — Sundays at 03:00
- `0 3 1 * *` — first of each month at 03:00

Pre-defined macros (some cron implementations):
- `@reboot` — at boot
- `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`

## Per-user vs system crontabs

| Location | Editor | Runs as |
|---|---|---|
| `crontab -e` | Per-user, edits `/var/spool/cron/crontabs/<user>` | The owning user |
| `crontab -u <user> -e` | Same, but for a different user (requires root) | `<user>` |
| `/etc/cron.d/<file>` | Drop-in directory, edited as root | User specified inline |
| `/etc/crontab` | System-wide, edited as root | User specified inline |

Format difference: `/etc/cron.d/<file>` and `/etc/crontab` need an extra column for the user:

```
# /etc/cron.d/snapraid
0 2 * * *   root   /usr/local/sbin/snapraid-maintenance.sh sync
0 3 1 * *   root   /usr/local/sbin/snapraid-maintenance.sh scrub
```

User crontabs (`crontab -e`) don't have this column — the user is implied.

## Programmatic crontab installation

```bash
# Replace the entire crontab for the postgres user from a string
echo "0 3 * * * /usr/local/sbin/pg-backup.sh" | crontab -u postgres -

# Append to existing without losing other entries
( crontab -u postgres -l 2>/dev/null; echo "0 3 * * * /usr/local/sbin/pg-backup.sh" ) | crontab -u postgres -
```

The `-` at the end of `crontab -u user -` means "read crontab from stdin". The first form
**replaces** the user's crontab, the second form preserves existing entries.

For idempotency in scripts, prefer drop-in files in `/etc/cron.d/` — overwriting a single file
is simpler than parsing existing crontab content.

## When `/etc/cron.d/` over user crontab

| Choose `/etc/cron.d/<service>` when... | Choose `crontab -u <user> -e` when... |
|---|---|
| Job is system maintenance (root or service user) | Job is user-specific (their backups, their reminders) |
| Config should be in version control / Ansible | Manual tweaks expected by the user |
| Multiple jobs share a service identity | Single ad-hoc job |
| Easy to deploy via `install -m 0644` | — |

Drop-in files survive package upgrades cleanly and play well with config management tools.

## The PATH problem

Cron jobs run with a minimal `PATH`, typically `/usr/bin:/bin`. Custom binaries in `/usr/local/sbin`
or installed via `pip` may not be found.

Defensive practice:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * postgres /usr/local/sbin/pg-backup.sh
```

Setting `PATH` at the top of the cron file applies to all entries below it. Or use absolute
paths in the command itself (more verbose but harder to break).

## Capture cron output

Cron emails failures by default if a local mail transport (postfix/sendmail) is configured —
in a homelab, usually nothing is. Without mail, output is silently dropped.

Two patterns to capture output:

**Per-job log file:**
```cron
0 * * * *   root   /usr/local/sbin/scan-paperless-inbox.sh >> /var/log/scan-paperless.log 2>&1
```

**Logger to journal:**
```cron
0 * * * *   root   /usr/local/sbin/scan-paperless-inbox.sh 2>&1 | logger -t paperless-scan
```

`logger -t <tag>` writes to syslog/journal with the given tag, queryable via:

```bash
journalctl -t paperless-scan
journalctl -t paperless-scan --since "today"
```

## Idempotent cron jobs

A cron job may overlap with itself if a previous run is still in progress (e.g., a backup
runs longer than expected). Two patterns to prevent this:

**`flock` for mutual exclusion:**
```cron
0 2 * * *   root   flock -n /var/lock/snapraid.lock -c '/usr/local/sbin/snapraid-maintenance.sh sync'
```

| Flag | Effect |
|---|---|
| `-n` | Non-blocking — exit immediately if the lock is held |
| `-c '<cmd>'` | Run the command with the lock held |

If the previous run is still running, the new one is skipped. No queue, no overlap.

**`pidof` check:**
```bash
if pidof -x "$(basename "$0")" -o $$ >/dev/null; then
  exit 0
fi
```

Inside the script: exit if another instance is already running. `-o $$` excludes the current
process from the check.

## Maintenance cadence template

A typical homelab cadence borrowed from this platform:

| Cadence | Tasks |
|---|---|
| **Hourly (automated)** | Cache sync (e.g., Nextcloud Paperless inbox scan) |
| **Daily (automated)** | SnapRAID sync, PostgreSQL `pg_dumpall`, monitoring sanity dashboards |
| **Weekly (manual review)** | `snapraid status`, container restart counts, disk space trend |
| **Monthly (automated)** | SnapRAID scrub |
| **Monthly (manual)** | SMART health review, restore-test spot check |
| **After major changes** | Reboot-safe validation: storage → services → monitoring |

Automate everything that runs more than weekly. Manual review tasks become checklists.

## systemd timers (the modern alternative)

Two unit files per job: a `.service` (what to run) and a `.timer` (when to run it).

```ini
# /etc/systemd/system/pg-backup.service
[Unit]
Description=PostgreSQL backup

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/sbin/pg-backup.sh
```

```ini
# /etc/systemd/system/pg-backup.timer
[Unit]
Description=Daily PostgreSQL backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

| Timer field | Purpose |
|---|---|
| `OnCalendar=` | Schedule in systemd's calendar syntax (similar to cron) |
| `Persistent=true` | If the system was off at the scheduled time, run on next boot |
| `RandomizedDelaySec=300` | Spread load by adding random 0–300s delay — useful when many hosts run a job at the same time |

Activate:
```bash
systemctl daemon-reload
systemctl enable --now pg-backup.timer
systemctl list-timers              # show all active timers
journalctl -u pg-backup.service    # see job output
```

The `Persistent=true` behavior is the killer feature: a laptop that was off at 03:00 will run
the missed backup when it boots back up. Cron has no equivalent — missed runs are lost.

## Related

- [Linux: systemd Basics](systemd-basics.md)
- [Linux: systemd Service Hardening](systemd-service-hardening.md)
- [Linux: Bash Scripting Patterns](bash-scripting-patterns.md)
