---
name: delegate
description: >-
  Required protocol for routing any task to OpenAI Codex. Handles @codex, codex:, "delegate to codex", "save tokens", "use the cheaper model", "second opinion", and "sanity check via codex" requests. Do not handle these yourself — always go through this skill for proper expert selection and attribution.

  INVOKE IMMEDIATELY (before doing anything else) when the user says any variant of: delegate, codex, @codex, save tokens, cheaper model, use codex, send to codex, let codex handle it, second opinion, sanity check.

  Also invoke proactively mid-reasoning whenever you feel uncertain and want an independent agent to verify your conclusion before presenting it to the user.

  DO NOT trigger for: tasks the UserPromptSubmit hook already delegated (arrive pre-tagged in additionalContext), security review, auth design, or tasks requiring this full conversation's context.
---

# Delegation Assessment & Dispatch

## Autonomy Rules

Act immediately. Do not ask the user for permission, confirmation, or clarification before dispatching. If the task is ambiguous, pick the most reasonable interpretation and proceed. Only pause if the task is explicitly in the DO NOT trigger list.

When this skill is triggered, follow this sequence:

## 1. Identify What to Delegate

State the precise sub-task you want Codex to handle. This should be self-contained — a fresh agent with only this description and access to the codebase should be able to complete it.

If you triggered this because of **uncertainty**, frame the task as: "Independently verify: [your conclusion]. Return either 'Confirmed' with a one-sentence reason, or 'Correction: [what's actually right]'."

If you triggered this because of **budget / offloading**, frame the task as you would frame it to any capable engineer.

## 2. Select the Right Expert Category

| Scenario | Category |
|---|---|
| Verify reasoning, second opinion, general analysis | `analyst` |
| Write new code (function, class, component) | `code-generator` |
| Write tests | `test-writer` |
| Add documentation or docstrings | `doc-writer` |
| Rename, extract, inline, restructure | `refactor` |
| Fix formatting or style | `format` |

When in doubt, use `analyst` — its expert persona is tuned to be direct and independent.

## 3. Dispatch to codex-agent

Invoke the codex-agent with the task description, selected category, and the current working directory.

The codex-agent will select the sandbox level, run `codex exec`, and return formatted output.

## 4. Present Results with Clear Attribution

```
**[Delegated to Codex · <category>]**

<codex output>
```

If this was a **verification request**: present the result as "Codex confirms: ..." or "Codex disagrees: ..." and act accordingly — do not silently discard a correction.

Never present Codex output as your own work.

## 5. Validate (Dual-Gate Truthfulness)

Before relying on Codex output:
- For code: check for structural/syntax errors, missing imports, and obvious logic flaws
- For analysis: check that conclusions follow from the evidence presented
- For verification: check that the confirmation/correction is internally consistent

If something looks wrong:
> "**[Claude note]:** I've reviewed the Codex output and noticed [issue]. Corrected: [fix]"

## Escalation

If Codex produces 2 successive wrong outputs for the same task:
1. Stop delegating for this task
2. Handle it directly
3. Tell the user: "Codex produced inconsistent results here. I'm handling it directly."
