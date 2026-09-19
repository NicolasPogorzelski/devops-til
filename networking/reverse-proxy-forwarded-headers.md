# Reverse Proxy: X-Forwarded-* Headers and Why Backends Must Not Trust Them Blindly

## The chain

```
browser ──TLS──▶ Caddy (terminates TLS) ──plain HTTP──▶ backend (nginx/Tomcat/Puma)
```

From the backend's point of view every request comes from the proxy's
address, over plain HTTP. Two things are lost unless someone passes them on:

1. **The scheme.** The backend believes the request was `http://`. Links it
   renders and redirects it sends become `http://…` → extra redirect
   round-trips, mixed content, cookies without the `Secure` flag, broken
   login flows.
2. **The client address.** Logs, audit trails, "last sign-in from" and every
   per-IP rate limit see one address: the proxy. A brute-force attempt and a
   legitimate user look the same, and a rate limit locks out everyone at once.

The proxy passes both on as headers: `X-Forwarded-Proto: https` and
`X-Forwarded-For: <client ip>` (Caddy's `reverse_proxy` does this by default).

## Why the backend ignores them by default

Any client can send `X-Forwarded-For: 1.2.3.4` itself. A backend that
believes the header from everywhere lets an attacker choose the address that
appears in its logs and dodge per-IP limits by rotating fake values. So every
engine ships the mechanism *off*, and turning it on always means naming the
addresses the header may come from:

| Engine | Mechanism | Trust list |
|---|---|---|
| nginx | `ngx_http_realip_module`: `set_real_ip_from`, `real_ip_header X-Forwarded-For`, `real_ip_recursive on` | GitLab Omnibus: `gitlab_rails['nginx']['real_ip_trusted_addresses']` |
| Tomcat | `RemoteIpValve` in `server.xml` (`remoteIpHeader`, `protocolHeader`) | `internalProxies` (regex, not CIDR) |
| Rails/Puma | `ActionDispatch::RemoteIp` / `config.action_dispatch.trusted_proxies` | OpenProject reads `X-Forwarded-Proto` when `OPENPROJECT_HTTPS=true` |

`real_ip_recursive on` (nginx) / the valve's default (Tomcat): walk the
comma-separated `X-Forwarded-For` list from the right and take the first
address that is *not* a trusted proxy — that is the client, even when several
proxies are chained.

## The other half: the proxy must not forward what the client sent

If the proxy simply appended to an incoming `X-Forwarded-For`, a client could
still plant a fake first entry. Caddy strips client-supplied `X-Forwarded-*`
unless `trusted_proxies` is configured. Verified end to end in the lab:
`curl -H 'X-Forwarded-For: 203.0.113.9' https://git.lab.test/…` was logged by
GitLab with the workstation's real address.

## Residual risk in a Docker setup

Trusting the Docker address pool (`172.16.0.0/12`) means every container on
the shared proxy network could forge the header towards a backend it can
reach directly. Precise fix: a fixed address for the proxy and a `/32` trust
entry; accepted as an extension step in the lab, because a container in that
position already has worse options.

## Checks that prove it

- Redirect through the proxy carries `Location: https://…` (scheme honoured).
- Backend access log shows the client's public address, not the proxy's.
- A forged header from outside does not appear in the log.
