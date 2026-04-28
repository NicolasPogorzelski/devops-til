# Git Branching Patterns

## Cherry-Pick

Cherry-pick applies a single commit from one branch to another — without merging
the entire branch.

```bash
git cherry-pick <commit-hash>
```

Use case: a commit on a feature branch is ready for `main`, but the rest of the
branch is not.

```bash
git checkout main
git cherry-pick <commit-hash-1>
git cherry-pick <commit-hash-2>
git push origin main
git checkout feat/my-feature
```

The commit is copied with a **new hash** — it exists independently on both branches.
When the feature branch is eventually merged, Git detects the content is already
present and skips those commits automatically.

Find the commit hash to cherry-pick:

```bash
git log --oneline feat/my-feature
```

Inspect what a commit touches before picking it:

```bash
git show <commit-hash> --stat
```

## Cherry-Pick + CI: dependency trap

Cherry-picking a commit that references files or paths not present on the target
branch will pass locally but fail in CI.

Example: cherry-picking a README commit that links to `ansible/playbooks/` onto
`main`, where the `ansible/` directory does not exist yet.

- Local validation runs on the feature branch → passes (files exist)
- CI runs on `main` after push → fails (files missing)

**Rule:** before cherry-picking, verify that all file references in the commit
exist on the target branch — not just on the source branch.

## Feature branch workflow

```
main          ──────────────────────────────────►
                \                        ↑
feat/ansible    ─────────────────────────── merge when complete
```

- Work happens on the feature branch
- Only merge to `main` when the feature is complete and validated
- Use cherry-pick for isolated, dependency-free commits (docs, hotfixes) that
  are ready before the feature is done

## Related

- [Conventional Commits](conventional-commits.md)
- [Repo Validation](repo-validation.md)
