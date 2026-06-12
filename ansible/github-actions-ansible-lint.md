# GitHub Actions: CI/CD for Ansible with ansible-lint

## What

A GitHub Actions workflow that runs `ansible-lint` automatically on every push and on PRs to main — enforces code quality without manual intervention.

## Workflow file location

```
.github/workflows/ansible-lint.yml
```

GitHub scans this path automatically. The leading `.` makes it a hidden directory (tooling/metadata convention, not a security measure).

## Minimal workflow structure

```yaml
name: ansible-lint

on:
  push:
  pull_request:
    branches: [main]

jobs:
  Ansible_lint:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repo code
        uses: actions/checkout@v6
      - name: Install ansible-lint and collections
        run: |
          pip install ansible-lint
          ansible-galaxy collection install -r ansible/requirements.yml
      - name: Run ansible-lint
        run: cd ansible && ansible-lint .
```

## Why `cd ansible && ansible-lint .` not `ansible-lint ansible/`

`ansible-lint` resolves `roles_path` from `ansible.cfg` relative to the **current working directory**. Running from the repo root, `./roles` in `ansible.cfg` points to `<repo-root>/roles` — which doesn't exist. Running from `ansible/`, it correctly resolves to `ansible/roles/`.

## requirements.yml

Collections not bundled with `ansible-core` must be installed explicitly on the CI runner. Create `ansible/requirements.yml`:

```yaml
---
collections:
  - name: ansible.posix
  - name: community.postgresql
  - name: community.docker
```

`ansible-galaxy collection install -r <file>` reads the list and installs all of them.

## Triggers

- `push:` with no filter — runs on every branch push (early feedback)
- `pull_request: branches: [main]` — runs on PRs targeting main (the merge gate)

## Common lint violations and fixes

| Rule | Problem | Fix |
|---|---|---|
| `name[casing]` | Task name starts lowercase | Capitalize first letter |
| `yaml[truthy]` | `yes`/`no` instead of `true`/`false` | Replace throughout |
| `risky-shell-pipe` | Pipe without `set -o pipefail` | Add `set -o pipefail` + `executable: /bin/bash` in `cmd:` block |
| `no-changed-when` | `shell`/`command` without `changed_when` | Add `changed_when: true` on handlers (they only run when notified = already changed) |
| `risky-file-permissions` | `get_url` without `mode:` | Add `mode: '0644'` |
| `partial-become` | `become_user` without `become: true` | Add `become: true` at the same level |
| `command-instead-of-module` | `shell: apt-get` when no module equivalent | Suppress with `# noqa: command-instead-of-module` and document why |

## Critical gotcha: handler name matching

`notify:` matches handler names by **exact string** (case-sensitive). If you rename a handler, update every `notify:` that references it — Ansible silently skips the handler without any error if the name doesn't match.

```yaml
# handler
- name: Reload ssh_config   # capital R

# task — must match exactly
  notify: Reload ssh_config  # capital R — NOT "reload ssh_config"
```

## pipefail explained

Without `set -o pipefail`, only the exit code of the **last** command in a pipe counts:

```bash
failing_command | grep something   # grep succeeds → whole pipe = success (silent failure)
```

With `pipefail`, any failure in the pipe propagates:

```bash
set -o pipefail
failing_command | grep something   # failing_command fails → whole pipe fails
```

`|| true` at the end still works correctly with `pipefail` — it covers the expected "no output" case (e.g. `grep` finding nothing = exit 1 = success for the caller).
