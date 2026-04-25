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
| [apt & dpkg](linux/apt-dpkg.md) | `apt update` vs `apt upgrade`, dpkg audit and repair, cleaning the package cache |
| [systemd Basics](linux/systemd-basics.md) | Unit types, systemctl commands, journalctl filtering, and mount units |

## Ansible

| Topic | Summary |
|---|---|
| [Playbook Structure](ansible/playbook-structure.md) | Minimum required fields, plays vs tasks, YAML indentation rules |
| [Privilege Escalation](ansible/privilege-escalation.md) | `become`, `become_user`, and how to configure NOPASSWD sudo for Ansible |
| [Inventory Groups](ansible/inventory-groups.md) | How to structure inventory groups by function and type |
| [Serial Execution](ansible/serial-execution.md) | Why parallel upgrades are dangerous and how `serial` prevents resource spikes |

## Proxmox

| Topic | Summary |
|---|---|
| [Thin-Pool Recovery](proxmox/thin-pool-recovery.md) | How to diagnose and recover from a full LVM thin-pool on a Proxmox host |
| [LXC & VM Management](proxmox/lxc-vm-management.md) | `pct` and `qm` commands, LXC vs VM differences, UID mapping, noVNC access |

## Networking

| Topic | Summary |
|---|---|
| [Tailscale](networking/tailscale.md) | Tailscale IPs, ACL tags, `tailscale serve`, and detecting deauthentication |

## Docker

| Topic | Summary |
|---|---|
| [Compose Patterns](docker/compose-patterns.md) | Named volumes, restart policies, `network_mode: host`, logging, GPU passthrough |

## Monitoring

| Topic | Summary |
|---|---|
| [Prometheus Stack](monitoring/prometheus-stack.md) | Scrape jobs, node_exporter, textfile collector pattern, alert rules, Alertmanager routing |

## Storage

| Topic | Summary |
|---|---|
| [SnapRAID + MergerFS](storage/snapraid-mergerfs.md) | Homelab storage stack architecture, sync/scrub discipline, content files, stable disk references |

## Database

| Topic | Summary |
|---|---|
| [PostgreSQL Operations](database/postgresql-ops.md) | `pg_dumpall`, `pg_dump`, `pg_isready`, `pg_hba.conf` auth methods, backup retention |

## Security

| Topic | Summary |
|---|---|
| [Least-Privilege Patterns](security/least-privilege-patterns.md) | SMB share permissions, credentials files, `.env` hygiene, service isolation, sudoers.d |

## Operations

| Topic | Summary |
|---|---|
| [Runbook Methodology](operations/runbook-methodology.md) | Root-cause process, failure domain thinking, KE pattern, boot order dependency modeling |

---

*Updated at the end of each working session.*
