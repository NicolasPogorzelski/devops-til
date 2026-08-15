# Tailscale ACL Design

## Why ACLs at all

Default Tailscale behavior: every node can reach every other node on every port.
For a single-user laptop scenario this is fine. For a homelab with services
exposing admin interfaces, databases, and metrics endpoints, default-allow is
exactly the wrong starting point.

The goal of ACL design is **principle of least privilege at the network layer**:
each node can reach only what it specifically needs.

## Tier-based design

A practical pattern is grouping nodes by trust tier and writing rules between tiers
rather than between individual hosts.

| Tier              | Examples                                       | Notes                                       |
|-------------------|------------------------------------------------|---------------------------------------------|
| `tag:admin`       | Personal laptop, admin VM                      | Full network access                         |
| `tag:tier0`       | Hypervisor, storage VM                         | Foundation - accessible by tier1, tier2     |
| `tag:tier1`       | Application servers (Nextcloud, Paperless)     | Reach tier0 for storage; reachable by users |
| `tag:tier2`       | User-facing endpoints                          | Reach tier1; reachable by clients           |
| `tag:storage`     | The storage node specifically                  | Special: read-only mounts, restricted ports |
| `tag:monitoring`  | Prometheus host                                | Outbound to all tiers (scraping)            |
| `tag:database`    | PostgreSQL host                                | Inbound 5432 from specific tags only        |
| `tag:client`      | End-user devices                               | Outbound to user-facing services            |
| `tag:untrusted`   | IoT devices, guest devices                     | Egress only to specific endpoints           |

A tier is *just* a tag string. The tag-based-tiers convention is a discipline
that prevents you from writing per-host rules that drift over time.

## Tag ownership

Before tags can be assigned, they must have an owner:

```json
"tagOwners": {
  "tag:admin":      ["autogroup:admin"],
  "tag:tier0":      ["autogroup:admin"],
  "tag:tier1":      ["autogroup:admin"],
  "tag:storage":    ["autogroup:admin"],
  "tag:monitoring": ["autogroup:admin"],
  "tag:database":   ["autogroup:admin"]
}
```

`autogroup:admin` means "any user with admin role in the tailnet". The owner
controls who can assign the tag to a node. For a single-operator homelab,
all tags owned by `autogroup:admin` is correct - no delegation needed.

## Hosts aliases

Instead of using IPs in ACLs, define aliases:

```json
"hosts": {
  "storage":    "100.x.y.10",
  "monitoring": "100.x.y.20",
  "database":   "100.x.y.30"
}
```

ACL rules then reference `hosts:storage` instead of the IP. Two benefits:

1. IPs can change (re-registration, manual reset) - names are stable
2. Rules become readable: `dst: ["storage:445"]` is self-documenting

## Rule structure - intra-tier vs cross-tier

Common pattern: allow within tier, restrict between tiers.

```json
"acls": [
  {
    "action": "accept",
    "src": ["tag:admin"],
    "dst": ["*:*"]
  },
  {
    "action": "accept",
    "src": ["tag:tier1"],
    "dst": ["tag:tier1:*"]
  },
  {
    "action": "accept",
    "src": ["tag:tier1"],
    "dst": ["tag:tier0:445,5432"]
  },
  {
    "action": "accept",
    "src": ["tag:client"],
    "dst": ["tag:tier2:443"]
  },
  {
    "action": "accept",
    "src": ["tag:monitoring"],
    "dst": ["tag:tier0:9100,9633","tag:tier1:9100,9187","tag:database:9187"]
  }
]
```

Rule reading:

- **admin -> everything**: explicit; admins can reach everything
- **tier1 -> tier1**: services in the same tier can talk freely
- **tier1 -> tier0:445,5432**: tier1 reaches storage SMB and database PG only
- **client -> tier2:443**: end-users reach user-facing services on HTTPS
- **monitoring -> all tiers:exporter ports**: scrape access, nothing else

The narrow ports on cross-tier rules are the value: monitoring can scrape
node_exporter (9100) and postgres_exporter (9187) but not SSH or PostgreSQL
itself. A compromised monitoring host cannot pivot into the database.

## Pre-existing tunnels mask missing rules - DD#11

**Symptom:** A new node is added with no specific ACL rules, but it can still
reach existing services.

**Cause:** Tailscale connections are persistent. When you change ACLs, *existing*
TCP connections are not torn down - only *new* connection attempts are filtered.
A monitoring host that opened a connection to PostgreSQL before the ACL was
tightened keeps that connection alive indefinitely.

**Verification:**

```bash
# On the source: check what's connected
ss -t state established | grep <target-tailscale-ip>
```

**Fix:** after ACL changes, force re-evaluation:

```bash
# Either: restart tailscaled on each node
systemctl restart tailscaled

# Or: temporarily deauthorize the node in admin console, re-auth
```

The lesson: **do not validate ACL changes by checking existing connectivity**.
Validate by establishing a new connection (`nc -zv` from a fresh shell, or
restarting the service on the source side). Otherwise you confirm only that
the old connection still works.

## Access matrix - documentation pattern

ACL rules are read top-down by Tailscale, but humans read better as a matrix:

|              | tier0 | tier1 | tier2 | database | monitoring |
|--------------|-------|-------|-------|----------|------------|
| admin        |     |     |     |        |          |
| tier0        |     |       |       |          |            |
| tier1        | 445,5432 | |       |   5432   |            |
| tier2        |       | 443   |     |          |            |
| client       |       |       | 443   |          |    9090    |
| monitoring   | 9100  | 9100,9187 | | 9187     |          |

This matrix lives in repo docs (`docs/platform/tailscale-acl.md`) and gets
updated when rules change. Mismatch between matrix and JSON = stale doc =
fix the doc.

## Mullvad exit nodes

Tailscale supports Mullvad as exit nodes. Limit which nodes can use it:

```json
"nodeAttrs": [
  {
    "target": ["tag:client"],
    "attr":   ["mullvad"]
  }
]
```

Only nodes tagged `tag:client` can route their internet egress through Mullvad.
Server tags don't get this - they should never need a third-party exit.

## ACL changelog as operational doc

Maintain a `tailscale-acl-changelog.md` with one entry per ACL change:

```
## 2026-04-15 - add monitoring scrape access for new postgres host

Added: tag:monitoring -> tag:database:9187
Reason: postgres_exporter on lxc260 came online; needed scraping
Impact: monitoring node can now scrape postgres metrics on lxc260
```

Why bother: ACL changes are infrequent but high-stakes. Six months later when
something breaks, the changelog tells you what was the last change and why.
Git blame on the ACL JSON file is too granular and lacks the "why".

## Service onboarding checklist

When adding a new service, the network onboarding step is:

1. What tier does this service belong to?
2. What other tiers must reach it, on which ports?
3. What does this service need to reach, on which ports?
4. Add tag in `tagOwners`, hostname alias in `hosts`, rules in `acls`
5. Update access matrix doc
6. Add changelog entry
7. After deploy: verify with `nc -zv` from each source tier

Skipping the verification step is the most common operational error - see
the "pre-existing tunnels" pitfall above.

## Related

- [Tailscale](tailscale.md)
- [Loopback + Tailscale Serve](loopback-tailscale-serve.md)
- [Network Tools](../linux/network-tools.md)
