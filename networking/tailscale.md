# Tailscale — Zero-Trust Overlay Network

## What it is

Tailscale is a WireGuard-based mesh VPN. Every device gets a stable IP (100.x.y.z)
regardless of its physical location or LAN. Devices communicate directly when possible
(peer-to-peer), via relay (DERP) when NAT blocks direct connections.

Key properties:
- No public ports needed — no port forwarding, no exposed ingress
- Identity-based access (not IP-based) via ACL tags
- LAN is treated as untrusted — services bind to Tailscale IP only

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
- `tag:tier0` — critical infrastructure (storage VM, monitoring)
- `tag:tier1` — user-facing services
- `tag:tier2` — non-critical services
- `tag:monitoring` — Prometheus stack
- `tag:database` — PostgreSQL platform
- `tag:ai-stack` — Ollama, OpenWebUI
- `tag:admin` — management nodes (LXC250)

## ACL rules

```json
{"action": "accept", "src": ["tag:monitoring"], "dst": ["tag:tier0:9100"]}
```

Rules are deny-by-default. Only explicitly allowed src→dst:port combinations work.

## Tailscale Serve

`tailscale serve` exposes a local service over HTTPS on the Tailscale network,
handling TLS termination automatically.

```bash
tailscale serve --https=443 http://localhost:3000
```

Services bind to `127.0.0.1` (loopback) and are proxied by Tailscale Serve —
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

## Related

- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
