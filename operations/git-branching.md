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

## Rewriting commit messages with filter-branch

To transform every commit message in a range using a shell command:

```bash
git filter-branch -f --msg-filter '<command>' HEAD~3..HEAD
```

- `--msg-filter '<cmd>'` — runs the command for each commit; stdin = old message,
  stdout = new message; any shell command that reads stdin and writes stdout works
- `-f` — force-overwrites any existing `refs/original/` backup from a prior run
- `HEAD~3..HEAD` — applies only to the last 3 commits; use `--all` for the full history

Example — remove all lines matching a pattern:

```bash
git filter-branch -f --msg-filter 'grep -v "^Signed-off-by:"' HEAD~5..HEAD
```

After rewriting, hashes change. Push requires `--force-with-lease`:

```bash
git push --force-with-lease origin <branch>
```

`--force-with-lease` aborts if someone else pushed since your last fetch.

## Cherry-pick with conflict resolution

When cherry-picking a commit onto a branch whose context lines differ:

```bash
git cherry-pick <hash>
# → CONFLICT in some-file.md

# Resolve conflict manually in the file, then:
git add some-file.md
git cherry-pick --continue --no-edit
```

- `--continue` — resumes after conflicts are resolved and staged
- `--no-edit` — keeps the original commit message without opening an editor

**Common cause:** the commit was made on a branch that diverged from the target.
The patch context (surrounding lines) no longer matches. Resolution: keep the
correct content from both sides, remove the conflict markers.

## Merge conflict resolution workflow

When two branches have diverged (e.g. a long-running feature branch and `main` both
received commits), `git merge` may produce conflicts that must be resolved manually.

### Full workflow

```bash
# 1 — bring main's changes into the feature branch
git merge origin/main

# 2 — identify all conflicted files
git status   # shows "Unmerged paths"

# 3 — find every remaining conflict marker in one pass
grep -rn "<<<<<<\|=======\|>>>>>>>" . --include="*.md" --include="*.yml" 2>/dev/null | grep -v ".git/"

# 4 — resolve each file manually (edit out the markers, keep the right content)

# 5 — stage each resolved file explicitly (not git add -A)
git add <file1> <file2> ...

# 6 — commit the merge (Git auto-generates a merge commit message)
git commit
```

### Anatomy of a conflict marker

```
<<<<<<< HEAD           ← start of YOUR branch's version
content from HEAD
=======                ← separator
content from incoming branch
>>>>>>> origin/main    ← end of incoming branch's version
```

Remove all three marker lines. Keep whichever content is correct, or
write a merged version that combines both sides.

### Common merge strategies

| Situation | Strategy |
|---|---|
| Both sides added different content | Keep both — additive merge |
| HEAD has more detail than incoming | Keep HEAD, integrate additive extras from incoming |
| Incoming has a newer port number / flag | Keep incoming value, discard HEAD's stale one |
| Changelog entries on both sides | Keep both in chronological order |

### Why explicit `git add` per file (not `git add .`)

Staging specific files prevents accidentally committing `.env` files,
build artifacts, or other sensitive files that happen to be in the workdir.
After a merge with many conflicts, the working directory can contain
unexpected state — explicit staging is safer.

### Stray conflict markers

If `<<<<<<< HEAD` and `>>>>>>> origin/main` were removed but `=======` was
left behind, `grep` may miss it depending on the pattern. Always verify by
running `git diff --check` before committing:

```bash
git diff --check
```

This catches leftover conflict markers and trailing whitespace in staged files.

### Merge commit message

A merge commit should explain the resolution strategy, not just list "resolved
conflicts". Useful content: which branch was authoritative for which section,
what was additive, what validation fixes were needed.

### Rename + modify: Git follows renames across a merge

If one branch **renames** a file (`git mv A B`) and the other branch **modifies** the
old path `A`, a merge does not lose the modification and does not conflict on the path.
Git's rename detection maps `A → B` and **replays the other side's edits onto `B`** —
silently (it may not even appear in the "Auto-merging" list). A textual conflict only
arises if both sides changed the *same lines*.

Real example: `main` renamed `roles/ssh-hardening/` → `roles/ssh_hardening/` and
touched the tasks file; a feature branch had added a new task to
`roles/ssh-hardening/tasks/main.yml`. The merge landed that new task in
`roles/ssh_hardening/tasks/main.yml` with no conflict and no mention.

Because it is silent, **verify explicitly** — don't assume a fix survived just because
there was no conflict:

```bash
# confirm the feature-branch change is present at the NEW path
grep -n 'the-thing-i-added' ansible/roles/ssh_hardening/tasks/main.yml
```

This is also why **merge is safer than rebase when the other side did invasive
renames**: a merge resolves the rename-vs-modify interaction once; a rebase replays
each commit and can re-hit it repeatedly across the series.

### Merge vs rebase: decide from the actual overlap

Before integrating a long-running branch, measure how many files both sides touched:

```bash
comm -12 <(git diff --name-only <base> feature | sort) \
         <(git diff --name-only <base> main | sort)
```

`comm -12` prints only lines common to both sorted lists (`-1`/`-2` suppress the
lines unique to each). Many overlapping files → prefer a **merge** (resolve once);
little overlap and you want linear history → **rebase**.

## `origin/main` is a local cache — always fetch first

`git log origin/main` does **not** contact GitHub. It reads a local ref
(`refs/remotes/origin/main`) that was last updated the last time you ran
`git fetch` or `git pull`. If someone merged a PR on GitHub in the meantime,
your local `origin/main` is stale and shows the old state.

Consequence: `git log main..feat/my-branch` can show dozens of commits as
"not yet in main" even though they were already merged remotely.

**Rule:** before comparing branches or opening a PR, always fetch first:

```bash
git fetch origin
git log --oneline origin/main | head -5   # now reflects current remote state
```

`git fetch origin` downloads all updated refs from the remote without touching
your working tree or local branches — safe to run any time.

Diagnostic: the fetch output line `c4be8da..e02cf47 main -> origin/main`
tells you exactly how far your local cache was behind:
- left hash = what you had locally
- right hash = what the remote now is

## Measure ahead/behind before a push or pull — `rev-list --left-right --count`

Before pushing or pulling, know exactly how the two sides diverge. One command
answers it as two numbers:

```bash
git rev-list --left-right --count main...origin/main
# → "0    11"   (left = only local, right = only remote)
```

- **`...` (three dots)** = symmetric difference: commits in exactly one side. This is
  a *different operator* from two-dot `A..B` (commits in B but not A). Mixing them up
  is a classic mistake — `A..B` answers "what would I push", `A...B` answers "how have
  we diverged".
- `--left-right` — tag each commit as left (`<`, only in the first ref) or right (`>`,
  only in the second).
- `--count` — collapse to two integers instead of listing hashes.

Reading the result drives the decision:

| Output | Meaning | Safe action |
|---|---|---|
| `0  N` | local behind by N, no local-only commits | `git pull --ff-only` (fast-forward) |
| `N  0` | local ahead by N | `git push` (fast-forward) |
| `N  M` | **diverged** — both have unique commits | merge or rebase; never `--force` blindly |

## `--ff-only` for a mirror-only branch

A node that is only ever supposed to *mirror* `main` (e.g. an automation control node
that must run committed code, never local edits) should integrate with:

```bash
git pull --ff-only
```

`--ff-only` advances local `main` to the remote **only if** it can be done without a
merge commit — i.e. only when the left count above is `0`. If local has diverged, it
**aborts** instead of silently creating a merge commit. That refusal is the feature:
on a mirror node, a divergence is a bug to investigate, not something to auto-merge.
Verify the precondition first (`0` on the left of the `rev-list` count), then pull.

## `fetch --prune` after a remote branch is deleted

When a PR is merged and its branch deleted on the host, your local
`refs/remotes/origin/<branch>` still lingers — a dead ref pointing at nothing.

```bash
git fetch --prune origin
# → " - [deleted]    (none) -> origin/chore/my-branch"
```

`--prune` removes any remote-tracking ref whose upstream no longer exists. Without it,
stale `origin/*` refs accumulate and `git branch -r` lists branches that are gone.
The local branch (`chore/my-branch`, not `origin/chore/my-branch`) is untouched — delete
that separately with `git branch -d` once its commits are confirmed in `main`.

## Related

- [Conventional Commits](conventional-commits.md)
- [Repo Validation](repo-validation.md)
