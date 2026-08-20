# devops-til

Things I learned while building and operating a homelab on the path to becoming a DevOps engineer.

Each entry is a short summary with a link to a detailed explanation. Organized by topic.

> Work in progress. Corrections and feedback welcome.

**[Glossary](glossary.md)** - the register of terms used across these notes and the homelab.
Every term is answered in three parts: what it is, where it lives in this setup, and why it
matters. Start there when an entry below uses a word you do not know.

---

## Linux Internals

| Topic | Summary |
|---|---|
| [LVM Thin Provisioning](linux/lvm-thin-provisioning.md) | How thin-pool storage works, why `df` lies inside containers, and how to reclaim space with fstrim |
| [Namespaces & nsenter](linux/namespaces-nsenter.md) | What Linux namespaces are, how LXC containers use them, and how to enter them from the host |
| [ELF Binaries & Corruption](linux/elf-binary-corruption.md) | What ELF format is, how to detect a corrupt binary, and how to reinstall it |
| [apt & dpkg](linux/apt-dpkg.md) | `apt update` vs `apt upgrade`, `dpkg --verify` with conffile filtering, dpkg audit and repair, Ansible `upgrade: dist` modes, cache hygiene |
| [systemd Basics](linux/systemd-basics.md) | Unit types, systemctl commands, journalctl filtering, persistent journald (`Storage=` auto trap), mount units, `Type=oneshot`, drop-in overrides; **when the running process does not match the unit file** - config states intent, only `ps` states fact; trace a stray daemon back with `systemctl status <pid>`, `show -p MainPID`, `cat` (unit + drop-ins), `list-unit-files`; a process outside the unit's `ControlGroup` was not started by it; `disable --now` leaves the file behind |
| [systemd Service Hardening](linux/systemd-service-hardening.md) | `Restart=on-failure`, `RestartPreventExitStatus`, `After=` vs `Wants=`, race-condition fixes, reactive vs proactive `ExecStartPre` readiness gates, the start-limit trap (`reset-failed`), fail-open vs fail-closed gates |
| [systemd Mount Units & the Network-Mount Boot-Race](linux/systemd-mount-units.md) | fstab->`.mount` unit escaping, `_netdev`/`nofail` (no retry!), why a CIFS share ends up `failed` after a boot-race, LXC bind-mount propagation needs a container restart, CIFS POSIX-mode is cosmetic |
| [Time Synchronization](linux/time-synchronization.md) | System clock vs RTC, NTP/chrony vs timesyncd, `timedatectl`/`chronyc`, why drift breaks SnapRAID & alert math, LXC inherits host clock vs VM needs its own |
| [Bash Scripting Patterns](linux/bash-scripting-patterns.md) | Strict mode, pre-flight checks, `command -v`, `install -m`, HEREDOC, sub-commands, `mktemp+trap`; **`$?` lies in a pipe -> `PIPESTATUS[0]`**; **capturing a non-zero exit under `set -e`** (`&& rc=0 \|\| rc=$?`) to inspect vs `\|\| true` to swallow |
| [SSH Keys](linux/ssh-keys.md) | Ed25519 keys, agent forwarding caveats, authorized_keys hygiene, break-glass fallback key, key rotation; **additive management never revokes** - `exclusive: true` is per invocation (a `loop` keeps only the last key), inline `join("\n")` yields a literal `\n`, an empty key list truncates the file |
| [Cron and Scheduling](linux/cron-and-scheduling.md) | crontab vs `/etc/cron.d/`, systemd timers, log conventions; **the decision rule** - "cron is fine for simple jobs" hides the premise that the machine is up at the scheduled time, and a failing cron job leaves no state to alert on; calendar vs monotonic timers (`Persistent=` is ignored on monotonic); `Persistent=true` does *not* fire on first start (stamp file, measured); template units (`unit@.service`, `%i`, `Unit=`); systemd escape processing in `ExecStart=`; retiring a hand-written crontab line with `sed -E '/pat/d'` (not `grep -v`, which exits 1 on empty output); **on a machine that sleeps through the scheduled hour, `Persistent=true` turns a calendar job into a boot-time job** - the time in the unit becomes decorative and the run lands in the boot window, where the network/VPN/mounts may not be ready; compare `list-timers` LAST against boot time to detect it |
| [Mount Existence vs Mount Identity](linux/mount-existence-vs-identity.md) | A recurring silent-failure class: when a network mount fails, consumers see the empty mountpoint directory underneath it. `[ -d ]`, `mountpoint -q` and Proxmox `mkdir 0` all pass; only `findmnt -no FSTYPE` asserts identity. Plus: a failed precondition must `exit 1`, or the systemd unit never reaches `failed` and no alert can fire |
| [Disk Diagnostics](linux/disk-diagnostics.md) | `smartctl`, `dmesg`, identifying drive failures, SMART attribute thresholds; **who reported the error** - `hostbyte`/`driverbyte`/sense key, `DID_SOFT_ERROR` (transport) vs `Medium Error` (media), `cmd_age` = timeout; why `-H PASSED` is worthless as evidence and `Pending`>0 with `Reallocated`=0 is the *bad* case (spares are consumed on write, not read); which controller a disk is really on; comparing boots via `journalctl -k -b -N` |
| [Failing-Disk Data Rescue](linux/failing-disk-data-rescue.md) | Rescue before repair: read-only `ro,noload` mount, ownership-preserving `tar` stream (vs rsync), `socket ignored` vs real I/O errors, `ddrescue` for damaged metadata, sparse allocated-vs-live |
| [Network Tools](linux/network-tools.md) | `nc -zv`, `ss`, `findmnt`, Python socket fallback, layer-by-layer reachability |
| [Input-Device Reconnects](linux/input-device-reconnect.md) | Why a BT controller reuses its `eventX` path while `inputN`-derived nodes (LEDs) renumber; key identity on a stable id, detect reconnect by presence not path, re-assert device state after settle; D-Bus bisection + sysfs-authority debugging |
| [Atomic File Writes](linux/atomic-file-writes.md) | Crash-safe state files: temp in the same filesystem + `fsync` + `rename`/`os.replace`; why truncate-in-place silently loses data; Ansible/Terraform/etcd parallels |
| [DualSense Lightbar: LED Class vs. Raw HID](linux/dualsense-lightbar-hid.md) | Kernel LED class vs. raw HID output reports; the firmware "light out" latch (sysfs sticks, hardware dark); why a driver rebind doesn't clear it but a raw colour report does; DualSense report 0x31/CRC32 seed `0xA2` vs USB 0x02; the two-firmware setup-flag gotcha; Steam-Input coexistence; bisection debugging + validated privileged helper |

## Ansible

| Topic | Summary |
|---|---|
| [Playbook Structure](ansible/playbook-structure.md) | Minimum required fields, plays vs tasks, YAML indentation rules |
| [Task Control](ansible/task-control.md) | `register`, `changed_when`, `ansible.builtin.fail`, `when` with Jinja2 filters, `shell` vs `command`, `docker --format`/Jinja2 collision in ad-hoc commands; **`ansible.builtin.cron` cannot remove an entry it did not write** (it finds entries by its own `#Ansible:` marker) - adoption pattern for hand-deployed jobs; **making a role dry-runnable**: `check_mode: false` on read-only probes, `when: not ansible_check_mode` on `systemctl enable`; `assert` as a precondition that deploys first and fails with a diagnosis |
| [Privilege Escalation](ansible/privilege-escalation.md) | `become`, `become_user`, and how to configure NOPASSWD sudo for Ansible |
| [Inventory Groups](ansible/inventory-groups.md) | Group structure, per-host overrides, `host_vars`/`group_vars`, sanitized inventory pattern |
| [Serial Execution](ansible/serial-execution.md) | Why parallel upgrades are dangerous and how `serial` prevents resource spikes |
| [Ansible Configuration](ansible/configuration.md) | `ansible.cfg` settings explained: `host_key_checking`, pipelining, ControlMaster, fork count |
| [Roles](ansible/roles.md) | Why roles exist, directory structure, `defaults/` vs `vars/`, `files/` vs `templates/`, binary deployment pattern, handlers |
| [Jinja2 Templates](ansible/jinja2-templates.md) | Generating config files from inventory: `groups[]`, `hostvars[]`, for loops, if conditions, mixing static and dynamic sections, `template` module |
| [Ansible Vault](ansible/ansible-vault.md) | AES-256 secrets encryption in Ansible: why plaintext in Git is permanent, breach window concept, `group_vars` split pattern, key commands, vault password file |
| [SSH Hardening](ansible/ssh-hardening.md) | `lineinfile` module pattern, regexp workflow for sshd_config directives, `--check --diff` dry-run habit, handler reload vs restart, idempotency signals; **sshd_config.d first-match-wins** - a `50-cloud-init.conf` drop-in beat the hardened line (`changed=0` but unhardened); fix by sorting a `00-hardening.conf` *before* it, verify with `sshd -T` (effective config, not the line you wrote); verifying the *applied* change needs a non-multiplexed connection (`ControlMaster=no`, `ControlPath=none`) or you reuse a socket and never re-authenticate; check `authorized_keys` before `PermitRootLogin no` |
| [Docker Compose Updates](ansible/docker-compose-updates.md) | `docker_compose_v2` for fleet updates: `pull`/`recreate` idempotency, per-host `compose_projects` list + `loop`/`item`, group targeting vs safe no-op default scoping; **the sync gap** - a role that acts on remote state but never ships the repo compose file is a silent no-op (`:latest` ran for weeks despite a repo pin); `{dest, src}` list shape, promoting a loop scalar to a dict |
| [PostgreSQL Provisioning](ansible/postgresql-provisioning.md) | Declarative DB-tenant onboarding via `community.postgresql`: peer auth (`become_user: postgres`), module-per-step mapping, plus two transferable traps - `acl` needed for unprivileged become, and never co-locating a secret with the loop `item` (Ansible dumps it on failure) |
| [Walkthrough: Fleet Docker Updates & Postgres Provisioning](ansible/walkthrough-items-9-10.md) | Two roles end to end on the shared group->host_vars->role->playbook skeleton: the `become`/`docker.sock` root-cause story, `pull` vs `recreate`, the verification ladder, and Postgres' four access layers, peer auth, and Vault-backed tenant provisioning |
| [Ad-Hoc Commands](ansible/ad-hoc-commands.md) | `ansible <host> -m <module> -a "<args>"` syntax, `command` vs `shell`, `ping` (not ICMP), `--become` trap, and the live-state verification pattern (verify before trusting docs) |
| [Fleet Health Checks & hostvars](ansible/fleet-health-hostvars.md) | `hostvars` magic variable for cross-host data aggregation, multi-play reporting pattern, `service_facts`, `docker_host_info`, `find`+`file` cleanup loop, `copy` with Jinja2 content, role-vs-inline decision rule; **two silent-no-op bugs** - Docker play needs `become` (`ansible` user not in `docker` group), and a report play targeting the control node's inventory name matches zero hosts (control node is deliberately not in inventory -> use `hosts: localhost` + `connection: local`) |
| [GitHub Actions: CI/CD for Ansible](ansible/github-actions-ansible-lint.md) | Minimal `ansible-lint` pipeline on push + PR; why `cd ansible && ansible-lint .` (CWD-relative `ansible.cfg`); `requirements.yml` for collections; common lint rules + fixes; handler name matching gotcha; `pipefail` explained; **pinning the version** vs default-profile drift; the **profile ladder** (min->production) + `.ansible-lint` config; **vault in CI** (dummy password; syntax-check parses but never decrypts; internal-error masking); **role-name -> var-naming cascade** + waiver; `--fix` reformat scope + excluding the vault file; **a finding != a defect** - read the rule source (`_executable_options` allow-list; `is-failed` flagged, `reset-failed` not); **three suppression levels** (inline `# noqa: id` vs bare vs `skip_list`), pick the narrowest |
| [Control-Node Hygiene](ansible/control-node-hygiene.md) | Playbooks execute from the **working tree**, not from a commit - a control node on a feature branch or left mid-merge runs code matching no commit and reports success; `--ff-only`, the pre-run cleanliness grep, and why CI cannot substitute for it (it only sees committed markers); recovering a stuck merge without losing stashes (`rev-list --left-right` before touching anything, `cp -a` incl. `.git`, `merge --abort`) |

## Proxmox

| Topic | Summary |
|---|---|
| [Thin-Pool Recovery](proxmox/thin-pool-recovery.md) | How to diagnose and recover from a full LVM thin-pool on a Proxmox host |
| [LXC & VM Management](proxmox/lxc-vm-management.md) | `pct` and `qm`, LXC vs VM, mount points, boot order, `nesting=1`, `/dev/disk/by-id`, bind-mount propagation; **passthrough safety** - a disk both host-mounted and passed to a VM means two kernels on one ext4 and there is no cross-host locking; `ps -C kvm` vs `qm config`, correlating by filesystem UUID, safe `qm set --delete`, and `is_mountpoint 1` so a failed mount can't fill the host root |
| [Tailscale TUN in Unprivileged LXCs](proxmox/lxc-tailscale-tun.md) | CT210-pattern: `cgroup2.devices.allow` + `mount.entry` for kernel WireGuard, userspace-networking pitfall; **the same fault with an inverted symptom** - a stray second `tailscaled` unit means the bind *succeeds* while delivery still fails (`connection refused` from a RST, `serve` on 443 keeps working, so blackbox says healthy while the scrape is down); **a successful `bind()` does not prove reachability** - `ss` is local evidence only, test from the far end; check the process and `list-unit-files`, not `/etc/default/tailscaled` |
| [Hard Shutdown Recovery](proxmox/hard-shutdown-recovery.md) | LXC boot failures after forced power-off: SMB mount dependency (exit 19), SSH/Tailscale race condition, access hierarchy, recovery order |
| [Diagnosing a Frozen VM](proxmox/vm-freeze-diagnosis.md) | Guest hard-freeze while `qm status` still reads `running`: guest-health probes (guest-agent + ACPI timeout, blank serial console) vs hypervisor state, `qm stop/start` recovery, the abrupt-journal-stop freeze signature; **two timeline traps** - align guest-UTC vs host-local clocks before reasoning, and absence-of-data != absence-of-problem (`--list-boots`/`uptime`); detection != response, and why the in-guest NMI watchdog is unreliable under KVM |
| [LXC Bindmount: CIFS via Host](proxmox/lxc-bindmount-cifs.md) | CIFS mounts live on the Proxmox host and are bindmounted into LXCs via `mp` config; systemd automount behavior, stacked mount pitfall, Samba tooling (`pdbedit`, `testparm`) |

## Networking

| Topic | Summary |
|---|---|
| [Tailscale](networking/tailscale.md) | Tailscale IPs, MagicDNS, Tailscale-managed certs, app-layer security boundary, vendor-lock-in considerations |
| [Loopback + Tailscale Serve](networking/loopback-tailscale-serve.md) | The `127.0.0.1` + Serve binding pattern, alternatives evaluated, HTTPS/HTTP mismatch |
| [nftables alongside Tailscale](networking/nftables-with-tailscale.md) | Enforcing a boundary the service cannot: own table (never `nftables.service` - its stock config `flush ruleset`s Tailscale's chains), `table inet`, counters as audit trail, `RemainAfterExit` |
| [Tailscale ACL Design](networking/tailscale-acl-design.md) | Tier-based design, hosts aliases, access matrix, ACL changelog, pre-existing tunnel pitfall |
| [Tailscale Debugging](networking/tailscale-debugging.md) | How Tailscale's userspace packet filter works, `tailscale ping` bypasses ACL, duplicate node key problem, tcpdump as layer-separator, fix via daemon restart |
| [Tailscale Exit Nodes: the Stale Pin](networking/tailscale-exit-nodes.md) | `tailscale up` kills WAN while LAN survives: an exit node pinned by ID was decommissioned upstream, and the dangling reference still installs a default route in table 52 (rule prio 5270 outranks `main`). **A stored ID is a claim about the past - only `exit-node list` is evidence about the present**; why `grep -c <id>` over the journal counts pref echoes and answers the wrong question; `auto:any` instead of a pin; the `up` flag-preservation trap (its own suggestion is self-contradictory, and `--reset` clears `OperatorUser`); dead-man's-switch pattern for changes that can sever your own connection; `AutoUpdate` is structurally broken on ostree; "only on Wi-Fi" was a false correlate - prefs are per profile, not per interface |

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
| [Prometheus Stack](monitoring/prometheus-stack.md) | Scrape jobs, node_exporter, textfile collector pattern, alert rules, node-up != service-up blind spot (blackbox_exporter), `up` over a window to bound an incident, Alertmanager routing |
| [Prometheus Configuration](monitoring/prometheus-config.md) | `scrape_configs`, rule_files, alertmanagers static_configs, job-naming, retention/lifecycle flags |
| [systemd Unit Alerting](monitoring/systemd-unit-alerting.md) | The `failed` unit no alert category covered (20k failures, green dashboard); `--collector.systemd` + the stock exclude that drops `.mount` units; why the first alert after enabling it is proof, not a regression; test the negative case |
| [PromQL & Alert Rules](monitoring/promql-patterns.md) | `for:` debouncing, severity labels, fstype filters, aggregations, annotation templating, recording rules |
| [Alertmanager Routing](monitoring/alertmanager-routing.md) | Routes, group_by/wait/interval, repeat_interval, inhibit_rules, silences, Discord webhooks |

## Storage

| Topic | Summary |
|---|---|
| [SnapRAID + MergerFS](storage/snapraid-mergerfs.md) | Storage stack architecture, sync/scrub discipline, `noatime`, excludes, multiple content files, `category.create=mfs`, hash-mismatch recovery, live disk expansion via xattr, empty-disk sync (XOR neutral), status output interpretation |
| [CIFS via systemd Automount](storage/cifs-automount.md) | Reboot-safe network mounts, `x-systemd.automount` options, boot-trigger oneshot, app-state vs uploads split, Tailscale boot-race on desktops (`_netdev` waits for network-online, not the tailscale route) |
| [CIFS `hard` vs `soft`](storage/cifs-hard-vs-soft.md) | Why an unreachable SMB server yields an unkillable **D-state** process instead of an error, and how autofs + a polling daemon (`gvfsd-recent`) turn one dead share into a desktop-wide freeze; counting the real trigger sources from the journal (`Got automount request` -> the blamed app was 18%, the file-manager recent-files daemon 70%); disarm-before-unmount recovery order (`.automount` stop -> `umount -f -l`); `soft` + `mount-timeout` + `idle-timeout` and **the gap `soft` does not close** (it governs established mounts, not the initial connect) |
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
| [Least-Privilege Patterns](security/least-privilege-patterns.md) | SMB perms, credentials files, `.env` hygiene, service isolation, sudoers.d, NOPASSWD helper hardening (the binary is the boundary), secret generation, defense in depth |

## Operations

| Topic | Summary |
|---|---|
| [Runbook Methodology](operations/runbook-methodology.md) | Root-cause process, failure-modes table, layer-by-layer health checks, verification log, doku-first workflow, fail-forward visibility |
| [Git Branching Patterns](operations/git-branching.md) | Cherry-pick workflow, CI dependency trap, feature branch strategy, `-d` vs `-D`, filter-repo replacement side effects, `filter-branch --msg-filter`, cherry-pick conflict resolution; merge-conflict resolution workflow; **rename + modify merges** (rename detection replays edits onto the new path - silently, verify it); **merge vs rebase** decided from file overlap (`comm -12`); **ahead/behind in one shot** (`rev-list --left-right --count A...B`, three-dot vs two-dot); **`--ff-only`** for a mirror-only node (refusal is the feature); **`fetch --prune`** after a remote branch is deleted; **sanitizing an already-public history** - a forward sanitization commit re-leaks in its own diff, `--replace-text` misses messages (`--replace-message`) and filenames (`--path-rename`), and a rewrite **cannot touch GitHub PR metadata** (titles/branch names/diff tabs survive force-push - Support or delete only; edit titles via REST); **`refs/pull/*/head` keeps force-pushed commits *reachable*** (fetch them all with `+refs/pull/*/head:refs/remotes/origin/pr/*` - a force-push frees nothing while a PR ref holds the commit; check `for-each-ref --contains` and `merge-base --is-ancestor <sha> main` to see whether deleting PRs is even sufficient); **renaming is not removing** - verify a sanitizing rewrite by grepping file *content* across all refs, not commit subjects; keep a gitignored legend + a validate guard against re-introduction; ship-then-soak (merge a verified fix now, refactor later on its own tests-first branch); **retiring the pre-rewrite clone** - an empty `git merge-base` (prints nothing, no exit code) is the unrelated-histories diagnostic that `ahead/behind` hides; after fetching, one clone holds *both* lineages, so `cat-file -e` proves nothing (`--is-ancestor` per strand does, and `branch -r --contains` only searches *fetched* tracking refs); `diff --diff-filter=D --name-only old new` lists whole files that exist only in the old lineage; salvage by content, never push the old lineage back as a tag - rotation closes the exploit window, it does not license re-publishing |
| [Conventional Commits](operations/conventional-commits.md) | Commit message format with required scope, per-node and thematic scope conventions |
| [Repo Validation](operations/repo-validation.md) | Self-validating documentation repos, structural checks, sanitization rules, CI integration; **a local check that shells out to an external linter can be silently inert** - guard on `command -v`, print `SKIP` loudly, pin to CI's version, scope to the diff, test the FAIL path deliberately |
| [.gitignore Patterns](operations/gitignore-patterns.md) | **`dir/` excludes the directory, `dir/*` excludes its contents** - only the second leaves negations working, because a re-include is impossible once the parent is excluded; last matching pattern wins, so `!` must come after; default-deny (`dir/*` + explicit `!`) for tool-written directories fails *closed* instead of publishing state you never saw; `git check-ignore -v` answers "which rule matched" (silence = no rule, exit 1); `?? dir/` is a **collapsed** listing, not proof the rule is broken (`-uall`); rules never apply to already-tracked files (`git ls-files`, `git rm --cached`) |
| [CI Quality Gates](operations/ci-quality-gates.md) | Why a green pipeline can be an untested one (tests self-skip on missing deps), fixing it, the `setup-python` vs `apt` interpreter trap |
| [Documentation-vs-Reality Audits](operations/doc-reality-audit.md) | Treat every documented claim as a hypothesis with a live-state verification command; reconciliation *direction* is a decision (fix doc vs fix reality vs record intent); drift classes (pins, boot order, "managed by X" claims, ACL, naming); "green and correct-looking" as the failure mode; public-repo hygiene (facts not exploit detail) |
| [Backup Strategy](operations/backup-strategy.md) | 3-2-1 rule, threat coverage matrix, restic with append-only credentials, retention policies, restore verification |
| [Claude Code Hooks](operations/claude-code-hooks.md) | Hook events, stdin JSON, `additionalContext` vs `systemMessage`, `if` conditional field, SessionStart context injection, dual-Stop pattern, defense-in-depth with branch protection, hook fatigue |
| [Git Commit Hooks](operations/git-commit-hooks.md) | What git hooks are, why `.git/hooks/` is not committed, symlink pattern for versioned hooks, `commit-msg` validation script, local hooks vs CI enforcement, pre-commit/husky overview |
| [Dotfiles Management](operations/dotfiles-management.md) | Template + render pattern, `--dry-run` flag, `pipx ensurepath` PATH fix, validate.sh, bootstrap/install split |

---

*Updated at the end of each working session.*
