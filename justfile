test:
  test/run.sh

# `claude plugin` writes to the config directory its own environment points at, so
# a machine that sets CLAUDE_CONFIG_DIR needs one pass per directory holding a copy.

# Reinstall the plugin from this checkout.
install:
  #!/usr/bin/env bash
  set -euo pipefail

  reinstall() { # reinstall [env-args...]
    env "$@" claude plugin marketplace update claude-sub
    env "$@" claude plugin uninstall sub@claude-sub || true
    env "$@" claude plugin install sub@claude-sub
  }

  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    echo "==> $CLAUDE_CONFIG_DIR"
    reinstall
    if [ -d "$HOME/.claude" ]; then
      echo "==> $HOME/.claude"
      reinstall -u CLAUDE_CONFIG_DIR
    fi
  else
    echo "==> $HOME/.claude"
    reinstall
  fi
