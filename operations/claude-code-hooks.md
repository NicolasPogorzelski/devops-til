# Claude Code Hooks

Hooks are shell commands that Claude Code runs automatically at specific lifecycle events.
They let you enforce workflow rules without relying on memory or habit.

## Hook Events

| Event | Fires | Common Use |
|---|---|---|
| `SessionStart` | When a session opens | Inject context (branch, recent commits) |
| `PreToolUse` | Before a tool runs | Block commits on validation failure |
| `PostToolUse` | After a tool succeeds | Auto-format files after edits |
| `Stop` | When Claude's turn ends | Reminders, post-session tasks |
| `UserPromptSubmit` | When user submits a message | Enforce learning rules |

## Hook Input

Every hook receives a JSON payload on stdin:

```json
{
  "session_id": "abc123",
  "tool_name": "Bash",
  "tool_input": { "command": "git commit -m ..." },
  "tool_response": { ... }
}
```

Extract values with `jq` (if installed):
```bash
jq -r '.tool_input.command'
```

Or with `python3` (always available):
```bash
python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))"
```

- `json.load(sys.stdin)` - parses the full JSON payload from stdin into a dict.
- `.get('tool_input', {})` - safe key access: returns `{}` instead of crashing on a missing key.
- `.get('command', '')` - extracts the command string; falls back to empty string if absent.
- Prefer python3 over raw `grep` on stdin: raw grep reads unstructured JSON text and breaks
  if the runtime unicode-escapes the string (e.g. `Co-Authored-By`).

## Hook Output

Hooks can return JSON to control Claude's behavior:

```json
{ "continue": false, "stopReason": "Reason shown to Claude" }
```

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Text injected into Claude's context"
  }
}
```

**`continue: false`** blocks the action (commit is not made, tool does not run).
**`additionalContext`** injects text that Claude sees but the user does not - useful for enforcing
behavioral guidelines without visible interruption.

## Settings File Locations

| File | Scope | Commit? |
|---|---|---|
| `~/.claude/settings.json` | Global - all projects | No (personal) |
| `.claude/settings.json` | Project - all users | Yes |
| `.claude/settings.local.json` | Project - this machine only | No - gitignore it |

Use `settings.local.json` for hooks that contain absolute paths (they vary per machine).
Store a sanitized reference in the repo for reproducibility.

## Structure

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "jq -r '.tool_input.command' | grep -q 'git commit' && ./scripts/validate-repo.sh || true"
      }]
    }]
  }
}
```

The outer array is a list of matchers. Each matcher has its own `hooks` array.
`matcher` is a `|`-separated list of tool names: `"Write|Edit"`, `"Bash"`, etc.

## Conditional Execution: the if Field

Add `"if"` to a hook to restrict when it fires within a matcher.
Without `if`, the hook fires for every tool call that matches the matcher.

```json
{
  "matcher": "Bash",
  "hooks": [{
    "type": "command",
    "if": "Bash(git commit *)",
    "command": "..."
  }]
}
```

Syntax: `Bash(<glob>)`. The glob is matched against the full bash command string.
`*` matches any suffix. The hook only fires when the command matches.

Use `if` when you want a `Bash` hook for specific subcommands (e.g. `git commit`)
without blocking the entire Bash tool.

## Defense-in-Depth Pattern

Local hooks = early warning. Remote branch protection = unbypassable enforcement.

Local hook on `git commit` -> runs `validate-repo.sh` -> blocks if it fails.
GitHub Branch Protection -> requires PR + passing CI -> blocks force-push and direct push to main.

Neither alone is sufficient:
- Local hook can be bypassed with `--no-verify`.
- GitHub protection only catches it at push time, not commit time.

## Stop Hook: systemMessage Pattern

`Stop` fires when Claude's turn ends. The only supported output is `systemMessage` -
a visible banner shown to the user.

**`additionalContext` on Stop does not fail validation - it means "continue".** This
paragraph used to say the output was rejected and the hook silently skipped. Measured
2026-09-17 on Claude Code 2.1.274: a Stop hook answering
`{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "..."}}` re-invoked
the model at every turn end, five turns in a row with no user input, each one another copy
of the reminder, until the entry was removed from the settings file. The hooks reference
lists Stop among the events that can block, and "block" on Stop is defined as "prevents
Claude from stopping, continues the conversation" - additionalContext lands in the same
place. A reminder must therefore be a `systemMessage`; verified the same day to show once
and let the session end. The homelab repository's own `hooks-reference.json` carried the
looping form for a month, which nobody noticed because no machine had installed it.

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "printf '{\"systemMessage\": \"SESSION-END CHECKLIST\\n1. Doku aktualisieren\\n2. commit + push\\n3. devops-til: push\"}'",
        "statusMessage": "Session-Ende Checkliste"
      }]
    }]
  }
}
```

- `systemMessage` - shown as a visible banner in the UI at the end of Claude's turn.
- `\n` inside the printf string - produces newlines in the rendered message.
- `statusMessage` - text shown in the spinner while the hook command is running.
- `Stop` has **no matcher** - there is no tool to match against.

## Hook Fatigue

More hooks is not better. Each hook that fires on every action adds noise and latency.

Principles:
- One hook per concern.
- Only run when the event is relevant (guard by matcher, not by checking inside the command).
- Prefer `PreToolUse` + matcher over checking command text inside the hook.

## SessionStart: Dynamic Context Injection

`SessionStart` fires once when the session opens, before any user prompt.
Use it to inject repo state so Claude has context without being told explicitly.

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "python3 -c \"import subprocess,json; log=subprocess.check_output(['git','log','--oneline','-5'],cwd='/path/to/repo').decode().strip(); branch=subprocess.check_output(['git','branch','--show-current'],cwd='/path/to/repo').decode().strip(); print(json.dumps({'hookSpecificOutput':{'hookEventName':'SessionStart','additionalContext':'Branch: '+branch+chr(10)+'Recent commits:'+chr(10)+log}}))\"",
        "statusMessage": "Loading repo state..."
      }]
    }]
  }
}
```

Line by line:
- `subprocess.check_output(['git','log','--oneline','-5'], cwd='/path/to/repo')` - runs the git command as a list (no shell injection risk). `cwd` sets the working directory explicitly so the hook works regardless of where Claude Code was launched.
- `.decode().strip()` - converts the bytes return value to a string and removes the trailing newline.
- `chr(10)` - newline character via Python expression. Avoids shell quoting conflicts inside an already-quoted one-liner string.
- `json.dumps({...})` - serializes the dict to valid JSON. `print()` writes it to stdout where the hook runtime reads it.
- `hookEventName: 'SessionStart'` - required in the `hookSpecificOutput` envelope so the runtime routes it correctly.
- `additionalContext` - injected into Claude's system context at session start. Not visible to the user.

`SessionStart` has no `matcher` - there is no tool to match against.

This hook belongs in `settings.local.json` because the `cwd` path is machine-specific.

## Reproduction Pattern

When `settings.local.json` has machine-specific paths:
1. Use a `<repo-path>` placeholder in the committed reference.
2. Render to `.claude/settings.local.json` via `sed` during setup.
3. The `dotfiles` repo installs this via `install.sh`.

```bash
sed "s|<repo-path>|$REPO_PATH|g" templates/homelab-settings.local.json \
  > "$REPO_PATH/.claude/settings.local.json"
```

For single-machine personal setups, hardcoding the absolute path directly in
`settings.local.json` is acceptable - the placeholder pattern matters when sharing
across team members or machines where the repo path differs.

## Whether Hooks Hot-Reload Is a Measurement, Not a Fact

This section used to state that a running session reads its hooks at startup and holds
them until `/hooks` or a restart. Measured 2026-09-17 on 2.1.274, the opposite held for both
files: removing the Stop entry from `settings.local.json` ended a re-invocation loop on the
very next turn, and a regex edited into `~/.claude/settings.json` fired on the next Bash
call. The earlier observation was made on an older version and was not dated, so which
version changed the behaviour cannot be recovered now. The durable lesson is the shape of
the test rather than either answer: after editing a hook, run the one call that must trip it
and read the result, and record the version next to what you saw. A fix that is correct on
disk and a fix that is live are different claims, and only the second is worth writing down.

## Anti-Pattern: git push (or any non-JSON) in a Stop hook

`Stop` fires at the end of **every** assistant turn, not at session end. Two consequences bit a
real setup:

- A `git push origin HEAD` placed in a `Stop` hook ran on every turn - auto-pushing WIP commits
  nobody asked to push.
- A hook's stdout is parsed as JSON control output. `git push` emits human text ("Everything
  up-to-date", "[new branch]", GitHub's PR hint) - **not** JSON - so the harness reported it as a
  hook error *while the push still succeeded*. That is the exact "it errors but goes through
  anyway" symptom.

Fixes: put run-once session-end logic on `SessionEnd`, not `Stop`; never emit non-JSON from a
hook; and make `git push` a **deliberate** action, not an automatic one. A reminder to push
(a `systemMessage` in the checklist) is the professional substitute for auto-push.

## Scope commit gates with `if:`, not a substring

A `PreToolUse`/`Bash` gate that decides with `case "$CMD" in *"git commit"*)` fires on **any**
command that merely contains the string - a `grep`, an `echo`, a `git log` showing a commit
message. Use the harness filter `"if": "Bash(git commit *)"` on the hook instead: it does
shell-aware matching (including sub-commands of `a && git commit ...`) and only runs on real commit
invocations. See *Conditional Execution: the if Field* above.

**With one documented hole, measured 2026-09-17.** A command containing `$VAR`, `$()` or
backticks runs an `if`-filtered hook regardless of the pattern, because the harness cannot
tell what the expansion is. The global Co-Authored-By hook, filtered exactly this way, denied
a test loop whose command carried a `"$m"` and the trailer text in a `printf` - no commit
anywhere in it. So `if:` narrows the common case and the hook body still has to decide the
uncommon one. That is why the homelab guard matches in the script and not in a filter: the
decision has to live in the script anyway, and a script can be fed a hand-written payload.
The workaround for a false refusal is to assemble the trigger word from parts (`a=Co-Authored;
b=By`), which is also the workaround for the guard refusing its own file name.

## The hook that never fired: test the regex under the grep the hook will use

The global push-refusal hook greps the command text with an ERE that required, read
literally, `git`, whitespace, anything, whitespace, `push` - two separate whitespace runs.
`git push origin main` has one. The hook matched `git -C <dir> push` and nothing else, and
the message it printed ("git push ist gesperrt") had never been seen on the form it was
written for. The `permissions.deny` rule was doing the work the whole time; the hook was
decoration with a confident name.

Finding it took three attempts, because the first offline test contradicted the live
behaviour: inside the Claude Code Bash tool, `grep` is a **shell function** that redirects to
the harness's bundled `ugrep` (`type -a grep` shows it), and ugrep reads that pattern
differently from GNU grep 3.12 in `/usr/bin`. The function is not exported, so scripts and
hooks run under the system grep - only one-liners typed into the tool do not. Test a regex
for a hook with `/usr/bin/grep`, or `command grep`, never bare `grep` in the tool shell. The
corrected pattern treats `git` as a word, allows any number of arguments inside the same
`;`/`&&`/`|` segment, and then needs `push` as a word:
`(^|[^[:alnum:]_/.-])git([[:space:]]+[^[:space:];&|]+)*[[:space:]]+push([[:space:]]|$)`.
Its one over-match is `git help push`.

The same session measured two more properties of PreToolUse hooks worth pinning: a hook
that exceeds its `timeout` does **not** block the call (the documentation says so), so a
guard's timeout is the width of a bypass, and the homelab guard went from 60 s to 120 s on a
measured 24 s worst case; and a guard invoked by its own absolute path from the tool shell
denies itself when that path holds both words of its pattern (`.../git/.../pre-commit-guard.sh`).

## A symlinked home directory defeats a path-comparing guard

`scripts/hooks/pre-commit-guard.sh` in the homelab repository asks which repository a
command touches and steps aside when the answer is a *different* one. It does that by
comparing two strings: `REPO_ROOT`, derived from the hook's own path with
`cd "$(dirname "$0")/../.." && pwd`, and `git -C <target> rev-parse --show-toplevel`.

On an rpm-ostree system (Bazzite, Silverblue) `/home` is a symlink to `/var/home`, and
`$HOME` is `/home/admin`. `pwd` returns the *logical* path - the one you typed, symlinks
intact - so a hook configured as `/home/admin/git/.../pre-commit-guard.sh` computes
`REPO_ROOT=/home/admin/...`. `rev-parse --show-toplevel` returns the *physical* path,
symlinks resolved: `/var/home/admin/...`. The strings differ, the guard concludes "a
different repository", and a commit on `main` passes silently. Measured, not inferred:

```bash
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"/var/home/admin/git/repo"}' \
  | /home/admin/git/repo/scripts/hooks/pre-commit-guard.sh     # prints nothing: pass
printf '...same payload...' \
  | /var/home/admin/git/repo/scripts/hooks/pre-commit-guard.sh # deny, as intended
```

Two consequences. The absolute path written into `settings.local.json` must be the
physical one (`readlink -f "$HOME/git/repo"`), which is exactly what a template renderer
using `$HOME` does *not* produce - `dotfiles/install.sh` would have installed the
silent variant. And the durable fix belongs in the guard, not in the config: derive
`REPO_ROOT` with `git -C "$(dirname "$0")" rev-parse --show-toplevel` so both sides of
the comparison come from the same resolver. Simulating the hook with a hand-written
stdin payload, as above, is the test; reading the JSON is not.

This is the fourth instance of the pattern this file already records: the notebook had
no `hooks` key at all (2026-08-17), and on 2026-09-17 the gaming PC had none either -
`jq '.hooks' .claude/settings.local.json` printed `null`. A gitignored file is verified
per machine or it is assumed.

One more measured detail from the same day: the guard's "which repository" resolver
prefers an explicit `git -C <dir>` over a leading `cd <dir>`. A heredoc that merely
*quotes* `git -C <target>` in prose therefore retargets the guard to a directory that
does not exist, the fallback treats the command as this repository, and a documentation
edit in the sister repository is refused. Accepted cost, as the script says - the retry
is to put the text in a file and run the file.
