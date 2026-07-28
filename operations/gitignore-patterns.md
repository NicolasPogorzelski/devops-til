# .gitignore Patterns: Excluding a Directory vs. Excluding Its Contents

Two forms look interchangeable and are not. Picking the wrong one does not fail
loudly — it fails later, when a negation you added silently does nothing.

## The rule that catches everyone

```gitignore
.claude/            # excludes the DIRECTORY
.claude/*           # excludes its CONTENTS
```

With `.claude/`, git stops descending into the directory at all. Anything under
it is excluded because its *parent* is excluded, and a later negation cannot
bring it back:

```gitignore
.claude/
!.claude/skills/    # has NO effect — the parent is already excluded
```

From `gitignore(5)`:

> It is not possible to re-include a file if a parent directory of that file is
> excluded.

With `.claude/*`, only the direct children are excluded — the `*` does not match
`/` — and the directory itself stays traversable, so negations work:

```gitignore
.claude/*
!.claude/skills/    # works
!.claude/agents/
```

Measured on a throwaway repo, which took under a minute and is worth doing rather
than trusting memory:

| Pattern | `skills/deploy.md` | `settings.local.json` | `todos/cache.json` |
|---|---|---|---|
| `.claude/` + negation | **ignored** | ignored | ignored |
| `.claude/*` + negation | **versionable** | ignored | ignored |

Two details that matter when writing the negation:

- Order is significant. The **last** matching pattern wins, so the negation must
  come *after* the exclusion.
- The trailing `/` in `!.claude/skills/` restricts the match to directories, so a
  file of the same name is not re-included by accident.

## Default-deny for directories a tool writes into

Any directory that a tool manages itself — editor state, agent settings, caches —
will grow files you did not anticipate. Two ways to handle it:

| Approach | Failure mode |
|---|---|
| Denylist (`dir/state.json`, `dir/state.json.bak`, …) | A new file the tool invents lands in the repo. Fails **open**. |
| Allowlist (`dir/*` + explicit `!`) | A file you wanted versioned is silently not. Fails **closed**. |

For anything that might contain paths, tokens or machine-specific config, the
allowlist is the right default: the worst case is "I forgot to add it", not
"I published it".

A real instance: a rule reading `.claude/settings.local.json` matched exactly one
path, so a `settings.local.json.bak-20260720` sitting next to it was untracked
and would have been swept up by the next `git add -A`.

## Answering "why is this file (not) ignored?"

Do not read `.gitignore` and reason about it. Ask git:

```bash
git check-ignore -v <path>
# .gitignore:105:.claude/*    .claude/settings.local.json
#  ^file      ^line ^pattern  ^the path you asked about
```

- `-v` prints source, line number and the matching pattern. Without it you get
  only the list of paths that are ignored.
- **No output means no rule matched** — the file is simply untracked, not ignored.
  Exit code is 1 in that case, which is easy to misread as an error.

## `?? dir/` does not mean the directory is unignored

`git status --short` collapses a directory that contains *only* untracked files
into a single line. One stray file is enough to make the whole directory appear
untracked, which reads as "my ignore rule is broken" when it is not:

```bash
git status --short              # ?? .claude/          (collapsed)
git status --short -uall        # ?? .claude/settings.local.json.bak-20260720
```

`-uall` is short for `--untracked-files=all`. The collapsing exists so that an
untracked `node_modules/` does not flood the output.

## Ignore rules do not apply to tracked files

A `.gitignore` entry only affects files git is not already tracking. If the file
was committed once, it stays tracked and keeps showing up in diffs:

```bash
git ls-files <path>             # empty output = not tracked, rule will apply
git rm --cached <path>          # stop tracking, keep the file on disk
```

Check `git ls-files` *before* concluding that a rule is broken — it separates
"the rule does not match" from "the rule never applied here in the first place".

## Verifying a pattern before committing to it

```bash
t=$(mktemp -d); cd "$t"; git init -q .
mkdir -p dir/keep dir/drop
touch dir/keep/a.md dir/drop/b.json dir/local.json
printf 'dir/*\n!dir/keep/\n' > .gitignore
git status --short -uall
```

Note that git does not track empty directories, so the probe files are required —
without a file inside, a negation on a directory cannot be observed at all.

## Related

- [Git Branching](git-branching.md)
- [Repo Validation](repo-validation.md)
- [Conventional Commits](conventional-commits.md)
