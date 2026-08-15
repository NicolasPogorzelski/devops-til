# Loopback Binding + Tailscale Serve

## The pattern

Services bind exclusively to `127.0.0.1` (loopback) on a chosen port.
Tailscale Serve sits in front, terminates TLS on the Tailnet interface,
and proxies traffic to the loopback port over HTTP.

```
Client (Tailnet) -> Tailscale Serve (HTTPS) -> 127.0.0.1:<port> (HTTP)
```

Result:
- Service is unreachable from LAN (not bound to `0.0.0.0`)
- Service is unreachable from the internet (no port-forwarding, no Tailscale Funnel)
- Only authenticated Tailnet members can reach it
- TLS is automatic (MagicDNS hostname + Let's Encrypt managed by Tailscale)

## Why this beats a traditional reverse proxy

A nginx/Caddy/Traefik setup requires:
- Manual TLS cert management (Let's Encrypt renewal, DNS challenges)
- Firewall + port-forwarding at the router
- nginx.conf / Caddyfile maintenance per virtual host
- Another service to monitor and update

Tailscale Serve eliminates all of that. The trade-off is vendor dependency
on Tailscale and no subpath routing (one service per port).

## Configuration

```bash
# Bind service to loopback in docker-compose.yml
ports:
  - "127.0.0.1:3000:3000"

# Expose via Tailscale Serve
tailscale serve --bg --https=443 http://127.0.0.1:3000
```

| Flag | Meaning |
|---|---|
| `--bg` | Run in background, persists after terminal close |
| `--https=<port>` | External port (TLS-terminated by Tailscale) |
| `http://...` | Backend target - must be HTTP because the local service has no TLS |

## Three rules that prevent foot-guns

1. **Always bind to `127.0.0.1`, never `0.0.0.0`** - prevents accidental LAN exposure.
2. **Backend protocol is always `http://`** - Tailscale Serve already handles TLS;
   if the backend speaks HTTPS too, the proxy fails with a TLS error.
3. **One service per Serve port** - Tailscale Serve does not support subpath routing
   (`/grafana` -> A, `/prometheus` -> B does not work). Assign unique ports per service
   and document them.

## Pitfall: HTTPS -> HTTP mismatch

**Symptom:** Tailscale Serve returns a TLS error or `connection refused`.

**Cause:** Configured with `https://127.0.0.1:...` as backend, but the service only speaks HTTP.

**Fix:**
```bash
tailscale serve off                                          # remove all serve entries
tailscale serve --bg --https=<port> http://127.0.0.1:<port>  # re-add with http://
```

## Pitfall: serve config persistence

Tailscale Serve config has been observed to survive single-container reboots
but not necessarily a full host reboot. Always verify after major restarts:

```bash
tailscale serve status
```

If empty: re-run the serve commands. Long-term, automate via systemd unit or Ansible.

## When to break the rule

LAN exposure is acceptable for performance-critical workloads where overlay overhead
matters. Document the exception explicitly:

| Service | Reason | Alternative |
|---|---|---|
| Media streaming (Jellyfin, Audiobookshelf) | High-bitrate LAN streaming, ~50 Mbit upstream limit | LAN reachable on `0.0.0.0:<port>` |
| Bulk file uploads (Nextcloud) | Multi-GB uploads benefit from LAN speed | Apache TLS handles HTTPS; no Tailscale Serve |

For these, security still relies on Tailscale-encrypted access for *remote* users -
the LAN binding is a deliberate convenience exception, not a security gap.

## Considered alternatives

### Nginx / Caddy / Traefik

Powerful but operationally heavier. Required where:
- Public-facing multi-user services need traditional TLS hostnames
- Subpath routing is needed
- Complex middleware (rate limiting, auth proxies) is required

### Direct binding to the Tailscale IP

```bash
# Service binds directly to the Tailscale interface
listen_addresses = '<tailscale-ip>'
```

Advantages:
- Removes Tailscale Serve as a moving part
- Makes loopback unnecessary

Disadvantages:
- No TLS termination (the service must do it)
- IP can change if the node is re-registered
- No `tailscale serve status` for centralized inspection

Useful for non-HTTP services like PostgreSQL, where TLS is service-native and
loopback indirection adds nothing.

## Related

- [Networking: Tailscale](tailscale.md)
- [Docker: Compose Patterns](../docker/compose-patterns.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
