#!/usr/bin/env bash
set -euo pipefail

# consult-codex.sh — Wrapper around `codex exec` for AI-to-AI second opinions.
# Delivers prompts via stdin (fd redirection) to avoid bash history / ps exposure.
#
# Usage:
#   consult-codex.sh [OPTIONS] [--] <PROMPT>
#   consult-codex.sh [OPTIONS] --prompt-file <FILE>
#
# Modes:
#   ask     (default) One-shot codex exec
#   resume  Continue most recent session (or specific --session-id)
#   review  Dedicated code review (--uncommitted, --base, --commit)
#
# Exit codes:
#   0   = success (result on stdout)
#   124 = timeout
#   *   = codex error (stderr has details)

# --- Defaults ---
MODE="ask"
MODEL="gpt-5.5"
EFFORT="high"
SANDBOX="read-only"
IDLE_TIMEOUT=120   # seconds of no JSONL activity before considering hung
SESSION_ID=""
PROMPT=""
PROMPT_FILE=""
EPHEMERAL=0
FAST=0
REVIEW_ARGS=()

# --- Check required binaries ---
if ! command -v codex &>/dev/null; then
    echo "Error: 'codex' not found on PATH (install and run 'codex login')" >&2
    exit 1
fi

# --- Helpers ---
require_value() {
    if [[ ${2+x} == "" || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "Error: $1 requires a value" >&2
        exit 1
    fi
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        require_value "$1" "${2:-}"; MODE="$2"; shift 2 ;;
        --prompt-file) require_value "$1" "${2:-}"; PROMPT_FILE="$2"; shift 2 ;;
        --model)       require_value "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
        --effort)      require_value "$1" "${2:-}"; EFFORT="$2"; shift 2 ;;
        --sandbox)     require_value "$1" "${2:-}"; SANDBOX="$2"; shift 2 ;;
        --timeout)     require_value "$1" "${2:-}"; IDLE_TIMEOUT="$2"; shift 2 ;;
        --session-id)  require_value "$1" "${2:-}"; SESSION_ID="$2"; shift 2 ;;
        --base)        require_value "$1" "${2:-}"; REVIEW_ARGS+=(--base "$2"); shift 2 ;;
        --commit)      require_value "$1" "${2:-}"; REVIEW_ARGS+=(--commit "$2"); shift 2 ;;
        --uncommitted) REVIEW_ARGS+=(--uncommitted); shift ;;
        --ephemeral)   EPHEMERAL=1; shift ;;
        --fast)        FAST=1; shift ;;
        --)            shift; PROMPT="$*"; break ;;
        -*)            echo "Error: unknown option '$1'" >&2; exit 1 ;;
        *)             PROMPT="$*"; break ;;
    esac
done

# --- Resolve prompt source ---
# Uses fd-based delivery: open file on fd 3, unlink path, then redirect to codex stdin.
# The file data remains readable via the open fd even after unlinking.
# Only files CREATED by this script are auto-deleted. User-supplied files are never deleted.
PROMPT_FD=""
OWNED_TEMP_FILE=""   # Track files we created so only we delete them

if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "Error: prompt file not found: $PROMPT_FILE" >&2
        exit 1
    fi
    if [[ ! -s "$PROMPT_FILE" ]]; then
        echo "Error: prompt file is empty: $PROMPT_FILE" >&2
        exit 1
    fi
    exec 3< "$PROMPT_FILE"
    PROMPT_FD=3
elif [[ -n "$PROMPT" ]]; then
    # Inline prompt: write to temp file, open on fd 3, unlink immediately
    OWNED_TEMP_FILE=$(mktemp)
    printf '%s' "$PROMPT" > "$OWNED_TEMP_FILE"
    exec 3< "$OWNED_TEMP_FILE"
    rm -f -- "$OWNED_TEMP_FILE"
    OWNED_TEMP_FILE=""
    PROMPT_FD=3
fi

# --- Validate inputs ---
if [[ ! "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$IDLE_TIMEOUT" -eq 0 ]]; then
    echo "Error: --timeout must be a positive integer, got: $IDLE_TIMEOUT" >&2
    exit 1
fi

if [[ -z "$PROMPT_FD" && "$MODE" != "review" ]]; then
    echo "Error: prompt required (use --prompt-file or pass as argument)" >&2
    exit 1
fi

# --- Temp files for output ---
RESULT_FILE=$(mktemp)
ERR_FILE=$(mktemp)
JSONL_FILE=$(mktemp)
CODEX_PID=""

cleanup() {
    # Kill codex if still running
    if [[ -n "${CODEX_PID:-}" ]]; then
        kill "$CODEX_PID" 2>/dev/null || true
        wait "$CODEX_PID" 2>/dev/null || true
    fi
    [[ -n "${PROMPT_FD:-}" ]] && exec 3<&- 2>/dev/null || true
    rm -f -- "${RESULT_FILE:-}" "${ERR_FILE:-}" "${JSONL_FILE:-}" "${OWNED_TEMP_FILE:-}"
}
trap cleanup EXIT INT TERM

# --- Build command ---
# Flag support differs by subcommand (verified against codex-cli 0.130.0):
#   codex exec:        -s, -m, -c, -o, --disable, --skip-git-repo-check, etc.
#   codex exec review: -m, -c, -o, --disable, --uncommitted, --base, --commit, --title (NO -s)
#   codex exec resume: -m, -c, -o, --disable, --last, [SESSION_ID] (NO -s)
#
# --json is always added: JSONL events stream to stdout for activity monitoring.
# -o RESULT_FILE captures the final message separately.
CMD=()

case "$MODE" in
    ask)
        CMD=(codex exec
            --json
            -m "$MODEL"
            -c "model_reasoning_effort=\"$EFFORT\""
            -s "$SANDBOX"
            --disable hooks
            -o "$RESULT_FILE")
        [[ "$FAST" -eq 1 ]] && CMD+=(-c 'service_tier="fast"')
        [[ "$EPHEMERAL" -eq 1 ]] && CMD+=(--ephemeral)
        CMD+=(-)
        ;;
    resume)
        CMD=(codex exec resume)
        if [[ -n "$SESSION_ID" ]]; then
            CMD+=("$SESSION_ID")
        else
            CMD+=(--last)
        fi
        CMD+=(--json
            -m "$MODEL"
            -c "model_reasoning_effort=\"$EFFORT\""
            --disable hooks
            -o "$RESULT_FILE")
        [[ "$FAST" -eq 1 ]] && CMD+=(-c 'service_tier="fast"')
        [[ "$EPHEMERAL" -eq 1 ]] && CMD+=(--ephemeral)
        CMD+=(-)
        ;;
    review)
        CMD=(codex exec review
            --json
            -m "$MODEL"
            -c "model_reasoning_effort=\"$EFFORT\""
            --disable hooks
            -o "$RESULT_FILE")
        [[ "$FAST" -eq 1 ]] && CMD+=(-c 'service_tier="fast"')
        [[ "$EPHEMERAL" -eq 1 ]] && CMD+=(--ephemeral)
        if [[ ${#REVIEW_ARGS[@]} -gt 0 ]]; then
            CMD+=("${REVIEW_ARGS[@]}")
        fi
        if [[ -n "$PROMPT_FD" ]]; then
            CMD+=(-)
        fi
        ;;
    *)
        echo "Error: unknown mode '$MODE' (use ask, resume, or review)" >&2
        exit 1
        ;;
esac

# --- Execute with activity-based idle watchdog ---
# Codex is run in the background. We monitor for activity by checking both:
# 1. JSONL output growth (stdout) — events like turn.started, item.completed
# 2. Stderr output growth — progress indicators
# 3. Process CPU time — if the process is actively using CPU, it's thinking
#
# JSONL events are sparse during deep thinking (can be >2min gap at xhigh),
# so we also check if the process is consuming CPU time. If CPU time advances,
# codex is actively working even without producing output. Only if BOTH
# output is static AND CPU time hasn't advanced do we consider it hung.

POLL_INTERVAL=5

if [[ -n "$PROMPT_FD" ]]; then
    # <&3 = prompt via stdin; 3<&- = close fd 3 in child
    "${CMD[@]}" <&3 3<&- >"$JSONL_FILE" 2>"$ERR_FILE" &
    CODEX_PID=$!
    exec 3<&-
else
    # review mode without custom prompt
    "${CMD[@]}" >"$JSONL_FILE" 2>"$ERR_FILE" &
    CODEX_PID=$!
fi

# Get combined CPU time (user + system) for a process tree
get_cpu_time() {
    # ps -o time= gives cumulative CPU time for the process
    # We check the codex process and its children
    ps -o time= -p "$1" 2>/dev/null | tr -d ' ' || echo "0:00.00"
}

LAST_OUTPUT_SIZE=0
LAST_CPU_TIME=""
IDLE_SECONDS=0

while kill -0 "$CODEX_PID" 2>/dev/null; do
    sleep "$POLL_INTERVAL"

    # Check output activity (JSONL + stderr combined)
    JSONL_SIZE=$(wc -c < "$JSONL_FILE" 2>/dev/null || echo 0)
    ERR_SIZE=$(wc -c < "$ERR_FILE" 2>/dev/null || echo 0)
    CURRENT_OUTPUT_SIZE=$((JSONL_SIZE + ERR_SIZE))

    # Check CPU activity
    CURRENT_CPU_TIME=$(get_cpu_time "$CODEX_PID")

    if [[ "$CURRENT_OUTPUT_SIZE" -ne "$LAST_OUTPUT_SIZE" ]] || [[ "$CURRENT_CPU_TIME" != "$LAST_CPU_TIME" ]]; then
        # Activity detected (output grew OR CPU time advanced)
        IDLE_SECONDS=0
        LAST_OUTPUT_SIZE=$CURRENT_OUTPUT_SIZE
        LAST_CPU_TIME=$CURRENT_CPU_TIME
    else
        # No activity
        IDLE_SECONDS=$((IDLE_SECONDS + POLL_INTERVAL))
        if [[ "$IDLE_SECONDS" -ge "$IDLE_TIMEOUT" ]]; then
            echo "Error: Codex appears hung (no output and no CPU activity for ${IDLE_TIMEOUT}s), terminating" >&2
            kill "$CODEX_PID" 2>/dev/null || true
            wait "$CODEX_PID" 2>/dev/null || true
            CODEX_PID=""
            # Print partial result if available
            [[ -s "$RESULT_FILE" ]] && cat "$RESULT_FILE"
            exit 124
        fi
    fi
done

# Codex exited — collect status
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?
CODEX_PID=""

# --- Output ---
if [[ "$EXIT_CODE" -eq 0 ]]; then
    if [[ -s "$RESULT_FILE" ]]; then
        cat "$RESULT_FILE"
    else
        echo "(Codex returned an empty response)" >&2
    fi
else
    echo "Error: Codex exited with code $EXIT_CODE" >&2
    [[ -s "$ERR_FILE" ]] && cat "$ERR_FILE" >&2
    # Print partial result if available
    [[ -s "$RESULT_FILE" ]] && cat "$RESULT_FILE"
    exit $EXIT_CODE
fi
