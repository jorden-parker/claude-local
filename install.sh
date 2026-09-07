#!/usr/bin/env bash
# One-shot setup for claude-local. Safe to re-run.
#   ./install.sh            full setup, including the ~20 GB model download
#   ./install.sh --no-pull  skip the model download
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

step "launcher"
chmod +x "${REPO_DIR}/claude-local" "${REPO_DIR}/install.sh"

# Prefer a brew-owned dir that is already on PATH; fall back to ~/.local/bin.
BIN_DIR=""
for d in /opt/homebrew/bin "${HOME}/.local/bin"; do
  mkdir -p "$d" 2>/dev/null || true
  if [ -w "$d" ]; then BIN_DIR="$d"; break; fi
done
[ -n "$BIN_DIR" ] || { echo "no writable bin dir found" >&2; exit 1; }
ln -sf "${REPO_DIR}/claude-local" "${BIN_DIR}/claude-local"
echo "linked ${BIN_DIR}/claude-local -> ${REPO_DIR}/claude-local"

# Remove stale links elsewhere so nothing shadows this one.
for d in /usr/local/bin "${HOME}/.local/bin" /opt/homebrew/bin; do
  f="${d}/claude-local"
  [ "$d" = "$BIN_DIR" ] && continue
  [ -e "$f" ] || [ -L "$f" ] || continue
  if [ -w "$d" ]; then
    rm -f "$f" && echo "removed stale ${f}"
  else
    echo "stale ${f} is root-owned; removing with sudo (you may be asked for your password)"
    sudo rm -f "$f" && echo "removed stale ${f}"
  fi
done

step "PATH"
# shellcheck disable=SC2016  # literal $HOME wanted in the rc file
PATH_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
case ":${PATH}:" in
  *":${BIN_DIR}:"*) echo "${BIN_DIR} already on PATH" ;;
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

if [ "$PULL" = 1 ] && command -v rapid-mlx >/dev/null; then
  step "model ${MODEL}"
  if rapid-mlx models --cached --json 2>/dev/null | grep -q "\"${MODEL}\"" \
     || rapid-mlx ls 2>/dev/null | grep -q "${MODEL}"; then
    echo "already downloaded"
  else
    echo "downloading (~20 GB, first time only)"
    rapid-mlx pull "$MODEL"
  fi
fi

step "verify"
found="$("${SHELL:-/bin/zsh}" -lic 'command -v claude-local' 2>/dev/null || true)"
if [ -n "$found" ] && [ -x "$found" ]; then
  echo "ok: a new terminal will find ${found}"
  "$found" status || true
else
  echo "a fresh shell still cannot find claude-local." >&2
  echo "run this in your current terminal and try again:" >&2
  echo "  export PATH=\"${BIN_DIR}:\$PATH\"" >&2
  exit 1
fi

step "done"
echo "Run:  claude-local"
