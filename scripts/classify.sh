#!/usr/bin/env bash
# classify.sh — Classify a user prompt as DELEGATE:<category>:<score>,
#               CLAUDE:<reason>:<score>, or UNSURE:<info>:<score>
#
# Usage: classify.sh "<prompt text>"
# Output: one of:
#   DELEGATE:code-generator:42
#   DELEGATE:test-writer:35
#   CLAUDE:architecture-decision:-40
#   UNSURE:unknown:5
#
# Exit codes: 0 always (errors are surfaced via UNSURE output)

set -euo pipefail

# ── Input ─────────────────────────────────────────────────────────────────────

PROMPT="${1:-}"
if [[ -z "$PROMPT" ]]; then
  echo "UNSURE:empty-prompt:0"
  exit 0
fi

# Normalise for matching: lowercase, collapse whitespace
LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')

# ── Load thresholds from routing-rules.json if jq is available ────────────────

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DELEGATE_THRESHOLD=25
CLAUDE_THRESHOLD=-20

if command -v jq &>/dev/null && [[ -f "${PLUGIN_ROOT}/settings.json" ]]; then
  # Single jq pass — read all three thresholds at once.
  _THRESH=$(jq -r '.thresholds | [.delegate_threshold // 25, .claude_threshold // -20, .max_prompt_words_for_delegation // 120] | map(tostring) | join(" ")' \
    "${PLUGIN_ROOT}/settings.json" 2>/dev/null || echo "25 -20 120")
  read -r DELEGATE_THRESHOLD CLAUDE_THRESHOLD MAX_WORDS <<< "$_THRESH"
else
  MAX_WORDS=120
fi

# Allow the hook to override the delegate threshold dynamically (e.g. budget-aware mode).
# A lower threshold means more tasks are delegated.
if [[ -n "${DELEGATE_THRESHOLD_OVERRIDE:-}" ]]; then
  DELEGATE_THRESHOLD="$DELEGATE_THRESHOLD_OVERRIDE"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# matches_pattern <string> <pattern>
# Returns 0 if the lowercase string contains the ERE pattern (case-insensitive)
matches_pattern() {
  echo "$1" | grep -iqE "$2" 2>/dev/null
}

# ── Word-count guard ──────────────────────────────────────────────────────────

WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d '[:space:]')
if [[ $WORD_COUNT -gt $MAX_WORDS ]]; then
  echo "CLAUDE:prompt-too-long-for-auto-delegation:-10"
  exit 0
fi

# ── Scoring ───────────────────────────────────────────────────────────────────

SCORE=0
CATEGORY=""
REASON=""

# ────────────────────────────────────────────────────────────────
# DELEGATE signals  (positive score → lean toward Codex)
# ────────────────────────────────────────────────────────────────

# Code generation — explicit verb + code noun.
# The optional identifier group ([a-z_][a-z0-9_]*[[:space:]]+)? covers the common
# "write a getUserById function" form where the name precedes the type noun.
if matches_pattern "$LOWER" \
   "(write|create|generate|implement)[[:space:]]+(a[[:space:]]+|an[[:space:]]+|the[[:space:]]+)?(new[[:space:]]+)?([a-z_][a-z0-9_]*[[:space:]]+)?([a-z_][a-z0-9_]*[[:space:]]+)?([a-z_][a-z0-9_]*[[:space:]]+)?(function|method|class|interface|type|enum|struct|dto|component|hook|service|controller|handler|middleware|route|endpoint|schema|migration|model|resolver|repository|adapter|mixin|decorator|validator|serializer|deserializer)"; then
  SCORE=$((SCORE + 30))
  CATEGORY="code-generator"
fi

# Add / implement with code noun (e.g. "add a getUser function", "implement a validateEmail helper")
if matches_pattern "$LOWER" \
   "(add|implement)[[:space:]]+(a[[:space:]]+|an[[:space:]]+|the[[:space:]]+)?(new[[:space:]]+)?([a-z_][a-z0-9_]*[[:space:]]+)?([a-z_][a-z0-9_]*[[:space:]]+)?(function|method|class|interface|type|route|endpoint|handler|hook|component)"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-code-generator}"
fi

# Test writing
if matches_pattern "$LOWER" \
   "(add|generate|write|create)[[:space:]]+(unit[[:space:]]+|integration[[:space:]]+|e2e[[:space:]]+|snapshot[[:space:]]+|regression[[:space:]]+)?tests?[[:space:]]+(for|to|covering|of)"; then
  SCORE=$((SCORE + 30))
  CATEGORY="test-writer"
fi

# Direct "write tests for X" form
if matches_pattern "$LOWER" "^(write|generate|create)[[:space:]]+.*tests?[[:space:]]+(for|of|covering)"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-test-writer}"
fi

# Documentation — split into two patterns to handle "add jsdoc comments to" and
# "add jsdoc to" (where doc-type and "for/to" are not necessarily adjacent)
if matches_pattern "$LOWER" \
   "(add|generate|write)[[:space:]]+(jsdoc|tsdoc|typedoc|apidoc|docstring|documentation)"; then
  SCORE=$((SCORE + 30))
  CATEGORY="doc-writer"
fi

# "add [doc] comments to/for" — catches "add JSDoc comments to", "add inline comments for"
if matches_pattern "$LOWER" \
   "(add|generate|write)[[:space:]]+(jsdoc[[:space:]]+|tsdoc[[:space:]]+|inline[[:space:]]+|doc[[:space:]])?comments?[[:space:]]+(to|for)"; then
  SCORE=$((SCORE + 28))
  CATEGORY="${CATEGORY:-doc-writer}"
fi

# "document the/this/all X" form — allow an identifier between article and type noun
# "document the OrderController class" → verb + article + identifier + type noun
if matches_pattern "$LOWER" "document[[:space:]]+(this|the|all|every)[[:space:]]+[a-z_][a-z0-9_]*[[:space:]]*(function|method|class|module|file|component|export)"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-doc-writer}"
fi
# "document this function" / "document the module" (no identifier in between)
if matches_pattern "$LOWER" "document[[:space:]]+(this|the|all|every)[[:space:]]*(function|method|class|module|file|component|export)"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-doc-writer}"
fi

# Format / lint
if matches_pattern "$LOWER" "(^|[[:space:]])(format|lint|prettify|auto-?fix|fix (formatting|indentation|whitespace|trailing|imports|style)|apply (prettier|eslint|black|gofmt|rustfmt))([[:space:]]|$)"; then
  SCORE=$((SCORE + 20))
  CATEGORY="${CATEGORY:-format}"
fi

# Refactoring — mechanical rename/extract.
# Pattern 1: verb directly followed by type noun (e.g. "extract function doX")
# Pattern 2: verb + optional "the/this" + identifier + type noun (e.g. "rename the getUserById function")
# Pattern 3: simple "rename X to Y" form without type noun
if matches_pattern "$LOWER" \
   "(rename|extract|inline|move|refactor)[[:space:]]+(the[[:space:]]+|this[[:space:]]+)?[a-z_][a-z0-9_]*[[:space:]]+(function|method|variable|const(ant)?|class|interface|type|component|module)"; then
  SCORE=$((SCORE + 20))
  CATEGORY="${CATEGORY:-refactor}"
fi
if matches_pattern "$LOWER" \
   "^(rename|extract|inline|move)[[:space:]]+(the[[:space:]]+|this[[:space:]]+)?(function|method|variable|const(ant)?|class|interface|type|component|module)"; then
  SCORE=$((SCORE + 20))
  CATEGORY="${CATEGORY:-refactor}"
fi

# Boilerplate / scaffold
if matches_pattern "$LOWER" "(boilerplate|scaffold|skeleton|stub|placeholder|crud|getters?[[:space:]]+and[[:space:]]+setters?|accessor|template[[:space:]]+(file|class|function|component))"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-code-generator}"
fi

# Code conversion / translation
if matches_pattern "$LOWER" \
   "(convert|translate|rewrite|port)[[:space:]]+(this|the|my)[[:space:]].*(to|from|into)[[:space:]]+(javascript|typescript|python|go|rust|java|kotlin|swift|c\+\+|csharp|c#|ruby|php)"; then
  SCORE=$((SCORE + 20))
  CATEGORY="${CATEGORY:-code-generator}"
fi

# Type annotation additions
if matches_pattern "$LOWER" "(add|annotate[[:space:]]+with|fill[[:space:]]+in)[[:space:]]+(types?|type[[:space:]]+annotations?|typescript[[:space:]]types?|type[[:space:]]hints?)"; then
  SCORE=$((SCORE + 22))
  CATEGORY="${CATEGORY:-code-generator}"
fi

# Analyst / independent verification — explicit second-opinion or verify requests.
# Only fires when the user explicitly wants an independent check, not on every question.
if matches_pattern "$LOWER" \
   "(second[[:space:]]+opinion|sanity[[:space:]]+check|independent(ly)?[[:space:]]+(verify|check|confirm)|double[[:space:]]+-?check|cross[[:space:]]+-?check)[[:space:]]+"; then
  SCORE=$((SCORE + 25))
  CATEGORY="${CATEGORY:-analyst}"
fi
if matches_pattern "$LOWER" \
   "(verify|confirm|check)[[:space:]]+(that|whether|if)[[:space:]]+.*(correct|right|accurate|valid)"; then
  SCORE=$((SCORE + 20))
  CATEGORY="${CATEGORY:-analyst}"
fi

# Short-prompt bonus (simple requests tend to be short)
if [[ $WORD_COUNT -lt 10 ]]; then
  SCORE=$((SCORE + 15))
elif [[ $WORD_COUNT -lt 20 ]]; then
  SCORE=$((SCORE + 8))
fi

# ────────────────────────────────────────────────────────────────
# CLAUDE signals  (negative score → keep with Claude)
# ────────────────────────────────────────────────────────────────

# Architecture / design decisions
if matches_pattern "$LOWER" "(architect(ure|ural)?|design[[:space:]]+pattern|system[[:space:]]+design|design[[:space:]]+(decision|choice)|how[[:space:]]+should[[:space:]]+(i|we)[[:space:]]+(structure|organize|design))"; then
  SCORE=$((SCORE - 40))
  REASON="architecture-decision"
fi

# Security domain — always Claude.
# Short attack abbreviations (rce, xss, lfi, sqli, ssrf, csrf) MUST be whole words
# to avoid false positives: "resource" contains "rce", "process" contains none but
# other common words could collide. Use \b word boundaries for abbreviations only.
if matches_pattern "$LOWER" "(securit(y|ies)|vulnerabilit|exploit|pentest|injection|path[[:space:]]+traversal)"; then
  SCORE=$((SCORE - 40))
  REASON="security-domain"
fi
if matches_pattern "$LOWER" "\b(csrf|xss|sqli|ssrf|rce|lfi)\b"; then
  SCORE=$((SCORE - 40))
  REASON="${REASON:-security-domain}"
fi

if matches_pattern "$LOWER" "(auth(entication|orization|z)?|access[[:space:]]+control|permission[[:space:]]+(check|model|layer)|privilege[[:space:]]+(escalation|check)|token[[:space:]]+(validation|verification|forgery))"; then
  SCORE=$((SCORE - 35))
  REASON="${REASON:-security-auth}"
fi

# "Why" questions — always requires reasoning
if matches_pattern "$LOWER" "(^why[[:space:]]|[[:space:]]why[[:space:]]+(is|are|does|do|did|was|were|can|would|should|isn.?t|aren.?t|doesn.?t|don.?t))"; then
  SCORE=$((SCORE - 35))
  REASON="${REASON:-reasoning-question}"
fi

# Advisory / recommendation questions
if matches_pattern "$LOWER" "(should[[:space:]]+(i|we)[[:space:]]|(would[[:space:]]+you[[:space:]]+)?recommend|what.?s[[:space:]]+(the[[:space:]]+)?best[[:space:]]+(way|approach|practice)|which[[:space:]]+(is|would[[:space:]]+be)[[:space:]]+better|pros[[:space:]]+and[[:space:]]+cons|trade.?off)"; then
  SCORE=$((SCORE - 30))
  REASON="${REASON:-advisory-question}"
fi

# Debugging / broken code
if matches_pattern "$LOWER" "(debug|not[[:space:]]+working|isn.?t[[:space:]]+working|broken|failing|threw[[:space:]]+(an?[[:space:]])?error|getting[[:space:]]+(an?[[:space:]])?error|stack[[:space:]]+trace|exception|segfault|crash|hang[[:space:]]+on|deadlock|race[[:space:]]+condition)"; then
  SCORE=$((SCORE - 30))
  REASON="${REASON:-debugging-task}"
fi

# Performance analysis
if matches_pattern "$LOWER" "(performance|optimize[[:space:]]|slow(er|est)?[[:space:]]|bottleneck|memory[[:space:]]+(leak|usage|issue)|cpu[[:space:]]+(usage|spike)|profile[[:space:]]|benchmark|latency|throughput|scalab)"; then
  SCORE=$((SCORE - 25))
  REASON="${REASON:-performance-analysis}"
fi

# Code review / analysis
if matches_pattern "$LOWER" "(review[[:space:]]+(my|this|the)[[:space:]]+(code|implementation|approach|solution|pr|pull[[:space:]]+request)|audit[[:space:]]|analyze[[:space:]]+(my|this)|find[[:space:]]+(issues?|bugs?|problems?)[[:space:]]+in|what.?s[[:space:]]+wrong[[:space:]]+with)"; then
  SCORE=$((SCORE - 25))
  REASON="${REASON:-code-review}"
fi

# Explanation requests
if matches_pattern "$LOWER" "(explain[[:space:]]|help[[:space:]]+me[[:space:]]+understand|how[[:space:]]+does[[:space:]]|what[[:space:]]+does[[:space:]].*[[:space:]]+do|tell[[:space:]]+me[[:space:]]+(about|how)|walk[[:space:]]+me[[:space:]]+through|what[[:space:]]+is[[:space:]]+the[[:space:]]+(purpose|difference|point))"; then
  SCORE=$((SCORE - 20))
  REASON="${REASON:-explanation-request}"
fi

# "How do/can/would/should I/we/you X" — interrogative framing signals want-to-know,
# not a pure imperative. e.g. "how do I implement auth" sounds like code-gen but the
# user wants guidance, not a raw code drop. Cancel out the delegate signal.
if matches_pattern "$LOWER" "how[[:space:]]+(do|can|would|should)[[:space:]]+(i|we|you)[[:space:]]"; then
  SCORE=$((SCORE - 20))
  REASON="${REASON:-how-to-question}"
fi

# Multiple file paths (3+ slashes → multi-file context → keep Claude)
# grep -o exits 1 when there are no matches; || echo 0 handles that safely.
SLASH_COUNT=$(echo "$PROMPT" | grep -o '/' 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)
if [[ $SLASH_COUNT -ge 3 ]]; then
  SCORE=$((SCORE - 20))
  REASON="${REASON:-multi-file-context}"
fi

# Contains code block (``` ) → complex context, keep Claude
if echo "$PROMPT" | grep -q '```'; then
  SCORE=$((SCORE - 15))
fi

# Long prompt penalty (> 50 words) — reduced from -15 to -10 so that well-specified
# longer tasks (e.g. "write a complete CRUD API with validation and tests") can still
# cross the delegate threshold when combined with strong category signals.
if [[ $WORD_COUNT -gt 50 ]]; then
  SCORE=$((SCORE - 10))
fi

# ── Routing decision ──────────────────────────────────────────────────────────

if [[ $SCORE -ge $DELEGATE_THRESHOLD && -n "$CATEGORY" ]]; then
  echo "DELEGATE:${CATEGORY}:${SCORE}"
elif [[ $SCORE -le $CLAUDE_THRESHOLD ]]; then
  echo "CLAUDE:${REASON:-complex-task}:${SCORE}"
else
  echo "UNSURE:${CATEGORY:-unknown}:${SCORE}"
fi

# Documented contract: exit 0 always — callers depend on this.
exit 0
