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

- `cass definitely-not-a-command` **exits 0**. cass does not reliably error on unknown subcommands, so the guard's allow-list is load-bearing — it cannot delegate validation to cass.
- `cass health` currently **exits 1** (stale index). A guard that gates on `health` before searching would disable cass entirely on a merely stale index — the exact case we must still query. **Do not gate on health.** Report it; search anyway.
- `cass search` supports `--limit`, `--json`, `--robot-meta`, `--robot-format`, `--timeout`, and the footgun `--refresh`.
- GNU `timeout` is at `/opt/homebrew/bin/timeout` on this machine but is **not** a macOS default. Degrade gracefully when absent.
- Claude transcripts: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; subagents in `subagents/agent-*.jsonl`. Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (different schema).
- Every Claude message record carries `.cwd`, so `jq -r 'select(.cwd)|.cwd' <file> | head -1` maps a session file to its project — no `ccbox projects` needed.

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

**Step 2: Enumerate cass's sessions as JSON**

```bash
cass sessions --json > /tmp/cass-sessions.json 2>/dev/null || cass sessions > /tmp/cass-sessions.txt
head -40 /tmp/cass-sessions.json
```

Inspect the shape before scripting against it — do not assume field names. If `--json` is unsupported on 0.6.22, fall back to the text form and parse defensively.

**Step 3: Export each session to a plain file**

`cass export <PATH>` takes a *session file path*, so drive it from the enumerated list. Write one file per session into the archive directory, named `<provider>_<native_session_id>.json`.

**Step 4: Write a tool-neutral manifest**

For each exported session record: `provider`, `native_session_id`, `original_path`, `cwd`, `started_at`, `bytes`, `sha256`. This is metadata, not an index — it lets a future tool know what exists and detects corruption without understanding cass's schema.

```bash
# after export, for each file:
shasum -a 256 "$f" | awk '{print $1}'
```

**Step 5: Verify the export is complete**

```bash
ls ~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/archive/sessions/*.json | wc -l
```

Expected: ≥ the `claude_code` conversation count cass reported in Step 1. **If materially fewer, stop and investigate** — do not proceed to Task 1 believing the data is safe.

**Step 6: Commit the manifest (not necessarily the bodies)**

Session bodies contain client work. Decide deliberately whether they belong in the config repo or in a backed-up directory outside git. The manifest is small and belongs in git either way.

```bash
cd ~/coding/claude_code/skills/my_claude_skills_claude_config
git add claude_docs/archive/manifest.json
git commit -m "chore: archive pre-2026-07-09 session history manifest"
```

---

## Task 1: Gold retrieval set

Cheap, and it is the only objective way to settle lexical-vs-hybrid later and to test the next migration.

**Files:**
- Create: `~/coding/claude_code/skills/my_claude_skills_claude_config/claude_docs/research/2026-08-08_session_investigation_skill/gold-retrieval-set.md`

**Step 1: Write ~20 questions you actually remember, each with its correct session ID**

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

check "allows api-version"            0  api-version
check "allows search --json"          0  search "foo" --json --limit 5
check "allows view"                   0  view /some/path.jsonl -n 42 --json
check "allows pack"                   0  pack "foo" --json --max-tokens 2000
check "refuses index"                42  index
check "refuses doctor --fix"         42  doctor --fix
check "refuses search --refresh"     42  search "foo" --json --refresh
check "refuses pack --catch-up"      42  pack "foo" --catch-up
check "refuses models install"       42  models install
check "refuses unknown subcommand"   42  definitely-not-a-command
check "refuses empty invocation"     42

# A refused flag must be caught anywhere in the arg list, not just position 2.
check "refuses --refresh at the end"  42  search "foo" --limit 5 --json --refresh

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
# cass-ro — run cass read-only: allow-list of safe subcommands, hard timeout.
#
# Exit codes:
#   0     cass ran and succeeded
#   42    refused by this guard (never reached cass)
#   124   timed out (GNU timeout convention)
#   other cass's own exit code
#
# The caller treats any non-zero as "fall through to rg/jq".
#
# Why an allow-list rather than a deny-list: `cass definitely-not-a-command`
# exits 0, so cass cannot be trusted to reject what we did not intend to run.
set -uo pipefail

CASS_BIN="${CASS_RO_BIN:-cass}"
TIMEOUT_SECS="${CASS_RO_TIMEOUT:-8}"

ALLOWED_SUBCOMMANDS="api-version capabilities status health search view expand pack sessions stats introspect triage"
FORBIDDEN_FLAGS="--refresh --catch-up --fix --apply --force-rebuild --full"

die() { echo "cass-ro: refused: $*" >&2; exit 42; }

[ $# -ge 1 ] || die "no subcommand given"

sub="$1"
case " $ALLOWED_SUBCOMMANDS " in
  *" $sub "*) ;;
  *) die "subcommand '$sub' is not on the allow-list" ;;
esac

for arg in "$@"; do
  for bad in $FORBIDDEN_FLAGS; do
    [ "$arg" = "$bad" ] && die "flag '$bad' mutates state"
  done
done

# GNU timeout is not a macOS default; degrade to no timeout rather than failing.
if command -v timeout >/dev/null 2>&1;      then exec timeout "${TIMEOUT_SECS}s" "$CASS_BIN" "$@"
elif command -v gtimeout >/dev/null 2>&1;   then exec gtimeout "${TIMEOUT_SECS}s" "$CASS_BIN" "$@"
else
  echo "cass-ro: warning: no timeout(1); running without a time limit" >&2
  exec "$CASS_BIN" "$@"
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
---
```

`context: fork` runs the skill in its own subagent so transcripts never enter the caller's context. Note the fork still loads harness context (CLAUDE.md) — it is not a blank process.

**Step 2: Document the two operations and the evidence envelope**

The body must specify exactly two operations. Anything more breaks the retrieval-only boundary.

- **`find <query>`** — ranked candidate sessions. Default: all projects, Claude + Codex.
- **`evidence <query>`** — bounded cited excerpts via `cass pack`. **Not** "synthesize an answer": the caller synthesizes.

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

1. Probe: `cass-ro api-version --json`, then `cass-ro status --json`. Record index freshness. **Do not gate on `cass health`** — it exits 1 on a merely stale index, which must still be searched.
2. Run `cass-ro search "<query>" --json --limit N`.
3. **If the index is stale, also search the raw delta** — files modified since the index coverage point — and merge by `native_session_id`. A stale-but-healthy cass returns a confident, well-ranked, *incomplete* answer; that is more dangerous than a failure.
4. If `cass-ro` exits non-zero (refused, timed out, cass missing), fall through to the raw path for the whole query and mark `index_freshness: unknown`.

**Step 4: Write the raw path with byte bounds**

```bash
# Locate files — never print matching lines. A single Codex JSONL record can be 60 MB.
rg -l --fixed-strings "<term>" ~/.claude/projects ~/.codex/sessions

# Project fields under an explicit byte cap.
jq -r 'select(.type=="user" or .type=="assistant")
       | {t: .timestamp, r: .message.role, s: .sessionId, c: .cwd,
          x: (.message.content | tostring | .[0:400])}' "<file>"
```

Rules to state explicitly: `rg -l` to locate, never bare `rg -n` on JSONL; cap excerpt **bytes**, not lines; tolerate unknown record types (filter on `.type` + `.message`, ignore the rest).

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

- [ ] `test-cass-ro.sh` passes; `shellcheck` clean
- [ ] Gold set runs against `find` with a recorded hit rate
- [ ] The skill answers a query with cass unavailable (raw path only)
- [ ] Stale-index union verified: a session newer than the index is still found
- [ ] `grep -rc ccbox` returns zero across both consumer skills
- [ ] `ccbox-insights` deleted, its heuristics preserved in `references/`
- [ ] Pre-2026-07-09 history exported and manifest committed
- [ ] Two ADRs written
- [ ] Session log in `claude_docs/session_progress_details/`; `CLAUDE-activeContext.md` and `CLAUDE-decisions.md` updated

## Deliberately out of scope

- No custom indexer. No transcript-parsing library. No MCP server. No daemon.
- No generic extraction operation — the two consumers have different lenses; it would have no callers.
- No semantic tier until the gold set justifies it.
- `nicknisi/sessions` is the **watch candidate**, not an adoption: it auto-refreshes its index on use, which conflicts with the no-auto-index rule. Re-evaluate if it gains a read-only mode and sustains maintenance.
