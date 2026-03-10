#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

assert_json_valid "$REPO_ROOT/.claude-plugin/plugin.json"
assert_json_valid "$REPO_ROOT/hooks/hooks.json"
assert_json_valid "$REPO_ROOT/settings.json"
