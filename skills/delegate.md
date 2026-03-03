---
name: delegate
description: |
  Trigger automatic or manual delegation of the current task to OpenAI Codex.

  TRIGGER this skill when:
  - The user says "delegate this", "use codex", "send this to codex", "let codex handle it"
  - The user says "save tokens" or "use the cheaper model"
  - The same task has failed or produced a wrong answer 2+ times
  - The task is clearly mechanical: pure code generation, test scaffolding, docstring writing,
    mechanical refactoring, or style formatting, AND you have not yet used the codex-agent
  - The user prefixes their request with "codex:" or "@codex"

  DO NOT trigger this skill for:
  - Tasks already handled by the automatic UserPromptSubmit hook (those are already delegated)
  - Architecture decisions, security review, complex debugging, advisory questions
  - Tasks requiring understanding of deeply intertwined multi-file logic
---

# Delegation Assessment & Dispatch

When this skill is triggered, follow this exact sequence:

## 1. Assess the Current Task

Identify the precise task to delegate. If the task is ambiguous, ask one clarifying question before proceeding.

Classify it:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/classify.sh" "<task description>"
```

## 2. Confirm Delegation is Appropriate

If the classification returns `CLAUDE:<reason>`, explain why the task should stay with Claude:

> "This task involves [reason]. Delegating it to Codex would risk lower-quality output because [brief explanation]. I'll handle it directly."

If the classification returns `DELEGATE` or `UNSURE`, proceed.

## 3. Dispatch to codex-agent

Use the `codex-agent` to execute the task:

> Invoke the codex-agent with the task description and the current working directory.

The codex-agent will:
- Select the appropriate expert persona
- Run `codex exec` with the right sandbox and model
- Return the output formatted and attributed

## 4. Present Results with Dual Attribution

Always make the delegation transparent:

```
**[Delegated to Codex]** — _task was routed to OpenAI to conserve Claude tokens_

<codex output>
```

Never present Codex-generated code as your own work.

## 5. Validate the Output (Dual-Gate Truthfulness)

After presenting the Codex output, perform a rapid sanity check:

- Does the code compile/parse syntactically? (Check for obvious structural errors)
- Does it match the user's stated requirements?
- Does it follow the project's existing patterns? (Check one similar file if needed)

If any check fails:
> "**[Claude note]:** I've reviewed the Codex output and noticed [issue]. Here is a correction: [fix]"

Never silently pass incorrect code to the user.

## 6. Log Completion

After successful delegation, the token-tracker script is called automatically by the hook/agent pipeline. No manual logging step is needed.

## Escalation Path

If Codex produces 2 successive incorrect outputs for the same task:
1. Stop delegating
2. Handle the task directly with Claude
3. Inform the user: "Codex produced inconsistent results for this task. I'm handling it directly."
