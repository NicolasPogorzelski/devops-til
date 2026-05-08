# devops-til

Things I learned while building and operating a homelab on the path to becoming a DevOps engineer.

Each entry is a short summary with a link to a detailed explanation. Organized by topic.

> Work in progress. Corrections and feedback welcome.

---

## Linux Internals

| Topic | Summary |
|---|---|
| [LVM Thin Provisioning](linux/lvm-thin-provisioning.md) | How thin-pool storage works, why `df` lies inside containers, and how to reclaim space with fstrim |
| [Namespaces & nsenter](linux/namespaces-nsenter.md) | What Linux namespaces are, how LXC containers use them, and how to enter them from the host |
| [ELF Binaries & Corruption](linux/elf-binary-corruption.md) | What ELF format is, how to detect a corrupt binary, and how to reinstall it |
| [apt & dpkg](linux/apt-dpkg.md) | `apt update` vs `apt upgrade`, `dpkg --verify` with conffile filtering, dpkg audit and repair, Ansible `upgrade: dist` modes, cache hygiene |
| [systemd Basics](linux/systemd-basics.md) | Unit types, systemctl commands, journalctl filtering, mount units, `Type=oneshot`, drop-in overrides |
| [systemd Service Hardening](linux/systemd-service-hardening.md) | `Restart=on-failure`, `RestartPreventExitStatus`, `After=` vs `Wants=`, race-condition fixes |
| [Bash Scripting Patterns](linux/bash-scripting-patterns.md) | Strict mode, pre-flight checks, `command -v`, `install -m`, HEREDOC, sub-commands, `mktemp+trap` |
| [SSH Keys](linux/ssh-keys.md) | Ed25519 keys, agent forwarding caveats, authorized_keys hygiene, key rotation |
| [Cron and Scheduling](linux/cron-and-scheduling.md) | crontab vs `/etc/cron.d/`, systemd timers, when to choose which, log conventions |
| [Disk Diagnostics](linux/disk-diagnostics.md) | `smartctl`, `dmesg`, identifying drive failures, SMART attribute thresholds |
| [Network Tools](linux/network-tools.md) | `nc -zv`, `ss`, `findmnt`, Python socket fallback, layer-by-layer reachability |

## Ansible

| Topic | Summary |
|---|---|
| [Playbook Structure](ansible/playbook-structure.md) | Minimum required fields, plays vs tasks, YAML indentation rules |
| [Task Control](ansible/task-control.md) | `register`, `changed_when`, `ansible.builtin.fail`, `when` with Jinja2 filters, `shell` vs `command` |
| [Privilege Escalation](ansible/privilege-escalation.md) | `become`, `become_user`, and how to configure NOPASSWD sudo for Ansible |
| [Inventory Groups](ansible/inventory-groups.md) | Group structure, per-host overrides, `host_vars`/`group_vars`, sanitized inventory pattern |
| [Serial Execution](ansible/serial-execution.md) | Why parallel upgrades are dangerous and how `serial` prevents resource spikes |
| [Ansible Configuration](ansible/configuration.md) | `ansible.cfg` settings explained: `host_key_checking`, pipelining, ControlMaster, fork count |
| [Roles](ansible/roles.md) | Why roles exist, directory structure, `defaults/` vs `vars/`, `files/` vs `templates/`, binary deployment pattern, handlers |
| [Jinja2 Templates](ansible/jinja2-templates.md) | Generating config files from inventory: `groups[]`, `hostvars[]`, for loops, if conditions, mixing static and dynamic sections, `template` module |

## Proxmox

| Topic | Summary |
|---|---|
| [Thin-Pool Recovery](proxmox/thin-pool-recovery.md) | How to diagnose and recover from a full LVM thin-pool on a Proxmox host |
| [LXC & VM Management](proxmox/lxc-vm-management.md) | `pct` and `qm`, LXC vs VM, mount points, boot order, `nesting=1`, `/dev/disk/by-id`, bind-mount propagation |
| [Tailscale TUN in Unprivileged LXCs](proxmox/lxc-tailscale-tun.md) | CT210-pattern: `cgroup2.devices.allow` + `mount.entry` for kernel WireGuard, userspace-networking pitfall |

## Networking

| Topic | Summary |
|---|---|
| [Tailscale](networking/tailscale.md) | Tailscale IPs, MagicDNS, Tailscale-managed certs, app-layer security boundary, vendor-lock-in considerations |
| [Loopback + Tailscale Serve](networking/loopback-tailscale-serve.md) | The `127.0.0.1` + Serve binding pattern, alternatives evaluated, HTTPS/HTTP mismatch |
| [Tailscale ACL Design](networking/tailscale-acl-design.md) | Tier-based design, hosts aliases, access matrix, ACL changelog, pre-existing tunnel pitfall |
| [Tailscale Debugging](networking/tailscale-debugging.md) | How Tailscale's userspace packet filter works, `tailscale ping` bypasses ACL, duplicate node key problem, tcpdump as layer-separator, fix via daemon restart |

## Docker

| Topic | Summary |
|---|---|
| [Compose Patterns](docker/compose-patterns.md) | Restart policies, `network_mode: host`, logging, `depends_on` w/ healthcheck, `env_file` vs environment, PUID/PGID, named-volume mix |
| [Daemon Recovery](docker/daemon-recovery.md) | Docker vs containerd process model, stale task state after ungraceful crash, `docker rm -f` + `compose up` recovery |
| [Data Root Migration](docker/data-root-migration.md) | Moving containerd + Docker data root off the root disk to Aux storage: `daemon.json`, `config.toml`, `rsync -aH`, boot-time dependency, fstrim |
| [Bind-Mount Pitfalls](docker/bind-mount-pitfalls.md) | Silent directory creation for missing files, host-networking DNS loss, UID alignment in unprivileged LXCs |
| [GPU Passthrough](docker/gpu-passthrough.md) | NVIDIA Container Toolkit, `pid: host`, `deploy.resources.reservations.devices`, capability scoping |

## Monitoring

| Topic | Summary |
|---|---|
| [Prometheus Stack](monitoring/prometheus-stack.md) | Scrape jobs, node_exporter, textfile collector pattern, alert rules, Alertmanager routing |
| [Prometheus Configuration](monitoring/prometheus-config.md) | `scrape_configs`, rule_files, alertmanagers static_configs, job-naming, retention/lifecycle flags |
| [PromQL & Alert Rules](monitoring/promql-patterns.md) | `for:` debouncing, severity labels, fstype filters, aggregations, annotation templating, recording rules |
| [Alertmanager Routing](monitoring/alertmanager-routing.md) | Routes, group_by/wait/interval, repeat_interval, inhibit_rules, silences, Discord webhooks |

## Storage

| Topic | Summary |
|---|---|
| [SnapRAID + MergerFS](storage/snapraid-mergerfs.md) | Storage stack architecture, sync/scrub discipline, `noatime`, excludes, multiple content files, `category.create=mfs`, hash-mismatch recovery, live disk expansion via xattr, empty-disk sync (XOR neutral), status output interpretation |
| [CIFS via systemd Automount](storage/cifs-automount.md) | Reboot-safe network mounts, `x-systemd.automount` options, boot-trigger oneshot, app-state vs uploads split |
| [Samba Server Config](storage/samba-server-config.md) | `smb.conf` structure, SMB3-only, mandatory signing, bind interfaces, share types (RW/RO/Ingest) |

## Database

| Topic | Summary |
|---|---|
| [PostgreSQL Operations](database/postgresql-ops.md) | `pg_dumpall`, backup scripts with `install -m`, `crontab -u`, `pg_monitor` role, dump validation |
| [PostgreSQL CLI](database/postgresql-cli.md) | psql meta-commands, `pg_stat_activity`, `pg_terminate_backend`, `dropdb`, restore verification |
| [Zero-Trust PostgreSQL Access](database/postgres-zero-trust.md) | Four-layer access: Tailscale ACL + binding + `pg_hba` `hostssl` + role privileges |

## AI / LLM Inference

| Topic | Summary |
|---|---|
| [Ollama Deployment](ai/ollama-deployment.md) | Modelfile syntax, quantization tags, context-window trade-offs, OLLAMA_HOST, ROCm vs CUDA |

## Applications

| Topic | Summary |
|---|---|
| [Nextcloud Administration](applications/nextcloud-admin.md) | `occ` CLI, `files:scan`, `files_external:verify`, APCu+Redis cache split, Apache TLS via Tailscale certs |
| [Paperless-ngx](applications/paperless-ngx.md) | Pipeline (Gotenberg+Tika+Redis), CSRF origins, OCR languages, polling vs inotify on CIFS, USERMAP_UID/GID |
| [Vaultwarden](applications/vaultwarden.md) | Argon2id ADMIN_TOKEN, signups/invitations off, non-root container user, "no SQLite on CIFS" rule |
| [Audiobookshelf Library Structure](applications/audiobookshelf-library-structure.md) | `Author/Series/Book/` folder layout, prefix stripping, series detection regex, dry-run/execute pattern, privacy in public repos |

## Security

| Topic | Summary |
|---|---|
| [Least-Privilege Patterns](security/least-privilege-patterns.md) | SMB perms, credentials files, `.env` hygiene, service isolation, sudoers.d, secret generation, defense in depth |

## Operations

| Topic | Summary |
|---|---|
| [Runbook Methodology](operations/runbook-methodology.md) | Root-cause process, failure-modes table, layer-by-layer health checks, verification log, doku-first workflow, fail-forward visibility |
| [Git Branching Patterns](operations/git-branching.md) | Cherry-pick workflow, CI dependency trap, feature branch strategy |
| [Conventional Commits](operations/conventional-commits.md) | Commit message format with required scope, per-node and thematic scope conventions |
| [Repo Validation](operations/repo-validation.md) | Self-validating documentation repos, structural checks, sanitization rules, CI integration |
| [Backup Strategy](operations/backup-strategy.md) | 3-2-1 rule, threat coverage matrix, restic with append-only credentials, retention policies, restore verification |
| [Claude Code Hooks](operations/claude-code-hooks.md) | Hook events, stdin JSON, `additionalContext` injection, `continue: false` blocking, defense-in-depth with branch protection, hook fatigue |
| [Dotfiles Management](operations/dotfiles-management.md) | Template + render pattern, `--dry-run` flag, `pipx ensurepath` PATH fix, validate.sh, bootstrap/install split |

---

*Updated at the end of each working session.*
