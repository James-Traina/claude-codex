#!/usr/bin/env bash
set -uo pipefail  # -e omitted: sourced by run-all.sh which must not abort on test failures
source "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh"

assert_json_valid "$REPO_ROOT/.claude-plugin/plugin.json"
assert_json_valid "$REPO_ROOT/hooks/hooks.json"
assert_json_valid "$REPO_ROOT/settings.json"
