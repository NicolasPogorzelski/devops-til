# Docker Daemon Recovery

## Docker and containerd are separate processes

The Docker daemon (`dockerd`) delegates container lifecycle management to
`containerd`, which is a separate daemon. Both run independently.

When `dockerd` crashes ungracefully, `containerd` keeps running - including
any task state it holds for previously running containers.

## Stale task state after ungraceful daemon shutdown

When `dockerd` crashes (e.g. binary corrupted, OOM-killed, host power loss),
containerd is left with stale task directories in:

```
/run/containerd/io.containerd.runtime.v2.task/moby/<container-id>/
```

`/run/` is a tmpfs - this is ephemeral state, not persistent storage.

On the next Docker start, `dockerd` reads its own container database and
tries to restart containers with `restart: unless-stopped` or `restart: always`.
It attempts to create a new containerd task - and fails because the stale
directory already exists.

## Error messages

Two distinct errors depending on recovery stage:

**Stage 1 - stale directory:**
```
failed to create task for container: mkdir /run/containerd/.../moby/<id>: file exists
```

**Stage 2 - stale container registration in containerd:**
```
failed to create task for container: failed to create shim task:
OCI runtime create failed: runc create failed: container with given ID already exists
```

Both mean: containerd thinks this container is still registered, Docker cannot
create a new task for it.

## Recovery

The cleanest fix is to remove Docker's record of the container and recreate it
from the Compose file. This also cleans up the containerd registration:

```bash
docker rm -f <container-name>
cd /path/to/compose && docker compose up -d
```

`docker rm -f` tells containerd to drop the container from its registry,
removing both the task directory and the container object. The `-f` flag forces
removal even if the container is not in a running state.

Do not attempt to manually delete `/run/containerd/...` directories - by the
time Stage 2 is reached, the stale state is in containerd's metadata, not just
the filesystem.

## Checking if runc itself is corrupt

If `docker start` or `docker compose up` fails with:

```
fork/exec /usr/bin/runc: exec format error
```

The `runc` binary is corrupt (same thin-pool truncation pattern as other binaries).
Reinstall:

```bash
dpkg -S /usr/bin/runc        # find which package owns it
apt-get install --reinstall containerd.io
systemctl restart containerd
systemctl restart docker
docker compose up -d
```

## Related

- [Compose Patterns](compose-patterns.md)
- [ELF Binary Corruption](../linux/elf-binary-corruption.md)
- [apt & dpkg](../linux/apt-dpkg.md)
