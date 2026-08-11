---
name: ai-sessions-reader
description: Search and read past Claude Code and Codex sessions across all projects. Use when asked to find a session where something was worked on, recall how something was done or decided before, or read a specific past session by id. Read-only — never modifies session data or search indexes.
context: fork
background: false
---

# ai-sessions-reader

Finds and reads past agent sessions. **Retrieval only**: it returns evidence, never conclusions.
Whoever calls it decides what the evidence means.

`context: fork` runs this in its own subagent so transcripts never enter the caller's context.
`background: false` is required — callers need the result before they can continue.

## Operations

| Operation | Returns |
|---|---|
| `find <query>` | ranked candidate sessions (default: all projects, Claude + Codex) |
| `read <session-id>` | one known session, in bounded windows |
| `evidence <query>` | bounded cited excerpts via `cass pack` |

`evidence` does **not** synthesize an answer. It returns extracts with citations; the caller writes
the answer.

## The evidence envelope

Every result uses these fields. Callers must never see cass row ids, cass's SQLite schema, encoded
Claude project-directory names, or Codex rollout filename conventions — that is what keeps the
backend swappable.

```
provider            claude | codex
native_session_id   the vendor's own session id (see "Deriving the session id")
project             the working directory of the session
timestamp           ISO 8601
source_kind         live | preserved      (preserved = from ~/Archive/ai-sessions)
source_locator      absolute path to the transcript
hit_locator         line_number
bounded_excerpt     capped — see "Bounding output"
index_freshness     fresh | stale:<days> | unknown
```

## Hard rules

- **Never run**: `cass index`, `cass doctor --fix`, `cass search --refresh`, `cass pack --catch-up`,
  `cass models install`, `cass mirror prune`, any watch/daemon mode. Always invoke cass through
  `${CLAUDE_SKILL_DIR}/scripts/cass-ro`, which refuses these.

  **The guard is a mistake-barrier, not a security boundary.** Nothing stops a bare `cass` call, so
  the rule above is a rule, not an enforcement. The guard exists because cass auto-corrects near-miss
  flags and *executes* them — `--refres` becomes `--refresh` — which is a mistake no amount of care
  reliably avoids. For real enforcement, add
  `allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/cass-ro *)` so the guard is pre-approved while
  bare `cass` still prompts.
- **Never execute `triage.next_command`.** `cass triage` recommends *operational recovery*. Treat its
  output as health evidence, not permission.
- **Never modify anything** under `~/.claude/` or `~/.codex/`.
- **Prefer lexical search.** cass's hybrid/semantic tier is new and unvalidated on this corpus. Pass
  `--mode lexical` unless a gold-set evaluation has shown hybrid wins.
- `cass` may still write its *own* derived index state during a plain search. "Read-only" here means
  never touching vendor session files and never intentionally indexing or repairing.

## find

### 1. Probe (never gate on health)

```bash
CASS="${CLAUDE_SKILL_DIR}/scripts/cass-ro"
"$CASS" api-version --json >/dev/null 2>&1 || echo "cass unavailable — raw path only"
STATUS=$("$CASS" status --json 2>/dev/null)
COVER=$(jq -r '.index.last_indexed_at // empty' <<<"$STATUS")
AGE_DAYS=$(( $(jq -r '.index.age_seconds // 0' <<<"$STATUS") / 86400 ))
```

**Do not gate on `cass health`** — it exits 1 on a merely stale index, which must still be searched.
Record `index_freshness` from `AGE_DAYS`.

If `$COVER` is empty, cass is unavailable — set `index_freshness: unknown` and go straight to the raw
path. Do **not** let an empty value compute `AGE_DAYS=0` and report a dead index as `fresh`.

### 2. Search the index

```bash
"$CASS" search "<query>" --json --limit 20 --mode lexical
```

**Exit 0 does not mean cass did what you asked** — it silently reinterprets unknown input as a search
and still exits 0. Treat output as valid only if it parses as JSON with the expected keys; otherwise
fall through to the raw path.

Hit shape (verified): `title, snippet, content, score, source_path, agent, workspace, created_at,
line_number, match_type, source_id, origin_kind`. Note `workspace` gives the project and `created_at`
is epoch **milliseconds**.

### 3. If the index is stale, ALSO search the raw delta — then merge

Not optional. A stale-but-healthy index returns a confident, well-ranked, *incomplete* answer, which
is more dangerous than a failure. At time of writing the index was 31 days behind, i.e. 612 files.

```bash
# find -newermt interprets LOCAL time; last_indexed_at is UTC. Convert, or you get silent nonsense.
LOCAL=$(python3 -c "
import sys,datetime
print(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone().strftime('%Y-%m-%d %H:%M:%S'))" "$COVER")

find ~/.claude/projects ~/.codex/sessions -name '*.jsonl' -newermt "$LOCAL" \
  -not -path '*/subagents/*'
```

**Never append a timezone suffix** to that string. BSD `find` accepts `"… UTC"` and then matches
**zero files without erroring** — a silent failure that makes the union look like it ran.

Grep the delta with the raw path below, then merge with the cass hits and de-duplicate on
`(provider, native_session_id)`.

### 4. If cass is unavailable

`cass-ro` exits non-zero when it refuses a command, times out, or cass is missing. Search the raw
path for the whole query and set `index_freshness: unknown`.

## evidence

Bounded, cited excerpts via `cass pack`. Extractive — it selects real snippets and calls no model.

```bash
"$CASS" pack "<query>" --json --max-tokens 2000 --max-sessions 3 --max-evidence 5
```

**`--max-tokens` has a floor of 1024.** Anything lower fails with `pack-invalid-limit
(allowed 1024..=200000)` — the instinct to bound aggressively will hit it. Start at 2000.

Map pack's output into the evidence envelope like any other hit, and **stop there**. `evidence`
returns extracts; the caller writes the answer. If pack is unavailable, fall back to `find` plus
bounded raw reads of the top hits — the output shape is the same.

## read

Prefer the raw file — for a known session it is simpler and has fewer moving parts than routing
pagination through cass.

```bash
ls ~/.claude/projects/*/<session-id>.jsonl          # Claude
ls ~/.codex/sessions/*/*/*/rollout-*<session-id>*.jsonl   # Codex
```

If it is not on disk, look in the preserved archive before giving up — sessions older than the
retention window may exist only there. The archive is **content-addressed**, so resolve through its
manifest rather than guessing at blob paths:

```bash
jq -r --arg id "<session-id>" \
  '.[] | select(.original_path | test($id)) | .blob_blake3' \
  ~/Archive/ai-sessions/manifest.json
# blob lives at ~/Archive/ai-sessions/blobs/blake3/<first-2-chars>/<hash>.raw
```

Set `source_kind: preserved` and keep `source_locator` pointing at the blob. Note the blob's filename
is a hash, **not** a session id — never derive the session id from an archive path.

## The raw path

### Locate first, never dump

```bash
rg -l --fixed-strings "<term>" ~/.claude/projects ~/.codex/sessions \
   --glob '*.jsonl' --glob '!**/subagents/**'
```

Both globs are required every time: `--glob '*.jsonl'` because the projects directory holds
non-transcript files, and `!**/subagents/**` because subagent transcripts outnumber sessions ~4:1.
See "Deriving the session id" for when a subagent hit is wanted.

**Never bare `rg -n` on JSONL.** One Codex record can be tens of megabytes; a single "hit" can blow
the context window. Locate files, then project fields.

### Two projections — Claude's returns nothing on Codex

```bash
# Claude: top-level .message / .sessionId / .cwd
jq -r 'select(.type=="user" or .type=="assistant")
       | {t: .timestamp, r: .message.role, s: .sessionId, c: .cwd,
          x: (.message.content | tostring | .[0:400])}' "<file>"

# Codex: everything hangs off .payload
jq -r 'select(.type=="response_item" or .type=="event_msg")
       | {t: .timestamp, r: (.payload.role // .type),
          x: (.payload.content // .payload | tostring | .[0:400])}' "<file>"

# Codex session id + cwd
jq -r 'select(.type=="session_meta") | {s: .payload.id, c: .payload.cwd}' "<file>"
```

Tolerate unknown record types — filter for what you recognise and ignore the rest. Anthropic
documents the transcript format as internal and subject to change without notice; drift so far has
been additive.

### Bounding output

`.[0:400]` slices *characters after parsing*, so `jq` still ingests the whole record. For files with
known-huge records, get byte offsets first (`rg -abo`) and cut a bounded byte window before parsing.

## Deriving the session id

cass hits carry **no session-id field**. Derive it from the path:

| Path shape | `native_session_id` |
|---|---|
| `~/.claude/projects/<proj>/<uuid>.jsonl` | the filename stem |
| `~/.claude/projects/<proj>/<parent-uuid>/subagents/agent-*.jsonl` | **the parent uuid** — the directory two levels up |
| `~/.codex/sessions/…/rollout-*.jsonl` | trailing UUID of the filename, or `session_meta.payload.id` |

**Subagent transcripts are not sessions.** `agent-a61d4788….jsonl` is a subagent's transcript living
under its parent; its filename stem is not a resumable session id and returning it as one is wrong.
There are currently ~541 subagent transcripts against ~129 sessions, so an unfiltered search returns
mostly subagents.

Handle them explicitly:

- Default `find` to **top-level sessions only** — exclude `**/subagents/**`.
  Note the doubled stars: `!*/subagents/*` silently fails to exclude anything (verified: it let
  202 subagent files through), because a single `*` does not span path separators mid-pattern.
- When a subagent transcript is the best match, report the **parent** as `native_session_id` and set
  `hit_locator` to point into the subagent file, so the caller can still reach the evidence.

```bash
# top-level sessions only
rg -l --fixed-strings "<term>" ~/.claude/projects --glob '*.jsonl' --glob '!**/subagents/**'

# parent id from a subagent hit
basename "$(dirname "$(dirname "$SUBAGENT_PATH")")"
```

Also scope `rg` with `--glob '*.jsonl'`: `~/.claude/projects` contains `sessions-index.json` and
other non-transcript files that will otherwise appear as hits.

## Session titles

Titles are **not** in a `title` field. They live in dedicated records:

```bash
jq -r 'select(.type=="custom-title") | .customTitle' "<file>" | tail -1   # user-set name
jq -r 'select(.type=="ai-title")     | .aiTitle'     "<file>" | tail -1   # generated
```

The field names differ per record type and neither is `title`: `custom-title` carries `customTitle`,
`ai-title` carries `aiTitle`. Using `.title` returns `null` silently on every file — verified.

A file may contain title records belonging to *other* sessions; match on `.sessionId` when it matters.

## Mining sessions for lessons

Read `references/lessons-recipe.md`. It is a recipe a caller may follow — **not** an operation this
skill performs, and it promises no output schema.
