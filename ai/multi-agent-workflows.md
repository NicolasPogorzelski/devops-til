# Multi-Agent Workflows with Claude Code

## What it is

Claude Code can spawn subagents via the `Agent` tool. Each subagent starts with no memory of the parent conversation, receives a targeted prompt, executes its task (research, code review, repo exploration), and returns results to the orchestrator.

Built-in agent types include:
- **Explore** — read-only repo search, locates files/symbols without polluting the main context window
- **code-review** — independent review pass; no shared reasoning bias with the author
- **general-purpose** — multi-step research across files, docs, web

The `/code-review ultra` slash command launches a multi-agent cloud review of the current branch diff.

## Professional parallel

Multi-agent in Claude Code maps directly to patterns already familiar from DevOps:

| Claude Code | DevOps equivalent |
|---|---|
| Orchestrator spawns two Explore agents in parallel | CI job with parallel stages |
| Each agent starts cold, works independently | Stateless workers, no shared mutable state |
| Results returned to orchestrator for synthesis | Job artifacts collected, pipeline continues |
| Explore agent isolates search output from main context | Separate log stream, not mixed into build output |

The mental model is the same: identify genuinely independent subtasks, run them in parallel, recombine.

## When multi-agent helps

- **Parallel research**: exploring two unfamiliar tools/APIs simultaneously (e.g., AWS provider docs + Proxmox Terraform provider at the same time)
- **Independent review**: code-review agent has no anchoring bias from the implementation session — catches things a tired author misses
- **Context isolation**: large search results from an Explore agent don't bloat the main conversation window
- **Incident simulation**: two agents playing different roles (operator vs. service owner) produce more realistic dialogue

## Why it's not the current priority (as of 2026-06)

The active learning bottleneck is **recall and depth**, not throughput. More parallel agents produce more answers per minute — but only the author's active struggle builds durable mental models.

Specific risks in the current phase:
- Multi-agent further removes Nicolas from the implementation loop, defeating blank-file-first and active-recall goals
- Orchestrating agents is a meta-skill that requires solid baseline knowledge of what the agents are doing — otherwise you can't judge whether their output is correct
- The blank-file-first rule exists precisely because recognition (reading a generated answer) feels like learning but isn't

**Exception that applies now:** `/code-review` after self-written implementations. This is the correct use pattern: author writes, independent agent reviews. The author still did the work.

## When the right time arrives

The correct unlock conditions:

1. **Terraform arc** — exploring AWS provider + Proxmox provider simultaneously is a genuine parallel task. Spawning two Explore agents to map both provider docs while you design the architecture is legitimate parallelization, not a shortcut around learning.

2. **Incident simulation** — once runbooks and architecture knowledge are solid enough to evaluate agent output critically, multi-agent incident drills add value.

3. **Kubernetes arc** — multi-component deployments with genuinely independent configuration domains (control plane, storage, networking) are natural candidates for parallel research agents.

The gate is: *can you tell if the agent's answer is wrong?* If not, you're delegating judgment you don't yet own — that's when multi-agent becomes harmful rather than helpful.

## Practice when the time comes

- Write context-rich prompts for subagents: include system state, constraints, what you've already ruled out. This is the same skill as incident communication and ticket writing — transferable.
- Distinguish genuinely parallel tasks from sequentially dependent ones before spawning. Three agents waiting on each other's output is slower than one.
- Use `Explore` for repo-mapping *while you design*, never *instead of* designing.
