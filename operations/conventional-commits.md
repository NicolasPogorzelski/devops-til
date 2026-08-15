# Conventional Commits with Scopes

## Format

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

The type and scope are not optional. The scope identifies *where* the change lives;
the type identifies *what kind* of change it is.

## Types

| Type | Use for |
|---|---|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code change without behavior change |
| `chore` | Repo housekeeping, dependency bumps, gitignore |
| `test` | Adding or modifying tests |
| `ci` | CI/CD pipeline changes |

## Scopes (homelab convention)

Two scope categories - pick whichever is most specific:

**Per-node** (when the change affects a single node):
`vm100`, `vm102`, `lxc200`, `lxc210`, `lxc211`, `lxc220`, `lxc230`, `lxc240`, `lxc250`, `lxc260`

**Thematic** (when the change is cross-cutting):
`monitoring`, `network`, `docs`, `adr`, `runbook`, `ci`, `repo`, `platform`

Examples:
```
feat(lxc260): add PostgreSQL 15 with hardened pg_hba
docs(platform): add tailscale ACL tier0 rules
fix(monitoring): correct grafana datasource url
chore(repo): update validate-repo.sh check 12
ci(repo): add GitHub Actions workflow for validation
refactor(ansible): split apt-upgrade into lxcs and vms plays
```

## Why scopes matter

Without scope, `git log --oneline` is a wall of equally-weighted noise.
With scope, you can:
- `git log --oneline | grep '(monitoring)'` to see only monitoring history
- Spot architectural changes (`(adr)`, `(platform)`) at a glance
- Trace per-node changes when troubleshooting a single LXC

## What goes in the description

The "what", briefly. Keep it under ~70 characters so it fits in
`git log --oneline` output.

```
feat(lxc260): add PostgreSQL 15 with hardened pg_hba
              ^ what was added                ^ how it's distinct
```

The body (separated by a blank line) is for the "why" - one or two short
paragraphs explaining motivation, trade-offs, references. Skip the body if
the title is self-explanatory.

## What does NOT belong in commit messages

- AI tool attribution ("Generated with X", "Co-Authored-By: AI")
- Author signatures that aren't actual co-authors
- Issue/PR numbers in the title (use the footer: `Refs: #123`)
- "Various changes" or similar non-information

## Tooling

- `git log --oneline --grep='^feat'` - filter by type
- `git log --grep='(monitoring)' --oneline` - filter by scope
- `commitlint` (npm) can enforce the format in CI if needed

## Related

- [Operations: Runbook Methodology](runbook-methodology.md)
- [Operations: Repo Validation](repo-validation.md)
