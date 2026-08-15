# nftables Alongside Tailscale - Enforcing a Boundary the Service Cannot

## Why this exists

Some services cannot bind where you want them to. Samba, for example, refuses to bind an
IPv4 address on `tailscale0` (a point-to-point TUN device without the `BROADCAST` flag -
see [Samba server config](../storage/samba-server-config.md#the-trap-samba-cannot-bind-ipv4-on-a-tun-interface-measured-2026-07-14)).
The service then listens on the wildcard address, and its own access control (`hosts allow`)
runs *after* the TCP accept - an application filter, not a boundary.

When the application cannot enforce it, move one layer down: a kernel packet filter, evaluated
before the service ever sees the connection.

## The mental model

nftables has **tables**, and tables are independent. Multiple tables can hook the same point;
each is evaluated, and a `drop` in **any** of them drops the packet. This is what makes it safe
to add your own rules next to Tailscale's - you do not have to merge anything into its chains.

```
packet -> hook input -> [table ip filter: ts-input]      (Tailscale's, via iptables-nft)
                    -> [table inet smb_guard: input]    (yours)
                    -> ...
         any drop wins
```

## The trap that eats your tailnet

Debian's stock `/etc/nftables.conf` begins with:

```nft
flush ruleset
```

`nftables.service` loads that file at boot - and its `ExecStop` flushes the ruleset too. Either
one **wipes Tailscale's own chains** (`ts-input`, `ts-forward`, the `ip nat` masquerade chain).
You would break the tailnet's own filtering to close one port.

**Rule: never put your rules in `/etc/nftables.conf`, and never enable `nftables.service` on a
Tailscale node.** Use your own table, loaded by your own unit.

## The pattern

`/etc/nftables.d/smb-guard.nft`:

```nft
#!/usr/sbin/nft -f

# Idempotent prelude: declaring the table before deleting it makes `nft -f` re-appliable,
# and lets the delete succeed on the very first run too (deleting a table that does not
# exist is an error).
table inet smb_guard
delete table inet smb_guard

table inet smb_guard {
  chain input {
    type filter hook input priority filter; policy accept;

    # Scope: only the LAN NIC. Tailscale traffic arrives on tailscale0 and is never
    # evaluated here - which is why tailnet clients are unaffected by everything below.
    iifname != "ens18" accept

    # The point: the LAN NIC has a globally routable IPv6 address, and the service listens
    # on [::]:445. Without this rule the port is bound on a world-routable address.
    meta nfproto ipv6 tcp dport 445 counter drop

    # IPv4: only the two hosts that actually consume the service. Counters are the audit trail.
    ip saddr { 192.168.0.34, 192.168.0.50 } tcp dport 445 counter accept
    tcp dport 445 counter drop
  }
}
```

`table inet` covers IPv4 **and** IPv6 in one table (`ip` would be v4-only, `ip6` v6-only).
`policy accept` plus explicit drops keeps the table narrow: it guards one port and touches
nothing else on the box.

The unit:

```ini
[Unit]
Description=SMB boundary enforcement (nftables table inet smb_guard)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/smb-guard.nft
ExecStop=/usr/sbin/nft delete table inet smb_guard   # only our table. never `flush ruleset`
```

`After=network-pre.target` loads the rules **before** the network is configured, so the port is
never briefly unguarded during boot. `RemainAfterExit=yes` is what makes a `Type=oneshot` unit
show as `active` after it finishes - without it systemd considers it dead and `ExecStop` never
runs on `systemctl stop`.

## Verifying - counters are the whole point

```bash
nft list table inet smb_guard      # rules + counters
```

```
ip saddr { 192.168.0.34, 192.168.0.50 } tcp dport 445 counter packets 99 bytes 26348 accept
tcp dport 445 counter packets 3 bytes 180 drop
```

99 accepted = the legitimate consumers, undisturbed. 3 dropped = the SYN retries of a probe from
a machine that is *not* on the allow-list. That is the proof the rule does what you think - and a
rising drop counter later means a consumer you forgot about is being blocked.

**The honest limitation:** nobody watches counters. There is no alert on them. If a new LAN client
ever needs the service, it gets "connection refused" and nothing tells you. Know that you are
trading a silent-lockout risk for a closed port, and write it down.

Check you did not break the neighbours:

```bash
nft list ruleset | grep -c 'ts-input\|ts-forward'   # Tailscale's chains still there
```

## Reflex to build

Before adding any nftables rule on a node that runs Tailscale, Docker, or libvirt: **list the
ruleset first**. All three inject their own tables (Docker and Tailscale via `iptables-nft`, which
shows up as `table ip filter ... managed by iptables-nft, do not touch!`). Your rules go in your own
table, next to theirs - never into theirs, and never behind a `flush`.

## Related

- [Samba server config](../storage/samba-server-config.md) - the bind limitation that forces this
- [Tailscale](tailscale.md)
- [systemd basics](../linux/systemd-basics.md) - `Type=oneshot`, `RemainAfterExit`
