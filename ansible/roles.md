# Ansible Roles

## Why roles exist

A playbook with tasks inline works fine for one-off operations. Roles exist for
tasks you want to **reuse** across multiple playbooks or apply to new nodes later
without duplicating YAML.

A role is a self-contained package: tasks, variables, templates, and handlers
bundled under a single name. You invoke the role by name instead of copying tasks.

```yaml
# Without role — tasks inline, not reusable
- name: install node_exporter
  hosts: all
  tasks:
    - name: download binary
      ...

# With role — reusable, invoked by name
- name: install node_exporter
  hosts: all
  roles:
    - node_exporter
```

## Directory structure

Ansible expects roles under `roles/<name>/` relative to the playbook or `ansible.cfg`.

```
roles/node_exporter/
├── tasks/
│   └── main.yml       # entry point — Ansible loads this automatically
├── vars/
│   └── main.yml       # variables (version, port, binary path, etc.)
├── templates/
│   └── *.j2           # Jinja2 templates (e.g. systemd unit files)
└── handlers/
    └── main.yml       # triggered actions (e.g. restart service on config change)
```

Only `tasks/main.yml` is mandatory. The others are loaded automatically when present.

## When to use a role vs a playbook task

| Scenario | Use |
|---|---|
| One-time operation (bootstrap, migration) | Inline tasks in playbook |
| Repeatable installation across nodes | Role |
| Shared between multiple playbooks | Role |
| Will be applied to new nodes later | Role |

## Idempotency in roles

Roles should be safe to run repeatedly. Use modules with built-in idempotency
(`ansible.builtin.user`, `ansible.builtin.copy`, `ansible.builtin.systemd`) rather
than `shell` commands that have no state awareness.

For conditional installation (install only if not present):

```yaml
- name: check if binary exists
  ansible.builtin.stat:
    path: /usr/local/bin/node_exporter
  register: binary_stat

- name: install binary
  # ... download and place binary ...
  when: not binary_stat.stat.exists
```

## Handlers

Handlers are tasks that only run when notified by another task. They execute
once at the end of the play, even if notified multiple times.

Common use: restart a service only when its config changed.

```yaml
# In tasks/main.yml
- name: deploy systemd unit
  ansible.builtin.template:
    src: node_exporter.service.j2
    dest: /etc/systemd/system/node_exporter.service
  notify: restart node_exporter

# In handlers/main.yml
- name: restart node_exporter
  ansible.builtin.systemd:
    name: node_exporter
    state: restarted
    daemon_reload: true
```

Without handlers, you would restart the service every run regardless of whether
the config changed.

## Related

- [Playbook Structure](playbook-structure.md)
- [Task Control](task-control.md)
- [Privilege Escalation](privilege-escalation.md)
