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

## Defense-in-Depth Pattern

Local hooks = early warning. Remote branch protection = unbypassable enforcement.

Local hook on `git commit` → runs `validate-repo.sh` → blocks if it fails.
GitHub Branch Protection → requires PR + passing CI → blocks force-push and direct push to main.

Neither alone is sufficient:
- Local hook can be bypassed with `--no-verify`.
- GitHub protection only catches it at push time, not commit time.

## Hook Fatigue

More hooks is not better. Each hook that fires on every action adds noise and latency.

Principles:
- One hook per concern.
- Only run when the event is relevant (guard by matcher, not by checking inside the command).
- Prefer `PreToolUse` + matcher over checking command text inside the hook.

## Reproduction Pattern

When `settings.local.json` has machine-specific paths:
1. Use a `<repo-path>` placeholder in the committed reference.
2. Render to `.claude/settings.local.json` via `sed` during setup.
3. The `dotfiles` repo installs this via `install.sh`.

```bash
sed "s|<repo-path>|$REPO_PATH|g" templates/homelab-settings.local.json \
  > "$REPO_PATH/.claude/settings.local.json"
```
