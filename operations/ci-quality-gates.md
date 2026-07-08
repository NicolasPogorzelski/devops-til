# CI Quality Gates That Actually Gate

## The failure: green because the tests skipped

A test suite that self-skips when its dependencies are missing turns a quality
gate blind. Concrete case: the tests `import` a few runtime modules; the CI job
never installed them, so each test hit `ModuleNotFoundError` and did
`sys.exit(0)`. The pipeline was green — not because the tests passed, but
because they never ran.

**A green pipeline is not a tested pipeline.** "0 tests executed" must be a
failure, not a success.

## Why skip-on-missing-dep is seductive

Self-skipping is a reasonable *local* convenience — run what you can on a laptop
without the full stack. The bug is letting that same escape hatch run in CI,
where the environment is supposed to be complete. Same code, two very different
expectations.

## Fixes, in order of strength

1. **Make the environment complete.** Install the real dependencies in CI so the
   tests actually run. This is the root cause — do this first.
2. **Fail on an empty run.** Assert "at least N tests ran", or use a runner that
   exits non-zero on "collected 0 items".
3. **Separate skip from pass in reporting** so a wall of skips is visible instead
   of blending into green.

## The interpreter-vs-apt trap

A detail that bit here: `actions/setup-python` provides an *isolated*
interpreter that does not see system (`apt`) packages. If the tests need modules
that ship as compiled C extensions (`python3-evdev`, `python3-dbus`,
`python3-gi`), you either:

- `apt-get install python3-*` **and** use the system `python3` (drop
  `setup-python`), or
- `pip install` them under `setup-python`, which recompiles the C extensions —
  slow and flaky.

The rule: match where the dependencies land to which interpreter the tests
invoke.

## Transfer

The same failure class shows up as a linter that isn't installed silently
skipping, a security scan that no-ops when its token is missing, or a smoke test
that returns 0 when the service URL is unreachable. Any gate that cannot do its
job must say so loudly — an unenforced control is worse than no control, because
it looks like coverage.

## Related

- [Repo Validation](repo-validation.md)
- [Claude Code Hooks](claude-code-hooks.md)
