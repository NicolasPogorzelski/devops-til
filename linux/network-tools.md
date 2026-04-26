# Network Diagnostic Tools

A toolkit for answering "is the network broken, or is it the application?".

## TCP reachability — `nc -zv`

The fastest way to confirm a port is open:

```bash
nc -zv <host> <port>
```

| Flag | Purpose |
|---|---|
| `-z` | Zero-I/O mode — connect, then close. No data sent. |
| `-v` | Verbose — print success or failure |

```
$ nc -zv <tailscale-ip-ct260> 5432
Connection to <tailscale-ip-ct260> 5432 port [tcp/postgresql] succeeded!

$ nc -zv <unreachable> 5432
nc: connect to <unreachable> port 5432 (tcp) failed: Connection refused
```

Three possible outcomes:

| Result | Meaning |
|---|---|
| `succeeded!` | Port is open and accepting connections |
| `Connection refused` | Host is reachable, but nothing is listening on that port |
| `No route to host` / `Connection timed out` | Network path is broken (routing, firewall, ACL) |

`Connection refused` vs `timed out` is the key distinction: refused = service problem,
timeout = network problem.

## When `nc` isn't available — Python fallback

Minimal containers and slim distros may not include netcat:

```bash
python3 -c "
import socket
s = socket.create_connection(('<host>', 5432), timeout=3)
print('ok')
s.close()
"
```

Inside a Docker container with no extras:
```bash
docker exec <container> python3 -c "import socket; socket.create_connection(('<host>', 5432), 3); print('ok')"
```

## Listening sockets — `ss`

`ss` (socket statistics) replaced `netstat`. Faster, more accurate, lives in `iproute2`.

```bash
# All TCP listening sockets with the owning process
ss -tlnp

# Same for UDP
ss -ulnp

# Filter for a specific port
ss -tlnp 'sport = :5432'

# Show all established TCP connections
ss -tn state established
```

| Flag | Meaning |
|---|---|
| `-t` | TCP |
| `-u` | UDP |
| `-l` | Listening sockets only |
| `-n` | Numeric — don't resolve hostnames or service names |
| `-p` | Show process owning each socket (requires root for full info) |

Reading `ss -tlnp` output:
```
LISTEN 0  4096  127.0.0.1:9090  0.0.0.0:*  users:(("prometheus",pid=1234,fd=8))
       │   │      │       │     │     │
       │   │      │       │     │     └── peer port (any for listening)
       │   │      │       │     └────────── peer address
       │   │      │       └──────────────── local port
       │   │      └──────────────────────── local address (127.0.0.1 = loopback only)
       │   └─────────────────────────────── send-queue capacity
       └─────────────────────────────────── recv-queue (current backlog)
```

The local address column is what matters for binding rules: `127.0.0.1` = loopback only,
`0.0.0.0` = all interfaces, `<specific-ip>` = that interface only.

## Interfaces and routing — `ip`

```bash
# All interfaces with IPs
ip addr
ip addr show <interface>     # e.g. tailscale0, eth0

# Routing table
ip route
ip route get <destination>   # which route would be used to reach <destination>

# Show interface link state up/down
ip link
```

`ip` from `iproute2` replaced the deprecated `ifconfig` and `route` commands. Same data,
more accurate, single tool.

For Tailscale debugging:
```bash
ip addr show tailscale0
# expected: inet 100.x.y.z/32 scope global tailscale0
```

If `tailscale0` doesn't exist, Tailscale is in userspace-networking mode (see
[Tailscale TUN in Unprivileged LXCs](../proxmox/lxc-tailscale-tun.md)).

## Mount inspection — `findmnt`

```bash
# Show all mounts in tree format
findmnt

# Find which mount covers a path
findmnt -T /mnt/smb/openwebui

# All mounts of a specific filesystem type
findmnt -t cifs
findmnt -t nfs
findmnt -t ext4

# Output specific columns
findmnt -T /mnt/foo -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Better than `mount | grep` because `findmnt` parses `/proc/self/mountinfo` directly and
gives structured output.

## DNS resolution — `dig` and `getent`

```bash
# Forward lookup
dig <hostname>
dig <hostname> +short              # just the IP

# Reverse lookup
dig -x <ip>

# Use a specific DNS server
dig @8.8.8.8 <hostname>

# Show the answer chain (CNAME → A)
dig <hostname> +trace
```

`dig` only queries DNS. To see what `getent` resolves through (DNS + `/etc/hosts` + `nsswitch`):

```bash
getent hosts <hostname>
getent ahosts <hostname>           # all addresses (v4 + v6)
```

For Tailscale MagicDNS resolution, `getent hosts <name>.<tailnet-id>.ts.net` should return the
Tailscale IP.

## Path tracing — `mtr`

`mtr` (My TraceRoute) combines `traceroute` and `ping` into a continuously-updating display:

```bash
mtr <host>

# Numeric only (no DNS)
mtr -n <host>

# Run for 10 cycles then exit (good for capturing in scripts)
mtr -nrc 10 <host>
```

Each row is a hop. The `Loss%` and `Avg` columns reveal where latency or packet loss starts.
A single hop with high loss but later hops fine = ICMP rate-limit, not real loss. Real loss
shows up at one hop and persists in all later hops.

## Bandwidth testing — `iperf3`

To measure actual throughput between two hosts:

```bash
# On the receiver
iperf3 -s

# On the sender
iperf3 -c <receiver-ip>

# 30 seconds, 4 parallel streams (saturates more reliably)
iperf3 -c <receiver-ip> -t 30 -P 4

# UDP test at 100 Mbit/s
iperf3 -c <receiver-ip> -u -b 100M
```

Useful for verifying that Tailscale isn't introducing unexpected bottlenecks vs the LAN path.

## Packet capture — `tcpdump`

When higher-level tools don't reveal the problem:

```bash
# Watch traffic on a specific interface
tcpdump -i tailscale0

# Filter by host and port
tcpdump -i any host <ip> and port 5432

# Save to a file for analysis in Wireshark
tcpdump -i any -w /tmp/capture.pcap port 5432

# Show packet contents in ASCII
tcpdump -A -i any port 80
```

Requires root. Use sparingly — captures grow fast on busy networks.

## Quick decision tree

```
"Service unreachable"
    │
    ├── ss -tlnp on the server:                  is the service even listening?
    │       │
    │       ├── nothing on that port          ─→ service is down or bound to wrong interface
    │       └── listening on the right addr   ─→ continue
    │
    ├── nc -zv from client to server:port:      can we reach it?
    │       │
    │       ├── connection refused             ─→ firewall on server, or service stopped between checks
    │       ├── timeout                        ─→ network path issue (routing, ACL, firewall in the middle)
    │       └── succeeded                      ─→ network is fine; problem is application-level
    │
    └── Application-level                       ─→ check service logs, auth, TLS
```

## Related

- [Networking: Tailscale](../networking/tailscale.md)
- [Networking: Loopback + Tailscale Serve](../networking/loopback-tailscale-serve.md)
- [Storage: CIFS Automount](../storage/cifs-automount.md)
