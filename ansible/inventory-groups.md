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
          ansible_host: 10.0.0.1
        web02:
          ansible_host: 10.0.0.2
    databases:
      hosts:
        db01:
          ansible_host: 10.0.0.3
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

## Related

- [Playbook Structure](playbook-structure.md)
- [Serial Execution](serial-execution.md)
