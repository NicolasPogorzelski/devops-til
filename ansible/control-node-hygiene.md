# Ansible Control-Node Hygiene

## The core fact: playbooks run from the working tree, not from a commit

`ansible-playbook playbooks/foo.yml` reads the files **on disk**. Git is not involved. There is no
check that the tree matches a commit, no warning if you are on a feature branch, and no complaint
if three files still contain merge conflict markers.

Consequences:

- A role fixed in the repo has **no effect** until the control node's checkout is updated.
- A control node parked on an old branch silently runs old code against the live fleet, and
  reports success.
- A checkout left mid-merge runs a mixture that corresponds to no commit anywhere.

This is the failure mode behind "we fixed that, why is production still broken?"

## Symptom: a fix exists in git but the fleet does not have it

```bash
# On the control node — where is this checkout, really?
git -C ~/git/<repo> status --short --branch
git -C ~/git/<repo> log --oneline -1
```

`--branch` prints the `## <branch>...<upstream>` header line. `--short` gives two status columns:
index and working tree.

Look for:

| Sign | Meaning |
|---|---|
| `## some-feature...origin/some-feature` | not on `main` — you are running feature code |
| `UU <file>` | **unresolved merge conflict** ("both modified") |
| `.git/MERGE_HEAD` exists | a merge is in progress and was abandoned |
| `?? ansible/` | the directory is untracked here — this branch predates it |

```bash
# Is a merge stuck?
ls .git/MERGE_HEAD 2>/dev/null && echo "merge in progress"

# List only the conflicted paths
git diff --name-only --diff-filter=U
```

`--diff-filter=U` selects **U**nmerged paths — the canonical way to enumerate conflicts.

## The rule

The control node's checkout tracks `main`, and only `main`.

```bash
git -C ~/git/<repo> pull --ff-only
```

`--ff-only` refuses anything that is not a fast-forward. A node that should only *consume* history
must never *invent* a merge commit. If this errors, the node has local commits — investigate, do
not force.

Feature work happens on a workstation. The control node is a deployment surface, not a desk.

## Pre-run check before touching live state

```bash
git -C ~/git/<repo> status --short --branch          # must be a clean main
grep -rlE "^(<<<<<<<|=======|>>>>>>>)" ~/git/<repo>/ansible/   # must print nothing
```

The `^` anchors matter: without them, `=======` matches Markdown heading underlines and any line
of dashes-and-equals in normal prose.

**Why the grep is not redundant with CI:** a repo validator (or a pre-commit hook) catches conflict
markers that reach a *commit*. Nothing catches markers sitting in an *uncommitted working tree* —
and that tree is exactly what Ansible executes.

**Scope it to the directory Ansible actually reads.** Run it over `ansible/`, not the whole repo.
Documentation that *explains* merge conflicts contains the markers as examples, and a check that
cries wolf on a docs file is a check that gets ignored the day it matters. If you must scan the
whole tree, exclude the known offenders explicitly rather than relaxing the pattern.

## Recovering a checkout stuck mid-merge

Order matters. Establish that nothing is unique to this machine **before** changing anything.

```bash
# 1. Is the branch already pushed? (three-dot = symmetric difference)
git rev-list --left-right --count origin/<branch>...HEAD
#    output "0  0"  → 0 behind, 0 ahead → everything is on origin, nothing to lose

# 2. Stashes are local-only and never pushed. Check.
git stash list

# 3. Back up the whole tree including .git, so stash + reflog survive
cp -a ~/git/<repo> ~/backup-<repo>-$(date +%Y%m%d)

# 4. Now it is safe
git merge --abort
git checkout main
git pull --ff-only
```

- `git rev-list --left-right --count A...B` — the **three-dot** form is the symmetric difference:
  left count = commits only in `A`, right = only in `B`. The canonical ahead/behind test.
  (Two-dot `A..B` means "in B, not in A" — a different question.)
- `git merge --abort` restores index and working tree to the pre-merge state and removes
  `MERGE_HEAD`. It discards only the automatic merge resolution, which is reproducible.
- `cp -a` — archive mode: recursive, preserves permissions, timestamps and symlinks, and copies
  `.git/` so stashes and the reflog come along. A `git clone` of the directory would **not** bring
  the stash.

Verify afterwards, do not assume:

```bash
git status --short          # empty
git ls-files --error-unmatch ansible/roles/<role>/tasks/main.yml   # exits 0 if tracked
ls -l ansible/inventory/hosts.yml    # gitignored file still present?
```

`git ls-files --error-unmatch <path>` exits non-zero if the path is **not** tracked. It is the
precise test for "is this file under version control here?".

## Gitignored files are not restored by a checkout

The inventory (`inventory/hosts.yml`) is typically gitignored — it holds real hostnames and IPs.
It lives only on the control node. A branch switch leaves it alone, but a fresh clone will not
have it, and `git clean -x` will delete it. Back it up separately from the repo.

## Related

- [Ansible Configuration](configuration.md)
- [Inventory Groups](inventory-groups.md)
- [Git Branching Patterns](../operations/git-branching.md)
- [CI Quality Gates](../operations/ci-quality-gates.md)
