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

## Reproducibility: pin the ansible-lint version

`pip install ansible-lint` (unpinned) installs the **newest** release each time the
workflow runs. ansible-lint's default rule profile gets stricter over releases, so a
version bump can turn a green pipeline red **on an unrelated push** — nothing in the
repo changed, the tool did.

```yaml
# ❌ unpinned — CI behaviour drifts with every ansible-lint release
run: pip install ansible-lint
# ✅ pinned — reproducible; upgrades are a deliberate, reviewed change
run: pip install 'ansible-lint==26.6.0'
```

Diagnosing this: if `main` was green days ago and a feature branch is suddenly red
with findings nobody introduced, compare the installed version between runs
(`Successfully installed ansible-lint-X` in the install step log). A newer version =
drift, not a real regression.

## Profiles: the strictness ladder

ansible-lint groups rules into cumulative profiles, weakest to strongest:

```
min  <  basic  <  moderate  <  safety  <  shared  <  production
```

- `min` — only rules that catch code that won't **load/parse/run** (syntax errors,
  `internal-error`). A "does it even work" gate.
- `basic` — adds style/idiom (`name`, `yaml`, `role-name`).
- `production` — the strictest built-in (adds `fqcn`, `var-naming`,
  `risky-file-permissions`, `no-changed-when`, …).

When no profile is configured, ansible-lint applies its **own evolving default** —
that default is what creeps stricter across versions. Lock it explicitly so the gate
is deterministic regardless of the installed version.

The summary line tells you the highest profile that passed:

```
Failed: 52 failure(s) ... Last profile that met the validation criteria was 'min'.
Passed: 0 failure(s) ... Profile 'production' was required, and it passed.
```

## The `.ansible-lint` config file

Lives at the directory ansible-lint runs from (here `ansible/.ansible-lint`, since CI
does `cd ansible && ansible-lint .`). Auto-discovered.

```yaml
---
profile: production
skip_list:
  - var-naming[no-role-prefix]   # one documented waiver, see below
```

- `profile:` — pins the enforcement floor; version-proof against default-profile creep.
- `skip_list:` — rules (or exact `rule[subrule]` tags) to not enforce at all.
  (`warn_list:` reports them without failing — a softer option.)

## Vault in CI: syntax-check needs the file, not the secret

ansible-lint runs `ansible-playbook --syntax-check` per role. If `ansible.cfg` sets
`vault_password_file` and the repo has committed `!vault` vars (e.g.
`group_vars/all/vault.yml`), the syntax-check **parses** those vars and errors if the
password file is absent:

```
[ERROR]: The vault password file ~/.vault_pass was not found
internal-error: Unexpected error code 1 from ansible-playbook --syntax-check ...
```

Key insight: `--syntax-check` **parses but never decrypts** the vaulted values, so any
placeholder file suffices — no real secret needs to touch CI:

```yaml
- name: Provide a vault password file for syntax-check
  run: echo 'ci-syntax-check-only' > ~/.vault_pass
```

**Masking trap:** this `internal-error` fires *per role* and aborts that file's whole
evaluation, so it **hides every other rule** in the same file. A run reporting "28
internal-error" may actually have 50+ style findings underneath — fix the vault file
first, then the real count appears.

## role-name and the var-naming cascade

`role-name` requires role **directory** names to match `^[a-z][a-z0-9_]*$` — i.e.
underscores, **no hyphens**. `ssh-hardening` → `ssh_hardening`.

Renaming a role dir ripples through every invocation (`roles:` lists,
`import_role`/`include_role`, `meta/dependencies`) — but **not** playbook filenames or
unrelated paths (`/etc/cron.d/homelab-schedule`, `pg-backup.sh`). Rename the dirs with
`git mv` (preserves history), then update the `roles:` entries; a real
`ansible-playbook --syntax-check` confirms the roles still resolve.

The cascade: a **hyphenated** role name can't form a valid variable prefix, so
`var-naming[no-role-prefix]` is silently inapplicable. Renaming to underscores
**unmasks** it — it now demands every role var carry the role name as a prefix
(`paperless_dbuser` → `paperless_env_dbuser`). Expect a jump in findings *after* the
rename, not before.

`var-naming[no-role-prefix]` is the canonical rule to **waive** rather than satisfy:
the prefixes are verbose and their anti-collision value only matters for roles shared
to Galaxy — negligible for a private single-tenant repo whose vars are already
namespaced. Waive it in `skip_list` with a comment; keep every other production rule on.

## `ansible-lint --fix`

Auto-remediates the transformable rules (most of `name`, `yaml`):

```bash
ansible-lint --profile production --fix=name .   # or --fix=all
```

Two cautions:

- It is **broader than the tag suggests**: applying a `name` fix re-emits the whole
  file through the YAML formatter, so it also reindents/normalises untouched files —
  **including the encrypted `vault.yml`** (harmless in theory, but never let a linter
  rewrite a vault file). Run the fix, then `git restore` any file that had no findings
  of its own (e.g. `vault.yml`), and review the diff: it must be purely cosmetic
  (casing, indentation, blank lines) — no changed values or logic.
- Not everything is auto-fixable: `role-name` (rename) and `var-naming` (rename) need
  manual work or a waiver.
