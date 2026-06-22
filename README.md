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
| [systemd Basics](linux/systemd-basics.md) | Unit types, systemctl commands, journalctl filtering, persistent journald (`Storage=` auto trap), mount units, `Type=oneshot`, drop-in overrides |
| [systemd Service Hardening](linux/systemd-service-hardening.md) | `Restart=on-failure`, `RestartPreventExitStatus`, `After=` vs `Wants=`, race-condition fixes, reactive vs proactive `ExecStartPre` readiness gates |
| [systemd Mount Units & the Network-Mount Boot-Race](linux/systemd-mount-units.md) | fstab→`.mount` unit escaping, `_netdev`/`nofail` (no retry!), why a CIFS share ends up `failed` after a boot-race, LXC bind-mount propagation needs a container restart, CIFS POSIX-mode is cosmetic |
| [Time Synchronization](linux/time-synchronization.md) | System clock vs RTC, NTP/chrony vs timesyncd, `timedatectl`/`chronyc`, why drift breaks SnapRAID & alert math, LXC inherits host clock vs VM needs its own |
| [Bash Scripting Patterns](linux/bash-scripting-patterns.md) | Strict mode, pre-flight checks, `command -v`, `install -m`, HEREDOC, sub-commands, `mktemp+trap` |
| [SSH Keys](linux/ssh-keys.md) | Ed25519 keys, agent forwarding caveats, authorized_keys hygiene, break-glass fallback key, key rotation |
| [Cron and Scheduling](linux/cron-and-scheduling.md) | crontab vs `/etc/cron.d/`, systemd timers, when to choose which, log conventions |
| [Disk Diagnostics](linux/disk-diagnostics.md) | `smartctl`, `dmesg`, identifying drive failures, SMART attribute thresholds |
| [Network Tools](linux/network-tools.md) | `nc -zv`, `ss`, `findmnt`, Python socket fallback, layer-by-layer reachability |

## Ansible

| Topic | Summary |
|---|---|
| [Playbook Structure](ansible/playbook-structure.md) | Minimum required fields, plays vs tasks, YAML indentation rules |
| [Task Control](ansible/task-control.md) | `register`, `changed_when`, `ansible.builtin.fail`, `when` with Jinja2 filters, `shell` vs `command`, `docker --format`/Jinja2 collision in ad-hoc commands |
| [Privilege Escalation](ansible/privilege-escalation.md) | `become`, `become_user`, and how to configure NOPASSWD sudo for Ansible |
| [Inventory Groups](ansible/inventory-groups.md) | Group structure, per-host overrides, `host_vars`/`group_vars`, sanitized inventory pattern |
| [Serial Execution](ansible/serial-execution.md) | Why parallel upgrades are dangerous and how `serial` prevents resource spikes |
| [Ansible Configuration](ansible/configuration.md) | `ansible.cfg` settings explained: `host_key_checking`, pipelining, ControlMaster, fork count |
| [Roles](ansible/roles.md) | Why roles exist, directory structure, `defaults/` vs `vars/`, `files/` vs `templates/`, binary deployment pattern, handlers |
| [Jinja2 Templates](ansible/jinja2-templates.md) | Generating config files from inventory: `groups[]`, `hostvars[]`, for loops, if conditions, mixing static and dynamic sections, `template` module |
| [Ansible Vault](ansible/ansible-vault.md) | AES-256 secrets encryption in Ansible: why plaintext in Git is permanent, breach window concept, `group_vars` split pattern, key commands, vault password file |
| [SSH Hardening](ansible/ssh-hardening.md) | `lineinfile` module pattern, regexp workflow for sshd_config directives, `--check --diff` dry-run habit, handler reload vs restart, idempotency signals |
| [Docker Compose Updates](ansible/docker-compose-updates.md) | `docker_compose_v2` for fleet updates: `pull`/`recreate` idempotency, per-host `compose_projects` list + `loop`/`item`, group targeting vs safe no-op default scoping |
| [PostgreSQL Provisioning](ansible/postgresql-provisioning.md) | Declarative DB-tenant onboarding via `community.postgresql`: peer auth (`become_user: postgres`), module-per-step mapping, plus two transferable traps — `acl` needed for unprivileged become, and never co-locating a secret with the loop `item` (Ansible dumps it on failure) |
| [Walkthrough: Fleet Docker Updates & Postgres Provisioning](ansible/walkthrough-items-9-10.md) | Two roles end to end on the shared group→host_vars→role→playbook skeleton: the `become`/`docker.sock` root-cause story, `pull` vs `recreate`, the verification ladder, and Postgres' four access layers, peer auth, and Vault-backed tenant provisioning |
| [Ad-Hoc Commands](ansible/ad-hoc-commands.md) | `ansible <host> -m <module> -a "<args>"` syntax, `command` vs `shell`, `ping` (not ICMP), `--become` trap, and the live-state verification pattern (verify before trusting docs) |
| [Fleet Health Checks & hostvars](ansible/fleet-health-hostvars.md) | `hostvars` magic variable for cross-host data aggregation, multi-play reporting pattern, `service_facts`, `docker_host_info`, `find`+`file` cleanup loop, `copy` with Jinja2 content, role-vs-inline decision rule |
| [GitHub Actions: CI/CD for Ansible](ansible/github-actions-ansible-lint.md) | Minimal `ansible-lint` pipeline on push + PR; why `cd ansible && ansible-lint .` (CWD-relative `ansible.cfg`); `requirements.yml` for collections; common lint rules + fixes; handler name matching gotcha; `pipefail` explained |

## Proxmox

| Topic | Summary |
|---|---|
| [Thin-Pool Recovery](proxmox/thin-pool-recovery.md) | How to diagnose and recover from a full LVM thin-pool on a Proxmox host |
| [LXC & VM Management](proxmox/lxc-vm-management.md) | `pct` and `qm`, LXC vs VM, mount points, boot order, `nesting=1`, `/dev/disk/by-id`, bind-mount propagation |
| [Tailscale TUN in Unprivileged LXCs](proxmox/lxc-tailscale-tun.md) | CT210-pattern: `cgroup2.devices.allow` + `mount.entry` for kernel WireGuard, userspace-networking pitfall |
| [Hard Shutdown Recovery](proxmox/hard-shutdown-recovery.md) | LXC boot failures after forced power-off: SMB mount dependency (exit 19), SSH/Tailscale race condition, access hierarchy, recovery order |
| [LXC Bindmount: CIFS via Host](proxmox/lxc-bindmount-cifs.md) | CIFS mounts live on the Proxmox host and are bindmounted into LXCs via `mp` config; systemd automount behavior, stacked mount pitfall, Samba tooling (`pdbedit`, `testparm`) |

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
| [Compose Patterns](docker/compose-patterns.md) | Restart policies, `network_mode: host`, bridge service-name DNS vs `localhost` trap, logging, `depends_on` w/ healthcheck, `env_file` vs environment, PUID/PGID, named-volume mix |
| [Daemon Recovery](docker/daemon-recovery.md) | Docker vs containerd process model, stale task state after ungraceful crash, `docker rm -f` + `compose up` recovery |
| [Data Root Migration](docker/data-root-migration.md) | Moving containerd + Docker data root off the root disk to Aux storage: `daemon.json`, `config.toml`, `rsync -aH`, boot-time dependency, fstrim |
| [Bind-Mount Pitfalls](docker/bind-mount-pitfalls.md) | Silent directory creation for missing files, host-networking DNS loss, UID alignment in unprivileged LXCs |
| [GPU Passthrough](docker/gpu-passthrough.md) | NVIDIA Container Toolkit, `pid: host`, `deploy.resources.reservations.devices`, capability scoping |

## Monitoring

| Topic | Summary |
|---|---|
| [Prometheus Stack](monitoring/prometheus-stack.md) | Scrape jobs, node_exporter, textfile collector pattern, alert rules, node-up ≠ service-up blind spot (blackbox_exporter), `up` over a window to bound an incident, Alertmanager routing |
| [Prometheus Configuration](monitoring/prometheus-config.md) | `scrape_configs`, rule_files, alertmanagers static_configs, job-naming, retention/lifecycle flags |
| [PromQL & Alert Rules](monitoring/promql-patterns.md) | `for:` debouncing, severity labels, fstype filters, aggregations, annotation templating, recording rules |
| [Alertmanager Routing](monitoring/alertmanager-routing.md) | Routes, group_by/wait/interval, repeat_interval, inhibit_rules, silences, Discord webhooks |

## Storage

| Topic | Summary |
|---|---|
| [SnapRAID + MergerFS](storage/snapraid-mergerfs.md) | Storage stack architecture, sync/scrub discipline, `noatime`, excludes, multiple content files, `category.create=mfs`, hash-mismatch recovery, live disk expansion via xattr, empty-disk sync (XOR neutral), status output interpretation |
| [CIFS via systemd Automount](storage/cifs-automount.md) | Reboot-safe network mounts, `x-systemd.automount` options, boot-trigger oneshot, app-state vs uploads split |
| [SQLite on CIFS Locking](storage/sqlite-on-cifs-locking.md) | Why `database is locked` over CIFS (byte-range locks not honored), CIFS-vs-local control test, `nobrl` vs the local-copy + atomic-swap workaround, and delete-the-source-last (durability ordering) for ingest-then-delete jobs |
| [Samba Server Config](storage/samba-server-config.md) | `smb.conf` structure, SMB3-only, mandatory signing, bind interfaces, share types (RW/RO/Ingest) |
| [Samba Access Control & SMB Clients](storage/samba-access-control.md) | SMB 3.1.1 vs mandatory signing (two gates), `hosts allow` default-deny (app-layer, not firewall), discovery (nmbd) vs connection (smbd), diagnosing with `smbstatus`/`ss`/`testparm`/`%m.log`/`smbcontrol debug`, app vs OS SMB client (Android SAF `content://` vs real path), same-host bridge vs Tailscale |

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
| [Local LLM Coding Fallback (aider + Ollama)](ai/local-llm-coding-fallback.md) | Self-hosted Claude Code fallback: native Anthropic API vs aider, the KV-cache `q8_0` lever, "optimal = largest fully-resident context", `size` vs `size_vram` spill check, aider config |
| [Multi-Agent Workflows](ai/multi-agent-workflows.md) | Spawning subagents in Claude Code, CI/CD parallel-stage analogy, when it helps vs. when it defeats active learning, unlock conditions (Terraform/k8s arc), and the meta-test: can you tell if the output is wrong? |

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
| [Git Branching Patterns](operations/git-branching.md) | Cherry-pick workflow, CI dependency trap, feature branch strategy, `-d` vs `-D`, filter-repo replacement side effects, `filter-branch --msg-filter`, cherry-pick conflict resolution |
| [Conventional Commits](operations/conventional-commits.md) | Commit message format with required scope, per-node and thematic scope conventions |
| [Repo Validation](operations/repo-validation.md) | Self-validating documentation repos, structural checks, sanitization rules, CI integration |
| [Backup Strategy](operations/backup-strategy.md) | 3-2-1 rule, threat coverage matrix, restic with append-only credentials, retention policies, restore verification |
| [Claude Code Hooks](operations/claude-code-hooks.md) | Hook events, stdin JSON, `additionalContext` vs `systemMessage`, `if` conditional field, SessionStart context injection, dual-Stop pattern, defense-in-depth with branch protection, hook fatigue |
| [Git Commit Hooks](operations/git-commit-hooks.md) | What git hooks are, why `.git/hooks/` is not committed, symlink pattern for versioned hooks, `commit-msg` validation script, local hooks vs CI enforcement, pre-commit/husky overview |
| [Dotfiles Management](operations/dotfiles-management.md) | Template + render pattern, `--dry-run` flag, `pipx ensurepath` PATH fix, validate.sh, bootstrap/install split |

---

*Updated at the end of each working session.*
