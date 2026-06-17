# Self-Validating Documentation Repos

## The problem

Documentation rots. Conventions written in a CONTRIBUTING.md are read once,
then forgotten. The repo grows, gets contributions from automated tools or
future-you, and slowly drifts out of compliance with its own rules.

A documentation repo that *enforces* its own rules in CI catches drift before merge.

## The pattern

A single shell script (`scripts/validate-repo.sh`) runs all structural checks.
A GitHub Actions workflow runs the same script on every push and PR.
The script also runs locally before commit — same code path in both places,
so contributors find issues without waiting for CI.

```
scripts/validate-repo.sh   ← single source of truth for repo rules
.github/workflows/*.yml    ← runs the script on push/PR
local pre-commit habit     ← runs the script before pushing
```

## Categories of checks worth automating

### Structural integrity

- Empty markdown files (a `*.md` with zero bytes is almost always a mistake)
- Broken internal links (`./foo.md` referenced but file does not exist)
- Files outside the allowed top-level directory list
- Leftover git merge conflict markers (`^<<<<<<< `, `^=======$`, `^>>>>>>> `) —
  a botched merge resolution can commit these into tracked files. Match the divider
  as a whole line (`=======$`) so markdown rules and setext underlines don't false-positive,
  and require the trailing space on `<<<<<<< ` / `>>>>>>> ` so shell redirects don't match.

> **The gap is the check you don't have yet.** A stray `<<<<<<< HEAD` sat in a
> committed `CLAUDE.md` for weeks — `validate-repo.sh` was green the whole time because
> no check looked for it. It surfaced only in a manual pre-milestone audit. The fix is
> two-part: remove the marker *and* add the check, so the same class can never slip
> through silently again. Every "how did this get committed?" finding should leave
> behind a new automated check, not just a fix.

### Required sections

If every doc of a given type must include certain sections, validate it:

| Doc type | Required section |
|---|---|
| `docs/services/*.md` | `## Access Model` |
| `docs/nodes/*.md` | `## Failure Impact` |
| `runbooks/**/*.md` | `Precondition`, `Verification`, `Failure` |

A grep-based check catches missing sections at PR time, not three months
later when someone needs the runbook in an incident.

### Sanitization rules

For repos that mix sanitized examples with sensitive originals:

- Reject bare Tailscale IPs (`100.x.y.z`) — must use `<tailscale-ip-nodename>` placeholder
- Reject bare tailnet IDs (`*.ts.net`) — must use `<tailnet-id>` placeholder
- Reject committed private keys / certs (`*.pem`, `*.key`, `*.crt`, `*.p12`, `*.pfx`)
- Reject committed `.env` files (only `.env.example` is allowed)

### Convention enforcement

- Each `docker/<service>/docker-compose.yml` must have a sibling `.env.example`
- No duplicate `## ` headings inside the same markdown file
- Top-level directory list is closed (only docs/, docker/, runbooks/, etc. allowed)

## Anatomy of a check

```bash
# Check: every service doc has an Access Model section
while read -r file; do
    if ! grep -q "## Access Model" "${file}"; then
        echo "  Missing 'Access Model' section: ${file}"
        ERRORS=$((ERRORS + 1))
    fi
done < <(find "${REPO_ROOT}/docs/services" -name "*.md" -type f)
```

The pattern repeats:
1. Enumerate the files in scope
2. Apply the rule (grep, find, regex)
3. Print the offender
4. Increment a counter
5. At the end, exit non-zero if any check failed

## Why bash, not a "real" linter

For documentation hygiene, bash + `grep` + `find` cover ~95% of useful checks
with zero dependencies. A repo of mostly markdown does not need to drag in
Python or Node tooling just to validate itself.

Move to a proper linter when:
- Checks need real markdown parsing (heading hierarchy, link resolution across files)
- The script crosses ~300 lines of conditional grep
- Multiple repos share the same checks (extract to a reusable action)

## CI workflow

```yaml
name: Validate Repository

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          chmod +x scripts/validate-repo.sh
          ./scripts/validate-repo.sh
```

Exit code from the script is the build status. Non-zero = red ❌, zero = green ✅.

## Limits — what validation cannot catch

- **Truth of content.** A doc can pass every structural check while saying
  factually wrong things. Validation enforces shape, not accuracy.
- **Runtime artifacts.** A `.example` file may exist while the materialized
  config file does not — the validator can't see the running system.
- **Drift between code and docs.** A service doc can describe a configuration
  the actual `docker-compose.yml` no longer matches.

For these, the answer is human review (PRs, periodic doc sweeps), not more checks.

## Related

- [Operations: Conventional Commits](conventional-commits.md)
- [Operations: Runbook Methodology](runbook-methodology.md)
