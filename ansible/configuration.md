# Ansible Configuration (`ansible.cfg`)

## What `ansible.cfg` controls

`ansible.cfg` is Ansible's main configuration file. It sets defaults that would
otherwise have to be supplied as command-line flags or environment variables on
every run.

Lookup order (first match wins):
1. `ANSIBLE_CONFIG` env var
2. `./ansible.cfg` (current directory)
3. `~/.ansible.cfg` (user home)
4. `/etc/ansible/ansible.cfg`

For a project-scoped repo, **always commit `./ansible.cfg`**. It pins behavior
across operators and CI runs. Letting Ansible fall back to `/etc/ansible/ansible.cfg`
makes runs depend on whoever's machine you're on.

## Minimal homelab `ansible.cfg`

```ini
[defaults]
inventory             = ./inventory/hosts.yml
remote_user           = root
host_key_checking     = False
retry_files_enabled   = False
stdout_callback       = yaml
forks                 = 10
gathering             = smart

[ssh_connection]
pipelining            = True
ssh_args              = -o ControlMaster=auto -o ControlPersist=60s
```

## Each setting explained

### `roles_path = ./roles`

Where Ansible looks for roles. Without this, Ansible searches `<playbook_dir>/roles/`,
`~/.ansible/roles`, and `/etc/ansible/roles` — but not `ansible/roles/` if your
playbooks live in a subdirectory.

Set this whenever your `roles/` directory is not a sibling of your playbooks:

```ini
roles_path = ./roles
```

Relative to the directory where `ansible.cfg` lives. Verify it's being found:
if Ansible reports `role 'X' was not found in <playbook_dir>/roles`, this setting
is missing or wrong.

### `inventory = ./inventory/hosts.yml`

Default inventory file. Without this, every `ansible-playbook` invocation needs
`-i path/to/inventory`. Relative path means it resolves relative to the directory
where `ansible.cfg` lives, not the CWD — which is what you want.

### `remote_user = root`

Default SSH user. Set to `root` for Proxmox-managed Debian LXCs (which boot with
root SSH access enabled by default). Per-host override in inventory:

```yaml
vm100:
  ansible_host: 100.x.y.z
  ansible_user: nicolas       # overrides the default
```

For production: this should be a dedicated `ansible` user with sudo, not `root`.
Homelab compromise: root is acceptable inside a Tailnet, since SSH-as-root is
already restricted by Tailscale ACL.

### `host_key_checking = False`

Disables SSH host key verification. **This is a trade-off**, not a default:

| Pro                                              | Con                                                |
|--------------------------------------------------|----------------------------------------------------|
| Re-imaged hosts don't break playbook runs        | Vulnerable to MITM if attacker is on the network   |
| New nodes work first-run without `ssh-keyscan`   | Real host substitution would go undetected         |

For a homelab over Tailscale: the Tailnet is end-to-end encrypted, MITM by an
external attacker requires breaking WireGuard. `host_key_checking = False` is
defensible.

For production crossing untrusted networks: **set this to True** and manage
known_hosts properly via a separate playbook.

### `retry_files_enabled = False`

Stops Ansible from creating `*.retry` files in the playbook directory after a
failed run. The retry files clutter git status and serve almost no purpose
(re-running with `--limit @retry_file` is rarely useful — by then the issue
has been fixed and you re-run the whole play).

### `stdout_callback = yaml`

Default output format is one-line-per-task and hard to read for multi-line
output (changed files, command stdout). YAML callback formats it readably:

```yaml
TASK [Install packages] *********************************************
ok: [vm100] => changed=false
  cache_update_time: 1714030200
  cache_updated: false
```

Alternatives: `default` (the original), `minimal`, `oneline`, `debug`.
For interactive use, `yaml` is the best balance of detail and readability.

### `forks = 10`

How many hosts to run tasks on in parallel. Default is 5 — too low for a
homelab with 10+ nodes (each play takes 2× as long).

For a real homelab: set to `len(inventory)` or slightly more. The cost is
mostly memory on the controller; 10 parallel SSH sessions to LXCs is trivial.

### `gathering = smart`

When to run `setup` (gather facts about the remote host).

| Value       | Behavior                                                      |
|-------------|---------------------------------------------------------------|
| `implicit`  | Run on every play (default). Slow.                           |
| `explicit`  | Only when explicitly requested. Fast but plays must declare. |
| `smart`     | Cached: gather once per host per session. Best default.      |

`smart` is almost universally correct. Only use `explicit` for performance-critical
plays where you've audited that no role uses facts.

### `pipelining = True`

In `[ssh_connection]`. Reduces SSH operations per task: instead of `scp` then
exec, Ansible streams the module to Python's stdin over SSH. ~30% faster.

Requires the remote `sudoers` to *not* have `requiretty`. Most Debian/Ubuntu
boxes don't have it; older RHEL did. Verify with `grep requiretty /etc/sudoers`
on a target.

### `ControlMaster=auto`, `ControlPersist=60s`

SSH-level connection multiplexing. Once Ansible opens an SSH connection to a
host, subsequent operations within `60s` reuse the same TCP+TLS session,
skipping the handshake. For a play with many tasks, this is significant.

`ControlMaster=auto` means "enable if not already enabled". `ControlPersist=60s`
keeps the master socket alive for 60 seconds after the last operation.

## Sanitized vs gitignored inventory

The inventory file often contains real hostnames or IPs. Two patterns:

**Pattern A — gitignore the real, commit a sanitized example:**

```
inventory/
  hosts.yml              # gitignored
  hosts.yml.example      # committed, with placeholders
```

`.gitignore`:
```
inventory/hosts.yml
```

Onboarding: copy the example, fill in real values.

**Pattern B — encrypt with ansible-vault:**

```bash
ansible-vault encrypt inventory/hosts.yml
```

The file is committed encrypted. Decrypted at runtime with `--ask-vault-pass`.

For a homelab, Pattern A is simpler and the sensitive data (Tailscale IPs)
isn't critical enough to warrant encryption. For production, Pattern B is
the right choice for any file containing real secrets.

## Verifying config is being read

```bash
ansible --version
```

This prints the loaded config file path. If it says `/etc/ansible/ansible.cfg`
instead of your project's `./ansible.cfg`, you're not in the right directory
or the file has a syntax error (silent fallback to system config).

```bash
ansible-config dump --only-changed
```

Shows every setting that differs from the built-in defaults. Useful sanity check
that your `ansible.cfg` is doing what you think.

## Related

- [Ansible Inventory Groups](inventory-groups.md)
- [Ansible Playbook Structure](playbook-structure.md)
- [SSH Keys](../linux/ssh-keys.md)
