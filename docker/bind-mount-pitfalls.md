# Docker Bind-Mount Pitfalls

## File vs directory: the silent directory creation

When a Docker bind-mount references a host path that **does not exist**, Docker
does not fail — it silently creates an empty **directory** at that path.

If the container expected a *file* (e.g., a config file), the mount fails with:

```
error mounting "..." to rootfs: not a directory
```

The exit code may be misleading (e.g., 127), and the original cause —
the missing config file — is not in the error message.

## Common triggers

- Config file was never created from `.env.example` / `.yml.example` after cloning
- Config file was removed by `git clean` (especially `git clean -xdf`)
- Manual deletion of a file referenced by `docker-compose.yml`
- A path typo in the compose file

## Fix

```bash
# 1. Remove the empty directory Docker created
rmdir /path/that/should/be/a/file

# 2. Recreate the file from the .example template
cp config.yml.example config.yml

# 3. Restart the container
docker compose up -d
```

## Prevention

There is no automatic prevention. Repo-level options:

- A `setup.sh` that copies every `*.example` to its target path on first run
- A pre-flight `docker compose config` check before `up -d`
- Documented in the README: "after clone, copy all `.example` files before starting"

Repo-validation scripts can confirm `*.example` exists per compose dir but
cannot know whether the target file has actually been materialized at runtime.

## Related: gitignored config files

Most homelab compose stacks have a pattern like:

```
docker/<service>/
├── docker-compose.yml         # tracked
├── .env.example                # tracked, sanitized placeholders
├── .env                        # gitignored, real secrets
├── config/
│   ├── config.yml.example      # tracked
│   └── config.yml              # gitignored, real values
```

Anything bind-mounted from `.env` or `config.yml` is at risk of the
silent-directory-creation issue if those gitignored files don't exist.

## host vs bridge networking gotcha

```yaml
network_mode: host
```

`network_mode: host` removes Docker's internal DNS resolution. Container-name
references (`http://prometheus:9090`) become unresolvable.

Use `127.0.0.1` (or the host's Tailscale IP) instead:

```yaml
# datasource.yml for Grafana — host networking
url: http://127.0.0.1:9090   # NOT http://prometheus:9090
```

This applies to *every* inter-service reference: env vars, config files,
provisioned templates, healthcheck commands.

Concrete failure: Grafana with a provisioned Prometheus datasource pointing at
`http://prometheus:9090` silently breaks dashboards after switching to host
networking. The datasource appears in the UI but every query fails.

## Bind-mounts and read-only flag

```yaml
volumes:
  - ./config:/app/config:ro
```

`:ro` is a security practice — the container cannot modify host files even if
compromised. Useful for:
- Read-only consumers (media servers, document viewers)
- Static config bind-mounts (Prometheus rules, nginx.conf)

Don't use `:ro` for:
- Application data directories (writes will fail)
- SQLite database files (writes + locks needed)
- Logs (compose stacks usually want to write logs)

## UID/GID alignment in unprivileged LXC

When running Docker inside an unprivileged LXC, host UIDs are shifted by 100000.
A container process running as `uid=1000` is actually `uid=101000` on the host.

For bind-mounted directories from outside the LXC (e.g., CIFS mounts on the
Proxmox host shared into the LXC), the host directory must be owned by the
shifted UID, otherwise the container sees permission errors:

```bash
# On the Proxmox host, prepare a directory for unprivileged LXC bind-mount
chown -R 100000:100000 /mnt/lxc220-config
```

## Related

- [Docker: Compose Patterns](compose-patterns.md)
- [Proxmox: LXC & VM Management](../proxmox/lxc-vm-management.md)
- [Security: Least-Privilege Patterns](../security/least-privilege-patterns.md)
