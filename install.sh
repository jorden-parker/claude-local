#!/usr/bin/env bash
# One-shot setup for claude-local. Safe to re-run.
#   ./install.sh            full setup, including the ~20 GB model download
#   ./install.sh --no-pull  skip the model download
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
MODEL="${CLAUDE_LOCAL_MODEL:-qwen3.8-27b-4bit}"
PULL=1
[ "${1:-}" = "--no-pull" ] && PULL=0

step() { printf '\n==> %s\n' "$*"; }

step "Homebrew"
if ! command -v brew >/dev/null; then
  echo "Homebrew not found. Install it from https://brew.sh then re-run." >&2
  exit 1
fi

step "rapid-mlx"
if command -v rapid-mlx >/dev/null; then
  echo "already installed: $(command -v rapid-mlx)"
elif [ "${CLAUDE_LOCAL_SKIP_BREW:-0}" = "1" ]; then
  echo "skipped (CLAUDE_LOCAL_SKIP_BREW=1)"
else
  brew install rapid-mlx
fi

step "claude"
if command -v claude >/dev/null; then
  echo "already installed: $(command -v claude)"
else
  echo "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code" >&2
fi

step "symlink ${BIN_DIR}/claude-local"
mkdir -p "$BIN_DIR"
ln -sf "${REPO_DIR}/claude-local" "${BIN_DIR}/claude-local"
ls -l "${BIN_DIR}/claude-local"

step "PATH"
# shellcheck disable=SC2016  # literal $HOME wanted in the rc file
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
case ":${PATH}:" in
  *":${BIN_DIR}:"*) echo "already on PATH" ;;
  *)
    RC="${HOME}/.zshrc"
    case "$(basename "${SHELL:-zsh}")" in
      bash) RC="${HOME}/.bashrc" ;;
      fish) RC="" ;;
    esac
    if [ -n "$RC" ] && ! grep -qF "$PATH_LINE" "$RC" 2>/dev/null; then
      printf '\n# claude-local\n%s\n' "$PATH_LINE" >> "$RC"
      echo "added to ${RC}"
    fi
    export PATH="${BIN_DIR}:${PATH}"
    ;;
esac

if [ -e /usr/local/bin/claude-local ]; then
  step "WARNING"
  echo "/usr/local/bin/claude-local exists and will shadow this one on PATH."
  echo "Remove it after checking what it is:  sudo rm /usr/local/bin/claude-local"
fi

if [ "$PULL" = 1 ] && command -v rapid-mlx >/dev/null; then
  step "model ${MODEL} (~20 GB, first time only)"
  rapid-mlx pull "$MODEL"
fi

step "done"
echo "Open a new terminal, then run:  claude-local status"
