# Ansible Task Control

## `register` — capture task output

`register` saves the result of a task into a variable. The variable is
available to all subsequent tasks in the same play.

```yaml
- name: run a command
  ansible.builtin.shell: some-command
  register: result
```

The registered variable is a dict with these keys:

| Key | Content |
|---|---|
| `stdout` | Standard output as a string |
| `stderr` | Standard error as a string |
| `stdout_lines` | stdout split into a list by newline |
| `rc` | Return code (integer) |
| `failed` | Boolean — whether Ansible considers the task failed |

## `changed_when` — control the "changed" state

Ansible marks `shell` and `command` tasks as **changed** every time they run,
because it cannot know whether the command modified anything.

`changed_when: false` tells Ansible: this task is read-only, never mark it
as changed. Use it for any task that only collects information.

```yaml
- name: collect package integrity results
  ansible.builtin.shell: dpkg --verify 2>&1 | grep -v ' c /' || true
  register: dpkg_verify
  changed_when: false
```

Without `changed_when: false`, every run shows yellow "changed" in the output
even though nothing was modified. This makes the changed/ok distinction
meaningless for that play.

## `ansible.builtin.fail` — abort with a message

`fail` immediately stops the play on that host and prints a message.
Unlike a task error, it lets you write a human-readable explanation
including context variables.

```yaml
- name: abort if corruption found
  ansible.builtin.fail:
    msg: "Corrupt files on {{ inventory_hostname }}: {{ dpkg_verify.stdout }}"
```

`{{ inventory_hostname }}` is a built-in variable — the hostname of the current
target node as defined in inventory. Useful in plays that run across multiple
hosts (`serial: 1`) so the error message names the affected node.

## `when` — conditional execution

`when` controls whether a task runs at all. It accepts a Jinja2 expression.

```yaml
- name: only run if there is output
  ansible.builtin.fail:
    msg: "..."
  when: dpkg_verify.stdout | trim | length > 0
```

**Jinja2 filters used here:**

| Filter | What it does |
|---|---|
| `trim` | Removes leading and trailing whitespace, including newlines |
| `length` | Returns the character count of the string |

The combination `stdout \| trim \| length > 0` means: "the output is not empty
after stripping whitespace". This prevents false positives when `grep` returns
nothing (empty string, possibly with a trailing newline).

## `ansible.builtin.shell` vs `ansible.builtin.command`

| Module | Shell features (pipes, redirects) | Use when |
|---|---|---|
| `command` | No | Simple command, no piping needed |
| `shell` | Yes | Command uses `\|`, `>`, `&&`, `\|\|`, globs |

`command` is preferred when possible — it avoids shell injection risk.
Use `shell` only when the command genuinely needs shell features.

## Combining the patterns — post-upgrade integrity check

```yaml
- name: collect dpkg integrity results
  ansible.builtin.shell: dpkg --verify 2>&1 | grep -v ' c /' || true
  register: dpkg_verify
  changed_when: false

- name: fail on corrupt non-conffile packages
  ansible.builtin.fail:
    msg: |
      Binary corruption on {{ inventory_hostname }}.
      Corrupt files:
      {{ dpkg_verify.stdout }}
      Identify: dpkg -S <path>
      Fix: apt-get install --reinstall <package>
  when: dpkg_verify.stdout | trim | length > 0
```

The `|| true` at the end of the shell command ensures exit code 0 even when
`grep -v` finds no output (grep exits 1 when no lines match). Without it,
a clean system would cause the task to fail.

## Pre-upgrade dry-run + conditional service restart

Before running an upgrade, capture which packages are pending. Use this to
conditionally restart services that need it after the upgrade:

```yaml
- name: collect packages pending upgrade
  ansible.builtin.shell: apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst /{print $2}'
  register: packages_pending
  changed_when: false

- name: upgrade apt
  ansible.builtin.apt:
    upgrade: dist

- name: restart tailscaled if tailscale was upgraded
  ansible.builtin.systemd:
    name: tailscaled
    state: restarted
  when: "'tailscale' in packages_pending.stdout"
```

- `apt-get -s dist-upgrade` — simulate only, no changes; lists what would be upgraded
- `awk '/^Inst /{print $2}'` — lines starting with `Inst` are packages being installed/upgraded; `$2` is the package name
- `changed_when: false` — this task only reads state, never mark it as changed
- The restart task is skipped entirely when `tailscale` is not in the pending list

Run the dry-run **before** the actual upgrade. Afterwards, the dpkg log reflects
the new state and you can no longer reliably detect what changed.

Why this matters for tailscale: after a `tailscaled` restart triggered by an
upgrade, the daemon can start with a stale packet filter, blocking all incoming
TCP connections despite correct ACL configuration. A forced restart ensures a
clean netmap fetch. See [Tailscale Debugging](../networking/tailscale-debugging.md).

## Jinja2 collision with `docker --format` syntax in ad-hoc commands

`docker ps --format '{{.Names}}'` uses `{{ }}` placeholder syntax. Ansible's `-a` argument
is processed by Jinja2 before the command runs. Jinja2 interprets `{{.Names}}` as
a template expression and throws a syntax error:

```
Error while resolving value for '_raw_params': Syntax error in template: unexpected '.'
```

**Fix:** Avoid `--format '{{...}}'` in ad-hoc commands. Use `docker ps` without
format and pipe through `awk` instead:

```bash
ansible all -m shell -a "docker ps --no-trunc | awk '{print \$NF, \$2}'" --become
```

Note the `\$NF` and `\$2` — the `\` escapes the `$` from the outer shell before
Ansible sees the string. Without the backslash, the shell expands `$NF` to empty
before passing the argument to Ansible.

**Why `command` module doesn't help here:** Even without Jinja2 collision, `command`
doesn't support pipes. Use `shell` for any command that needs `|`, `&&`, `>`, or
variable escaping.

## `ansible.builtin.cron` — idempotent cron entries

The `cron` module writes cron entries into a user's crontab. The `name` parameter
is the idempotency key: Ansible writes it as a comment above the entry
(`#Ansible: <name>`) and uses it to find and update the same entry on subsequent
runs. Without `name`, Ansible cannot identify the entry and will duplicate it.

```yaml
- name: Schedule pg_dumpall cron job
  ansible.builtin.cron:
    name: pg-backup          # idempotency key → written as "#Ansible: pg-backup"
    user: postgres           # whose crontab to write into (crontab -u postgres)
    minute: "0"
    hour: "3"
    job: /usr/local/sbin/pg-backup.sh
```

If a manual cron entry already exists with the same job string, Ansible adds the
`#Ansible: <name>` comment above it (taking ownership) without duplicating the entry.

`user` writes into that user's personal crontab — equivalent to `crontab -u postgres -e`.
Omit `cron_file` unless you want a file under `/etc/cron.d/` (system-wide, owned by root).

## `ansible.builtin.copy` — `remote_src` gotcha

By default, `copy` expects `src` to be a path on the **Ansible controller**.
Set `remote_src: yes` when the source file is already on the **target host**
(e.g. after `unarchive` extracted it there).

```yaml
- name: unarchive binary
  ansible.builtin.unarchive:
    src: /tmp/node_exporter.tar.gz
    dest: /tmp/
    remote_src: yes          # tarball is on the remote, not the controller

- name: install binary
  ansible.builtin.copy:
    src: /tmp/node_exporter-1.11.1.linux-amd64/node_exporter
    dest: /usr/local/bin/node_exporter
    remote_src: yes          # extracted file is on the remote — REQUIRED
    owner: root
    mode: '0755'
```

**Latent bug pattern:** if `remote_src` is missing but the destination file already
exists at `dest`, Ansible checks the destination and reports `changed=0` (already
in place) — the missing flag is never hit. The bug only surfaces when the tarball
is re-downloaded and the copy task actually needs to run.

## Related

- [Playbook Structure](playbook-structure.md)
- [Serial Execution](serial-execution.md)
