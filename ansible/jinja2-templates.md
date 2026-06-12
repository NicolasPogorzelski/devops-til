# Jinja2 Templates in Ansible

## What they are

A `.j2` file is a text file with Jinja2 placeholders and logic. Ansible renders it
at run time — substituting variables from the inventory — and writes the result to
the target host. The source file stays in the repo without real IPs or secrets.

Use case: generate a `prometheus.yml` from inventory so Prometheus targets and
Ansible inventory stay in sync. One source of truth.

## Syntax overview

| Syntax | Purpose |
|---|---|
| `{{ variable }}` | Output a value |
| `{% for x in list %}` ... `{% endfor %}` | Loop |
| `{% if condition %}` ... `{% endif %}` | Condition |
| `{# comment #}` | Template comment (not in output) |

## Ansible special variables used in templates

### `groups`

Dictionary of all inventory groups. `groups['lxcs']` returns a list of hostnames
in that group.

```jinja2
{% for host in groups['lxcs'] %}
{{ host }}
{% endfor %}
```

### `hostvars`

Dictionary of all hosts. `hostvars['lxc260']['ansible_host']` returns the
`ansible_host` variable of `lxc260`.

Inside a loop, `host` is the current loop variable:
```jinja2
{{ hostvars[host]['ansible_host'] }}
```

Outside a loop, use a literal string:
```jinja2
{{ hostvars['lxc260']['ansible_host'] }}
```

## Generating a list from inventory

```jinja2
{% for host in groups['lxcs'] %}
  - job_name: "node-{{ host }}-{{ hostvars[host]['prometheus_label'] }}"
    static_configs:
      - targets: ["{{ hostvars[host]['ansible_host'] }}:9100"]
{% endfor %}
```

## Excluding specific hosts from a loop

Ansible's `hosts: all:!lxc200` syntax only works in playbook `hosts:` fields.
Inside a Jinja2 template, use an `if` condition:

```jinja2
{% for host in groups['lxcs'] %}
{% if host != 'lxc200' %}
  - job_name: "node-{{ host }}-{{ hostvars[host]['prometheus_label'] }}"
    static_configs:
      - targets: ["{{ hostvars[host]['ansible_host'] }}:9100"]
{% endif %}
{% endfor %}
```

Note the closing order: `{% endif %}` before `{% endfor %}` — close inner blocks first.

## Custom host variables as template input

Any variable defined per-host in inventory is accessible via `hostvars`.

Adding a `prometheus_label` to each host in `hosts.yml`:
```yaml
lxcs:
  hosts:
    lxc210:
      ansible_host: <tailscale-ip-nextcloud>
      prometheus_label: nextcloud
```

Then in the template:
```jinja2
{{ hostvars[host]['prometheus_label'] }}  # → nextcloud
```

Define per-host variables in groups that list each node exactly once
(e.g. `lxcs`, `vms`) to avoid duplicate definitions.

## Mixing static and dynamic sections

Templates can combine hardcoded blocks with generated loops:

```jinja2
scrape_configs:
  # Static — special cases
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:9090"]

  - job_name: "node-lxc200-monitoring"
    static_configs:
      - targets: ["127.0.0.1:9100"]

  # Dynamic — from inventory
  {% for host in groups['lxcs'] %}
  {% if host != 'lxc200' %}
  - job_name: "node-{{ host }}-{{ hostvars[host]['prometheus_label'] }}"
    static_configs:
      - targets: ["{{ hostvars[host]['ansible_host'] }}:9100"]
  {% endif %}
  {% endfor %}
```

## Deploying with the template module

```yaml
- name: render prometheus config
  ansible.builtin.template:
    src: prometheus.yml.j2     # relative to roles/<name>/templates/
    dest: /etc/prometheus/prometheus.yml
    owner: root
    group: root
    mode: '0644'
    lstrip_blocks: yes
```

The `template` module renders the `.j2` file and copies the result to `dest` on
the target host. `src` is relative to the role's `templates/` directory.

### `lstrip_blocks` and `trim_blocks`

Jinja2 block tags (`{% for %}`, `{% if %}`, etc.) on their own line leave behind
whitespace in the output if not handled carefully.

| Option | Effect | Default in Ansible |
|---|---|---|
| `trim_blocks` | Removes the newline **after** `%}` | yes |
| `lstrip_blocks` | Removes leading spaces/tabs **before** `{%` | no |

With both active, a line like `  {% for host in groups['lxcs'] %}` produces
**nothing** in the output — the leading spaces are stripped by `lstrip_blocks`,
the trailing newline by `trim_blocks`.

**Always set `lstrip_blocks: yes`** when the template contains `for`/`if` blocks
and the output format is whitespace-sensitive (YAML, TOML, Python, etc.).

Without it, each control tag line leaves a "ghost line" with just spaces — in YAML
this causes inconsistent indentation that may confuse parsers or produce invalid structure.

Do not use `{%-` / `-%}` whitespace control as a substitute — it strips newlines
from adjacent content lines, causing entries to run together.

### `trim_blocks` pitfall: inline `{% %}` at end of a content line

`trim_blocks` applies whenever a `{% %}` tag is the **last thing on a line** —
including when it is appended to a content line (not on its own line).

**Broken template:**

```jinja2
ExecStart=/usr/local/bin/node_exporter --web.listen-address={{ host }}:9100{% if textfile_dir %} --collector.textfile.directory={{ textfile_dir }}{% endif %}
Restart=on-failure
```

When `textfile_dir` is empty: the `{% endif %}` is the last tag on the line →
`trim_blocks` eats the newline → `Restart=on-failure` is appended directly to
`ExecStart` with no newline. Result: a broken systemd unit where two directives
are merged onto one line.

**Fix: compute the value with `{% set %}` on a separate line, use `{{ }}` in the content line:**

```jinja2
{% set textfile_flag = '' %}{% if textfile_dir %}{% set textfile_flag = ' --collector.textfile.directory=' + textfile_dir %}{% endif %}
ExecStart=/usr/local/bin/node_exporter --web.listen-address={{ host }}:9100{{ textfile_flag }}
Restart=on-failure
```

- The `{% set %}...{% endif %}` line has no visible output; `trim_blocks` eating its
  newline is harmless.
- `ExecStart` now ends with `{{ textfile_flag }}` — a **variable tag**, not a block tag.
  `trim_blocks` only applies to `{% %}` block tags, so the newline is preserved.

## References

- [Ansible Templating](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_templating.html)
- [Jinja2 Template Designer Docs](https://jinja.palletsprojects.com/en/3.1.x/templates/)
- [Ansible Special Variables](https://docs.ansible.com/ansible/latest/reference_appendices/special_variables.html)
- [ansible.builtin.template module](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html)

## Related

- [Roles](roles.md)
- [Inventory Groups](inventory-groups.md)
