# Recipe: mining sessions for lessons

> **This is a recipe, not an operation.** The `session-history` skill does not perform this analysis
> and promises no output schema for it. Read it if you want the lens; the interpretation is yours.
>
> Salvaged from `ccbox-insights` (retired 2026-08) — the tool it depended on was abandoned, but this
> part was worth keeping.

## The core idea

**Your corrections are the highest-signal moments in any transcript.** Tool errors are noisy and
often irrelevant; a place where the user stopped the agent and redirected it is a place where the
instructions were wrong. Mine those first.

For each one, capture a course-correction record:

```
kind        clarification | correction | constraint_restate | interruption
trigger     what the agent did immediately before (evidence-based, one sentence)
evidence    one short line copied verbatim from the user message
fix         what changed after the correction
lesson      one rule that would have prevented the detour
```

Look for messages that:

- clarify intent — "I meant X", "not that", "use Y instead"
- correct — "this is wrong", "stop", "revert", "you didn't follow the instructions"
- restate a constraint after the fact — "do not run X", "no emojis", "don't change the version"
- interrupt out of friction — hangs, repeated retries, "cancel", or simply abandoning the thread

If a session ends unresolved, say so and explain the likely cause from evidence (hang, repeated
invalid tool use, conflicting constraints) rather than guessing.

## Three discipline rules that matter more than the taxonomy

1. **Evidence first.** Every counted failure carries a short snippet copied from the log. Never infer
   a failure you cannot quote.
2. **Separate "tool failed" from "wrong approach."** A tool can succeed and still be the wrong move.
   These have different fixes: one is a bug, the other is an instruction gap.
3. **Count explicit user rejections as their own category.** The tool did not fail — the action was
   declined. Conflating the two hides the most useful signal you have.

And when proposing rules: prefer ones that fired **2+ times** over one-off fixes, and keep them free
of local paths, repo names, and one-off incident detail.

## Failure taxonomy (for cross-session aggregation only)

Only useful when aggregating; overkill for a single session.

`invalid_tool_input` · `tool_not_available` · `user_rejected_action` · `permission_denied` ·
`path_not_found` · `auth_or_secret_missing` · `network_error` · `timeout_or_hang` ·
`command_failed` · `conflicting_instructions` · `partial_or_truncated` · `wrong_tool_or_scope` ·
`unknown`

Optional tool grouping for stable aggregation: `exec`, `edit`, `read`, `search`, `fetch`, `browser`,
`other` — keeping the raw tool name alongside.

## Where the output should go

`ccbox-insights` emitted `AGENTS.md` snippets, which had to be hand-placed. In this harness the
natural targets are:

| Finding | Destination |
|---|---|
| A recurring behavioural rule | `CLAUDE-patterns.md`, or global `CLAUDE.md` if project-independent |
| A bug with a known cause and fix | `CLAUDE-troubleshooting.md` |
| A decision and its rationale | `CLAUDE-decisions.md` |
| Something needing real work | a Backlog.md task |

**Propose diffs; do not apply them.** The consumer decides. `refresh-harness` already owns
reconciling harness state against reality and is the natural place for this to land.
