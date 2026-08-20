# Ansible Inventory Groups

## What groups are

Groups let you target multiple hosts at once without listing them individually.
A host can belong to multiple groups.

```yaml
# hosts.yml
all:
  children:
    webservers:
      hosts:
        web01:
          ansible_host: 192.0.2.1
        web02:
          ansible_host: 192.0.2.2
    databases:
      hosts:
        db01:
          ansible_host: 192.0.2.3
```

## Two approaches to grouping

**By function** (what the node does):

```yaml
media:       # Jellyfin, Audiobookshelf
services:    # Nextcloud, Paperless
monitoring:  # Prometheus, Grafana
```

**By type** (what kind of node it is):

```yaml
lxcs:   # all LXC containers
vms:    # all virtual machines
```

Both can coexist. A node can be in `media` AND `lxcs` at the same time.

## Why type groups matter for Ansible

LXC containers and VMs often require different handling:
- LXCs may connect as `root` directly; VMs may require `become: true`
- fstrim works differently in LXCs vs VMs
- Different Python interpreter paths

Having `lxcs` and `vms` groups lets you write plays targeting each type explicitly:

```yaml
- name: upgrade LXCs
  hosts: lxcs
  tasks: ...

- name: upgrade VMs
  hosts: vms
  become: true
  tasks: ...
```

## Useful group patterns in playbooks

```yaml
hosts: all            # every node in inventory
hosts: lxcs           # only nodes in the lxcs group
hosts: lxcs,vms       # union of both groups
hosts: all,!vms       # all nodes except vms group
hosts: lxc200         # single specific node
```

## Listing group members

```bash
ansible lxcs --list-hosts
ansible vms --list-hosts
ansible all --list-hosts
```

## Per-host variable overrides

Variables defined on a host override group-level and inventory-level defaults:

```yaml
all:
  vars:
    ansible_user: root              # default for everyone
  children:
    workstations:
      vars:
        ansible_user: <username>    # group override
      hosts:
        lxc250:
          ansible_host: 100.x.y.z
        laptop:
          ansible_host: 100.a.b.c
          ansible_user: admin       # host-specific override (most-specific wins)
```

Resolution order (highest priority first):

1. Host-level `vars` in inventory
2. Host-specific YAML files in `host_vars/<hostname>.yml`
3. Group-level `vars`
4. Group-specific YAML files in `group_vars/<groupname>.yml`
5. Inventory-wide `all` vars

**Mental model - collect-and-rank, not fallback-search.** Ansible does *not*
look in one place, find it empty, then search the next. It loads *all* sources
up front and applies a fixed precedence ranking when the same variable name is
defined in more than one place: more-specific wins (host > group > all). So a
`group_vars/all` default of `[]` and a real `host_vars/<node>.yml` list coexist;
the host_vars value simply *overrides* the default on that node. On a node with
no host_vars entry, only the `all` default applies. The full (notorious) 22-level
table: <https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html#understanding-variable-precedence>

### Safe no-op defaults (`[]`)

Because referencing an *undefined* variable is a **fatal error**
(`'foo' is undefined` aborts the play on that host), a reusable role or a
fleet-wide playbook should define a safe default for any list it loops over:

```yaml
# roles/<role>/defaults/main.yml   (lowest precedence - overridden by anything)
compose_projects: []
```

An empty list makes `loop: "{{ compose_projects }}"` run **0 iterations** -
harmlessly skipped - instead of crashing on hosts that never set the variable.
This is exactly the `breakglass_pubkeys: []` pattern in
`roles/breakglass/defaults/main.yml`.

This is distinct from, and complementary to, **group targeting** (`hosts: docker`):
the group decides *who* the play touches (intent, visible in the inventory), the
empty default decides *what happens if a var is missing* (robustness). The default
belongs in `defaults/main.yml` rather than `group_vars/all` so the role stays
self-contained and can't crash when reused in another project that lacks that
group_var. See [Docker Compose Updates](docker-compose-updates.md) for a worked
example.

Common per-host overrides:

| Variable                   | When to override                                                  |
|----------------------------|-------------------------------------------------------------------|
| `ansible_user`             | A specific node has a different login user                        |
| `ansible_host`             | Decoupling inventory name from real hostname/IP                   |
| `ansible_python_interpreter` | A node ships only `python3` and not `python`, etc.              |
| `ansible_become_method`    | `sudo` (default) vs `su` for nodes without sudo                   |

The `ansible_host` decoupling is useful for renaming: keep the inventory key
stable (`lxc230`), but point it at a new IP if the host moves.

## `host_vars/` and `group_vars/` directories

For variables longer than a couple of lines, split them into directory files:

```
inventory/
  hosts.yml                  # the inventory itself
  host_vars/
    lxc230.yml               # vars only for lxc230
  group_vars/
    all.yml                  # defaults for everyone
    lxcs.yml                 # for the lxcs group
    storage.yml              # for the storage group
```

Ansible automatically loads these files. The naming convention is fixed:
the file basename must match the host or group name exactly.

This is also where vault-encrypted variables live - `group_vars/all/vault.yml`
(encrypted) alongside `group_vars/all/main.yml` (plain) lets you split
secrets from non-secrets cleanly.

## Sanitized vs gitignored inventory pattern

Real inventories contain real IPs (or FQDNs). For a public-facing repo:

- `inventory/hosts.yml` - gitignored, contains real values
- `inventory/hosts.yml.example` - committed, has placeholders

`.gitignore`:
```
inventory/hosts.yml
inventory/host_vars/
```

Onboarding workflow: clone the repo, copy `hosts.yml.example` to `hosts.yml`,
fill in real values. The example file demonstrates structure without leaking
real network topology.

For a private repo where leaking the inventory is acceptable: skip the split,
commit the real file directly. The choice depends on whether the repo is
public-readable.

## Related

- [Playbook Structure](playbook-structure.md)
- [Serial Execution](serial-execution.md)
- [Ansible Configuration](configuration.md)
