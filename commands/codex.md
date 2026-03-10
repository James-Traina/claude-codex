---
name: codex
description: Delegate a coding task explicitly to OpenAI Codex with optional sandbox and model control.
argument-hint: "[task] [--sandbox read-only|workspace-write|danger-full-access] [--model fast|default|capable]"
allowed-tools: Bash, Read
---

# /codex — Direct Codex Delegation

You have been invoked via the `/codex` slash command. The user wants to
delegate a task explicitly to OpenAI Codex.

## Parse Arguments

Extract from the invocation:
- `TASK_PROMPT`: the coding task (required — if absent, ask: "What task would you like to delegate to Codex?")
- `SANDBOX`: `read-only`, `workspace-write`, or `danger-full-access` (default: `workspace-write`)
- `MODEL_KEY`: `fast`, `default`, or `capable` (default: `default`)

## Execute

Classify the task to select the right expert persona:

```bash
CLASSIFY_RESULT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/classify.sh" "$TASK_PROMPT" 2>/dev/null \
  || echo "DELEGATE:code-generator:30")
CATEGORY=$(echo "$CLASSIFY_RESULT" | cut -d: -f2)
[[ -z "$CATEGORY" || "$CATEGORY" == "unknown" || "$CATEGORY" == "classify-error" ]] \
  && CATEGORY="code-generator"
```

Run with the resolved category and sandbox (substitute actual values for `$TASK_PROMPT` and `$SANDBOX`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" "$CATEGORY" "$TASK_PROMPT" "$(pwd)" "$SANDBOX"
```

If the user specified `--model`, read the model name from `settings.json` and set `CODEX_MODEL_OVERRIDE`:

```bash
# Model keys are defined in settings.json under .models: fast, default, capable
MODEL_NAME=$(jq -r --arg key "$MODEL_KEY" '.models[$key] // .models.default' \
  "${CLAUDE_PLUGIN_ROOT}/settings.json")
CODEX_MODEL_OVERRIDE="$MODEL_NAME" \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" "$CATEGORY" "$TASK_PROMPT" "$(pwd)" "$SANDBOX"
```

## Display Results

```
**[via Codex · <category>]**

<codex output>

---
_Sandbox: <sandbox> · Model: <model>_
_To apply file changes directly, re-run with `--sandbox workspace-write`_
```

## Validation

Before presenting output:
1. Check for obvious syntax errors in any code blocks.
2. Verify the output addresses the stated task.
3. If corrections are needed, append them with `> **[Claude note]:**`.

## Log the Delegation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/token-tracker.sh" \
  "$TASK_PROMPT" "manual" "$CODEX_OUTPUT" "MANUAL_DELEGATE" &>/dev/null &
```

## Session Resumption

To continue a Codex session with a follow-up prompt:

```bash
codex exec --skip-git-repo-check resume --last "$FOLLOWUP_PROMPT" 2>/dev/null
```
