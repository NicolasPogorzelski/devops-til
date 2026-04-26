# Docker GPU Passthrough (NVIDIA)

## What "GPU passthrough" actually means in Docker

A Docker container by default sees no GPU. Even if the host has an NVIDIA card,
`/dev/nvidia*` device nodes are not bind-mounted, the libraries are not present,
and CUDA-compiled binaries inside the container will fail with "no CUDA-capable device".

The **NVIDIA Container Toolkit** is the missing piece. It hooks into Docker's
runtime, so when a container requests GPU access, it injects:

- The required `/dev/nvidia*` device nodes
- Host-matched user-space libraries (`libcuda.so`, `libnvidia-encode.so`, etc.)
- Driver-version metadata for the CUDA runtime in the image

Without the Toolkit, GPU containers do not work. With it, GPU access becomes a
declarative property of the compose file.

## Two syntaxes — same outcome

**Compose v2 deploy.resources syntax (recommended):**

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

**Legacy `runtime: nvidia` syntax:**

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    runtime: nvidia
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility,video
```

Both work today. Prefer the `deploy.resources` form because:

- It's the documented compose-spec way
- It works with `docker compose up` and Docker Swarm equivalently
- It expresses *what* (GPU access) rather than *how* (a specific runtime name)

## NVIDIA_VISIBLE_DEVICES

Controls which GPUs the container sees:

| Value          | Effect                                                       |
|----------------|--------------------------------------------------------------|
| `all`          | All GPUs visible                                             |
| `0` or `0,1`   | Specific GPU indices (as listed by `nvidia-smi`)             |
| `none`         | No GPUs (rarely useful — same as not setting it)             |
| `<UUID>`       | Specific GPU by UUID — survives reordering                   |

For multi-GPU hosts, prefer UUIDs (`nvidia-smi -L`) over indices. The kernel
can renumber GPUs after a reboot if a card is added or removed.

## NVIDIA_DRIVER_CAPABILITIES

Tells the Toolkit which categories of libraries to mount:

| Capability  | What it enables                                              |
|-------------|--------------------------------------------------------------|
| `compute`   | CUDA / OpenCL — compute kernels                              |
| `utility`   | `nvidia-smi` and management libraries                        |
| `video`     | NVENC/NVDEC for hardware video encoding/decoding             |
| `graphics`  | OpenGL / Vulkan — for graphical applications                 |
| `display`   | Display output — almost never needed in containers           |
| `all`       | Everything                                                   |

For media servers (Jellyfin, Plex): `compute,utility,video`.
For LLM inference (Ollama, vLLM): `compute,utility`.
For ML training: `compute,utility` (and `graphics` only if the framework needs it).

Don't use `all` — it mounts more libraries than the container needs and increases
the surface area of the host driver exposed inside the container.

## `pid: host` — when you need it

Some workloads (notably media transcoding via NVENC under specific driver versions)
need `pid: host` in the container:

```yaml
services:
  jellyfin:
    pid: host
```

**What it does:** disables PID namespace isolation. The container sees the host's
process tree.

**Why it's sometimes required:** the NVIDIA driver tracks GPU-using processes by PID.
When a container has its own PID namespace, the driver may see PIDs that don't
match what the user-space libraries expect, breaking certain operations
(notably hardware-accelerated transcoding under some driver versions).

**Cost:** the container can `ps` and see all host processes. This is a real
isolation downgrade. Add it only when:

- You have a verified failure mode that `pid: host` resolves
- The container is otherwise trusted (your own software, not a public image)
- You've documented the exception in the service's runbook

## Verifying GPU access from inside the container

```bash
docker exec jellyfin nvidia-smi
```

If this shows the GPU table: passthrough works. If it returns
"command not found": `NVIDIA_DRIVER_CAPABILITIES` doesn't include `utility`.
If it returns "no devices found": `NVIDIA_VISIBLE_DEVICES` is wrong or the
Toolkit isn't installed on the host.

For a pure compute check without `nvidia-smi`:

```bash
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvcc --version
```

## Host prerequisites

The Toolkit must be installed on the *host* (or VM) running Docker, not in the LXC
that runs Docker. On Debian:

```bash
apt install nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
```

| Step                                          | Why                                                           |
|-----------------------------------------------|---------------------------------------------------------------|
| `nvidia-container-toolkit`                    | The package providing the runtime hook and CLI                |
| `nvidia-ctk runtime configure --runtime=docker` | Edits `/etc/docker/daemon.json` to register the nvidia runtime |
| `systemctl restart docker`                    | Apply the daemon config change                                |

For an LXC running Docker on a Proxmox host: GPU passthrough into an unprivileged
LXC is a separate problem (cgroup device rules, mount entries) and generally not
worth fighting. Use a VM for GPU workloads.

## Related

- [Docker Compose Patterns](compose-patterns.md)
- [Docker Bind-Mount Pitfalls](bind-mount-pitfalls.md)
- [Ollama Deployment](../ai/ollama-deployment.md)
