# Session-History Search Skill Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

> **Note (2026-08-11):** the skill was renamed `session-history` → **`ai-sessions-reader`** after
> implementation, to avoid autocomplete collisions with the `session-logs-*` commands. This plan
> keeps the original name throughout as a record of the work as executed; the shipped skill lives
> at `ai-sessions-reader/`.

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

## Task 0: Archive the mirror, then restore pruned sessions (BLOCKING — do this first)

Claude Code pruned session transcripts on a 30-day window until `cleanupPeriodDays: 3650` was set on
2026-08-08. cass had already mirrored them **byte for byte**, so the deleted files are recoverable to
their exact original paths — not merely archivable.

**Order matters: archive first, restore second.** The archive is the stable recovery source; build it
before touching live Claude Code state.

### Evidence base (verified 2026-08-10)

A live round-trip was performed on one deleted session
(`-Users-<user>-coding-clawdbot/17b7b8d4-….jsonl`, now restored): bytes identical to the blob, size
exactly matching the manifest (1,258,316), 388/388 JSONL lines parsed, `compression: none`,
`encryption: none`, permissions `-rw-------`. The restored `source_mtime_ms` (20:53 +03:00) equals the
last in-file timestamp (17:53 UTC) — the same instant, confirming the manifest carries the true mtime.

Facts extracted from the Claude Code 2.1.220 binary itself (not inferred):

- **The `/resume` picker sorts by file mtime.** The lister stats each `.jsonl` and stores
  `mtime: l.mtime.getTime()`; the comparator is `QL_(e,t){if(t.mtime!==e.mtime)return t.mtime-e.mtime;…}`.
  In-file timestamps are only a fallback. **Restoring original mtimes is therefore mandatory** — fresh
  mtimes would stack 46 stale sessions above all current work in every picker.
- **`sessions-index.json` is dead.** The string appears **zero times** in the binary. The two on-disk
  copies are relics. Do not create or update it.
- **Retention cleanup deletes by mtime and reaps the whole session directory**: `if(!(i.mtime<t))`
  retain, else unlink, then `rm -rf` of `<uuid>/` including `.ccr-tip.json`, `.precompact.json` and
  file-history.
- **Orphaned session dirs are an anticipated state** — cleanup has an explicit branch for a session
  dir with no matching top-level `.jsonl`.
- The picker is a non-recursive `readdir` filtering `*.jsonl` with UUID basenames; subagent files are
  loaded on demand by parent sessionId, never listed as top-level entries.

### Inventory (measured 2026-08-10, reproduced independently by two reviewers)

| Under `~/.claude/projects` | Mirrored | Missing = restorable |
|---|---|---|
| Top-level sessions (resumable) | 80 | **46** |
| Subagent transcripts (`<parent-uuid>/subagents/agent-*.jsonl`) | 237 | **179** |
| **Total** | 317 | **225 files, 405,565,385 bytes** |

- **Zero orphans**: all 179 subagent transcripts have a parent that is either already on disk or among
  the 46 being restored. **Restore all 225 to their original paths** — do not split subagents into a
  separate destination. Doing so would add a second destination and a split manifest, and would break
  the vendor layout that Tasks 1–8 search, for no benefit.
- 4 project directories do not currently exist and will be created. Harmless: the all-projects picker
  lists them, and selecting a session from an unrelated project copies a `cd`+resume command rather
  than switching state.
- 0 duplicate manifests among the missing set. Oldest restorable: 2026-05-21. 70 GiB free.

### Scope guard — anchor, do not substring-match

**A substring test on `"/.claude/projects/"` is wrong and was a real defect.** 317 manifests match it
but only **309** are under `~/.claude/projects`; **8 are Claude *Desktop*** files at
`~/Library/Application Support/Claude/local-agent-mode-sessions/…/local_*/.claude/projects/…` — the
encoded Desktop sandbox cwd itself contains the substring. They exist on disk today so they would be
skipped today, but a Desktop sandbox cleanup would turn them into restore targets in a directory
Claude Code does not own.

Anchor with `startswith(os.path.expanduser("~/.claude/projects/"))`. Also out of scope, and excluded
by the anchor: `~/.codex/sessions` (797 manifests), other Claude Desktop paths (85), `~/.local/share`
(136).

**Step 1: Archive the mirror first (stable recovery source)**

`cass export --format json` is **lossy** — `--include-tools` and `--include-skills` are opt-in
("stripped for privacy"). Copy the raw mirror instead; it is byte-for-byte.

```bash
MIRROR=~/Library/Application\ Support/com.coding-agent-search.coding-agent-search/raw-mirror/v1
mkdir -p ~/Archive/ai-sessions
cp -R "$MIRROR"/blobs "$MIRROR"/manifests ~/Archive/ai-sessions/
du -sh ~/Archive/ai-sessions
```

Build the tool-neutral manifest by projecting cass's own — do not hand-build one, and do not compute a
second hash (the manifests already carry `blob_blake3`):

```bash
jq -s 'map({provider, original_path, source_size_bytes, blob_blake3, source_mtime_ms, captured_at_ms})' \
   ~/Archive/ai-sessions/manifests/*.json > ~/Archive/ai-sessions/manifest.json
jq 'group_by(.provider) | map({provider: .[0].provider, n: length})' ~/Archive/ai-sessions/manifest.json
```

**Bodies stay out of git** — ~872 MB of client work, and the config repo is pushed to GitHub. Only the
manifest is committed, and note that `original_path` can itself reveal client names.

**Step 2: Build the restore list, and stop on any count drift**

```bash
python3 - <<'PYEOF' > /tmp/restore-plan.json
import json,glob,os,sys
from pathlib import Path
mirror = os.path.expanduser("~/Library/Application Support/com.coding-agent-search.coding-agent-search/raw-mirror/v1")
anchor = os.path.expanduser("~/.claude/projects/")          # anchored, NOT a substring test
blobs_root = os.path.realpath(os.path.join(mirror, "blobs"))
skips = {}
def skip(reason): skips[reason] = skips.get(reason, 0) + 1
out = []
for m in glob.glob(mirror + "/manifests/*.json"):
    try:
        d = json.load(open(m))
    except Exception:
        skip("unreadable manifest"); continue
    p = d.get("original_path") or ""
    if not p.startswith(anchor):                      skip("out of scope"); continue
    if os.path.exists(p):                             skip("target exists"); continue
    if d.get("compression", {}).get("state") != "none": skip("compressed"); continue
    if d.get("encryption", {}).get("state") != "none":  skip("encrypted"); continue
    blob = os.path.realpath(os.path.join(mirror, d["blob_relative_path"]))
    if not blob.startswith(blobs_root + os.sep):      skip("blob path escapes mirror"); continue
    if not os.path.isfile(blob):                      skip("blob missing"); continue
    out.append({"target": p, "blob": blob, "size": d["source_size_bytes"],
                "blake3": d["blob_blake3"], "mtime_ms": d["source_mtime_ms"]})
print(json.dumps(out, indent=1))
sys.stderr.write("skips: " + json.dumps(skips, indent=1) + "\n")
PYEOF

jq 'length' /tmp/restore-plan.json                                  # expect 225
jq -r '.[].target' /tmp/restore-plan.json | grep -c '/subagents/'   # expect 179
jq '[.[].size] | add' /tmp/restore-plan.json                        # expect 405565385
jq -r '.[].target' /tmp/restore-plan.json | sort | uniq -d | wc -l  # expect 0
```

**Stop and investigate on any drift from 225 / 179 / 405,565,385 / 0.** Skip reasons are printed to
stderr by cause — never silently swallowed.

**Step 3: Restore, with an incremental journal**

Invariants, in priority order:

1. **Never overwrite an existing file.** This protects live sessions, including the one you are
   running in. Published with `os.link`, which raises `FileExistsError` rather than overwriting —
   `os.replace` would silently clobber a file created between the check and the write.
2. **Restore the original mtime** — mandatory, per the picker's mtime sort.
3. **`chmod 600` before publishing**, matching Claude Code's convention and leaving no window at
   looser temp permissions.
4. **Verify per file**: size equals the manifest, `cmp` byte-identical to the blob, and the file
   parses as JSONL end to end.
5. **Journal every action immediately**, so a crash still leaves an authoritative rollback list.

```bash
find ~/.claude/projects -name '*.restore-tmp' -delete   # clear any leftovers from a previous crash

python3 - <<'PYEOF'
import json, os, shutil, filecmp
plan = json.load(open("/tmp/restore-plan.json"))
journal = open("/tmp/restore-journal.jsonl", "a", buffering=1)   # line-buffered: crash-safe
done = skipped = failed = 0
def log(action, target, detail=""):
    journal.write(json.dumps({"action": action, "target": target, "detail": detail}) + "\n")
for r in plan:
    t = r["target"]
    try:
        if os.path.exists(t):
            skipped += 1; log("skip", t, "exists"); continue
        os.makedirs(os.path.dirname(t), exist_ok=True)
        tmp = t + ".restore-tmp"
        shutil.copyfile(r["blob"], tmp)
        if os.path.getsize(tmp) != r["size"]:
            os.remove(tmp); failed += 1; log("fail", t, "size mismatch"); continue
        if not filecmp.cmp(r["blob"], tmp, shallow=False):
            os.remove(tmp); failed += 1; log("fail", t, "bytes differ"); continue
        ok = bad = 0
        for line in open(tmp, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line: continue
            try: json.loads(line); ok += 1
            except Exception: bad += 1
        if bad or ok == 0:
            os.remove(tmp); failed += 1; log("fail", t, f"unparseable ({bad} bad)"); continue
        os.chmod(tmp, 0o600)
        try:
            os.link(tmp, t)          # no-overwrite publish; raises if target appeared meanwhile
        except FileExistsError:
            os.remove(tmp); skipped += 1; log("skip", t, "appeared during restore"); continue
        os.remove(tmp)
        s = r["mtime_ms"] / 1000
        os.utime(t, (s, s))
        done += 1; log("restored", t)
    except Exception as e:
        failed += 1; log("fail", t, f"{type(e).__name__}: {e}")
print(f"restored={done} skipped={skipped} failed={failed}")
PYEOF
```

**Step 4: Verify and preserve the rollback list**

```bash
grep -c '"action": "restored"' /tmp/restore-journal.jsonl   # expect 225
grep '"action": "fail"'        /tmp/restore-journal.jsonl   # expect empty
cp /tmp/restore-journal.jsonl ~/Archive/ai-sessions/        # /tmp is wiped on reboot
```

Rollback is `rm` of exactly the `restored` paths in the journal. Note it leaves the 4 created project
directories and any `<uuid>/subagents/` directories behind, empty — harmless, and Claude Code's
cleanup opportunistically removes empty dirs, but "rollback is complete" is not literally true.

**Step 5: Confirm Claude Code still behaves**

`sessions-index.json` is not required (verified: the string is absent from the binary). Nothing else —
`history.jsonl` is arrow-up prompt history, `__store.db` does not exist on this machine — needs
updating. Scanning `.jsonl` is genuinely sufficient.

1. `claude --resume` in a project that received restored sessions — do they appear, dated correctly?
2. Open one **with `--fork-session`**, not a plain resume: a plain resume writes into the restored
   transcript, mutating the artifact you just recovered.
3. `claude --resume` in a project that received nothing — confirm it is unchanged.
4. Confirm the currently-running session's `.jsonl` is untouched.

**Do not claim `/rewind` fidelity.** Checkpoint and file-history state lives outside the transcript
and was pruned with the originals; a restored session resumes and searches fine, but `/rewind` has
nothing to rewind to (the binary logs "FileHistory: Missing most recent snapshot" and continues).
Resuming an old session is otherwise safe by design: a retired model is not restored, `plan`/
`bypassPermissions` are never restored, settings files are re-read at launch, and a missing agent
degrades to defaults with a warning.

**Step 6: Record the retention hazard**

> These 225 files carry mtimes from May–July 2026. Retention cleanup deletes by mtime and `rm -rf`s
> the session directory with it. **If `cleanupPeriodDays` is ever lowered back to 30, all 225 are
> deleted again on the next startup pass.** The Step 1 archive is the durable copy; `~/.claude/projects`
> is not.

Add a preflight assertion before any future re-run:

```bash
jq -e '.cleanupPeriodDays >= 365' ~/.claude/settings.json >/dev/null \
  || echo "REFUSING: cleanupPeriodDays is too low; restored files would be pruned"
```

**Step 7: Commit the manifest**

```bash
cd ~/coding/claude_code/skills/my_claude_skills_claude_config
mkdir -p claude_docs/archive
cp ~/Archive/ai-sessions/manifest.json claude_docs/archive/manifest.json
git add claude_docs/archive/manifest.json
git commit -m "chore: record archived session manifest"
```

**Note on verification depth:** `b3sum`/`blake3` are not installed, so blobs are not re-hashed. This is
deliberate. The blobs were blake3-verified by cass at capture (`verification.content_blake3` in every
manifest), the restore is a same-disk copy, and `cmp` byte-compares each restored file against its
source — strictly stronger than a hash for *copy* integrity, and requiring no new tooling. The
manifests retain `blob_blake3` if a future audit wants it.

**cass will not interfere:** no cass daemon in `ps`, no launchd agent, and `cass status` reports a
passive stale index. Restored files are re-ingested only when someone runs `cass index` explicitly —
which is desirable for Tasks 1–8 and never mutates the source files.

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
