#!/usr/bin/env bash
set -uo pipefail  # -e omitted: sourced by run-all.sh which must not abort on test failures
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

scripts=(
  "$REPO_ROOT/hooks/session-start.sh"
  "$REPO_ROOT/hooks/user-prompt-submit.sh"
  "$REPO_ROOT/scripts/classify.sh"
  "$REPO_ROOT/scripts/codex-exec.sh"
  "$REPO_ROOT/scripts/token-tracker.sh"
)

for script in "${scripts[@]}"; do
  assert_shebang "$script"
  assert_executable "$script"
  assert_contains "$script" "set -" "$(basename "$script") has set flags"
done
