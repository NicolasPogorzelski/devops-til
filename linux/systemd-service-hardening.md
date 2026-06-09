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

## Reactive vs proactive: ExecStartPre gates

The SSH fix above is **reactive**: let the service fail, then `Restart=on-failure`
retries until the dependency is ready. That works only if the failure actually
produces a non-zero exit systemd can see. Sometimes it doesn't — then you need a
**proactive** gate that blocks startup until the prerequisite is *really* true.

**Case study — PostgreSQL bound to a Tailscale IP.** Same race as sshd
(`listen_addresses` includes the Tailscale IP, which isn't assigned yet at boot),
but the reactive fix is useless here, for two reasons:

1. Debian's `postgresql@.service` has `ExecStart=-/usr/bin/pg_ctlcluster …`. The
   **leading `-`** tells systemd to ignore a non-zero exit, so the unit never
   enters `failed` → `Restart=on-failure` never fires.
2. A *partial* bind is treated as success anyway. PostgreSQL binds loopback, logs
   the Tailscale-IP failure as a mere `WARNING: could not create listen socket`,
   and keeps running. The process is up (a local health check is green) — it's
   just missing the remote bind. **There is no failure to react to.**

So you gate it proactively with `ExecStartPre`, which runs *before* `ExecStart`:

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/usr/local/bin/wait-for-tailscale-ip.sh 90
```

If `ExecStartPre` exits non-zero, the unit fails and `ExecStart` never runs — so
the gate script's exit code is a deliberate policy lever:

| Exit on timeout | Behaviour | Use when |
|---|---|---|
| non-zero (**fail-closed**) | service refuses to start without the prerequisite | the service is useless/unsafe without it |
| `0` (**fail-open**) | service starts anyway after the wait | "up, but degraded" beats "totally down" — e.g. a central DB still usable on loopback |

**The gate must verify the real condition, not a proxy.** "tailscaled is up" ≠
"the IP is assigned" — so poll the actual interface, not the daemon:

```bash
ts_ip="$(tailscale ip -4)"                  # this node's Tailscale IPv4
ip -4 -o addr show | grep -qFw "$ts_ip"     # true only once it's on an interface
```

`grep -F` (fixed string, the dots aren't regex wildcards) + `-w` (word boundary,
so `…78.79` doesn't match `…78.790`). Loop with a `sleep` until it's true or a
timeout elapses.

This pairs with `Type=forking` + `TimeoutStartSec=0` on the postgres unit: the
wait can take as long as it needs without tripping a start timeout.

**Reactive vs proactive — which to reach for:**

| | Reactive (`Restart=on-failure`) | Proactive (`ExecStartPre` gate) |
|---|---|---|
| Mechanism | fail, then retry | block until ready, then start |
| Needs | a visible non-zero exit | a checkable readiness condition |
| Fails when | the error is swallowed (`ExecStart=-`) or a partial start counts as success | the readiness condition is hard to express as a command |
| Cost | restart churn / journal noise during the window | startup is delayed by the poll |

For a clean failure that systemd can see, reactive is simpler. When the failure
is silent or "successful-but-wrong" (the PostgreSQL case), only the proactive
gate works.

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
