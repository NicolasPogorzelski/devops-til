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

---

*Updated at the end of each working session.*
