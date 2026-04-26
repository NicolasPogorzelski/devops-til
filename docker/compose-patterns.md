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

## `depends_on` — startup ordering, with caveats

```yaml
services:
  app:
    depends_on:
      - db
      - redis
```

What this **does**: starts `db` and `redis` containers before `app`.

What this **does not** do (without `condition:`): wait for them to be *ready*.
A container being "started" means the entrypoint has been launched — not that
the application is listening on its port.

For real readiness ordering:

```yaml
services:
  app:
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
```

| Condition           | Meaning                                                            |
|---------------------|--------------------------------------------------------------------|
| `service_started`   | Container has been launched. Default; weak                         |
| `service_healthy`   | Container's healthcheck reports healthy. Strong; requires healthcheck on dependency |
| `service_completed_successfully` | Dependency exited 0. Used for one-shot init containers   |

`service_healthy` is what you actually want for "wait until the database is
accepting connections". The dependency must define a healthcheck.

## `env_file` vs `environment`

```yaml
# A — env_file: load from a file
env_file: .env

# B — environment: list-form
environment:
  - PUID=1000
  - PGID=1000
  - TZ=Europe/Berlin

# C — environment: map-form
environment:
  PUID: 1000
  PGID: 1000
  TZ: "Europe/Berlin"
```

| Form         | Use when                                                          |
|--------------|-------------------------------------------------------------------|
| `env_file`   | Many vars, or contains secrets. The file is gitignored            |
| `environment` (list) | Few vars, all non-sensitive. Gets fully into compose.yml |
| `environment` (map)  | Same as list, but YAML-cleaner for many vars              |

You can use both together: `env_file` for secrets, `environment` for non-secret
defaults that belong with the service definition.

## `linuxserver/*` images and `PUID`/`PGID`

A common pattern in homelab images (Calibre-Web, Sonarr, Bazarr, many others):

```yaml
services:
  calibre-web:
    image: lscr.io/linuxserver/calibre-web:latest
    environment:
      PUID: 1000
      PGID: 1000
      TZ: Europe/Berlin
```

| Variable | What it does                                                          |
|----------|-----------------------------------------------------------------------|
| `PUID`   | Container's `abc` user is mapped to this host UID at startup          |
| `PGID`   | Same for primary group                                                |
| `TZ`     | Container timezone — affects log timestamps and scheduled jobs        |

The `lscr.io/linuxserver/*` namespace is the linuxserver.io maintained image
registry. Their images consistently use `PUID`/`PGID`. Other image families
use different variable names — Paperless uses `USERMAP_UID`/`USERMAP_GID`.
Always check the image's docs.

Why bother: bind-mounted host directories have specific UIDs. If the container
runs as a different UID, files it creates appear with that UID on the host —
either unreadable from the host side, or with the wrong owner for backup/sync
tools. Setting `PUID:PGID` to match the host's expected ownership avoids this.

## Named volumes + bind mounts — mixing strategies

```yaml
services:
  paperless:
    volumes:
      - paperless-data:/usr/src/paperless/data    # named volume
      - paperless-media:/usr/src/paperless/media  # named volume
      - /mnt/smb/inbox:/usr/src/paperless/consume # bind mount

volumes:
  paperless-data:
  paperless-media:
```

When to use each:

| Volume type    | Right for                                                       |
|----------------|------------------------------------------------------------------|
| Named volume   | Service-internal state — DB files, cache, logs. Docker manages location |
| Bind mount     | Cross-service paths — user-visible files, files written by host scripts |
| `:ro` bind     | Configs, certificates, read-only data — can't be modified from container |

Don't bind-mount everything just for visibility. Named volumes back up via
`docker volume` commands and are well-isolated. Use them whenever the
container-internal layout doesn't need to be visible from the host.

## 3-part bind syntax — explicit host interface

```yaml
ports:
  - "${BIND_ADDRESS}:${PORT}:8083"
```

| Part                  | Meaning                                                       |
|-----------------------|---------------------------------------------------------------|
| `${BIND_ADDRESS}`     | Host interface to bind on (`127.0.0.1`, `100.x.y.z`, `0.0.0.0`) |
| `${PORT}`             | Host port                                                     |
| `8083`                | Container port                                                |

The 3-part form is the only form that lets you pin to a specific host interface.
The 2-part form (`8080:8080`) binds to `0.0.0.0` — every interface, including
LAN. For homelab security, `${BIND_ADDRESS}` should be `127.0.0.1` or the
Tailscale IP, never `0.0.0.0` unless explicitly intended.

Using env-var substitution lets the same compose file deploy to different hosts
without editing — each host's `.env` sets its own bind address.

## Related

- [Networking: Tailscale](../networking/tailscale.md)
- [Docker GPU Passthrough](gpu-passthrough.md)
- [Bind-Mount Pitfalls](bind-mount-pitfalls.md)
- [Loopback + Tailscale Serve](../networking/loopback-tailscale-serve.md)
