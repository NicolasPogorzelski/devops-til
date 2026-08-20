# Tailscale - Zero-Trust Overlay Network

## What it is

Tailscale is a WireGuard-based mesh VPN. Every device gets a stable IP (100.x.y.z)
regardless of its physical location or LAN. Devices communicate directly when possible
(peer-to-peer), via relay (DERP) when NAT blocks direct connections.

Key properties:
- No public ports needed - no port forwarding, no exposed ingress
- Identity-based access (not IP-based) via ACL tags
- LAN is treated as untrusted - services bind to Tailscale IP only

## Tailscale IPs

Each node gets a stable `100.x.y.z` IP that never changes, even across reboots or
network changes. This is the IP used for all inter-service communication in the homelab.

## ACL Tags

Tags are identities assigned to nodes. ACL rules use tags as source/destination,
not individual IPs. This makes rules policy-based rather than host-based.

```json
"tagOwners": {
  "tag:tier0": ["autogroup:admin"],
  "tag:tier1": ["autogroup:admin"],
  "tag:monitoring": ["autogroup:admin"]
}
```

Tag hierarchy in this homelab:
- `tag:tier0` - critical infrastructure (storage VM, monitoring)
- `tag:tier1` - user-facing services
- `tag:tier2` - non-critical services
- `tag:monitoring` - Prometheus stack
- `tag:database` - PostgreSQL platform
- `tag:ai-stack` - Ollama, OpenWebUI
- `tag:admin` - management nodes (LXC250)

## ACL rules

```json
{"action": "accept", "src": ["tag:monitoring"], "dst": ["tag:tier0:9100"]}
```

Rules are deny-by-default. Only explicitly allowed src->dst:port combinations work.

## Tailscale Serve

`tailscale serve` exposes a local service over HTTPS on the Tailscale network,
handling TLS termination automatically.

```bash
tailscale serve --https=443 http://localhost:3000
```

Services bind to `127.0.0.1` (loopback) and are proxied by Tailscale Serve -
not exposed on any LAN or public interface.

## Key commands

```bash
tailscale status                  # connected nodes and their IPs
tailscale ping <node>             # test connectivity
tailscale up                      # connect / re-authenticate
tailscale down                    # disconnect
systemctl status tailscaled       # service status
```

## Detecting deauthentication

After a package reinstall, the auth state file may be lost:

```bash
systemctl status tailscaled
# Status: "Needs login: https://login.tailscale.com/a/..."
```

Fix: open the login URL in a browser. After approval, the node reconnects automatically.
Then ensure the service is enabled: `systemctl enable tailscaled`.

## Binding rule

**Services must never bind to LAN interfaces.** Bind to:
- The Tailscale IP directly (e.g. `100.x.y.z:9100`)
- Loopback (`127.0.0.1`) + proxied via `tailscale serve`

LAN IPs are untrusted and may change. Tailscale IPs are stable and identity-backed.

Two caveats learned the hard way:

- **Some services cannot bind to `tailscale0` at all.** Samba skips point-to-point TUN
  interfaces for IPv4 (see [Samba server config](../storage/samba-server-config.md)). When the
  service cannot enforce the boundary, the kernel must -
  [nftables alongside Tailscale](nftables-with-tailscale.md).
- **Binding to a Tailscale IP couples the service's startup to `tailscaled`.** The address does
  not exist until the tunnel is up, so the unit needs `After=tailscaled.service` - and ideally
  `Restart=on-failure`, so a lost race self-heals instead of leaving the service dead until
  someone notices.

## Performance: same-subnet peers go direct - measure before you believe otherwise

The intuition "traffic through the VPN is capped by my internet upload" is **wrong for peers on
the same LAN**. Tailscale negotiates a **direct** WireGuard path using the local endpoints; the
DERP relay is only a fallback when no direct path can be established. Same-subnet peers therefore
talk over the LAN cable, encrypted, and never touch the uplink.

Check which path is in use - do not guess:

```bash
tailscale ping storage
# pong from storage (100.x.y.z) via <lan-ip-vm102>:41641 in 2ms
#                                    ^^^^^^^^^^^^^^^^^^^^ the LAN address = direct
```

```bash
tailscale status --json | jq '.Peer[] | select(.HostName=="storage") | .CurAddr'
# a LAN address  -> direct
# empty ("")     -> relayed via DERP (this is the slow case)
```

`Relay: fra` in the status output only names the *assigned* DERP region. It does **not** mean the
relay is in use - if `CurAddr` is set, the path is direct.

Measured cost of the encryption, workstation -> storage node, 1500 MiB into a discarding sink
(network + crypto only, no disk):

| Path | Throughput |
|---|---|
| LAN address, plain TCP | 809 Mbit/s |
| Tailscale address, WireGuard | 741 Mbit/s |

**~8 %, not an order of magnitude.** On a gigabit link this is noise. It only becomes a real
bottleneck on 2.5G/10G, where userspace WireGuard's CPU cost starts to matter - measure there,
do not extrapolate.

The practical lesson: "we keep this on the LAN for speed" is a claim, and claims of that shape
are cheap to test. A wrong one costs you a Zero-Trust boundary for nothing.

## MagicDNS - name resolution inside the tailnet

Tailscale assigns each node a hostname like `nextcloud.<tailnet-id>.ts.net`.
With MagicDNS enabled, those names resolve from any tailnet member:

```bash
dig +short nextcloud.<tailnet-id>.ts.net    # returns the 100.x.y.z IP
```

Names are stable across IP changes - useful for services binding to a
Tailscale IP directly. Bind to the IP in configs, but use the MagicDNS name
in client URLs so a re-issued IP doesn't break links.

MagicDNS is also what makes `tailscale cert <hostname>` work - the cert is
issued for the MagicDNS name and resolves only within the tailnet.

## TLS via Tailscale-managed certs

For services that handle their own TLS (e.g., Apache for Nextcloud), Tailscale
can provision Let's Encrypt certs for the MagicDNS hostname:

```bash
tailscale cert nextcloud.<tailnet-id>.ts.net
# writes to /var/lib/tailscale/certs/nextcloud.<tailnet-id>.ts.net.{crt,key}
```

Apache then uses those paths directly:

```apache
SSLCertificateFile    /var/lib/tailscale/certs/nextcloud.<tailnet-id>.ts.net.crt
SSLCertificateKeyFile /var/lib/tailscale/certs/nextcloud.<tailnet-id>.ts.net.key
```

Renewal: re-run `tailscale cert` (idempotent - re-issues if close to expiry).
Cron weekly:

```cron
0 4 * * 0 tailscale cert nextcloud.<tailnet-id>.ts.net && systemctl reload apache2
```

This is the alternative to the loopback + `tailscale serve` pattern. Use direct
TLS when:

- Multi-GB uploads make the Serve proxy hop wasteful
- The service already has well-tested TLS handling (Apache, nginx)
- You need protocol features Serve doesn't support (HTTP/2 push, WebDAV chunking)

## Pre-existing tunnels mask missing ACLs

**Symptom:** A new node added without specific ACL rules can still reach existing
services.

**Cause:** Tailscale connections are persistent. ACL changes filter *new*
connection attempts, not existing TCP sessions. A long-lived connection from
before the rule was added stays alive indefinitely.

**Verification (don't trust existing connectivity):**

```bash
# On the source: check what's already connected
ss -t state established | grep <target-tailscale-ip>

# Force a fresh connection - this respects current ACLs
nc -zv <target> <port>
```

**Fix after ACL changes:** restart `tailscaled` on relevant nodes, or briefly
deauthorize+reauthorize the node. Then verify with a fresh `nc -zv`, not by
checking that an existing service still works.

See [Tailscale ACL Design](tailscale-acl-design.md) for the full ACL methodology.

## Vendor lock-in considerations

Tailscale is a SaaS product. The control plane (coordination server, ACL store,
admin console) is Tailscale Inc.'s infrastructure. The data plane (WireGuard
between nodes) is yours.

Migration path if Tailscale becomes untenable: **Headscale**, an open-source
re-implementation of the Tailscale coordination server. Same client binary,
self-hosted control plane.

| Aspect                     | Tailscale (managed)             | Headscale (self-hosted)            |
|----------------------------|----------------------------------|------------------------------------|
| Control plane              | Tailscale's servers              | Your Debian VM                     |
| MagicDNS                   | Yes                              | Yes                                |
| ACLs                       | Yes (web UI + JSON)              | Yes (CLI + JSON)                   |
| Tailscale Serve            | Yes                              | Limited (newer feature)            |
| Tailscale Funnel           | Yes (public exposure)            | No                                 |
| Cert provisioning          | Yes                              | Manual                             |
| Operational burden         | Near zero                        | Real (DB, backups, upgrades)       |

Designing the homelab to use Tailscale-IP-binding + MagicDNS keeps the migration
small: replace coordination server, re-register nodes, ACL JSON ports over.
The actual services don't change.

## Application-layer security is independent

A common misconception: "Tailscale encrypts the connection, so I don't need
HTTPS inside it."

**WireGuard encrypts node-to-node traffic on the wire.** That's transport-layer
security between Tailscale endpoints. It does not provide:

- Application-layer authentication (who's the user? - service does that)
- Database-level encryption (at rest, on disk)
- Protection from a compromised endpoint (other end is in clear)

Practical implication: PostgreSQL on a Tailnet still needs `hostssl` in
`pg_hba.conf` and SCRAM-SHA-256 auth. The Tailscale layer is a perimeter,
not a substitute for service-level controls.

## Related

- [Loopback + Tailscale Serve](loopback-tailscale-serve.md)
- [Tailscale ACL Design](tailscale-acl-design.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
- [PostgreSQL Zero-Trust](../database/postgres-zero-trust.md)
