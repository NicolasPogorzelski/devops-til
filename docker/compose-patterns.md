# Docker Compose Patterns

## Basic structure

```yaml
services:
  myapp:
    image: myapp:1.2.3          # always pin versions, never :latest
    container_name: myapp
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:8080:8080"  # bind to loopback only
```

## Volume mounts

```yaml
volumes:
  - /host/path:/container/path        # bind mount (host directory)
  - /host/path:/container/path:ro     # read-only
  - myvolume:/container/path          # named volume (managed by Docker)
```

`:ro` is a security practice — if the container is compromised, it cannot write
to the mounted path.

## Environment variables

```yaml
# Option 1: inline (avoid for secrets)
environment:
  - MY_VAR=value

# Option 2: env_file (reference a .env file)
env_file: .env
```

`.env` files must never be committed to git. Always commit a `.env.example`
with placeholder values.

## network_mode: host

```yaml
network_mode: host
```

The container shares the host's network stack directly — no Docker network isolation,
no NAT, no Docker DNS.

**Consequence:** Container name resolution (`http://other-container`) does not work.
Use `127.0.0.1` or the host's Tailscale IP to reach other services.

Use case: services that need to bind to specific host interfaces (e.g. Prometheus
scraping via Tailscale IP, Jellyfin with NVIDIA Container Toolkit).

## Restart policies

| Policy | Behavior |
|---|---|
| `no` | Never restart |
| `always` | Always restart, including on boot |
| `unless-stopped` | Restart always except when manually stopped |
| `on-failure` | Restart only on non-zero exit code |

`unless-stopped` is the standard for homelab services — survives reboots,
respects manual stops.

## Logging limits

Docker logs grow unbounded by default. Always set limits:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

## GPU access (NVIDIA)

```yaml
services:
  ollama:
    image: ollama/ollama
    runtime: nvidia
    pid: "host"               # required for NVIDIA Container Toolkit
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
```

`pid: "host"` shares the host PID namespace — required for the NVIDIA toolkit
to access GPU devices.

## Healthchecks

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
  interval: 30s
  timeout: 10s
  retries: 3
```

## Key commands

```bash
docker compose up -d              # start in background
docker compose down               # stop and remove containers
docker compose pull               # pull latest images (for updates)
docker compose logs -f <service>  # follow logs
docker compose ps                 # show running containers
docker system df                  # disk usage summary
docker image prune -a --force     # remove unused images
```

## Related

- [Networking: Tailscale](../networking/tailscale.md)
