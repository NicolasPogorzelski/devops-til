# Ansible Task Control

## `register` - capture task output

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
| `failed` | Boolean - whether Ansible considers the task failed |

## `changed_when` - control the "changed" state

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

## `ansible.builtin.fail` - abort with a message

`fail` immediately stops the play on that host and prints a message.
Unlike a task error, it lets you write a human-readable explanation
including context variables.

```yaml
- name: abort if corruption found
  ansible.builtin.fail:
    msg: "Corrupt files on {{ inventory_hostname }}: {{ dpkg_verify.stdout }}"
```

`{{ inventory_hostname }}` is a built-in variable - the hostname of the current
target node as defined in inventory. Useful in plays that run across multiple
hosts (`serial: 1`) so the error message names the affected node.

## `when` - conditional execution

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

`command` is preferred when possible - it avoids shell injection risk.
Use `shell` only when the command genuinely needs shell features.

## Combining the patterns - post-upgrade integrity check

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

- `apt-get -s dist-upgrade` - simulate only, no changes; lists what would be upgraded
- `awk '/^Inst /{print $2}'` - lines starting with `Inst` are packages being installed/upgraded; `$2` is the package name
- `changed_when: false` - this task only reads state, never mark it as changed
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

Note the `\$NF` and `\$2` - the `\` escapes the `$` from the outer shell before
Ansible sees the string. Without the backslash, the shell expands `$NF` to empty
before passing the argument to Ansible.

**Why `command` module doesn't help here:** Even without Jinja2 collision, `command`
doesn't support pipes. Use `shell` for any command that needs `|`, `&&`, `>`, or
variable escaping.

## `ansible.builtin.cron` - idempotent cron entries

The `cron` module writes cron entries into a user's crontab. The `name` parameter
is the idempotency key: Ansible writes it as a comment above the entry
(`#Ansible: <name>`) and uses it to find and update the same entry on subsequent
runs. Without `name`, Ansible cannot identify the entry and will duplicate it.

```yaml
- name: Schedule pg_dumpall cron job
  ansible.builtin.cron:
    name: pg-backup          # idempotency key -> written as "#Ansible: pg-backup"
    user: postgres           # whose crontab to write into (crontab -u postgres)
    minute: "0"
    hour: "3"
    job: /usr/local/sbin/pg-backup.sh
```

If a manual cron entry already exists with the same job string, Ansible adds the
`#Ansible: <name>` comment above it (taking ownership) without duplicating the entry.

`user` writes into that user's personal crontab - equivalent to `crontab -u postgres -e`.
Omit `cron_file` unless you want a file under `/etc/cron.d/` (system-wide, owned by root).

### The module cannot remove an entry it did not write

`state: absent` locates the entry to delete by its `#Ansible: <name>` marker. An entry that a
human added with `crontab -e` has no marker, so the module finds nothing and reports `ok`. This
is the shape of an adoption task: a script that was hand-deployed with a hand-written crontab
line, now being taken over by a role.

Two cases, two tools:

**A file in `/etc/cron.d/`** - just delete the file. It is a file:

```yaml
- name: Remove the legacy snapraid cron file
  ansible.builtin.file:
    path: /etc/cron.d/snapraid
    state: absent
```

**A line in a user crontab** - filter the crontab and pipe it back through `crontab -`, which
validates the syntax and fixes ownership and mode, rather than editing the spool file directly:

```yaml
- name: Read the root crontab
  ansible.builtin.command:
    cmd: crontab -l -u root
  register: root_crontab
  changed_when: false     # a read never changes anything
  failed_when: false      # an empty crontab exits 1; that is not an error
  check_mode: false       # must run under --check, or .stdout is undefined below

- name: Remove the legacy watchdog cron entry
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      crontab -l -u root | sed -E '/jellyfin-cuda-watchdog/d' | crontab -u root -
    executable: /bin/bash
  when: root_crontab.stdout is search('jellyfin-cuda-watchdog')
  changed_when: true      # guarded by `when`, so reaching this task *is* a change
```

Three details that each cost a debugging round:

- **`sed -E '/pat/d'`, not `grep -vE pat`.** `grep` exits 1 when it prints no lines. On a crontab
  whose only entry is the one being removed, printing nothing is success - and `set -o pipefail`
  turns that into a task failure. `sed` exits 0 either way.
- **`check_mode: false` on the read.** `command`/`shell` are skipped under `--check`. Without the
  override, `root_crontab.stdout` never gets registered and the `when:` on the next task raises
  an undefined-variable error instead of showing a clean dry run.
- **`when:` doubles as the idempotency guard.** On the second run the pattern is gone, the task
  skips, and the play reports `changed=0`. A `changed_when: true` without the `when:` would
  report a change forever.

## Making a role dry-runnable

`--check --diff` is only a useful review tool if the role can survive it. Two constructs routinely
break check mode, and both have a one-line fix.

**Read-only probes must still run.** A `command` that measures state (an installed version, a
filesystem type, an existing crontab) is skipped under `--check`, so anything `register`ed from it
is undefined and every `when:` downstream explodes:

```yaml
- name: Probe the filesystem type of the rw library mount
  ansible.builtin.command:
    cmd: findmnt -no FSTYPE /books-rw
  register: library_fstype
  changed_when: false
  failed_when: false
  check_mode: false     # it reads. Let it read, even in a dry run.
```

**`systemctl enable` on a unit that was never written must be skipped.** Under `--check` the
`template` task did not really create `/etc/systemd/system/foo.timer`, so systemd cannot find it:

```
Could not find the requested service foo.timer: host
```

That is not a node problem, it is a role problem - the role simply cannot be dry-run:

```yaml
- name: Enable and start the timer
  ansible.builtin.systemd_service:
    name: foo.timer
    enabled: true
    state: started
    daemon_reload: true
  when: not ansible_check_mode
```

`ansible_check_mode` is a magic variable, true exactly when `--check` is active.

The target to aim for: on a converged system, `--check` prints `failed=0, changed=0`. Then a
non-empty diff means a real pending change, and the dry run is evidence rather than noise.

## `assert` as a precondition, not a comment

When a role depends on state it does not manage - a mount, a hand-installed binary, an env file -
assert it and let the play fail with a sentence that tells the next person what to do:

```yaml
- name: Assert the rw library is the CIFS share and not the directory beneath it
  ansible.builtin.assert:
    that: library_fstype.stdout | trim == "cifs"
    fail_msg: >-
      /books-rw has fstype '{{ library_fstype.stdout | trim }}', expected 'cifs'.
      The Proxmox host has not mounted the rw share; the bind mount is exposing the
      empty directory underneath it. Mount it on the host, then `pct reboot 220`.
```

Order the role so the artefacts deploy *before* the assert. Then a run against a broken node still
ships the fixed script and units, and fails afterwards with the diagnosis - rather than refusing to
do the part it could have done.

## `ansible.builtin.copy` - `remote_src` gotcha

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
    remote_src: yes          # extracted file is on the remote - REQUIRED
    owner: root
    mode: '0755'
```

**Latent bug pattern:** if `remote_src` is missing but the destination file already
exists at `dest`, Ansible checks the destination and reports `changed=0` (already
in place) - the missing flag is never hit. The bug only surfaces when the tarball
is re-downloaded and the copy task actually needs to run.

## Related

- [Playbook Structure](playbook-structure.md)
- [Serial Execution](serial-execution.md)
