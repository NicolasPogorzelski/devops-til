# Container Hardening Ladder: Non-root, Root Without Capabilities, or Root

## The question

"Least privilege" for a container is not one switch. Three levels came up
in one day with three images that are built differently:

| Image | Can run non-root? | Needs capabilities? | Result |
|---|---|---|---|
| lldap (`-rootless` variant) | yes, `user: 1000:1000` | no (ports > 1024) | non-root + `cap_drop: ALL` + `read_only` |
| PostgreSQL (alpine) | yes, `user: 70:70` if the data dir is owned accordingly | no | non-root + `cap_drop: ALL` + `read_only` + tmpfs for the socket dir |
| XWiki (Tomcat) | no - the entrypoint edits files inside the image | no | **root + `cap_drop: ALL`** |
| GitLab Omnibus | no - runit starts services as root and switches users | yes (SETUID, SETGID, CHOWN, DAC_OVERRIDE, ...) | root + Docker's default set, `no-new-privileges` only |

## Why "root without capabilities" is a real level

Root in the Linux kernel is a bundle of ~40 capabilities. `cap_drop: ALL`
removes every one of them from the container's root; what remains is a
process with UID 0 and no special powers:

- It can still read and write its own files: file access as the *owner*
  works through the normal permission bits. Image files belong to root, the
  bind-mounted volume belongs to host UID 100000 (= container root under
  `userns-remap`), so nothing needs `CAP_DAC_OVERRIDE`.
- It cannot `chown` (`CAP_CHOWN`), cannot switch users (`CAP_SETUID`),
  cannot bind ports below 1024 (`CAP_NET_BIND_SERVICE`), cannot send signals
  to other users' processes (`CAP_KILL`), cannot mount, cannot load modules.

Whether it works is an empirical question per image: does the process do
anything at start-up that needs one of these? Tomcat (bind 8080, no user
switch, no chown) - no. Omnibus (chown volumes, drop to `git`, `postgres`) -
yes, on several counts. The test costs one start; the log names the
missing capability as `Operation not permitted` in the failing sub-service.

## Why a root process can still not become non-root here

The XWiki entrypoint rewrites `hibernate.cfg.xml`/`xwiki.cfg` under
`WEB-INF`, which the image owns as root. Running it as UID 1000 would fail
on the first write. The clean fix is a derived image (pre-configured, then
`USER 1000`) - not an option when the project builds no images. Root without
capabilities is the honest middle: smaller attack surface than the default,
documented as an exception rather than hidden.

## Where `userns-remap` sits in this

All of the above is *inside* the container. `userns-remap` (host-level)
maps container UID 0 to an unprivileged host UID, so even the GitLab case
is not "root on the host" after an escape. The container ladder limits what
a compromised process can do to *itself and its neighbours*; the remap
limits what it can do to the host. Both, not either.

## Verification commands

```
docker inspect --format '{{.Name}} user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} ro={{.HostConfig.ReadonlyRootfs}}' <container>
docker exec <container> id -u
docker exec <container> grep Cap /proc/1/status     # CapEff 0000000000000000 = no capabilities
```
