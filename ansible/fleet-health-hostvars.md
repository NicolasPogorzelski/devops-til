# Ansible Fleet Health Checks & hostvars

## The core pattern: hostvars

Ansible stores all gathered facts and registered variables for every inventory host
in a single in-memory dictionary called `hostvars`. Any play, on any host, can read
data from any other host:

```yaml
hostvars['lxc200']['ansible_uptime_seconds']
hostvars['lxc200']['ansible_memory_mb']['real']['free']
```

This is how a reporting play on one node (e.g. lxc250) can aggregate data collected
from all other nodes earlier in the same playbook run.

`hostvars` is a "magic variable" — Ansible populates it automatically, no task needed.

## Multi-play aggregation pattern

```
Play 1 (hosts: all)      → gather facts (gather_facts: true fills hostvars)
Play 2 (hosts: docker)   → gather docker-specific data
Play 3 (hosts: lxc250)   → iterate groups['all'], read hostvars[host], write report
```

Play 3 runs *after* plays 1 and 2, so all facts are already in hostvars by the time
the report is written.

## Key modules used

### ansible.builtin.service_facts
Populates `ansible_facts.services` with status of all systemd services.
Two-task pattern: collect first, then read.

```yaml
- ansible.builtin.service_facts:          # no args — just populates the dict

- ansible.builtin.debug:
    var: ansible_facts.services['docker.service']   # read one specific service
```

### community.docker.docker_host_info
Queries the Docker daemon directly (not systemd).
`containers: true` adds the container list to the result.

```yaml
- community.docker.docker_host_info:
    containers: true
  register: docker_info
```

### ansible.builtin.find + file (cleanup loop)

```yaml
- ansible.builtin.find:
    paths: /var/log/fleet-health
    age: 7d
    recurse: false
  register: old_reports

- ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ old_reports.files }}"
```

`find` returns a list in `register.files`. The `loop` iterates over it;
`item.path` is the full path of each matched file.

### ansible.builtin.copy with Jinja2 content

```yaml
- ansible.builtin.copy:
    dest: "/var/log/fleet-health/report-{{ ansible_date_time.date }}.txt"
    content: |
      {% for host in groups['all'] %}
      --- {{ host }} ---
      Uptime: {{ hostvars[host]['ansible_uptime_seconds'] | default('N/A') }}
      {% endfor %}
    mode: '0644'
```

`ansible_date_time.date` gives `YYYY-MM-DD` — requires `gather_facts: true` on the play.
`| default('N/A')` prevents errors if a host was unreachable and has no facts.

## gather_facts: true vs false vs omitted

`gather_facts: true` (or omitted — it's the default) runs the `setup` module on
connection: collects ~200 facts (CPU, RAM, mounts, network, OS, `ansible_date_time`,
...) and stores them in `hostvars`. Without it, those variables are empty.

`gather_facts: false` skips the `setup` module — saves time when you don't need
system facts (e.g. a play that only queries Docker).

Convention: if any play in the same playbook uses `gather_facts: false`, make the
others explicitly `gather_facts: true` — otherwise a reader must know the default
to understand the intent.

## When to use a role vs. inline in the playbook

| Use a role | Keep inline |
|---|---|
| Logic reused by multiple playbooks | One-shot operational playbook |
| Different host groups call the same logic | Only one calling context |
| Has own vars, templates, handlers | Self-contained, no reusable parts |

Fleet health check → inline. `node_exporter` install → role.

## Data types in Ansible facts

- `{}` Dictionary — one thing with named fields. Example: `ansible_memory_mb` (one RAM, fields: free/total/used).
- `[]` List — multiple items of the same type. Example: `ansible_mounts` (one entry per mountpoint).

A list of dictionaries: `ansible_mounts` is `[{mount: /, fstype: ext4, ...}, {mount: /boot, ...}]`.
Access via loop or index: `ansible_mounts[0].mount`.
