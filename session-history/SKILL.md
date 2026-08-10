---
name: session-history
description: Search and read past Claude Code and Codex sessions across all projects. Use when asked to find a session where something was worked on, recall how something was done or decided before, or read a specific past session by id. Read-only — never modifies session data or search indexes.
context: fork
background: false
---

# session-history

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
source_kind         live | preserved | cass-archive
source_locator      absolute path to the transcript
hit_locator         line_number | record_uuid | message_index
bounded_excerpt     capped — see "Bounding output"
index_freshness     fresh | stale:<days> | unknown
```

## Hard rules

- **Never run**: `cass index`, `cass doctor --fix`, `cass search --refresh`, `cass pack --catch-up`,
  `cass models install`, `cass mirror prune`, any watch/daemon mode. Always invoke cass through
  `${CLAUDE_SKILL_DIR}/scripts/cass-ro`, which refuses these. Do not route around the guard by
  calling `cass` directly.
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

find ~/.claude/projects ~/.codex/sessions -name '*.jsonl' -newermt "$LOCAL"
```

**Never append a timezone suffix** to that string. BSD `find` accepts `"… UTC"` and then matches
**zero files without erroring** — a silent failure that makes the union look like it ran.

Grep the delta with the raw path below, then merge with the cass hits and de-duplicate on
`(provider, native_session_id)`.

### 4. If cass is unavailable

`cass-ro` exits non-zero when it refuses a command, times out, or cass is missing. Search the raw
path for the whole query and set `index_freshness: unknown`.

## read

Prefer the raw file — for a known session it is simpler and has fewer moving parts than routing
pagination through cass.

```bash
ls ~/.claude/projects/*/<session-id>.jsonl          # Claude
ls ~/.codex/sessions/*/*/*/rollout-*<session-id>*.jsonl   # Codex
```

If it is not on disk, look in the preserved archive (`~/Archive/ai-sessions/`, `source_kind:
preserved`) before giving up — sessions older than the retention window may only exist there.

## The raw path

### Locate first, never dump

```bash
rg -l --fixed-strings "<term>" ~/.claude/projects ~/.codex/sessions
```

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

cass hits carry **no session-id field**. Derive it:

- **Claude** — the filename stem: `<session-id>.jsonl`
- **Codex** — the trailing UUID of `rollout-*.jsonl`, or `session_meta.payload.id`

## Session titles

Titles are **not** in a `title` field. They live in dedicated records:

```bash
jq -r 'select(.type=="custom-title") | .customTitle' "<file>" | tail -1   # user-set name
jq -r 'select(.type=="ai-title")     | .title'       "<file>" | tail -1   # generated
```

A file may contain title records belonging to *other* sessions; match on `.sessionId` when it matters.

## Mining sessions for lessons

Read `references/lessons-recipe.md`. It is a recipe a caller may follow — **not** an operation this
skill performs, and it promises no output schema.
