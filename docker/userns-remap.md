# Docker userns-remap - Container Root Is Not Host Root

## The three privilege models

| Mode | `dockerd` runs as | UID 0 inside a container is, on the host | Container escape means |
|---|---|---|---|
| rootful (default) | root | root | host compromised |
| rootful + `userns-remap` | root | an unprivileged high UID (e.g. 100000) | a nobody without a home, without sudo |
| rootless | your user | unprivileged UID from your subuid range | daemon *and* container are unprivileged |

`userns-remap` is the middle path: one line of daemon configuration, no operational
restrictions (ports below 1024, source-IP preservation and untested vendor compose files are
the rootless costs), but the blast radius of an escape shrinks to an unprivileged UID.
It is damage limitation, not a guarantee - kernel exploits can bypass user namespaces.

## Enable it - before the first image pull

```json
{ "userns-remap": "default" }
```
in `/etc/docker/daemon.json`, then `systemctl restart docker`. `default` makes Docker create
the system user `dockremap` and a 65 536-ID range in `/etc/subuid` and `/etc/subgid`
(`dockremap:100000:65536`). Container UID *n* maps to host UID *100000 + n*.

Enabling it later "hides" everything pulled before: Docker starts a fresh data directory
`/var/lib/docker/<uid>.<gid>/` for the remapped daemon. Enable it on a fresh host.

## The recurring consequence: bind-mount ownership

Every bind-mounted directory or file must be owned by the **remapped** UID, not the one the
image documentation names:

| Image says | Owner on the host |
|---|---|
| runs as UID 1000 | `chown 101000:101000` |
| PostgreSQL as UID 999 | `chown 100999:100999` |
| runs as root (UID 0) | `chown 100000:100000` |

A private key with mode 600 for a proxy running as UID 1000 therefore belongs to host UID
101000, otherwise the process cannot read it. `ls -ln` shows numeric IDs and makes the
mapping visible.

## What does not work with user namespaces

- `--network=host`, `--pid=host` (sharing host namespaces)
- `--privileged` without `--userns=host`
- `mknod` inside the container, even as container root
- external volume drivers that do not understand the mapping

## Verify

```bash
docker info | grep -A5 "Security Options"     # must list userns
grep dockremap /etc/subuid /etc/subgid
ls -ln /var/lib/docker/                       # a <uid>.<gid> directory exists
```

## Related decision: the `docker` group

Membership in the `docker` group is root-equivalent without a password prompt and without
a `sudo` audit line (`docker run -v /:/host ...`). Prefer `sudo docker` for humans; for
unattended read-only checks (monitoring, tooling) a narrow `sudoers.d` rule
(`NOPASSWD: /usr/bin/docker ps, /usr/bin/docker logs *, ...`) beats the group - see
[Least-Privilege Patterns](../security/least-privilege-patterns.md).
