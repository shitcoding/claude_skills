# Session-History Search Skill Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A read-only Claude Code skill that finds and reads past Claude Code and Codex sessions across all projects, so the agent stops rediscovering `ccbox` every session — and so `handover-from-session` and `refresh-harness` stop depending on an abandoned tool.

**Architecture:** Raw vendor JSONL is the durable substrate; `cass` is a replaceable ranked-search accelerator queried through a tiny allow-list guard; `rg`/`jq` is the always-available floor. The skill returns a stable *evidence envelope* so consumers never learn backend identifiers. It performs no analysis and mutates nothing.

**Tech Stack:** Markdown (`SKILL.md`), Bash (one guard script), `cass` 0.6.22+, `rg`, `jq`, GNU `timeout` (optional).

---

## Context an implementer needs

**Read `claude_docs/backlog/tasks/task-1 - Create-AI-coding-session-investigation-skill.md` first.** It holds the full decision history. The research is in `claude_docs/research/2026-08-08_session_investigation_skill/` — start with `2026-08-09_21-45-00_cross_report_summary_and_decision.md`.

**Where things live.** Three separate git repos, siblings on disk:

| Repo | Path | Holds |
|---|---|---|
| public skills | `~/coding/claude_code/skills/my_claude_skills` | this plan; the new skill |
| private skills | `~/coding/claude_code/skills/my_claude_skills_private` | `handover-from-session`, `refresh-harness` |
| config | `~/coding/claude_code/skills/my_claude_skills_claude_config` | harness files, backlog, research |

The new skill goes in the **public** repo: it is generally useful, and the reports judged a read-only session reader publishable. Consumers in the private repo reach it **by name** via the Skill tool, never by path — so cross-repo placement costs nothing.

**Verified facts that shape the code** (re-verify before relying on them; all checked 2026-08-09/10):

- **cass auto-corrects near-miss flags and subcommands, then executes them.** `cass api-version --js` prints "Corrected typo '--js' to '--json'" and runs, exit 0. `cass definitely-not-a-command` prints "Assumed 'search' subcommand" and runs a search, exit 0. **This is why the guard uses allow-lists for both subcommands and flags** — a deny-list of exact strings is defeated by `--refres`, which cass will happily correct to `--refresh`.
- **`cass search` can write.** A bounded search returned exit 5 with `kind:"lexical-rebuild"` ("automatic lexical repair failed", touching `index-run.lock`) — cass attempts derived-index repair *without* `--refresh`. **"Read-only" in this plan therefore means: never mutates vendor session files, and never intentionally triggers indexing or repair. It does not mean zero writes anywhere** — that would require an OS-enforced read-only environment, which is out of scope.
- `cass health` currently **exits 1** (stale index). A guard that gates on `health` before searching would disable cass entirely on a merely stale index — the exact case we must still query. **Do not gate on health.** Report it; search anyway.
- `cass status --json` exposes `index.last_indexed_at` (e.g. `2026-07-10T11:55:10Z`) and `age_seconds`. That **is** the stale-index coverage point.
- **cass search hits carry no session-id field.** Verified hit JSON: `title, snippet, content, score, source_path, agent, workspace, created_at, line_number, match_type, source_id, origin_kind`. `native_session_id` must be derived (see Task 3).
- `cass export --format json` is **lossy**: `--include-tools` and `--include-skills` are opt-in ("stripped for privacy" by default). The **raw mirror** (`raw-mirror/v1/{blobs,manifests}`, ~872 MB) holds byte-for-byte originals with manifests carrying `provider`, `original_path`, `source_size_bytes`, `blob_blake3`, `captured_at_ms`. Task 0 uses the mirror, not export.
- GNU `timeout` is at `/opt/homebrew/bin/timeout` but is **not** a macOS default. Degrade gracefully when absent; use `-k` so a TERM-ignoring child is actually killed.
- Claude transcripts: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; subagents in `subagents/agent-*.jsonl`. Every Claude message record carries `.cwd`, so `jq -r 'select(.cwd)|.cwd' <file> | head -1` maps a session to its project — no `ccbox projects` needed.
- **Codex has a completely different schema.** Records are `{"timestamp", "type":"session_meta"|"event_msg"|"response_item"|…, "payload":{…}}` — no top-level `.message`, `.sessionId`, or `.cwd`. Any `jq` written for Claude returns **nothing** on Codex files. Codex session id comes from `session_meta.payload` or the rollout filename's trailing UUID.

**House rules:** `set -euo pipefail`; scripts executable; no AI/LLM attribution anywhere; Conventional Commits, imperative, ≤72 chars. Never `git add -A` in the config repo. See `CLAUDE-patterns.md`.

---

## Task 0: Export the cass-only history (BLOCKING — do this first)

All three research reports flagged this independently. ~4× more Claude history exists only inside cass's single-author SQLite mirror than survives on disk. Until it is exported, the architecture's premise ("the index is a disposable derivative") is false.

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/archive/sessions/` (destination)
- Create: `/tmp/export-cass-history.sh` (throwaway — do not commit)

**Step 1: Measure what needs exporting**

```bash
cass stats 2>/dev/null | sed -n '1,20p'
find ~/.claude/projects -name '*.jsonl' -not -path '*/subagents/*' | wc -l
```

Expected: cass reports ~322 `claude_code` conversations; disk shows ~81 top-level files. The gap is what exists only in cass.

**Step 2: Copy the raw mirror — do NOT use `cass export` for the archive**

`cass export --format json` strips tool use and skill content by default (`--include-tools` /
`--include-skills` are opt-in, "stripped for privacy"). Archiving that would silently discard exactly
the material that makes a session worth keeping. cass already stores **byte-for-byte originals**:

```bash
MIRROR=~/Library/Application\ Support/com.coding-agent-search.coding-agent-search/raw-mirror/v1
ls "$MIRROR"                     # blobs  manifests  tmp
ls "$MIRROR"/manifests | head -3
jq . "$MIRROR"/manifests/<one>.json   # inspect the real field names before scripting
```

Manifests carry `provider`, `original_path`, `source_size_bytes`, `blob_blake3`, `captured_at_ms`
and blob location. Verified: a session absent from disk has an intact blob whose first bytes are
literal Claude JSONL.

Copy `blobs/` and `manifests/` (or just the blobs whose `original_path` no longer exists) to:

```
~/Archive/ai-sessions/          # NOT inside any of the three git repos — see Step 5
```

**Step 3: Build the tool-neutral manifest by projecting cass's own**

Do not hand-build it and do not compute a second hash — the manifests already carry `blob_blake3`.

```bash
jq -s 'map({provider, original_path, source_size_bytes, blob_blake3, captured_at_ms})' \
   "$MIRROR"/manifests/*.json > ~/Archive/ai-sessions/manifest.json
jq 'group_by(.provider) | map({provider: .[0].provider, n: length})' ~/Archive/ai-sessions/manifest.json
```

Expected: `claude_code` ≈ 322 (matching the DB count), `codex` ≈ 693.

**Step 4: Verify by hash and size, not by file count**

`ls | wc -l` is not adequate verification for irreplaceable client work.

```bash
# for each copied blob: recompute blake3 and compare to the manifest's blob_blake3,
# and compare byte size to source_size_bytes. Report any mismatch and STOP.
b3sum <blob>    # or any blake3 implementation
```

**If any blob fails, stop and investigate.** Do not proceed believing the data is safe.

**Step 5: Keep bodies out of git; commit only the manifest**

The bodies are ~900 MB of client work and the config repo is pushed to GitHub. Bodies live in
`~/Archive/ai-sessions/` (covered by normal backups); only the manifest goes in git. Note that
`original_path` and `cwd` can themselves reveal client names — redact if that matters to you.

```bash
cd ~/coding/claude_code/skills/my_claude_skills_claude_config
mkdir -p claude_docs/archive
cp ~/Archive/ai-sessions/manifest.json claude_docs/archive/manifest.json
git add claude_docs/archive/manifest.json
git commit -m "chore: record archived session manifest"
```

**Step 6: Note why copying out is mandatory**

`cass mirror prune` can delete the mirror at any time. Until the copy exists outside cass's
ownership, cass is the sole custodian of ~4× the Claude history that survives on disk.

---

## Task 1: Gold retrieval set

Cheap, and it is the only objective way to settle lexical-vs-hybrid later and to test the next migration.

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/research/2026-08-08_session_investigation_skill/gold-retrieval-set.md`

**Start with 5, not 20.** Five known queries are enough to smoke-test `find` and to catch a
regression; growing to ~20 is worth doing later but must not block Task 0 or Task 2.

**Step 1: Write the questions you actually remember, each with its correct session ID**

Include deliberately fuzzy phrasings, not just exact keywords — fuzzy recall is the use case that justifies ranked search over `rg`:

```markdown
| # | Query (as you'd actually type it) | Expected session ID | Provider | Notes |
|---|---|---|---|---|
| 1 | the viewport thing that broke responsive checks | <id> | claude | fuzzy; session says "innerWidth", never "viewport bug" |
| 2 | when I replaced tmux with codex exec | <id> | claude | exact-ish |
| 3 | PUT-only /json/new | <id> | claude | exact error string |
```

**Step 2: Commit**

```bash
cd ~/coding/claude_code/skills/my_claude_skills_claude_config
git add claude_docs/research/2026-08-08_session_investigation_skill/gold-retrieval-set.md
git commit -m "docs: add gold retrieval set for session-search evaluation"
```

---

## Task 2: The guard script (the only code in this project)

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills/session-history/scripts/cass-ro`
- Test: `~/coding/claude_code/skills/my_claude_skills/session-history/scripts/test-cass-ro.sh`

**Why this exists:** all three reports rejected "no wrapper", and the defensible reason is *enforcement, not abstraction*. cass's machine contract is already better than any wrapper we'd maintain — but "never index, never repair" is a safety invariant, and prose is not a safety boundary. The script is an allow-list plus a timeout. It does not parse, normalise, or interpret cass output.

**Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# test-cass-ro.sh — assert the guard allows safe commands and refuses mutating ones.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/cass-ro"
FAIL=0

# Stub cass: echoes its args, exits 0. Keeps tests hermetic and fast.
STUB="$(mktemp -d)/cass"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "STUB_RAN: $*"
EOF
chmod +x "$STUB"
export CASS_RO_BIN="$STUB"

check() {  # check <desc> <expected-exit> <args...>
  local desc="$1" want="$2"; shift 2
  "$GUARD" "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" -eq "$want" ]; then echo "ok   — $desc"
  else echo "FAIL — $desc (want exit $want, got $got)"; FAIL=1; fi
}

check "allows api-version"             0  api-version
check "allows search --json"           0  search "foo" --json --limit 5
check "allows view"                    0  view /some/path.jsonl -n 42 --json
check "allows pack"                    0  pack "foo" --json --max-tokens 2000
check "refuses index"                 42  index
check "refuses doctor --fix"          42  doctor --fix
check "refuses search --refresh"      42  search "foo" --json --refresh
check "refuses pack --catch-up"       42  pack "foo" --catch-up
check "refuses models install"        42  models install
check "refuses unknown subcommand"    42  definitely-not-a-command
check "refuses empty invocation"      42

# A refused flag must be caught anywhere in the arg list, not just position 2.
check "refuses --refresh at the end"  42  search "foo" --limit 5 --json --refresh

# THE REGRESSION THAT MOTIVATED THE ALLOW-LIST: cass auto-corrects near-miss
# flags and then executes them, so a deny-list of exact strings is defeated by
# any abbreviation. Each of these must be refused BEFORE reaching cass.
check "refuses --refres (autocorrect)"   42  search "foo" --refres
check "refuses --refre  (autocorrect)"   42  search "foo" --refre
check "refuses --refresh=true (= form)"  42  search "foo" --refresh=true
check "refuses --catch-up=1   (= form)"  42  pack   "foo" --catch-up=1
check "refuses unknown flag"             42  search "foo" --definitely-not-a-flag
check "refuses --trace-file"             42  search "foo" --trace-file /tmp/x.jsonl

# Subcommand matching must be exact, not substring.
check "refuses two-word subcommand"      42  "view expand"

exit "$FAIL"
```

**Step 2: Run it to verify it fails**

```bash
chmod +x session-history/scripts/test-cass-ro.sh
./session-history/scripts/test-cass-ro.sh
```

Expected: every line `FAIL` (the guard does not exist yet), exit 1.

**Step 3: Write the guard**

```bash
#!/usr/bin/env bash
# cass-ro — run cass read-only: allow-lists for both subcommand and flags, hard timeout.
#
# Exit codes:
#   0     cass ran and succeeded
#   42    refused by this guard (never reached cass)
#   124   timed out (GNU timeout convention)
#   other cass's own exit code
#
# The caller treats any non-zero as "fall through to rg/jq".
#
# WHY ALLOW-LISTS, NOT DENY-LISTS — this is the whole point of the script:
# cass auto-corrects near-miss input and then EXECUTES the correction.
#   `cass api-version --js`            -> "Corrected typo '--js' to '--json'", runs, exit 0
#   `cass definitely-not-a-command`    -> "Assumed 'search' subcommand", runs a search, exit 0
# A deny-list of exact strings is therefore worthless: `--refres` slips past it and
# cass turns it into `--refresh`. Anything not explicitly known-safe is refused.
#
# SCOPE OF THE GUARANTEE: this prevents *intentionally* invoking indexing/repair.
# cass may still write its own derived state during a plain search (observed:
# exit 5, kind "lexical-rebuild"). Read-only here means "never mutates vendor
# session files, never intentionally indexes or repairs" — not "zero writes".
set -uo pipefail

CASS_BIN="${CASS_RO_BIN:-cass}"
TIMEOUT_SECS="${CASS_RO_TIMEOUT:-8}"

# Only what the skill actually needs on the production path.
ALLOWED_SUBCOMMANDS="api-version status search view expand pack sessions"
# Every flag the skill is allowed to pass. Anything else starting with '-' is refused.
ALLOWED_FLAGS="--json --robot-meta --robot-format --limit --offset --timeout --mode --fields
--max-content-length --max-tokens --max-evidence --max-sessions --max-excerpt-chars
--workspace --agent --since --until --days --line --context -n -C"

die() { echo "cass-ro: refused: $*" >&2; exit 42; }

[ $# -ge 1 ] || die "no subcommand given"

# Exact compare — a substring match would let "view expand" through as one arg.
sub="$1"; ok=0
for a in $ALLOWED_SUBCOMMANDS; do [ "$sub" = "$a" ] && { ok=1; break; }; done
[ "$ok" -eq 1 ] || die "subcommand '$sub' is not allow-listed"

shift
for arg in "$@"; do
  case "$arg" in
    -*)
      # Reject the '=' form too: match only the part before '='.
      base="${arg%%=*}"; ok=0
      for a in $ALLOWED_FLAGS; do [ "$base" = "$a" ] && { ok=1; break; }; done
      [ "$ok" -eq 1 ] || die "flag '$arg' is not allow-listed"
      ;;
  esac
done

# cass writes trace JSONL when these are set — strip them regardless of caller env.
unset CASS_TRACE_FILE CASS_SEARCH_MODE

# GNU timeout is not a macOS default; degrade to no timeout rather than failing.
# -k ensures a TERM-ignoring cass is actually killed rather than orphaned.
if command -v timeout >/dev/null 2>&1;    then exec timeout -k 2s "${TIMEOUT_SECS}s" "$CASS_BIN" "$sub" "$@"
elif command -v gtimeout >/dev/null 2>&1; then exec gtimeout -k 2s "${TIMEOUT_SECS}s" "$CASS_BIN" "$sub" "$@"
else
  echo "cass-ro: warning: no timeout(1); hang containment is DISABLED" >&2
  exec "$CASS_BIN" "$sub" "$@"
fi
```

**Step 4: Run the tests to verify they pass**

```bash
chmod +x session-history/scripts/cass-ro
./session-history/scripts/test-cass-ro.sh
```

Expected: every line `ok`, exit 0.

**Step 5: Lint**

```bash
shellcheck session-history/scripts/cass-ro session-history/scripts/test-cass-ro.sh
```

Expected: no output.

**Step 6: Verify against the real cass**

```bash
./session-history/scripts/cass-ro api-version --json | head -3   # expect JSON, exit 0
./session-history/scripts/cass-ro index; echo "exit=$?"          # expect refusal, exit 42
```

**Step 7: Commit**

```bash
cd ~/coding/claude_code/skills/my_claude_skills
git add session-history/scripts/cass-ro session-history/scripts/test-cass-ro.sh
git commit -m "feat: add read-only cass guard with allow-list and timeout"
```

---

## Task 3: SKILL.md

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills/session-history/SKILL.md`

**Step 1: Write the frontmatter and the contract**

```yaml
---
name: session-history
description: Search and read past Claude Code and Codex sessions across all projects. Use when asked to find a session where something was worked on, recall how something was done before, or read a specific past session. Read-only; never modifies session data or indexes.
context: fork
background: false
---
```

`context: fork` runs the skill in its own subagent so transcripts never enter the caller's context.

**`background: false` is required, not optional.** Forked skills default to `background: true`
(v2.1.218+) — the caller keeps working and the result arrives later. A retrieval skill whose caller
always needs the envelope before it can proceed must block.

Note the fork still loads harness context (CLAUDE.md) because no `agent:` is set (default
`general-purpose`). Setting `agent: Explore` would skip CLAUDE.md — don't change this casually.

**Step 2: Document the three operations and the evidence envelope**

- **`find <query>`** — ranked candidate sessions. Default: all projects, Claude + Codex.
- **`read <session-id>`** — a known session, in bounded windows. Required by `handover-from-session`
  (Task 6) and by any lookup of a session that now exists only in the archive.
- **`evidence <query>`** — bounded cited excerpts via `cass pack`. **Not** "synthesize an answer":
  the caller synthesizes.

An earlier draft said "exactly two operations", which contradicted both the skill's own goal ("find
**and read**") and Task 6's need for archived full-session reads. Three is the honest number. All
three are retrieval; none performs analysis, so the retrieval-only boundary holds.

Every result is an evidence envelope. Consumers must never see cass row IDs, cass's SQLite schema, encoded Claude project-directory names, or Codex rollout filename conventions:

```
provider            claude | codex
native_session_id   the vendor's own session ID
project             cwd of the session
timestamp
source_kind         live | preserved | cass-archive
source_locator      file path or archive key
hit_locator         message_index | record_uuid | line_number
bounded_excerpt     capped, see byte limits below
index_freshness     fresh | stale:<days> | unknown
```

**Step 3: Write the search procedure — including the stale-index union**

This is the part most likely to be got wrong, so state it as an explicit procedure:

1. Probe: `cass-ro api-version --json`, then `cass-ro status --json`. Read `index.last_indexed_at` — **that is the coverage point**. **Do not gate on `cass health`** — it exits 1 on a merely stale index, which must still be searched.
2. Run `cass-ro search "<query>" --json --limit N --mode lexical`.
3. **Validate before trusting.** Exit 0 does not mean cass did what you asked — it reinterprets unknown input as a search and still exits 0. Treat output as valid only if it parses as JSON with the expected top-level keys; otherwise use the raw path.
4. **If the index is stale, also search the raw delta** and merge. Not optional: the index has been stale ~31 days, so "union" currently means "cass for older, raw for the last month."

   ```bash
   # BSD find rejects the ISO 'Z' form; convert first.
   COVER="$(jq -r '.index.last_indexed_at' <<<"$STATUS")"      # 2026-07-10T11:55:10Z
   COVER_BSD="$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$COVER" '+%Y-%m-%d %H:%M:%S UTC')"
   find ~/.claude/projects ~/.codex/sessions -name '*.jsonl' -newermt "$COVER_BSD"
   ```

5. **Merge key.** cass hits carry **no session-id field** (only `source_path`, `agent`, `workspace`, `created_at`, `line_number`, …). Derive it:
   - Claude → the filename stem: `<session-id>.jsonl`
   - Codex → the trailing UUID of `rollout-*.jsonl`, or `session_meta.payload`

   Merge and de-duplicate on `(provider, native_session_id)`.
6. If `cass-ro` exits non-zero (refused, timed out, cass missing), fall through to the raw path for the whole query and mark `index_freshness: unknown`.

**Step 4: Write the raw path with byte bounds**

**Two projections are required — Claude's `jq` returns nothing on Codex files.**

```bash
# Locate files — never print matching lines. A single Codex JSONL record can be ~60 MB.
rg -l --fixed-strings "<term>" ~/.claude/projects ~/.codex/sessions

# Claude: top-level .message / .sessionId / .cwd
jq -r 'select(.type=="user" or .type=="assistant")
       | {t: .timestamp, r: .message.role, s: .sessionId, c: .cwd,
          x: (.message.content | tostring | .[0:400])}' "<claude-file>"

# Codex: everything hangs off .payload; session id and cwd come from session_meta
jq -r 'select(.type=="response_item" or .type=="event_msg")
       | {t: .timestamp, r: (.payload.role // .type),
          x: (.payload.content // .payload | tostring | .[0:400])}' "<codex-file>"

jq -r 'select(.type=="session_meta") | {s: .payload.id, c: .payload.cwd}' "<codex-file>"
```

Rules to state explicitly:

- `rg -l` to locate, **never bare `rg -n` on JSONL** — one record can be tens of MB.
- `.[0:400]` slices *characters after parsing*, so `jq` still ingests the whole record. For files
  with known-huge records, get byte offsets first (`rg -abo`) and extract a bounded byte window
  before parsing.
- Tolerate unknown record types — filter for what you recognise, ignore the rest. The format drifts
  additively and Anthropic documents it as internal.

**Step 5: State the prohibitions**

- Never run `cass index`, `doctor --fix`, `search --refresh`, `pack --catch-up`, `models install`, or any watch/daemon mode. The guard enforces this; the skill must not try to route around it.
- **Never execute `triage.next_command` automatically** — `triage` recommends *operational recovery*. Treat its output as health evidence, not permission.
- Never modify anything under `~/.claude/` or `~/.codex/`.
- Prefer lexical search. The hybrid/semantic tier is new and unproven on this corpus; enable it only after the gold set says it helps.

**Step 6: Point at the recipe in one line**

> Mining sessions for lessons? Read `references/lessons-recipe.md`. It is a recipe you may follow, not an operation this skill performs.

**Step 7: Commit**

```bash
git add session-history/SKILL.md
git commit -m "feat: add session-history retrieval skill"
```

---

## Task 4: references/lessons-recipe.md

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills/session-history/references/lessons-recipe.md`

Salvage from `~/.agents/skills/ccbox-insights/` **before deleting it in Task 7**. Keep only the ~40 lines that are genuinely non-obvious:

- Course-correction record: **Trigger → Correction → Fix → Lesson**, where user clarifications, corrections and interruptions are the highest-signal moments in a transcript.
- Separate "tool failed" from "wrong approach" — a tool can succeed and still be the wrong move.
- Count explicit user rejections as their own category.
- Evidence-first: every counted failure carries a copied snippet; never infer.
- Prefer rules that fired 2+ times over one-off fixes.
- The failure taxonomy from `references/facets.md` (aggregation only).

**Open the file with an explicit disclaimer** so it is never mistaken for a contract:

> This is a recipe a consumer may choose to follow. The `session-history` skill does not perform this analysis and promises no output schema for it.

**Commit:**

```bash
git add session-history/references/lessons-recipe.md
git commit -m "docs: salvage session-mining heuristics as an optional recipe"
```

---

## Task 5: Install and smoke-test the skill

**Step 1: Symlink into the global skills directory**

```bash
ln -s ~/coding/claude_code/skills/my_claude_skills/session-history ~/.claude/skills/session-history
ls -la ~/.claude/skills/session-history
```

**Step 2: Verify Claude Code registers it** — start a session and confirm `session-history` appears in the skill roster.

**Step 3: Run the gold set (Task 1) against `find`.** Record hit rate. This is the baseline every later change is measured against.

**Step 4: Test degradation explicitly** — the hardest requirement is "works when the tool is broken":

```bash
CASS_RO_BIN=/nonexistent ./session-history/scripts/cass-ro search "foo" --json; echo "exit=$?"
CASS_RO_TIMEOUT=1 ./session-history/scripts/cass-ro search "foo" --json; echo "exit=$?"
```

Then confirm the skill still answers a query with cass unavailable, via the raw path alone.

**Step 5 (optional): give the guard actual teeth via permissions**

The guard is a convention plus a timeout — an agent can always run bare `cass` and bypass it. The
only mechanism that makes it real enforcement is a Claude Code permission rule: deny `Bash(cass *)`
and allow the `cass-ro` path. Without that, be honest that the script buys uniform fall-through, a
timeout, and one executable statement of the invariant — not a security boundary.

Decide deliberately. Adding the deny rule also blocks *you* from running `cass` ad hoc in this
project, which may not be worth it.

---

## Task 6: Migrate `handover-from-session`

**Files:**
- Modify: `~/coding/claude_code/skills/my_claude_skills_private/handover-from-session/SKILL.md`

Its ccbox use is three things; **two are deletions, not migrations**:

1. **Project reverse-mapping** via `ccbox projects` → replace with `jq -r 'select(.cwd)|.cwd' <session>.jsonl | head -1`. Every message record carries `.cwd`.
2. **Scan fallback** when the JSONL isn't on disk → dead code. ccbox reads the same files the skill already locates. Delete.
3. **Paginated transcript reads** (`ccbox history --full --limit N --offset N`) → keep the existing raw-JSONL fast path; for sessions that exist only in the preserved archive, read the archive file. Invoke `session-history` by name only when it needs to *find* a session rather than read a known one.

Add an explicit degraded path: *"If a skill named `session-history` is available, use it. If not, use `rg`/`jq` over `~/.claude/projects` as described below."*

**Verify:** run the skill against a known session ID and confirm the handover doc is produced with no `ccbox` invocation.

```bash
grep -c ccbox handover-from-session/SKILL.md   # expect 0
```

**Commit** in the private repo (stage only this skill's files).

---

## Task 7: Migrate `refresh-harness` and delete `ccbox-insights`

**Files:**
- Modify: `~/coding/claude_code/skills/my_claude_skills_private/refresh-harness/SKILL.md`, `instructions.md`
- Delete: `~/.agents/skills/ccbox-insights/` (only after Task 4 has salvaged the recipe)

**Step 1: Remove the ccbox auto-install block** (`instructions.md` Phase 1). Auto-installing an abandoned tool is the worst artifact of the old design.

**Step 2: Make session history an optional enhancement, not a hard requirement.** `full`/`deep` should invoke `session-history` if present, use its bounded evidence, and otherwise continue from git/backlog/Memory Bank while reporting "session-history scan skipped."

**Step 3: Verify**

```bash
grep -rc ccbox refresh-harness/ | grep -v ':0' || echo "clean"
```

**Step 4: Delete `ccbox-insights` once the recipe is committed**

```bash
ls ~/coding/claude_code/skills/my_claude_skills/session-history/references/lessons-recipe.md  # must exist first
rm ~/.claude/skills/ccbox-insights && rm -rf ~/.agents/skills/ccbox-insights
```

**Step 5: Commit** (private repo, explicit paths only).

---

## Task 8: ADRs

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/decisions/0001-cass-license-rider.md`
- Create: `~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/decisions/0002-archive-ownership-boundary.md`

Use `claude_docs/templates/adr-template.md` (MADR 4.0.0).

**ADR 0001 — accept the cass license rider as a documented risk.** cass ships "MIT License (with OpenAI/Anthropic Rider)" (verified); the rider grants no rights to OpenAI, Anthropic, affiliates, or parties acting on their behalf. Ordinary personal use is almost certainly fine; the skill's purpose is nonetheless to have Claude Code invoke that binary, and the intent is to publish. Record the reasoning, note that the evidence envelope keeps cass swappable, and state what would change the decision.

**ADR 0002 — archive ownership boundary.** "Vendor raw histories and independently preserved copies are authoritative; search databases are disposable derivatives." Task 0 is what makes this true rather than aspirational.

**Commit** in the config repo.

---

## Definition of Done

- [ ] `test-cass-ro.sh` passes — **including the autocorrect cases** (`--refres`, `--refre`, `--refresh=true`); `shellcheck` clean
- [ ] Gold set (5+) runs against `find` with a recorded hit rate
- [ ] The skill answers a query with cass unavailable (raw path only)
- [ ] **Stale-index union verified end-to-end**: a session created *after* `index.last_indexed_at` is returned by `find`. This is the headline fix — if it isn't tested, it isn't done.
- [ ] **Codex path verified separately from Claude** — run `find` and `read` against a real `~/.codex/sessions` rollout and confirm non-empty output. A Claude-only `jq` returns nothing on Codex and fails silently.
- [ ] `grep -rc ccbox` returns zero across both consumer skills
- [ ] `ccbox-insights` deleted, its heuristics preserved in `references/`
- [ ] Raw mirror copied out of cass, **every blob verified by blake3 + size**, manifest committed, bodies outside git
- [ ] Two ADRs written
- [ ] Session log in `claude_docs/session_progress_details/`; `CLAUDE-activeContext.md` and `CLAUDE-decisions.md` updated

## Deliberately out of scope

- No custom indexer. No transcript-parsing library. No MCP server. No daemon.
- No generic extraction operation — the two consumers have different lenses; it would have no callers.
- No semantic tier until the gold set justifies it.
- `nicknisi/sessions` is the **watch candidate**, not an adoption: it auto-refreshes its index on use, which conflicts with the no-auto-index rule. Re-evaluate if it gains a read-only mode and sustains maintenance.
