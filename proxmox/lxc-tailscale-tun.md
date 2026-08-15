# Tailscale in Unprivileged LXCs (TUN Configuration)

## Problem

Tailscale uses the kernel's WireGuard module (kernel-mode networking) by default.
This requires access to `/dev/net/tun` - a character device that creates virtual
network interfaces.

In an unprivileged LXC container:
- The host's `/dev/net/tun` is not visible inside the container by default
- Even if visible, the kernel denies access without an explicit cgroup rule

Without both pieces, Tailscale silently falls back to userspace networking,
which is harder to debug and breaks services that bind to a specific interface.

## The CT210-pattern (reference TUN config)

Add to the LXC config (`/etc/pve/lxc/<ctid>.conf` on the Proxmox host):

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

| Line | Meaning |
|---|---|
| `cgroup2.devices.allow: c 10:200 rwm` | Allow read/write/mknod on character device with major 10, minor 200 (TUN). Without this, the kernel denies access regardless of mount visibility. |
| `mount.entry: /dev/net/tun dev/net/tun none bind,create=file` | Bind-mount the host's TUN device into the container's namespace. `create=file` ensures the target is created as a file (not a directory) if missing. |

Both lines are required. Either alone is insufficient.

## What NOT to do

These are common debugging shortcuts that should not survive into production:

```
lxc.apparmor.profile: unconfined   # disables AppArmor - bad
lxc.cap.drop:                      # empty drop = grants all caps - very bad
```

`unconfined` removes the kernel's mandatory access control for all processes
in the container. Combined with no dropped capabilities, this gives the
container near-host-level kernel privileges - defeats the point of unprivileged
LXCs entirely.

If Tailscale needs more than the CT210-pattern allows, the right move is to
identify the specific syscall or capability needed, not to disable AppArmor.

## Pitfall: `--tun=userspace-networking` legacy flag

**Symptom:**
```
listen tcp <tailscale-ip>:9100: bind: cannot assign requested address
```

`tailscale status` reports the node as connected, but `ip addr show tailscale0`
reports the device does not exist.

**Root cause:**
`/etc/default/tailscaled` contains:
```
FLAGS="--tun=userspace-networking"
```

In userspace mode, Tailscale does not create a kernel `tailscale0` interface.
The Tailscale IP is not assigned to any OS-level interface, so `bind()` calls
fail with `EADDRNOTAVAIL`.

**Fix:**
Remove the flag from `/etc/default/tailscaled`. Restart:

```bash
systemctl restart tailscaled
ip addr show tailscale0   # should now show the Tailscale IP
```

Then restart any service that binds to the Tailscale IP (e.g., node_exporter).

## The same flag, delivered differently - and the symptom inverts

The section above describes the case where `bind()` **fails** and the service will
not start. There is a second shape of this fault that looks like the opposite,
and it is far harder to spot.

Encountered 2026-07-28: a container where `node_exporter` was `active`,
`ss -tlnp` showed it listening on the Tailscale IP, and `ip addr show tailscale0`
showed the interface with its address - everything an operator would check looked
correct. Only the scrape from the monitoring node failed, with
`connection refused`.

Two things were going on:

1. The mode did not come from `/etc/default/tailscaled` at all. That file read
   `FLAGS=""` and the packaged unit was unmodified. A **second, hand-written
   unit** - `/etc/systemd/system/tailscaled-userspace.service` - was `enabled`
   alongside the stock `tailscaled.service`. Every boot started *two* daemons,
   two seconds apart, against the same `--state` and `--socket` paths.
2. Because a TUN daemon was also running, `tailscale0` existed and carried the
   address. So the bind succeeded. What did not happen was **delivery**: the
   userspace daemon terminates incoming connections in netstack and never hands
   them to the kernel socket the service is bound to. Tailscale answers with a
   RST, which the client reports as `connection refused` - indistinguishable at
   a glance from an ACL denial.

The tell that it was not an ACL: `tailscale serve` traffic on 443 worked the
whole time, because serve is answered *inside* that same userspace process. The
node therefore looked healthy in blackbox HTTPS probes while its metrics target
was down - a service-level probe and a metrics scrape disagreeing is a strong
hint that something is terminating traffic in userspace.

**The generalisable lesson: a successful `bind()` does not prove reachability.**
`ss` tells you a socket exists locally. It says nothing about whether packets
from a peer ever reach it. The only honest test is a connection from the far end:

```bash
# From the monitoring node, not from the node under test
pct exec 200 -- curl -s -o /dev/null -w '%{http_code}\n' \
    http://<tailscale-ip>:9100/metrics
# 200 = reachable; 000 = nothing got through
```

**Fix:** disable the stray unit, then restart the survivor so it claims the TUN
device cleanly:

```bash
systemctl disable --now tailscaled-userspace.service   # --now = disable + stop
systemctl restart tailscaled.service
```

Note that `disable` leaves the unit *file* in place. A later `systemctl enable`,
or a rebuild from this machine's state, revives it - delete the file to close it
out properly.

## Why this matters for service binding

The Zero-Trust binding model requires services to bind either to loopback or
to the Tailscale IP. With userspace networking, only loopback binding works -
so any service that should listen on `<tailscale-ip>:<port>` silently fails
to start. That includes `node_exporter`, `postgresql` with `listen_addresses`,
and Ollama.

## Verification checklist

```bash
# 1. TUN device exists inside the container
pct exec <ctid> -- ls -l /dev/net/tun
# expected: crw-rw-rw- ... /dev/net/tun

# 2. Tailscale interface exists
pct exec <ctid> -- ip addr show tailscale0
# expected: device with inet 100.x.y.z

# 3. tailscaled runs WITHOUT the userspace flag - check the process, not the config.
#    `cat /etc/default/tailscaled` is NOT sufficient: the flag can arrive from a
#    second unit file while that file reads FLAGS="" (seen on lxc220, 2026-07-28).
pct exec <ctid> -- ps -o pid,args -C tailscaled
# expected: exactly ONE process, and no --tun=userspace-networking

# 3b. No stray second unit is enabled
pct exec <ctid> -- systemctl list-unit-files | grep -i tailscale
# expected: exactly one enabled tailscale daemon unit
# (`systemctl status <pid>` maps any unexpected process back to its unit)

# 4. Service can bind to the Tailscale IP
pct exec <ctid> -- ss -tlnp | grep <tailscale-ip>

# 5. ...and is actually REACHABLE from another node. Step 4 alone proves nothing:
#    with userspace networking the bind succeeds and delivery still fails.
pct exec 200 -- curl -s -o /dev/null -w '%{http_code}\n' \
    http://<tailscale-ip>:9100/metrics
# expected: 200
```

## Related

- [Proxmox: LXC & VM Management](lxc-vm-management.md)
- [Networking: Tailscale](../networking/tailscale.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
