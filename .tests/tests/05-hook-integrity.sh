#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

# hooks.json must have description field
assert_contains "$HOOKS_JSON" '"description"' "hooks.json has description field"

# Both hook events must be present
assert_contains "$HOOKS_JSON" '"SessionStart"' "hooks.json has SessionStart"
assert_contains "$HOOKS_JSON" '"UserPromptSubmit"' "hooks.json has UserPromptSubmit"

# matcher must be present
assert_contains "$HOOKS_JSON" '"matcher"' "hooks.json has matcher fields"

# timeout must be present
assert_contains "$HOOKS_JSON" '"timeout"' "hooks.json has timeout fields"

# Referenced scripts must exist and be executable
assert_executable "$REPO_ROOT/hooks/session-start.sh"
assert_executable "$REPO_ROOT/hooks/user-prompt-submit.sh"
