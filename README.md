```diff
+                      .
+                     /|\
+                    / | \
+                   /  |  \
+                  /   |   \
+                 / ,--+--, \
+                /,'   |   ',\
!               //  ,--+--,  \\
!              //__/    |    \__\\
-                 \     |     /
-                  \  __|__  /
-                   \/     \/
!                    '.   .'
!                  ____'.'____
!                 /           \
+                /  I C A R U S  \
+               /                 \
+              '~~~~~~~~~~~~~~~~~~~'
```

> **Self-memory and replacement models for Hermes agents.**
>
> *Remember your work. Train your replacement.*

## What Icarus adds

Hermes already has strong per-instance memory and a capable runtime. Icarus adds the layer it doesn't:

- **Cross-instance shared memory** -- agents on different platforms and profiles read each other's work through `~/fabric/`
- **Decision-quality tagging** -- entries carry a `training_value` field (high/normal/low) so noise doesn't pollute training data
- **Training data extraction** -- fabric entries become fine-tuning pairs with quality filtering and pair weighting
- **Model replacement pipeline** -- fine-tune a cheaper model from your agent's own history, eval it, switch to it if it passes

## Install

With Hermes v0.6.0 profiles:

```bash
hermes profile create my-agent
git clone https://github.com/esaradev/icarus-plugin.git
cp -r icarus-plugin ~/.hermes/profiles/my-agent/plugins/icarus
```

Or global (all profiles):

```bash
cp -r icarus-plugin ~/.hermes/plugins/icarus
```

## Verify

Restart Hermes and run `/plugins`:

```
Plugins (1):
  ✓ icarus v0.3.0 (11 tools, 4 hooks)
```

## Tools

### Memory

| Tool | What it does |
|------|-------------|
| `fabric_recall` | Ranked retrieval from shared memory |
| `fabric_write` | Write entries with linking (`review_of`, `revises`, `assigned_to`, `training_value`) |
| `fabric_search` | Keyword grep across all entries |
| `fabric_pending` | Show work assigned to this agent |
| `fabric_curate` | Set training value (high/normal/low) on an entry |

### Training

| Tool | What it does |
|------|-------------|
| `fabric_export` | Export training pairs. Modes: high-precision, normal, high-volume |
| `fabric_train` | Start a Together AI fine-tune from your fabric data |
| `fabric_train_status` | Check job progress, updates model registry on completion |

### Replacement models

| Tool | What it does |
|------|-------------|
| `fabric_models` | List all trained models with eval scores |
| `fabric_eval` | Compare candidate vs base model on fabric-derived eval prompts |
| `fabric_switch_model` | Activate a replacement model if eval passes threshold |

## Hooks

4 automatic hooks fire without the agent calling anything:

- **on_session_start** -- loads SOUL, pending handoffs, recent context, open questions
- **pre_llm_call** -- injects relevant memories when the topic changes
- **post_llm_call** -- captures high-value decisions (requires decision keyword + outcome indicator + >200 chars)
- **on_session_end** -- writes the single best exchange as a session entry (skips thin sessions)

## Builder -> reviewer -> fix

```
# builder finishes work, hands off
fabric_write(type="code-session", summary="rate limiter ready",
             status="open", assigned_to="daedalus")

# reviewer sees it at session start, writes linked review
fabric_write(type="review", summary="found race condition",
             review_of="icarus:a3f29b01")

# builder sees the review, writes linked fix
fabric_write(type="code-session", summary="fixed race condition",
             revises="icarus:a3f29b01")
```

Runtime validation enforces: `type=review` requires `review_of`. `status=open` requires `assigned_to`. Refs must point to entries that exist.

## Memory -> training -> replacement model

```
1. Work normally. The plugin captures decisions and completions automatically.

2. Check readiness:
   fabric_export(mode="high-precision")

3. Fine-tune:
   fabric_train(suffix="my-agent-v2")

4. Check progress:
   fabric_train_status()

5. Evaluate:
   fabric_eval(candidate_model="user/my-agent-v2-abc123")

6. Switch:
   fabric_switch_model(model_id="user/my-agent-v2-abc123")
```

## Profiles (Hermes v0.6.0)

Each profile gets its own isolated plugins directory. Install Icarus per-profile to scope memory capture:

```bash
hermes profile create coder
hermes profile create reviewer --clone
cp -r icarus-plugin ~/.hermes/profiles/coder/plugins/icarus
cp -r icarus-plugin ~/.hermes/profiles/reviewer/plugins/icarus
hermes -p coder chat
hermes -p reviewer chat
```

Both profiles write to the same `~/fabric/`, so the reviewer sees the coder's work and vice versa. Profile isolation applies to config, SOUL, and model settings -- not to the shared memory layer.

## MCP

Hermes v0.6.0 supports `hermes mcp serve` to expose Hermes as an MCP server, and `hermes mcp add` to connect MCP tool servers. Icarus remains a plugin because it needs lifecycle hooks, automatic memory capture, training integration, and model lifecycle logic that MCP doesn't provide. MCP is an interoperability path for connecting Hermes to external tools.

## Fallback models

After switching to a replacement model with `fabric_switch_model`, set the original model as a fallback in `config.yaml`:

```yaml
model: user/my-agent-v2-abc123   # fine-tuned replacement (cheap)
fallback_model:
  provider: openrouter
  model: anthropic/claude-sonnet-4  # original (strong, expensive)
```

Hermes triggers the fallback on rate limits (429), overload (529), service errors (503), and connection failures. This gives you the cost savings of the replacement model with the safety net of the original.

## Training value

Entries carry a `training_value` field: `high`, `normal`, or `low`.

- **high** -- decisions with outcomes, completed reviews, successful fixes
- **normal** -- default for most entries
- **low** -- generic session summaries, conversational exchanges

Export modes:
- `high-precision` -- only high-value + completed + linked reviews
- `normal` -- excludes low-value (default)
- `high-volume` -- everything

## Smoke test

```bash
bash scripts/smoke-handoff.sh
```

## Requirements

- [Hermes](https://github.com/NousResearch/hermes-agent) v0.6.0+
- Python 3.10+
- `TOGETHER_API_KEY` in `.env` (for training/eval tools)
- `~/fabric/` directory (created automatically on first write)

## Files

```
__init__.py           registration (11 tools, 4 hooks)
plugin.yaml           manifest
schemas.py            tool schemas (what the LLM sees)
tools.py              tool handlers
hooks.py              lifecycle hooks
state.py              fabric I/O, model registry, training helpers
fabric-retrieve.py    ranked retrieval with scoring
export-training.py    training pair extraction with quality filtering
scripts/
  eval-replacement.py model comparison eval
  smoke-handoff.sh    end-to-end handoff proof
```

## License

MIT
