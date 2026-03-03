---
name: codex
description: Delegate a coding task explicitly to OpenAI Codex with optional sandbox and model control.
arguments:
  - name: prompt
    description: The coding task to delegate to Codex
    required: false
  - name: sandbox
    description: "Execution sandbox: read-only (default), workspace-write, or danger-full-access"
    required: false
  - name: model
    description: "Model override: fast (gpt-5.3-codex-spark), default (gpt-5.3-codex), capable (gpt-5.2)"
    required: false
---

# /codex — Direct Codex Delegation

You have been invoked via the `/codex` slash command. The user wants to delegate a task explicitly to OpenAI Codex, bypassing Claude's normal processing.

## Parse Arguments

The user may have provided:
1. A task description as the primary argument
2. Optional `--sandbox <level>` flag
3. Optional `--model <key>` flag

If no task description was provided, ask the user: "What task would you like to delegate to Codex?"

Extract from the invocation:
- `TASK_PROMPT`: the coding task (required)
- `SANDBOX`: one of `read-only`, `workspace-write`, `danger-full-access` (default: `workspace-write` for explicit /codex invocations)
- `MODEL_KEY`: one of `fast`, `default`, `capable` (default: `default`)

## Execute the Delegation

Run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" "code-generator" "<TASK_PROMPT>" "$(pwd)" "<SANDBOX>"
```

If the user specified a model, set the `CODEX_MODEL_OVERRIDE` environment variable before running:
```bash
CODEX_MODEL_OVERRIDE="<model name from routing-rules.json>" \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-exec.sh" "code-generator" "<TASK_PROMPT>" "$(pwd)" "<SANDBOX>"
```

## Display Results

Format the output as:
```
**[/codex · explicit delegation]**

<codex output>

---
_Sandbox: <sandbox level> · Model: <model used>_
_To apply file changes directly, re-run with `--sandbox workspace-write`_
```

## Validation

Before presenting output:
1. Check for obvious syntax errors in any code blocks
2. Verify the output addresses the user's stated task
3. If corrections are needed, append them with `> **[Claude note]:**`

## Token Tracker

After completion, log the delegation:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/token-tracker.sh" "<TASK_PROMPT>" "manual" "<CODEX_OUTPUT>" "MANUAL_DELEGATE" &>/dev/null &
```

## Session Resumption

If the user wants to continue a Codex session with follow-up:
```bash
echo "<follow-up prompt>" | codex exec --skip-git-repo-check resume --last 2>/dev/null
```
