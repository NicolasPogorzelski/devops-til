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

Extract values with `jq`:
```bash
jq -r '.tool_input.command'
```

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
**`additionalContext`** injects text that Claude sees but the user does not — useful for enforcing
behavioral guidelines without visible interruption.

## Settings File Locations

| File | Scope | Commit? |
|---|---|---|
| `~/.claude/settings.json` | Global — all projects | No (personal) |
| `.claude/settings.json` | Project — all users | Yes |
| `.claude/settings.local.json` | Project — this machine only | No — gitignore it |

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

Local hook on `git commit` → runs `validate-repo.sh` → blocks if it fails.
GitHub Branch Protection → requires PR + passing CI → blocks force-push and direct push to main.

Neither alone is sufficient:
- Local hook can be bypassed with `--no-verify`.
- GitHub protection only catches it at push time, not commit time.

## Stop Hook: Two Output Patterns

`Stop` fires when Claude's turn ends. Two output patterns exist for different audiences:

### systemMessage — visible to the user

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

- `systemMessage` — shown as a visible banner in the UI at the end of Claude's turn.
- `\n` inside the printf string — produces newlines in the rendered message.
- `statusMessage` — text shown in the spinner while the hook command is running.
- `Stop` has **no matcher** — there is no tool to match against.

### additionalContext — injected into Claude's context only

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "printf '{\"hookSpecificOutput\": {\"hookEventName\": \"Stop\", \"additionalContext\": \"Reminder: run quiz before switching topics.\"}}'",
        "statusMessage": "Context injected"
      }]
    }]
  }
}
```

- `hookSpecificOutput` wrapper with `hookEventName` — required envelope for context injection.
- `additionalContext` — injected into Claude's system context. **Not visible to the user.**

### When to use which

| Pattern | Audience | Use case |
|---|---|---|
| `systemMessage` | User | Checklists the user must act on |
| `additionalContext` | Claude | Behavioral reminders Claude should follow |

Both can run simultaneously from different settings files (e.g. project `settings.local.json` uses
`systemMessage` for the user checklist; global `settings.json` uses `additionalContext` to remind
Claude of session-end procedures). Both Stop hooks fire; outputs are independent.

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
- `subprocess.check_output(['git','log','--oneline','-5'], cwd='/path/to/repo')` — runs the git command as a list (no shell injection risk). `cwd` sets the working directory explicitly so the hook works regardless of where Claude Code was launched.
- `.decode().strip()` — converts the bytes return value to a string and removes the trailing newline.
- `chr(10)` — newline character via Python expression. Avoids shell quoting conflicts inside an already-quoted one-liner string.
- `json.dumps({...})` — serializes the dict to valid JSON. `print()` writes it to stdout where the hook runtime reads it.
- `hookEventName: 'SessionStart'` — required in the `hookSpecificOutput` envelope so the runtime routes it correctly.
- `additionalContext` — injected into Claude's system context at session start. Not visible to the user.

`SessionStart` has no `matcher` — there is no tool to match against.

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
`settings.local.json` is acceptable — the placeholder pattern matters when sharing
across team members or machines where the repo path differs.
