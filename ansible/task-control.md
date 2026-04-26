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

## Related

- [Playbook Structure](playbook-structure.md)
- [Serial Execution](serial-execution.md)
