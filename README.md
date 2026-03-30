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

An agent remembers its useful work, recalls it when it matters, turns that history into training data, and fine-tunes a cheaper replacement model that preserves its style and task knowledge.

## Install

```bash
git clone https://github.com/esaradev/icarus-plugin.git

# global (all agents)
cp -r icarus-plugin ~/.hermes/plugins/icarus

# or per-agent
cp -r icarus-plugin ~/.hermes-YOUR_AGENT/plugins/icarus
```

Restart Hermes. Run `/plugins` to verify:

```
Plugins (1):
  ✓ icarus v0.3.0 (11 tools, 4 hooks)
```

## What it does

**Self-memory** -- the agent captures decisions, completions, and reviews as it works. Low-value chatter is filtered out. High-value entries are tagged for training.

**Recall** -- when the agent starts a session or changes topic, relevant prior work is injected as context. Ranked by keyword match, project affinity, recency, and tier.

**Training** -- fabric entries become fine-tuning pairs. Review-correction and outcome pairs are weighted higher. Export in OpenAI, Together AI, and HuggingFace formats.

**Replacement models** -- fine-tune a cheaper model from the agent's own history, eval it against the original, and switch to it if it passes.

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
- **pre_llm_call** -- injects relevant memories when the topic changes (>60% keyword shift)
- **post_llm_call** -- captures high-value decisions (requires decision keyword + outcome indicator + >200 chars)
- **on_session_end** -- writes the single best exchange as a session entry (skips thin sessions with <2 substantive exchanges)

## Replacement-model workflow

```
1. Work normally. The plugin captures decisions and completions automatically.

2. Check training readiness:
   fabric_export(mode="high-precision")
   → shows pair count and token estimate

3. Start fine-tuning:
   fabric_train(suffix="my-agent-v2")
   → uploads to Together AI, returns job ID

4. Check progress:
   fabric_train_status()
   → updates model registry when done

5. Evaluate the candidate:
   fabric_eval(candidate_model="user/my-agent-v2-abc123")
   → compares against base model on your own eval set

6. Switch if it passes:
   fabric_switch_model(model_id="user/my-agent-v2-abc123")
   → only switches if eval score >= 0.7, backs up .env
```

## Builder -> reviewer -> fix

The plugin supports linked handoff chains:

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

Runtime validation enforces: `type=review` requires `review_of`. `status=open` requires `assigned_to`. `review_of` and `revises` must point to entries that exist.

## Smoke test

```bash
bash scripts/smoke-handoff.sh
```

Proves the full handoff chain end-to-end with temp fabric and temp Hermes homes.

## Training value

Entries carry a `training_value` field: `high`, `normal`, or `low`.

- **high** -- decisions with outcomes, completed reviews, successful fixes. Auto-tagged by hooks when the response contains both a decision keyword and an outcome indicator.
- **normal** -- default for most entries.
- **low** -- generic session summaries, conversational exchanges. Auto-tagged by hooks for thin sessions.

Export modes use this:
- `high-precision` -- only high-value + completed + linked reviews
- `normal` -- excludes low-value (default)
- `high-volume` -- everything

## Requirements

- [Hermes](https://github.com/NousResearch/hermes-agent) v0.5.0+
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
