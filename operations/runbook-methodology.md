# Runbook Methodology

## What a runbook is

A runbook is a documented operational procedure for a specific failure scenario
or maintenance task. It answers: "What do I do when X happens?"

Good runbooks are written before the incident, not during.

## Runbook contract (required sections)

Every runbook must have:

| Section | Purpose |
|---|---|
| **Preconditions** | What must be true before you start (access, services running, etc.) |
| **Commands** | Exact commands, in order |
| **Verification** | How to confirm the procedure succeeded |
| **Failure Modes** | What can go wrong and how to respond |

## Root-cause methodology

Never assume. The process:

1. **Observe** the symptom (what is broken, what error message)
2. **Hypothesize** a cause
3. **Verify** the hypothesis with a concrete command before acting
4. **Diagnose** based on verified evidence
5. **Fix** — only after diagnosis

```
Symptom → Verification command → Confirmed diagnosis → Fix
```

"It's probably X" without a verification step is not a diagnosis.

## Failure domain thinking

Before troubleshooting, identify the failure domain:
- Is the problem on this node only, or platform-wide?
- Is it network, storage, application, or OS?
- What changed recently?

A platform-wide outage (multiple nodes failing simultaneously) usually points to
shared infrastructure: storage pool, network, or the Proxmox host itself.

## Incident classification

Keep a record of known errors with their root cause, fix, and status.
Each entry gets a KE number (Known Error):

```
KE-1: SQLite on CIFS — "database is locked"
KE-7: Package corruption when LVM thin-pool overflows during apt upgrade
```

This prevents re-diagnosing the same issue next time it occurs.

## Recovery-oriented design

In a single-host homelab without HA, the design principle is:
**assume failure will happen, document how to recover**.

- No HA → clear recovery runbooks
- Single storage VM is a SPOF → documented recovery procedure
- No automated failover → manual runbooks with exact commands

## Boot order dependency modeling

After a host reboot, services must come up in dependency order:

```
Layer 0: Proxmox host
Layer 1: Storage (VM102 — MergerFS, SnapRAID, Samba)
Layer 2: Infrastructure LXCs (LXC260 PostgreSQL, LXC200 Monitoring)
Layer 3: Service LXCs (Nextcloud, Paperless, Calibre-Web, etc.)
```

Starting a service before its dependency is ready causes startup failures.
Check Tailscale connectivity and mount availability before declaring a node healthy.

## Conventional Commits

```
<type>(<scope>): <description>

Types: feat, fix, docs, refactor, chore, test, ci
Scopes: vm100, lxc200, monitoring, platform, ansible, repo, ...
```

Examples:
```
feat(ansible): add apt-upgrade playbook
docs(platform): document lvm thin-pool overflow incident
fix(monitoring): correct grafana datasource url
```

## Failure modes table — required runbook element

A runbook without a failure-modes section is incomplete. Pattern:

```markdown
## Failure modes

| What goes wrong                        | How to detect                  | Recovery                              |
|----------------------------------------|--------------------------------|---------------------------------------|
| pg_dumpall produces 0-byte file        | `[[ -s "$file" ]]` check fails | Check disk space; check `pg_isready`  |
| restic credentials rejected            | `restic backup` exits non-zero | Re-run `restic init`; check IAM policy|
| Mount target unmounted during backup   | `findmnt -T <target>` empty    | Trigger automount; verify network     |
```

Three columns, three perspectives: prevention (left), detection (middle),
response (right). Skipping the middle column is the most common mistake —
runbooks that say "restart the service" without saying *how you know it's broken*
are useless during incidents.

## Layer-by-layer health-check methodology

When a multi-tier service is broken, diagnose top-down or bottom-up depending
on what's most accessible:

```
Bottom-up (when you can reach the host):
  L0: Storage mounts        — findmnt, df
  L1: Network reachability  — nc -zv from this host to deps
  L2: Container/process     — docker ps, systemctl status
  L3: Database/state        — psql \dt, redis-cli ping
  L4: Application API       — curl /health
  L5: User-facing endpoint  — curl https://...

Top-down (when you only have the user-facing symptom):
  L5 → L0
```

Each layer has a fast verification command. Document the chain in the runbook
of the affected service. When the user reports "X is broken", running the
chain end-to-end takes 60 seconds and pinpoints the layer.

## Verification table — proof of working state

Restore runbooks and disaster-recovery procedures need a verification table
that gets filled in after each rehearsal:

```markdown
## Verification log

| Date       | Scope                  | Result | Operator   | Notes                  |
|------------|------------------------|--------|------------|------------------------|
| 2026-01-15 | postgres full restore  | OK     | nicolas    | 3min duration          |
| 2026-04-10 | nextcloud config       | OK     | nicolas    | Files matched checksum |
| 2026-07-01 | full disaster recovery | —      | (planned)  |                        |
```

Empty rows are a signal: either the rehearsal hasn't happened, or it failed
and wasn't documented. Both are problems. The table makes the gap visible
in the repo, so it doesn't get forgotten.

## Doku-First workflow

Before deploying or changing anything non-trivial:

1. Identify the official documentation for the tool/service
2. Read the relevant sections (not just skim — quote them in the runbook)
3. Link those sections in the implementation runbook
4. Only then write the actual procedure

The benefit isn't pedantry — it's traceability. Six months later when something
breaks, the runbook tells you not just "do X" but "do X, because the docs at
this URL say Y". If the docs have changed, you discover the assumption mismatch
quickly.

```markdown
## References

- [PostgreSQL pg_hba.conf](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html)
- [systemd.unit(5)](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)
```

For Arch-based systems: ArchWiki sections. For Debian: official Debian admin
handbook + upstream docs. Cite the section header you used, not just the URL.

## Fail-forward visibility — when degradation isn't downtime

A service that "still loads but does the wrong thing" is harder to diagnose
than one that's fully down. Examples:

- OpenWebUI shows the model list (cached) when Ollama is unreachable. UI
  appears healthy until you send a message.
- Nextcloud's web UI loads when the data dir is unmounted. File listings
  appear empty rather than erroring.
- Grafana dashboards render when Prometheus is unreachable, showing "no data".

This is *fail-forward* design — the UI prefers showing partial state over a
hard error. It is operationally fine *if* monitoring covers the underlying
layers. It is dangerous if monitoring only covers the UI's HTTP endpoint.

Rule: **any service with fail-forward behavior must have its dependencies
monitored separately**. UI-availability ≠ stack-availability.

## Related

- [Proxmox: Thin-Pool Recovery](../proxmox/thin-pool-recovery.md)
- [Monitoring: Prometheus Stack](../monitoring/prometheus-stack.md)
- [Backup Strategy](backup-strategy.md)
- [Network Tools](../linux/network-tools.md)
