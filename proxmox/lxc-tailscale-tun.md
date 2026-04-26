# Tailscale in Unprivileged LXCs (TUN Configuration)

## Problem

Tailscale uses the kernel's WireGuard module (kernel-mode networking) by default.
This requires access to `/dev/net/tun` — a character device that creates virtual
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
lxc.apparmor.profile: unconfined   # disables AppArmor — bad
lxc.cap.drop:                      # empty drop = grants all caps — very bad
```

`unconfined` removes the kernel's mandatory access control for all processes
in the container. Combined with no dropped capabilities, this gives the
container near-host-level kernel privileges — defeats the point of unprivileged
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

## Why this matters for service binding

The Zero-Trust binding model requires services to bind either to loopback or
to the Tailscale IP. With userspace networking, only loopback binding works —
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

# 3. tailscaled has no userspace-networking flag
pct exec <ctid> -- cat /etc/default/tailscaled
# FLAGS should be empty or absent

# 4. Service can bind to the Tailscale IP
pct exec <ctid> -- ss -tlnp | grep <tailscale-ip>
```

## Related

- [Proxmox: LXC & VM Management](lxc-vm-management.md)
- [Networking: Tailscale](../networking/tailscale.md)
- [Linux: Namespaces & nsenter](../linux/namespaces-nsenter.md)
