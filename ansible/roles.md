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
├── defaults/
│   └── main.yml       # low-priority variables — intended to be overridden
├── vars/
│   └── main.yml       # high-priority variables — internal, not for overriding
├── files/
│   └── *              # static files copied 1:1 to nodes
├── templates/
│   └── *.j2           # Jinja2 templates rendered per-host before copying
└── handlers/
    └── main.yml       # triggered actions (e.g. restart service on config change)
```

Only `tasks/main.yml` is mandatory. The others are loaded automatically when present.

## `defaults/` vs `vars/`

Both hold variables. The difference is who controls them.

| | `defaults/` | `vars/` |
|---|---|---|
| Priority | Lowest — easily overridden | High — hard to override |
| Intent | "I suggest this value, change it if needed" | "This is fixed, don't touch it" |
| Examples | version number, port, feature flags | binary path, system username |

```yaml
# defaults/main.yml — callers can override these per-playbook
node_exporter_version: "1.11.1"
node_exporter_port: 9100

# vars/main.yml — internal constants
node_exporter_binary: /usr/local/bin/node_exporter
node_exporter_user: node_exporter
```

Overriding a default from a playbook:
```yaml
roles:
  - role: node_exporter
    vars:
      node_exporter_version: "1.12.0"   # overrides defaults/, not vars/
```

## `files/` vs `templates/`

| | `files/` | `templates/` |
|---|---|---|
| Content | Static — copied byte-for-byte | Dynamic — Jinja2 variables rendered before copying |
| Extension | any | `.j2` |
| Use case | Config with no per-host variation | Config that differs per node (IPs, hostnames) |
| Module | `ansible.builtin.copy` | `ansible.builtin.template` |

`src` in both modules is relative to the role directory — no full path needed:

```yaml
# files/ — static copy
- ansible.builtin.copy:
    src: node_exporter.conf        # resolves to roles/node_exporter/files/
    dest: /etc/node_exporter.conf

# templates/ — Jinja2 render then copy
- ansible.builtin.template:
    src: node_exporter.service.j2  # resolves to roles/node_exporter/templates/
    dest: /etc/systemd/system/node_exporter.service
```

## Binary deployment pattern

Standard pattern for deploying a pre-compiled binary as a systemd service:

```yaml
# 1. Download archive
- ansible.builtin.get_url:
    url: https://example.com/releases/v{{ version }}/app-{{ version }}.tar.gz
    dest: /tmp/app-{{ version }}.tar.gz

# 2. Extract archive on the remote node
- ansible.builtin.unarchive:
    src: /tmp/app-{{ version }}.tar.gz
    dest: /tmp/
    remote_src: true          # file is already on the node, not on the controller

# 3. Copy binary to final location
- ansible.builtin.copy:
    src: /tmp/app-{{ version }}/app
    dest: /usr/local/bin/app
    owner: root
    group: root
    mode: '0755'
    remote_src: true

# 4. Deploy systemd unit from template (IP or other per-host values)
- ansible.builtin.template:
    src: app.service.j2
    dest: /etc/systemd/system/app.service
    owner: root
    group: root
    mode: '0644'
  notify: restart app

# 5. Enable and start the service
- ansible.builtin.systemd_service:
    name: app
    state: started
    enabled: true
    daemon_reload: true
```

`remote_src: true` tells Ansible the source file is already on the target node.
Without it, Ansible looks for the file on the controller and fails.

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

**Critical implicit behavior:** a handler only fires if the notifying task reports
`changed: true`. If the task was already in the desired state (`ok`, `changed=0`),
the handler is silently skipped — no notification is sent. This is correct behavior
for idempotency (don't restart if nothing changed), but it means you cannot rely on
a handler to "always run at the end of the play".

## Related

- [Playbook Structure](playbook-structure.md)
- [Task Control](task-control.md)
- [Privilege Escalation](privilege-escalation.md)
