#!/usr/bin/env bash
set -euo pipefail

# Refuse AI attribution in a commit message.
#
# Rewritten 2026-09-12. The previous version matched three phrases and let the
# case that actually happened straight through: a `Claude-Session:` trailer with
# a session URL under it, which reached the published history of this repository
# and of the homelab one. Two separate faults, and the second is the one worth
# remembering - no commit-msg hook was installed on the workstation, so this
# script had never run at all. A gate nobody installed is indistinguishable from
# a gate nobody wrote.
#
# Usage:
#   commit-msg-lint.sh "<message>" | <file>      # git commit-msg hook, and CI
#   commit-msg-lint.sh --attribution-only ...    # same rules; kept for symmetry
#                                                # with the homelab repository,
#                                                # where the other rule is format
#
# WHAT THIS DOES NOT BLOCK, and the reason is this repository's subject matter.
# Claude Code, the Anthropic API, aider and Copilot are things these notes are
# *about*: operations/claude-code-hooks.md, ai/local-llm-coding-fallback.md, and
# a commit scoped `docs(claude)` all predate this check. Naming a tool in a
# subject that describes a note about that tool is documentation.
#
# What is forbidden is marking the work as produced by one: a trailer under a
# commit, a session URL, a "generated with" line. The homelab repository draws
# the line further out, because there the tooling is infrastructure rather than
# a topic; here it would reject half the legitimate history.

if [[ "${1:-}" == "--attribution-only" ]]; then
    shift
fi

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

fail() {
    echo "ERROR: commit messages must not carry AI attribution." >&2
    echo "Naming a tool the notes are about is fine; marking the work as" >&2
    echo "produced by one is not. See the Commit Policy in CLAUDE.md." >&2
    echo "" >&2
    echo "Offending line(s):" >&2
    printf '  %s\n' "$1" >&2
    exit 1
}

# 1. Attribution trailers. Enumerated rather than pattern-matched on "any
#    Key: value", because this repository's notes legitimately contain lines of
#    that shape inside fenced examples.
TRAILERS='^[[:space:]]*(co-authored-by|claude-session|assisted-by|generated-by|ai-session)[[:space:]]*:'
if MATCH="$(printf '%s' "$BODY" | grep -inE "$TRAILERS" | head -3)"; then
    fail "$MATCH"
fi

# 2. A link into an assistant session or console. This is what leaked, and it is
#    the hardest form to argue is anything but attribution.
URLS='claude\.ai|anthropic\.com|chat\.openai\.com|chatgpt\.com|copilot\.microsoft\.com'
if MATCH="$(printf '%s' "$BODY" | grep -inE "$URLS" | head -3)"; then
    fail "$MATCH"
fi

# 3. The stock phrasings.
PHRASES='generated with|ai assistant|ai-generated|written by (claude|chatgpt|an ai)|with the help of (claude|chatgpt|an ai)'
if MATCH="$(printf '%s' "$BODY" | grep -inE "$PHRASES" | head -3)"; then
    fail "$MATCH"
fi

# 4. The robot emoji the usual generated trailer opens with, matched by code
#    point so this file stays plain ASCII - the repository's own punctuation
#    workflow scans .sh files and would reject the character itself.
if printf '%s' "$BODY" | grep -qP '\x{1F916}'; then
    fail "(robot emoji)"
fi

exit 0
