#!/usr/bin/env sh
# Icarus plugin installer for Hermes agents.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/esaradev/icarus-plugin/feat/wiki-v1.1/install.sh | sh
set -eu

REPO="${ICARUS_REPO:-https://github.com/esaradev/icarus-plugin.git}"
BRANCH="${ICARUS_BRANCH:-feat/wiki-v1.1}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DIR="$HERMES_HOME/plugins/icarus"
FABRIC_DIR="${FABRIC_DIR:-$HOME/fabric}"

ok()   { printf "  ok    %s\n" "$1"; }
warn() { printf "  warn  %s\n" "$1"; }
fail() { printf "  fail  %s\n" "$1" >&2; exit 1; }

printf "icarus plugin installer\n"
printf "  hermes home: %s\n" "$HERMES_HOME"
printf "  plugin dir:  %s\n" "$PLUGIN_DIR"
printf "  fabric dir:  %s\n" "$FABRIC_DIR"
printf "  branch:      %s\n\n" "$BRANCH"

[ -d "$HERMES_HOME" ] || fail "Hermes not found at $HERMES_HOME. Install Hermes first: https://github.com/NousResearch/hermes-agent"
command -v git >/dev/null 2>&1 || fail "git is required"

if [ -d "$PLUGIN_DIR" ]; then
  if [ -d "$PLUGIN_DIR/.git" ]; then
    ( cd "$PLUGIN_DIR" \
      && git fetch --quiet origin "$BRANCH" \
      && git checkout --quiet "$BRANCH" \
      && git pull --quiet --ff-only origin "$BRANCH" ) \
      || fail "git update failed in $PLUGIN_DIR"
    ok "updated existing plugin"
  else
    fail "$PLUGIN_DIR exists but is not a git checkout. Back it up and rerun."
  fi
else
  mkdir -p "$HERMES_HOME/plugins"
  git clone --quiet --branch "$BRANCH" "$REPO" "$PLUGIN_DIR" || fail "clone failed"
  ok "cloned plugin"
fi

if [ -e "$HERMES_HOME/plugins/icarus.disabled" ]; then
  warn "found icarus.disabled alongside new plugin — Hermes loads from icarus/"
fi

mkdir -p "$FABRIC_DIR"
if command -v python3 >/dev/null 2>&1; then
  PLUGIN_DIR="$PLUGIN_DIR" FABRIC_DIR="$FABRIC_DIR" python3 - <<'PY' >/dev/null 2>&1 \
    && ok "wiki scaffolded at $FABRIC_DIR/wiki" \
    || warn "wiki scaffold skipped (run 'use wiki_init' inside Hermes)"
import importlib.util, os, sys
from pathlib import Path
base = Path(os.environ["PLUGIN_DIR"])
spec = importlib.util.spec_from_file_location("icarus_wiki", base / "wiki.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["icarus_wiki"] = mod
spec.loader.exec_module(mod)
mod.init_wiki(Path(os.environ["FABRIC_DIR"]))
PY
else
  warn "python3 not found — run 'use wiki_init' inside Hermes once installed"
fi

version=$(awk -F'[[:space:]]+' '/^version:/ {print $2; exit}' "$PLUGIN_DIR/plugin.yaml" 2>/dev/null || echo "?")
printf "\ninstalled icarus %s\n\nnext:\n" "$version"
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  printf "  1. export OPENROUTER_API_KEY=sk-or-...   # enables LLM entity extraction\n"
  printf "  2. restart Hermes, then: use wiki_llm_status\n"
else
  printf "  1. restart Hermes, then: use wiki_llm_status\n"
fi
printf "\nfabric:  %s\nwiki:    %s/wiki\n" "$FABRIC_DIR" "$FABRIC_DIR"
