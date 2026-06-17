# Ansible Ad-Hoc Commands

## What they are and when to use them

Ad-hoc commands run a single Ansible module against one or more hosts — no playbook
file needed. They're the right tool when you want to **verify live state** before
writing a playbook, make a one-off change across the fleet, or debug why a playbook
is behaving unexpectedly.

```
ansible <host-pattern>  -m <module>  -a "<arguments>"  [options]
```

| Component | Meaning |
|---|---|
| `<host-pattern>` | Inventory host or group: `vm102`, `all`, `lxcs`, `vm102,lxc200` |
| `-m <module>` | Ansible module to run (default: `command`) |
| `-a "<arguments>"` | Arguments passed to the module as a key=value string |
| `[options]` | `-i`, `--become`, `-u`, `--check`, etc. |

## Core options

| Flag | Purpose |
|---|---|
| `--become` / `-b` | Escalate to root via sudo (equivalent to `become: true` in a playbook) |
| `-u <user>` | Connect as this user (overrides inventory `ansible_user`) |
| `-i <inventory>` | Specify inventory file (uses `ansible.cfg` default if omitted) |
| `--check` | Dry-run: show what would change, don't change anything |
| `-v` / `-vvv` | Verbose output; `-vvv` includes connection details |

## Common modules for live verification

### `command` — safe subprocess execution

```bash
# Read a file on a remote node
ansible vm102 -m command -a "cat /etc/cron.d/snapraid"

# Check a service status
ansible lxc200 -m command -a "systemctl status prometheus"

# Check a process
ansible vm100 -m command -a "docker ps --format '{{.Names}} {{.Status}}'"
```

`command` does not invoke a shell — no pipes, no redirects, no variable expansion.
Use it by default because it's safer and easier to predict.

### `shell` — when you need shell features

```bash
# Pipe output
ansible vm102 -m shell -a "df -h | grep /mnt/mergerfs"

# Variable expansion
ansible lxc260 -m shell -a "ls -la /var/lib/postgresql/"
```

`shell` runs through `/bin/sh`. Needed for pipes, globbing, redirects — not for plain commands.

### `ping` — connectivity check (not ICMP)

```bash
ansible all -m ping
# Returns pong on success, verifies SSH + Python + user mapping
```

`ansible.builtin.ping` verifies the full Ansible connection stack — SSH auth, Python
interpreter reachable, module execution works. It is NOT an ICMP ping.

### `copy` — one-off file push

```bash
ansible proxmox -m copy -a "src=/tmp/test.conf dest=/tmp/test.conf owner=root mode=0644" --become
```

Same semantics as the `copy` module in a playbook. Idempotent — no change if
content matches.

## Live-state verification pattern

The most important use: **verify the live system before updating docs or playbooks**.
Docs can drift from reality. If you assume a cron schedule is what the docs say and
edit accordingly, you may overwrite a correct live config with a wrong one.

```bash
# Verify before trusting docs
ansible vm102 -m command -a "cat /etc/cron.d/snapraid"

# Then compare against what the doc says, then decide what to update
```

The flow:

1. Read the doc to form a hypothesis ("snapraid sync runs at 02:00")
2. Run ad-hoc command to verify live state
3. If they differ, find out which is correct (check script comments, changelog)
4. Update whichever is wrong — usually the doc

This pattern catches the failure mode where a doc was written once and never
updated when the live config changed.

## Ad-hoc vs playbook: when to choose which

| Scenario | Use |
|---|---|
| Verify what a remote file contains | Ad-hoc (`command`) |
| Check if a service is running fleet-wide | Ad-hoc (`ping` or `command`) |
| One-time copy of a file | Ad-hoc (`copy`) |
| Repeatable installation or config | Playbook + role |
| Something you'll run again next month | Playbook |
| Anything that touches secrets | Playbook (ad-hoc args appear in logs) |

## The `become` trap

Without `--become`, ad-hoc commands run as the `ansible_user` (usually a non-root
user). Reading `/etc/cron.d/` usually works; writing to `/etc/` or reading sensitive
files like `/etc/shadow` does not.

```bash
# Wrong — no permission to write
ansible proxmox -m copy -a "src=homelab-setwake.sh dest=/usr/local/sbin/homelab-setwake.sh mode=0755"

# Correct
ansible proxmox -m copy -a "src=homelab-setwake.sh dest=/usr/local/sbin/homelab-setwake.sh mode=0755" --become
```

When a module silently produces no output or an unexpected permission error, add
`--become` first before investigating further.

## Output format

Ad-hoc output per host:

```
vm102 | SUCCESS | rc=0 >>
0 23 * * *  /usr/local/sbin/snapraid-maintenance.sh sync
0 20 1 * *  /usr/local/sbin/snapraid-maintenance.sh scrub
```

| Field | Meaning |
|---|---|
| `SUCCESS` / `FAILED` | Module exit status |
| `rc=0` | Return code of the executed command |
| `>>` | What follows is stdout |

`FAILED` with `rc=1` usually means the command itself failed. `UNREACHABLE` means
SSH failed before the module ran.

## Related

- [Playbook Structure](playbook-structure.md)
- [Privilege Escalation](privilege-escalation.md)
- [Inventory Groups](inventory-groups.md)
