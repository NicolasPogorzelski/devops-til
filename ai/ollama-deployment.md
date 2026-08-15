# Ollama Deployment & Modelfiles

## What Ollama actually is

Ollama is a thin wrapper around `llama.cpp` (and other backends) that exposes a
local HTTP API for running quantized LLMs. Practically, it does three things:

1. Downloads model weights from a registry (defaults to `ollama.com`)
2. Loads models into RAM/VRAM and serves them via HTTP
3. Lets you customize models via a `Modelfile` (think: Dockerfile for LLM configs)

It is a *deployment* tool, not a *training* tool. You pull pre-quantized models
and serve them; you do not fine-tune with Ollama.

## Hardware paths: CUDA, ROCm, CPU

| Backend | Hardware       | Speed (relative)  | Setup pain                                          |
|---------|----------------|-------------------|-----------------------------------------------------|
| CUDA    | NVIDIA GPUs    | 1.0x (baseline)   | Driver + Container Toolkit; well-supported          |
| ROCm    | AMD GPUs       | ~0.5-0.7x of CUDA | `ollama-rocm` package on Arch; spotty per-GPU       |
| CPU     | Any x86_64     | 5-20x slower      | Trivial - but unusable for >7B models               |

For a homelab AI host: NVIDIA + Container Toolkit is the path of least resistance.
Document the hardware path explicitly in the host's node doc so future-you knows
why the binary is `ollama-rocm` instead of `ollama`.

## Modelfile syntax

A Modelfile customizes a base model (different system prompt, different context
window, different inference parameters) without re-downloading the weights.

```
FROM qwen3:8b-q4_K_M

PARAMETER num_ctx 16384
PARAMETER temperature 0.7
PARAMETER top_p 0.9

SYSTEM """
You are a precise technical assistant. Answer in <200 words unless asked for detail.
"""
```

| Directive   | Meaning                                                                           |
|-------------|-----------------------------------------------------------------------------------|
| `FROM`      | Base model to derive from. Must be already pulled (`ollama pull <model>`).        |
| `PARAMETER` | Inference-time parameter. Most common: `num_ctx`, `temperature`, `top_p`.         |
| `SYSTEM`    | System prompt baked into the model. Triple-quoted for multiline.                  |
| `TEMPLATE`  | Override the chat template. Rarely needed; only when porting non-standard models. |

Build the customized model:

```bash
ollama create my-qwen3 -f ./qwen3-16k.modelfile
ollama run my-qwen3
```

## Quantization tags - what `q4_K_M` means

Model tags encode quantization. For Qwen3-8B you might see:

| Tag        | Bits | RAM usage (8B model) | Quality loss vs FP16 |
|------------|------|----------------------|----------------------|
| `q2_K`     | 2    | ~3 GB                | Severe               |
| `q4_0`     | 4    | ~5 GB                | Noticeable           |
| `q4_K_M`   | 4    | ~5 GB                | Small (recommended)  |
| `q5_K_M`   | 5    | ~6 GB                | Very small           |
| `q8_0`     | 8    | ~9 GB                | Negligible           |
| `f16`      | 16   | ~16 GB               | None (baseline)      |

The `_K_M` variants are "K-quantized, medium" - same bit budget as `q4_0` but
with smarter weight grouping. Default to `q4_K_M` unless you have a measurement
showing it's hurting your use case; it's the best quality-per-GB tradeoff.

## Context window - `num_ctx` and the trade-off

`num_ctx` sets the maximum token window the model considers. Doubling it does
not double VRAM, but it scales roughly linearly with KV-cache memory (the per-token
state the model keeps around).

There is a **quality** trade-off most users miss: at very large context sizes,
attention degrades - the model "forgets" details from the middle of long contexts.
For a 8B model, going from 8k -> 128k context typically:

- Increases VRAM usage by 2-6 GB
- Slows generation noticeably (KV cache pressure)
- *Reduces* answer quality on focused tasks (more "lost in the middle")

Right approach: maintain **two variants** per base model - a small-context one
for daily Q&A and a large-context one for "summarize this whole document".
Don't run a single 128k model and use it for everything.

## Bind address - loopback vs Tailscale IP

By default Ollama binds to `127.0.0.1:11434`. To expose it to other hosts on the
Tailnet, override via systemd drop-in:

```bash
systemctl edit ollama.service
```

```ini
[Service]
Environment="OLLAMA_HOST=100.x.y.z:11434"
```

| Variable      | Purpose                                                                 |
|---------------|-------------------------------------------------------------------------|
| `OLLAMA_HOST` | Both server bind address *and* default for the `ollama` CLI client      |

**Gotcha:** when the server binds non-loopback, the local CLI also needs
`OLLAMA_HOST` set in your shell (`export OLLAMA_HOST=100.x.y.z:11434`) - otherwise
`ollama list` connects to the default `127.0.0.1:11434` and reports "connection refused".
Add the export to `~/.bashrc` on the host to avoid re-debugging this every session.

For the loopback-binding rationale and Tailscale Serve as the alternative, see
[Loopback + Tailscale Serve](../networking/loopback-tailscale-serve.md).

## Backend health & failure modes

Two failure modes recur:

1. **GPU went away**: VRAM allocation failed, model unloaded, next request returns
   500. Cause: another process took the GPU, or the driver hung. `nvidia-smi` /
   `rocm-smi` is the first check.
2. **Model not pulled**: `ollama run my-model` returns "model not found" - the
   Modelfile-derived model wasn't created on this host. `ollama list` to verify.

OpenWebUI exhibits a related fail-forward pattern: if the Ollama backend is
unreachable, OpenWebUI still shows the model list (cached) and a chat UI. Sending
a message returns a 500. This is by design - UI stays usable for browsing prior
chats - but it means UI-availability != inference-availability. Monitor both layers.

## Verification commands

```bash
ollama list                     # all locally-available models
ollama ps                       # currently-loaded models (in VRAM)
ollama show <model>             # parameters, template, modelfile
curl http://localhost:11434/api/tags  # raw API check (no client needed)
```

`ollama ps` is the right command to answer "is my GPU actually being used right now".

## Related

- [Loopback Binding + Tailscale Serve](../networking/loopback-tailscale-serve.md)
- [Docker GPU Passthrough](../docker/gpu-passthrough.md)
- [systemd Service Hardening](../linux/systemd-service-hardening.md)
