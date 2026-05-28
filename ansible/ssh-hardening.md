# SSH Hardening with Ansible

## What we harden

Two directives in `/etc/ssh/sshd_config`:

- `PasswordAuthentication no` — disables password-based SSH login; forces key-based auth only. Eliminates brute-force attack vector.
- `PermitRootLogin no` — disables direct SSH login as root. Use a sudo-enabled user instead. Root actions are auditable via sudo logs; direct root SSH is not.

Default values (Debian 12):
- `PasswordAuthentication yes` (often commented out as `#PasswordAuthentication yes`)
- `PermitRootLogin prohibit-password` (allows root with key, but not password)

## Module: ansible.builtin.lineinfile

Used to set or replace a single line in a file. Does not require deploying a full template.

```yaml
- name: disable password authentication
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: ^#?PasswordAuthentication
    line: PasswordAuthentication no
  notify: reload sshd
```

Key parameters:
- `path` — the file to modify
- `regexp` — regex to find the target line; the matched line is replaced by `line`
- `line` — the desired final content of the line
- `notify` — triggers the named handler only if this task made a change

## regexp pattern workflow

1. Look at the actual line in the file: `grep "PasswordAuthentication" /etc/ssh/sshd_config`
2. Identify all variants (commented, uncommented, different values)
3. Build pattern left to right:
   - `^` — anchor to line start (prevents matching mid-line occurrences)
   - `#?` — optional `#` (matches both commented and uncommented lines)
   - rest — the fixed keyword

Reference: `man 7 regex`, or test patterns at regex101.com.

## Handler

```yaml
- name: reload sshd
  ansible.builtin.systemd_service:
    name: ssh
    state: reloaded
```

- `state: reloaded` — sends SIGHUP to sshd, reloads config without dropping existing sessions
- `state: restarted` — full restart, drops all active SSH connections (avoid on remote hosts)
- Under Debian 12 the service is named `ssh`, not `sshd`

## Dry-run workflow (standard from here on)

Always run with `--check --diff` before applying:

```bash
ansible-playbook playbooks/ssh-hardening.yml --check --diff
```

- `--check` — simulate the run, make no changes
- `--diff` — show before/after for file modifications (like git diff)

Only apply after reviewing the diff output.

## Idempotency signal

- First run: `ok=4` (Facts + 2 tasks + handler)
- Second run: `ok=3` (Facts + 2 tasks, handler not triggered because no task was `changed`)

`notify` only fires when the task reports `changed`. On a second run with no changes, the handler is skipped — this is expected and correct.
