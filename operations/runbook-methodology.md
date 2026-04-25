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

## Related

- [Proxmox: Thin-Pool Recovery](../proxmox/thin-pool-recovery.md)
- [Monitoring: Prometheus Stack](../monitoring/prometheus-stack.md)
