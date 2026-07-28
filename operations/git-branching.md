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

## Sanitizing an already-public history: what a rewrite reaches

Removing sensitive strings from a repo that is **already public** is not a forward
commit — it is a history rewrite plus cleanup of surfaces git does not own.

**A forward "sanitization commit" removes nothing.** Editing the working tree and
committing the clean version leaves every old value in place: prior commits still
hold it, and the sanitization commit's *own diff* shows the old (`-`) and new (`+`)
line side by side. The diff is the leak.

```bash
git log --all -S'5.8 TB' --oneline   # pickaxe: the value still lives in old commits
```

**`--replace-text` only rewrites blob *content*.** Two other surfaces need their own
flags in the same `filter-repo` run:

```bash
git filter-repo \
  --replace-text    repl.txt \
  --replace-message msg.txt \
  --path-rename old/aux1tb-name.md:new/aux-disk-name.md \
  --force
```

- `--replace-message` — commit *messages* (a message like "rename the size-revealing
  disk label" re-leaks the strategy; `--replace-text` never touches messages)
- `--path-rename` — *filenames* (a size-encoding name like `aux1tb-failure.md` stays
  in history; content replacement cannot rename a path)
- `--force` — required when the repo was **already** filter-repo'd once

Replacement format is `literal==>replacement`, applied **sequentially** — put specific
rules before general ones (`aux 1 TB disk` before `1 TB disk`, or the second clobbers
the first into `aux aux disk`).

**Enumerate from the sanitization commit's own diff, then validate against history.**
Its `-` lines are the strings to purge, its `+` lines the replacements. Count each
rule across all history to catch dead rules and collateral:

```bash
git grep -hF "$lhs" $(git rev-list --all) | wc -l
```

The trap is generic tokens: `5.8 TB` is a distinctive leak, but `8 GB` (RAM) and
`~5GB` (a model size) are legitimate and must survive. Scope by phrase, never by a
bare `[0-9]+ ?GB` pattern. Verify the rewritten tip still passes repo validation and
diff it against the pre-rewrite tip — the only changes should be the intended ones.

## A history rewrite does NOT reach GitHub PR metadata

The load-bearing lesson. `git push --force` rewrites the git objects, but **merged
pull-request pages live in GitHub's database, not in git**, and survive untouched:

- PR **titles** and **branch names** (`fix/retro-gaming-samba`) still show
- the PR **"Files changed" / "Commits"** tabs still serve the old diffs
- old commit **SHAs** stay reachable by direct URL until GitHub garbage-collects

Force-push cleans the browsable repo, all clones, blame, and future history — not
those. Fully removing them needs **GitHub Support** or **deleting the repo**; nothing
git-side does it. What you *can* do from the CLI:

```bash
# neutralize a PR title — via REST, because `gh pr edit` can fail on the
# GraphQL "Projects (classic)" deprecation
gh api -X PATCH repos/<owner>/<repo>/pulls/<N> -f title="neutral title"
```

Deleting the head branch does **not** remove its name from the merged-PR page.

**Decision rule for an already-public repo:** a credential leak means a rewrite is
necessary but *not sufficient* — rotate, because it was already public. Non-credential
fingerprint data (capacities, device paths, disk labels) → rewrite + PR-title cleanup
is proportionate, and the closed-PR-diff residual is acceptable. `forkCount == 0`
closes the worst vector — a fork is an independent public copy no rewrite can reach.

## `refs/pull/*/head` — PR refs keep force-pushed commits *reachable*, not just linkable

The section above says old SHAs "stay reachable by direct URL until GitHub garbage-collects".
That undersells it, and the difference decides what you have to do.

**GitHub keeps a real git ref per pull request.** They are not in your clone by default, but they
are fetchable — which means the commits behind them are properly *reachable objects*, not garbage
awaiting collection. Nothing gets GC'd while a ref points at it, and a merged or closed PR still
holds its ref.

Fetch them all and the whole pre-rewrite history reappears locally:

```bash
git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
git rev-list --all | wc -l        # now includes every PR head ever opened
```

This is the forensic move. It also means the reverse: **a force-push to `main` frees nothing** as
long as the PRs referencing those commits exist.

### Answering "which commit introduced this, and what still references it?"

GitHub Support asks for the full SHA of the introducing commit, then checks whether anything else
references it. Produce both yourself:

```bash
# 1. every commit (all refs, PR refs included) whose tree contains the string
git grep -lIiE 'retroarch|roms?|emulator' $(git rev-list --all) -- .

# 2. the commit that FIRST introduced the file
git log --all --diff-filter=A --format='%H %ad %s' --date=short -- path/to/file.md

# 3. what still holds it alive
git for-each-ref --contains <full-sha>          # → refs/remotes/origin/pr/30 … pr/47

# 4. is it reachable from main? (decides whether deleting PRs is enough)
git merge-base --is-ancestor <full-sha> main && echo "on main" || echo "not on main"
```

Step 4 is the one people skip. Two independent copies can exist:

- the **original** commits, unreachable from `main`, held only by PR refs → deleting the PRs plus
  a GC run removes them;
- the **rewritten** commits, reachable from `main` → no PR deletion touches them; only another
  rewrite of `main` does.

Both must be handled, or you pay for a cleanup that leaves the content in place.

### Renaming is not removing

The rewrite that produced my `main` lineage replaced *names* (`retro-gaming` → `storage-stack`,
share `roms` → `media`) and left the substance — a console directory tree and a `firmware` path —
in 74 commits still reachable from `main`. Searching commit *messages* found nothing; grepping
commit *contents* found everything.

**Verify a sanitizing rewrite against file content across all refs, never against subjects:**

```bash
git grep -lIiE '<pattern>' $(git rev-list --all) -- .   # must come back empty
```

## Retiring the pre-rewrite clone

A rewrite leaves a second clone behind — the one still holding the old lineage.
"The remote is the source of truth" is the right default, but it assumes everything
local was pushed. A rewrite breaks that assumption from both sides: the old clone
holds commits the remote no longer has, and the remote holds a lineage the clone has
never seen. Triage before deleting.

### An empty `merge-base` is the unrelated-histories diagnostic

```bash
git status -sb                      # ## main...origin/main [ahead 345, behind 371]
git merge-base main origin/main     # prints nothing
```

`ahead N, behind M` on its own looks like ordinary divergence, and invites a `pull`.
Empty `merge-base` output says there is no common ancestor at all — two unrelated
lineages, which no merge should reconcile. Note the interface: the plain form
communicates by *printing nothing*, only `--is-ancestor` communicates by exit code.
Guard anything consuming it (`xargs -r`, which skips the command on empty input).

### One clone, two lineages — object existence proves nothing

After `git fetch`, the old clone contains **both** lineages. So this test is worthless:

```bash
git cat-file -e <sha>    # true for old AND new commits alike
```

Object existence is not lineage membership. Ask per strand instead:

```bash
git merge-base --is-ancestor <sha> main        && echo "old lineage"
git merge-base --is-ancestor <sha> origin/main && echo "new lineage"
```

Same trap in `git branch -r --contains <sha>`: it searches `refs/remotes/*` only, so it
silently ignores every lineage with no fetched tracking ref — an empty result reads like
"nowhere on the remote" when it means "nowhere I have fetched".

### What would actually be lost

```bash
git diff --diff-filter=D --name-only main origin/main
```

`git diff A B` describes the change *from A to B*, so `--diff-filter=D` ("deleted") lists
files present in A and absent in B — here: present locally, gone from the remote. It finds
whole missing files only; content dropped *inside* a file that still exists does not show up,
so the file-count summary of the full diff stays worth a look.

### Salvage by content, never by commit

Extract with `git show <ref>:<path>` or a plain `git diff > patch`, then re-apply onto a
branch cut from the new lineage. Cherry-picking or merging drags the old lineage's objects
along.

**Never push the old lineage back — not as a branch, and not as a "just in case" tag.**
If the rewrite existed to purge secrets, a tag re-publishes exactly what was removed.
Rotation closes the exploit window; it does not make re-publishing acceptable.

Then delete the clone. It stores the pre-rewrite secrets in plaintext on disk, and a stale
second working copy is precisely the wrong-lineage failure the control-node hygiene entry
describes.

## Keep a private legend, and a guard so it stays private

Sanitizing replaces real values with placeholders; operating the system still needs
the mapping. Keep it in a gitignored file (same pattern as a real inventory or vault
password) — `.gitignore` prevents commits, not disk access, so treat it as a secret:

```gitignore
SANITIZATION-LEGEND.local.md
*.local.md
```

Add repo-validation guards so a stray `git add -f` cannot slip it in, and so the
sanitized-out labels cannot be **reintroduced** later:

```bash
git ls-files --error-unmatch "$rel"        # fail if a *.local.md is tracked
git check-ignore -q "$rel" || grep -niE 'aux[0-9]+tb' "$file"  # skip the legend, flag labels
```

A guard that scans files for a forbidden pattern will match **its own comment** if the
comment spells out an example (`aux01tb`) — word the comment without a literal.

## Ship-then-soak: merge a verified fix now, refactor later

When a bug fix is done on a branch, the instinct is "let it sit on the branch a few
days before merging." Usually wrong. Decide with a checklist, not a feeling:

**Merge to `main` now if** — the fix is verified (ideally on the real target), the
change is isolated, a revert is cheap, and `main` currently holds the *broken* state.
All true → merging replaces "confirmed broken" with "verified better." That **lowers**
risk; it doesn't add it. Sitting on the branch only lets it drift from `main` and grow
a harder merge later (trunk-based development: small verified changes land fast).

**Sit on a branch first only if** — there is no CI, many real users, and expensive
reverts (the "release branch + QA gate" style). A solo/homelab repo rarely qualifies.

**The soak still matters — but on the code you ship, not the branch you're deciding
about.** In a solo repo *you are the CI*: merge, then dogfood `main` for a few days on
the things one session can't cover — cold boot + autostart (not just `systemctl
restart`), suspend/resume, device power-cycle/reconnect, long real sessions. A glitch
→ fix-forward or revert (cheap, because the diff was small).

Footgun that forces the issue: if your **deployed** artifact already runs the branch
code but `git main` doesn't, an innocent reinstall from a `main` checkout silently
rolls back the fix. Keep **git = the running reality**.

**Refactor is a separate branch, after the soak, tests first.** Never bundle a
risky cleanup with a fix you want to ship fast — different risk profiles, keep them
independently revertable. A refactor claims to be *behaviour-preserving*; you can only
claim that if tests pin the behaviour **before** the code moves. So: harden tests →
green → remove the now-dead complexity → green. Leave a WIP plan note on the refactor
branch so the "later" version of you knows exactly where to resume.

```bash
git checkout main
git merge --ff-only fix/whatever      # ff when main hasn't moved since branching
git branch -d fix/whatever            # -d refuses if not merged (safety)
# …soak main a few days…
git checkout -b refactor/whatever     # separate branch, tests-first, when calm
```

## Related

- [Conventional Commits](conventional-commits.md)
- [Repo Validation](repo-validation.md)
- [DualSense Lightbar: LED Class vs. Raw HID](../linux/dualsense-lightbar-hid.md) — the
  fix whose ship-then-soak-then-refactor rollout this pattern came from
