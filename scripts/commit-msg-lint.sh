#!/usr/bin/env bash
# Reject AI/assistant attribution in commit messages.
#
# Usage:
#   ./scripts/commit-msg-lint.sh "docs(linux): capture cgroup v2 notes"
#   ./scripts/commit-msg-lint.sh path/to/commit-msg-file
#
# As a git hook (.git/hooks/commit-msg):
#   #!/usr/bin/env bash
#   exec "$(git rev-parse --show-toplevel)/scripts/commit-msg-lint.sh" "$1"
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<commit message>\" | <commit-msg-file>" >&2
    exit 2
fi

# Accept either a literal message or a path to a message file.
if [[ -f "$1" ]]; then
    BODY="$(cat "$1")"
else
    BODY="$1"
fi

# No AI / assistant attribution anywhere in the message.
if printf '%s' "${BODY}" | grep -qiE 'co-authored-by:.*(claude|anthropic|gpt|copilot|gemini)|generated with|ai assistant'; then
    echo "ERROR: commit messages must not contain AI/assistant attribution" >&2
    exit 1
fi

exit 0
