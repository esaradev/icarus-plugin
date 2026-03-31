# Contributing

## Setup

```bash
git clone https://github.com/esaradev/icarus-plugin.git
cd icarus-plugin
```

No build step. The plugin is pure Python with no dependencies beyond stdlib.

To test with a local Hermes profile:

```bash
hermes profile create dev-test
cp -r . ~/.hermes/profiles/dev-test/plugins/icarus
hermes -p dev-test chat
```

## Testing

```bash
bash scripts/smoke-handoff.sh
```

This proves the full builder -> reviewer -> fix chain end-to-end with temp fabric and temp Hermes homes. No live Hermes or API keys needed.

## Making changes

1. Fork the repo and create a branch.
2. Make your changes. Follow existing patterns in the codebase.
3. Run the smoke test.
4. Open a PR with a clear description of what changed and why.

## Code style

- Python 3.10+ stdlib only. No pip dependencies.
- Tool handlers: `def handler(args: dict, **kwargs) -> str` returning JSON via `_json()`.
- Hook callbacks: return `{"context": "..."}` for prompt injection or `None`.
- Errors: return `{"error": "message"}` JSON, never raise from tool handlers.
- Schema descriptions: be specific about when and how to use the tool. The LLM reads these to decide what args to pass.

## What to work on

**High value:**
- Retrieval quality improvements (scoring, ranking, deduplication)
- Export pair quality (new pair types, better filtering)
- Eval scoring (new metrics, better style matching)

**Welcome:**
- Bug fixes with reproduction steps
- Test coverage for edge cases
- Documentation improvements

**Please discuss first:**
- New tools (open an issue before implementing)
- Changes to the hook lifecycle (affects all agents)
- Schema field additions (affects fabric format compatibility)

## Plugin structure

```
__init__.py      registration (tools + hooks)
schemas.py       tool schemas (what the LLM sees)
tools.py         tool handlers (validation + delegation to state.py)
hooks.py         lifecycle hooks (session capture, context injection)
state.py         all I/O (fabric, registry, retriever, training API)
```

Changes to tool behavior go in `tools.py`. Changes to what gets captured automatically go in `hooks.py`. Changes to fabric I/O, model registry, or training go in `state.py`. Schema changes go in `schemas.py` and must match the handler in `tools.py`.

## Commit messages

Imperative mood, lowercase, no period. Say what changed and why.

```
fix review ranking when query is about the source work
add training_value field to session entries
```
