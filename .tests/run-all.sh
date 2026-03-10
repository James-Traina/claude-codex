#!/usr/bin/env bash
# claude-codex QA Suite
# Run all structural tests.
#
# Usage:
#   bash .tests/run-all.sh           # Run all tests
#   bash .tests/run-all.sh 03        # Run test group 03 only
#   bash .tests/run-all.sh --list    # List all test groups
#
set -uo pipefail  # -e deliberately omitted: test functions return non-zero on failure

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
REPORTS_DIR="$TESTS_DIR/reports"
mkdir -p "$REPORTS_DIR"

REPORT_FILE="$REPORTS_DIR/report-$(date +%Y%m%d-%H%M%S).log"

PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}  ✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  ✗${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  ○${NC} $1 (skipped)"; SKIP=$((SKIP + 1)); }

export -f pass fail skip
export PASS FAIL SKIP REPO_ROOT

if [[ "${1:-}" == "--list" ]]; then
  echo "Available test groups:"
  for f in "$TESTS_DIR/tests"/[0-9]*.sh; do
    name=$(basename "$f" .sh)
    echo "  $name"
  done
  exit 0
fi

FILTER="${1:-}"
TEST_GROUPS=()
for f in "$TESTS_DIR/tests"/[0-9]*.sh; do
  name=$(basename "$f" .sh | cut -d- -f1)
  if [[ -z "$FILTER" || "$name" == "$FILTER" ]]; then
    TEST_GROUPS+=("$f")
  fi
done

if [[ ${#TEST_GROUPS[@]} -eq 0 ]]; then
  echo "No test groups match: $FILTER"
  exit 1
fi

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${TEST_GROUPS[@]}"; do
  group_name=$(basename "$group" .sh)
  echo ""
  echo "── $group_name ──────────────────────────────"
  PASS=0; FAIL=0; SKIP=0
  # shellcheck source=/dev/null
  source "$group"
  TOTAL_PASS=$((TOTAL_PASS + PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
done

echo ""
echo "═══════════════════════════════════════════"
echo "Results: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed"

if [[ $TOTAL_FAIL -gt 0 ]]; then
  exit 1
fi
