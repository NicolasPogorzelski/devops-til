# Git Commit Hooks

## What are git hooks

Shell scripts that git calls automatically at specific points in the git workflow.
They live in `.git/hooks/` and run locally on the developer's machine.

Common hook events:

| Hook | When it runs | Common use |
|---|---|---|
| `commit-msg` | after typing the commit message | validate message format |
| `pre-commit` | before the commit is created | run linters, tests |
| `pre-push` | before `git push` | run tests, block force-push |

## Where hooks live — and why this matters

Hooks are stored in `.git/hooks/`. This directory is **never committed and never pushed** — `.git/` is git's internal state, not part of the repository content.

Consequence: hooks are machine-local. A fresh clone has empty `.git/hooks/`.

## The symlink pattern

To version-control a hook script while keeping it activatable locally:

1. Write the script in a tracked directory (e.g., `scripts/commit-msg-lint.sh`)
2. Create a symlink in `.git/hooks/` pointing to it:

```bash
ln -sf ../../scripts/commit-msg-lint.sh .git/hooks/commit-msg
```

- `ln -s` — symbolic link (pointer to a path, not a copy)
- `../../` — relative path from `.git/hooks/` up to the repo root
- `-f` — overwrite if a hook already exists

The script is committed and versioned. The symlink is local. When the script changes, the hook automatically uses the new version.

## commit-msg hook: validating Conventional Commits

A `commit-msg` hook receives the path to the commit message file as `$1`.

Minimal validation script:

```bash
#!/usr/bin/env bash
set -euo pipefail

MSG_FILE="$1"
SUBJECT=$(head -1 "$MSG_FILE")

# skip auto-generated messages (merge, revert, fixup)
if echo "$SUBJECT" | grep -qP '^(Merge|Revert|fixup!|squash!)'; then
    exit 0
fi

PATTERN='^(feat|fix|docs|refactor|chore|test|ci)\([a-z0-9-]+\): .+'

if ! echo "$SUBJECT" | grep -qP "$PATTERN"; then
    echo "ERROR: Commit message format invalid." >&2
    echo "Expected: type(scope): description" >&2
    exit 1
fi
```

- `head -1` — only check the subject line; the body is not validated
- `grep -qP` — quiet match with PCRE (`-P`); non-zero exit if no match
- `>&2` — error output goes to stderr; git displays stderr to the user
- `exit 1` — non-zero exit aborts the commit

## Bypassing hooks

Hooks can always be bypassed:

```bash
git commit --no-verify
```

`--no-verify` skips all local hooks. This means local hooks are **convenience**, not enforcement.

## Local hooks vs CI enforcement

| Layer | What it catches | Can be bypassed? |
|---|---|---|
| Local hook | catches issues before commit | yes (`--no-verify`) |
| CI pipeline | catches issues before merge | no (blocks PR) |

Local hooks give fast feedback. CI is the real enforcement point.
Run the same check in both places — local for speed, CI for reliability.

## Professional tooling

In team environments, hooks are managed with dedicated tools instead of manual symlinks:

| Tool | Ecosystem | Config file |
|---|---|---|
| [pre-commit](https://pre-commit.com/) | Python-centric, works for any language | `.pre-commit-config.yaml` |
| [husky](https://typicode.io/husky/) | JavaScript / Node.js projects | `package.json` / `.husky/` |

These tools commit the hook configuration to the repo and provide a single install command (`pre-commit install`, `npx husky`) that sets up the hooks after cloning. The hook scripts themselves stay versioned.

Key insight: even with these tools, `--no-verify` still bypasses them. CI remains the enforcement point.
