---
name: delegate
description: >-
  Use this skill when the user explicitly routes work to Codex or wants an
  independent verification pass. Triggers on: "@codex", "delegate to codex",
  "use codex for this", "send this to codex", "save tokens", "use the cheaper
  model", "let codex handle it", "get a second opinion", "sanity check via
  codex", "verify this independently". Also triggers mid-reasoning when Claude
  wants an independent agent to confirm a conclusion before presenting it.
  Do not trigger for tasks the UserPromptSubmit hook already delegated
  (those arrive pre-tagged in additionalContext), security review, auth
  design, or tasks that require the full conversation history.
---

# Delegation Assessment & Dispatch

Act immediately — no confirmation needed. Pick the most reasonable
interpretation and proceed. Only pause if the task is on the DO NOT trigger
list above.

## 1. Identify What to Delegate

State the precise sub-task for Codex. It must be self-contained: a fresh agent
with only this description and read access to the codebase should complete it.

- **Verification request** → frame as: "Independently verify: [your conclusion].
  Return 'Confirmed: <reason>' or 'Correction: <what's right>'."
- **Budget offload** → frame as you would frame it to any capable engineer.

## 2. Select Expert Category

| Scenario | Category |
|---|---|
| Verify reasoning, second opinion, general analysis | `analyst` |
| Write new code (function, class, component) | `code-generator` |
| Write tests | `test-writer` |
| Add documentation or docstrings | `doc-writer` |
| Rename, extract, inline, restructure | `refactor` |
| Fix formatting or style | `format` |

When uncertain, use `analyst` — its persona is tuned to be direct and independent.

## 3. Dispatch to codex-agent

Invoke the codex-agent with the task description, selected category, and
current working directory.

## 4. Present Results

```
**[via Codex · <category>]**

<codex output>
```

- **Verification result**: present as "Codex confirms: …" or "Codex disagrees: …"
  and act accordingly. Never discard a correction silently.
- Never present Codex output as your own work.

## 5. Validate

Before relying on the output:
- **Code**: check for syntax errors, missing imports, obvious logic flaws.
- **Analysis**: check that conclusions follow from the evidence.
- **Verification**: check that confirmation/correction is internally consistent.

If something is wrong:
> "**[Claude note]:** I've reviewed the Codex output and noticed [issue]. Corrected: [fix]"

## Escalation

After 2 successive wrong outputs for the same task:
1. Stop delegating for this task.
2. Handle it directly.
3. Tell the user: "Codex produced inconsistent results here. Handling it directly."
