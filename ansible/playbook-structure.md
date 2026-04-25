# Ansible Playbook Structure

## Minimum required fields

A playbook is a YAML file containing one or more **plays**. Each play needs:

| Field | Required | Purpose |
|---|---|---|
| `name` | Recommended | Label shown in output |
| `hosts` | Yes | Which nodes/groups this play targets |
| `tasks` | Yes | List of actions to execute |

```yaml
---
- name: my first play
  hosts: all
  tasks:
    - name: do something
      ansible.builtin.command:
        cmd: echo hello
```

## YAML indentation rules

YAML uses indentation as structure — not just style. Wrong indentation = wrong meaning.

- Each level: 2 spaces (no tabs)
- A list item starts with `- ` (dash + space)
- Everything belonging to a list item is indented 2 more spaces than the `-`

```yaml
tasks:           # key at play level
  - name: foo    # list item (2 spaces + dash)
    module:      # belongs to this task (4 spaces)
      param: val # belongs to module (6 spaces)
```

## Multiple plays in one file

A playbook can contain multiple plays. Plays run top to bottom.
Each play can target different hosts and have different settings.

```yaml
---
- name: play 1
  hosts: lxcs
  tasks:
    - ...

- name: play 2
  hosts: vms
  become: true
  tasks:
    - ...
```

## Limiting execution to specific hosts

```bash
ansible-playbook playbook.yml --limit lxc200
ansible-playbook playbook.yml --limit lxcs        # group
ansible-playbook playbook.yml --limit lxc200,lxc210
```

`--limit` restricts at runtime without changing the playbook.
`hosts: all` in the playbook + `--limit lxc200` = runs only on lxc200.

## Serial execution

By default, Ansible runs a play on all matching hosts in parallel.
`serial` limits how many hosts run at once:

```yaml
- name: upgrade apt
  hosts: all
  serial: 1       # one host at a time
  tasks:
    - ...
```

Use `serial: 1` for upgrades to prevent simultaneous load spikes on shared resources
(e.g. LVM thin-pool, network bandwidth).

## Related

- [Privilege Escalation](privilege-escalation.md)
- [Inventory Groups](inventory-groups.md)
- [Serial Execution](serial-execution.md)
