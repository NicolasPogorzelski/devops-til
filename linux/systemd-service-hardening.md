# systemd Service Hardening & Restart Policies

## The race-condition class of problems

A service that *starts before its prerequisites* is a common, silent failure mode:

- An SSH daemon binds to a Tailscale IP that doesn't exist yet because `tailscaled` hasn't come up.
- A monitoring exporter tries to scrape a target that resolves only after MagicDNS is ready.
- A backup script reads a CIFS path before `network-online.target` is reached.

Each looks like "service is broken" in logs, but the root cause is *ordering*, not logic.
systemd offers two tools to fix this: **dependency declarations** and **restart policies**.

## After= vs Wants= vs Requires=

These three live in `[Unit]` and answer different questions:

| Directive   | Meaning                                                     | Failure handling                                       |
|-------------|-------------------------------------------------------------|--------------------------------------------------------|
| `After=`    | Order — start *after* this unit is reached                  | None — pure ordering, no dependency                    |
| `Wants=`    | Soft dependency — try to start it, continue if it fails     | This unit starts even if the wanted unit fails         |
| `Requires=` | Hard dependency — fail this unit if the required unit fails | This unit is stopped if the required unit goes down    |

**Rule of thumb:** for non-critical ordering, use `Wants=` + `After=` together.
`Requires=` is for genuine "I cannot function at all without this" cases — overusing it
turns a single failed dependency into a cascade of stopped services.

```ini
[Unit]
Description=Node Exporter (Tailscale-bound)
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
```

The pair `Wants=` + `After=` says: "ask systemd to bring up `tailscaled`, and
order me after it — but if `tailscaled` is broken, still try."

## The SSH-bind-to-Tailscale race

**Symptom:** SSH daemon fails on boot with `Cannot assign requested address` or
`ListenAddress 100.x.y.z` — but starts fine after a manual restart.

**Cause:** `sshd.service` reaches its start point before `tailscaled` has finished
configuring the `tailscale0` interface. The IP doesn't exist yet, so `bind()` fails.

**Fix:** drop-in unit at `/etc/systemd/system/ssh.service.d/override.conf`:

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=on-failure
RestartSec=15s
RestartPreventExitStatus=
```

| Line                            | Why                                                                                       |
|---------------------------------|-------------------------------------------------------------------------------------------|
| `After=tailscaled.service`      | Order: only attempt to start sshd after tailscaled has reached its start point            |
| `Wants=tailscaled.service`      | Bring up tailscaled if it isn't running — but don't fail sshd if tailscaled is missing    |
| `Restart=on-failure`            | If sshd exits with non-zero status, restart it — covers the residual race window          |
| `RestartSec=15s`                | Wait 15s before retrying — gives tailscaled time to finish setting up the interface       |
| `RestartPreventExitStatus=`     | **Empty value** — overrides Debian's default that tells systemd to stop retrying on certain exit codes (notably the bind failure) |

The empty value is the subtle part. Distros often ship `RestartPreventExitStatus=255`
(or similar) in the upstream unit to avoid restart loops on configuration errors.
For a race condition, *every* failure is the same code — so the upstream policy
defeats `Restart=on-failure`. Setting it to empty re-enables retries.

## Drop-ins vs editing the upstream unit

Never edit `/lib/systemd/system/<unit>.service` directly. The next package upgrade
will overwrite your changes silently.

Drop-ins live in `/etc/systemd/system/<unit>.service.d/<name>.conf`:

```bash
systemctl edit ssh.service          # creates override.conf in editor
systemctl edit --full ssh.service   # creates a full copy under /etc (rarely correct)
```

`systemctl edit` (without `--full`) is the canonical way — it creates an `override.conf`
that systemd merges with the upstream unit at runtime. To inspect the merged result:

```bash
systemctl cat ssh.service           # shows upstream + all drop-ins concatenated
systemctl show ssh.service          # shows the effective resolved values
```

## Restart policy decision matrix

| `Restart=` value | When to use                                                                  |
|------------------|------------------------------------------------------------------------------|
| `no`             | Default. One-shot scripts, jobs that must not loop on failure.               |
| `on-failure`     | Long-running daemons that should recover from transient errors.              |
| `on-abnormal`    | Restart on signal/timeout but not on config errors (clean non-zero exits).   |
| `always`         | Restart no matter what. Use only for true crash-loop-tolerant services.      |

`on-failure` is the right default for race-vulnerable services. `always` masks
real bugs because it restarts on *every* exit including clean ones, which can
produce a tight loop when the service exits 0 immediately.

## RestartSec — why 15s, not 1s

A 1-second retry on a race condition produces 60 retries per minute, all hitting
the same not-yet-ready dependency. The journal fills up, CPU spikes, and if the
dependency is *also* slow to start (DNS, network mount), the retries can interfere
with its startup.

15s is conservative: enough time for `tailscaled` or `network-online.target` to
catch up, short enough that an admin watching `journalctl -u <unit> -f` doesn't
get bored. Tune downward only if you have a measurement showing the dependency
is reliably ready in less time.

## Type= matters for ordering

The `[Service]` `Type=` directive tells systemd when "started" actually means started:

| Type        | "Started" means                                                                |
|-------------|--------------------------------------------------------------------------------|
| `simple`    | The main process has been forked. **Default — and often wrong** for daemons.   |
| `forking`   | The parent process has exited (classic daemon double-fork).                    |
| `notify`    | The process has called `sd_notify(READY=1)`.                                   |
| `exec`      | `execve()` has succeeded — slightly stronger than `simple`.                    |
| `oneshot`   | The process has run and exited (used for scripts that do work and finish).     |

For ordering with `After=`, the dependency must reach its "started" state before
this unit runs. With `Type=simple`, that happens almost instantly — meaning
`After=` only guarantees the dependency *was launched*, not that it's *ready*.
For real readiness, the dependency must use `Type=notify` or `Type=forking` correctly.

This is why `After=tailscaled.service` is necessary but not sufficient for the
SSH race — `tailscaled` is `Type=notify` and signals readiness, but the IP-assignment
happens *after* readiness in some versions. The `Restart=on-failure` is the
belt-and-suspenders catch.

## Type=oneshot for boot-time scripts

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/trigger-smb-automounts.sh
RemainAfterExit=yes
```

| Directive            | Why                                                                                  |
|----------------------|--------------------------------------------------------------------------------------|
| `Type=oneshot`       | Run the command and exit. Don't expect a long-running process.                       |
| `RemainAfterExit=yes`| After exit, treat the unit as "active". Lets other units `After=` it correctly.      |

Without `RemainAfterExit=yes`, the unit goes to "inactive" immediately and
`WantedBy=multi-user.target` may fire it again on every state transition.

## Verification

```bash
systemctl status <unit>             # current state, last few log lines
systemctl show <unit> -p Restart -p RestartSec -p After -p Wants  # effective config
journalctl -u <unit> -b             # all logs since this boot
journalctl -u <unit> --since "10 min ago"
systemd-analyze blame               # what slowed boot
systemd-analyze critical-chain <unit>  # ordering tree leading to this unit
```

`systemd-analyze critical-chain` is the right tool when you suspect ordering issues
but aren't sure which dependency is the bottleneck.

## Related

- [systemd Basics](systemd-basics.md)
- [Networking: Tailscale](../networking/tailscale.md)
- [Operations: Runbook Methodology](../operations/runbook-methodology.md)
