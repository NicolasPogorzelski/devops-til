# CLAUDE.md — devops-til

This repo is a learning journal for a DevOps career transition.
Homelab infrastructure: ~/git/homelab-server-architecture

## Prüfungsmodus

Triggered when the user writes "Prüfungsmodus" (optionally followed by topic keywords).

**Topic selection:**
- "Prüfungsmodus" alone → read all TIL files, pick questions from the entire repo;
  weight older entries higher (they fade first)
- "Prüfungsmodus: hooks" → only that topic
- "Prüfungsmodus: hooks tailscale" → mix questions from both topics

**Procedure:**
1. Read the relevant TIL file(s) from this repo and ~/git/homelab-server-architecture as needed.
2. Ask questions one at a time. Wait for the answer before asking the next.
3. Evaluate critically:
   - Correct: confirm, move on.
   - Partially correct: point out what's missing, ask a follow-up — don't give the answer yet.
   - Wrong: ask "bist du sicher?" once. If still wrong, explain.
4. After 5-10 questions: verbal summary — what was solid, what needs review.

**Rules:**
- No hints unless the user explicitly asks.
- Question types: What does it do? Why this approach and not X? What breaks if you do Y instead?
- Mix conceptual and practical questions.
- Do NOT write anything to TIL files based on quiz results — weak points are stated verbally only.
- Language: Deutsch, unless the user switches.
