# Local LLM Coding Fallback (aider + Ollama)

## The problem this solves

When the Claude Pro usage limit hits mid-task, the choice is a forced pause or a
local fallback. A self-hosted coding model on existing hardware (a gaming PC with
a 20 GB AMD GPU) removes the pause. The quality bar is **Sonnet-class for routine
edits**, not Opus — the fallback handles mechanical work (boilerplate, follow-up
files, small refactors), not deep architecture.

The fallback is deliberately a *second-class* path: it keeps the same project
conventions (the `CLAUDE.md` files) but **does not** run the Claude Code hooks.
It is the spare tire, not a replacement engine.

## Architecture

```
Primary:   Claude Code (LXC250)  ── Anthropic API ──> Claude
Fallback:  aider (LXC250)        ── Tailscale ──────> Ollama (gaming PC, RX 7900 XT 20 GB)
```

- **aider** runs on the DevOps workstation LXC (always-on), not on the GPU host.
- **Ollama** runs on the gaming PC, which is brought online on demand (not 24/7).
- The two talk over Tailscale, so no LAN exposure.

## Two ways to point a coding agent at Ollama

| Path | How | Trade-off |
|---|---|---|
| Claude Code → Ollama | Ollama ≥ v0.14 speaks the native Anthropic Messages API. Set `ANTHROPIC_BASE_URL=http://<host>:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, then `claude --model <name>`. Keeps CLAUDE.md + hooks + settings 100%. | Claude Code is tuned for Claude's tool-calling; smaller local models drive it less reliably. |
| **aider → Ollama** (chosen) | aider is a model-agnostic CLI coding agent. Point it via `OLLAMA_API_BASE`. | Reads `CLAUDE.md` as a convention file but does **not** execute hooks. Purpose-built for the edit loop with weaker models. |

aider was chosen because it is built around a strict, model-friendly edit format
and degrades more gracefully on a 24B local model than full Claude Code does.

## The VRAM lever: KV-cache quantization

The hard constraint is **20 GB of VRAM**. Two things compete for it:

1. **Model weights** — fixed once the quant is chosen (Devstral 24B `Q4_K_M` ≈ 14.3 GB).
2. **KV cache** — grows linearly with `num_ctx`. This is the variable that decides
   whether a usable context window fits.

By default the KV cache is `f16` (2 bytes/element). Quantizing it to `q8_0`
(~1 byte/element) **halves** its VRAM cost for a negligible quality hit. This is
what makes a large context fit on a fixed card. It requires Flash Attention.

Set both on the Ollama **server** (systemd drop-in on the GPU host):

```ini
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
```

| Variable | Effect | Why |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION=1` | Enables Flash Attention (memory-efficient attention) | Prerequisite for KV quantization |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | KV cache stored at 8-bit instead of f16 | Halves KV VRAM; `q8_0` is the quality sweet spot (`f16` / `q8_0` / `q4_0`) |

After editing the drop-in: `systemctl restart ollama`, then verify the variables
landed with `systemctl show ollama -p Environment`.

## "Optimal" context = largest fully-resident, not maximum

The instinct is to set `num_ctx` as high as the model supports. That is wrong on a
VRAM-bound card. The moment weights + KV cache exceed VRAM, Ollama offloads layers
to system RAM and tokens/sec collapses. **The optimum is the largest context that
stays 100 % on the GPU.**

Rough KV-cache math for a 24B/40-layer GQA model with `q8_0` (~80 KB/token):

| `num_ctx` | KV cache | Total VRAM (weights + KV + buffers) | Fits 20 GB? |
|---|---|---|---|
| 32768 | ~2.6 GB | ~17 GB (measured) | yes, comfortable |
| 49152 | ~3.9 GB | ~18.5 GB (measured) | yes, ~1.5 GB headroom |
| 65536 | ~5.1 GB | ~19.6 GB (estimated) | on the edge — risks spill |

The number that matters is not the theoretical max but what `ollama ps` and
`/api/ps` report as resident. Pick the largest value that still shows 100 % GPU,
leaving ~1–1.5 GB headroom for the compute graph.

## Verifying residency: `size` vs `size_vram`

`ollama ps` (on the GPU host) shows a `PROCESSOR` column — `100% GPU` is the goal;
any `% CPU` means a spill. From a *remote* host, the same fact is in the API:

```bash
curl -s http://<host>:11434/api/ps | python3 -m json.tool
```

- `size` — total bytes the loaded model needs (weights + KV cache + buffers).
- `size_vram` — how much of that is actually in VRAM.
- **`size_vram == size` → fully resident (100 % GPU). `size_vram < size` → the
  difference is in system RAM (spill).**

A context change (`num_ctx`) forces Ollama to reload the model, so triggering one
chat request at the new `num_ctx` and then reading `/api/ps` confirms the new
footprint without touching the GPU host's shell.

## aider configuration

Two files in `$HOME` (global, so they apply over SSH from any directory):

**`~/.aider.conf.yml`**

```yaml
model: ollama_chat/devstral
set-env:
  - OLLAMA_API_BASE=http://<gpu-host>:11434
read:
  - CLAUDE.md
  - /home/<user>/.claude/CLAUDE.md
```

- `model` — default model. The `ollama_chat/` prefix (not `ollama/`) is
  recommended by aider; it uses the model's chat template.
- `set-env` — aider's way to set env vars from config. `OLLAMA_API_BASE` is the
  endpoint; setting it here avoids a manual `export` every SSH session.
- `read` — read-only context files. The **relative** `CLAUDE.md` resolves against
  the current directory, so it picks up the project's conventions when aider is run
  inside a repo. The **absolute** path loads the global conventions from anywhere.
  Files that don't exist (e.g. relative `CLAUDE.md` outside a repo) are skipped
  gracefully.

**`~/.aider.model.settings.yml`**

```yaml
- name: ollama_chat/devstral
  extra_params:
    num_ctx: 49152
```

- A list of per-model overrides. `name` must exactly match the `model` value, or
  the entry is ignored. `extra_params` are passed straight through to Ollama.
- `num_ctx` — **the most important line.** Without it Ollama uses its default
  (2048) and *silently discards* everything beyond it — the classic "why does the
  model forget the file I just gave it" bug.

## The fallback workflow

1. Bring the GPU host online (it's not 24/7).
2. SSH into the workstation LXC, `cd` into the repo.
3. `aider` — it pulls the model, both `CLAUDE.md` files, and the configured context
   automatically.
4. Non-interactive one-shot is also possible: `aider --message "..." --yes-always --no-auto-commits <file>`.

Most of the handover context already lives in the repo (the `CLAUDE.md` status
block + progress docs), so aider reads the project state itself rather than needing
a long pasted brief.

## Gotchas

- The `ollama` CLI client also reads `OLLAMA_HOST`; when the server binds a
  non-loopback address, the client errors with "could not connect" unless
  `OLLAMA_HOST` is set in the shell too — see
  [Ollama Deployment](ollama-deployment.md#bind-address--loopback-vs-tailscale-ip).
- KV quantization needs Flash Attention; setting `OLLAMA_KV_CACHE_TYPE` without
  `OLLAMA_FLASH_ATTENTION=1` has no effect.
- aider reads `CLAUDE.md` as plain context — it does **not** enforce hooks, so
  machine-enforced rules (commit-message blocks, explain-rule prompts) don't apply
  in the fallback path. Treat its output with that in mind.

## Related

- [Ollama Deployment & Modelfiles](ollama-deployment.md) — Ollama basics, Modelfiles, quant tags, bind address
- [Claude Code Hooks](../operations/claude-code-hooks.md) — the enforcement layer the fallback path lacks
- [Tailscale](../networking/tailscale.md) — the transport between workstation and GPU host
