# Linux Namespaces & nsenter

## What namespaces are

Linux namespaces isolate system resources so that processes inside a namespace see a
different view of the system than processes outside. They are the core technology
behind containers (LXC, Docker).

| Namespace | Isolates |
|---|---|
| `mnt` | Filesystem mount points |
| `net` | Network interfaces, routes, firewall rules |
| `pid` | Process IDs |
| `uts` | Hostname and domain name |
| `ipc` | IPC resources (message queues, semaphores) |
| `user` | User and group IDs |
| `cgroup` | cgroup root directory |

## How LXC uses namespaces

Each LXC container runs as a process on the Proxmox host with its own set of namespaces.
From inside the container, it looks like a separate system. From the host, the container
is just a PID with namespaces attached.

## nsenter - entering a namespace from the host

`nsenter` lets you run a command inside an existing namespace without being inside the
container itself. Useful for operations that are blocked inside the container (like fstrim).

```bash
nsenter -t <PID> --mount -- <command>
```

| Flag | Meaning |
|---|---|
| `-t <PID>` | Target process whose namespaces to enter |
| `--mount` | Enter only the mount namespace |
| `--net` | Enter only the network namespace |
| `--all` | Enter all namespaces |

## Finding a container's PID

```bash
# By container ID (Proxmox LXC)
lxc-info -n 200 | awk '/^PID:/{print $2}'

# Or
pct status 200   # shows running state
```

## Practical example - fstrim inside a container

```bash
PID=$(lxc-info -n 200 | awk '/^PID:/{print $2}')
nsenter -t $PID --mount -- fstrim -v /
```

This runs `fstrim` in the mount namespace of LXC 200 - the command sees the container's
filesystem, but runs with host-level privileges (bypassing the FITRIM ioctl restriction).

## Why FITRIM is blocked inside LXC

LXC security profiles block the `FITRIM` ioctl by default. This is a hardening measure -
containers should not be able to directly control block device behavior on shared storage.
The host can bypass this restriction using `nsenter` because it runs outside the namespace.

## Related

- [LVM Thin Provisioning](lvm-thin-provisioning.md)
