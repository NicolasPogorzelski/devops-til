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

## Branch Deletion: `-d` vs `-D`

```bash
git branch -d feat/my-feature   # safe: blocks if not fully merged
git branch -D feat/my-feature   # force: deletes regardless
```

`-d` checks whether all commits on the branch are reachable from another branch
(typically `main`). If not, it refuses — preventing accidental data loss.

`-D` skips that check. Use it only when you are certain the content is already
in another branch (e.g., it was merged via a squash merge or history was rewritten).

## filter-repo: side effects of broad replacement patterns

`git filter-repo --replace-text replacements.txt` rewrites every commit that
contains a matched string. A pattern that is too broad will hit unintended content.

Example: replacing `Nicolas` → `Operator` to remove a first name also rewrites
`Nicolas Pogorzelski` in README.md — turning the author attribution into
"Operator Pogorzelski".

**Rule:** review the diff on a test clone before force-pushing. After running
filter-repo, check:

```bash
git log --all --oneline | head -20
git diff <old-tip> HEAD -- README.md   # compare against pre-rewrite tip
```

After a history rewrite, old local branches (including `feat/*`) have hashes
that no longer match `main`. Git considers them "not fully merged" even if the
content is identical. Delete them with `-D`, not `-d`:

```bash
git branch -D feat/old-branch
```

## git restore: discarding unstaged changes

`git restore <file>` discards all unstaged changes in a file and restores it to the last committed state.

```bash
git restore docker/jellyfin/docker-compose.yml
```

- Only affects **unstaged** changes (not staged, not committed)
- Irreversible — no undo
- Does not affect commits already in the log; those are pushed separately

Contrast with:

| Command | What it touches |
|---|---|
| `git restore <file>` | Unstaged changes in working tree |
| `git restore --staged <file>` | Staged (index) → back to unstaged |
| `git reset --hard` | Everything — staged + unstaged (destructive) |

Use `git status` to verify the working tree is clean afterwards.

## Related

- [Conventional Commits](conventional-commits.md)
- [Repo Validation](repo-validation.md)
