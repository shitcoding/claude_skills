---
name: silent-test-runner
description: Use when running tests in any project. Wraps test commands to suppress passing output and only show failures, preventing test logs from polluting Claude context window.
---

# Silent Test Runner

## Overview

Run test commands silently — capture output to a temp file, print only on failure. Passing tests produce a single `✓` line instead of hundreds of lines of output. This keeps the Claude context window clean when agents run tests repeatedly.

## When to Use

- Any time tests need to be run (`run tests`, `run the tests`, `test X`)
- Running tests for a specific module or file
- QA agents running test suites
- Any test execution during development

**When NOT to use:**
- User explicitly asks for verbose/full output (`--info`, `--debug`, `--verbose`)
- User says "show me the full test output"

## The Shell Function

Emit this function inline in every Bash tool call that runs tests. Do NOT create persistent scripts in the project.

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMP_FILES=()

cleanup() {
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

run_silent() {
    local description="$1"
    shift
    local tmp_file
    tmp_file=$(mktemp)
    TEMP_FILES+=("$tmp_file")

    if "$@" > "$tmp_file" 2>&1; then
        printf "  \033[32m✓\033[0m %s\n" "$description"
        rm -f "$tmp_file"
        return 0
    else
        local exit_code=$?
        printf "  \033[31m✗\033[0m %s (exit %d)\n" "$description" "$exit_code"
        echo "--- Output ---"
        cat "$tmp_file"
        echo "--- End ---"
        rm -f "$tmp_file"
        return "$exit_code"
    fi
}
```

### Critical Design Decisions (Do NOT Change)

| Decision | Why |
|----------|-----|
| `"$@"` not `eval` | `eval` has command injection risks; `"$@"` preserves argument quoting |
| `$?` captured in `else` branch | `local x=$?` after `printf` would capture printf's exit code (0), not the command's |
| `${TEMP_FILES[@]+"${TEMP_FILES[@]}"}` | Required for `set -u` compatibility with empty arrays |
| `trap cleanup EXIT INT TERM` | Prevents temp file leaks on Ctrl-C / kill |

## Auto-Detection

Before running tests, detect the project's test framework:

| File Present | Framework | Command |
|-------------|-----------|---------|
| `build.gradle.kts` / `build.gradle` | Gradle | `./gradlew test` |
| `pom.xml` | Maven | `mvn test` |
| `package.json` (with `test` script) | npm/yarn/pnpm | `npm test` |
| `Cargo.toml` | Rust | `cargo test` |
| `go.mod` | Go | `go test ./...` |
| `pytest.ini` / `pyproject.toml` / `setup.py` | Python | `pytest` |
| `Makefile` (with `test` target) | Make | `make test` |

- **Multiple detected:** Ask the user which to use
- **None detected:** Ask the user for the test command — do not guess

## Multi-Module Projects

For projects with submodules (e.g., Gradle subprojects), run each module separately so:
1. A failure in one module doesn't prevent others from running
2. The summary shows exactly which modules passed/failed

Example for Gradle:
```bash
# Detect subprojects, then for each:
run_silent "core tests" ./gradlew :core:test
run_silent "api tests" ./gradlew :api:test
run_silent "snapshot tests" ./gradlew :snapshot:test
```

## Summary Output

After all suites finish, print a summary:

**All pass:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
All N suite(s) passed.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Some fail:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
M failed, N passed (failed: module1, module2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Track results with arrays:
```bash
PASSED=()
FAILED=()

# After each run_silent call, check exit code and append to appropriate array
# Then print summary at the end
```

## Full Bash Template

Here's the complete pattern for a Bash tool call. Adapt the test commands to the detected framework:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

run_silent() {
    local description="$1"
    shift
    local tmp_file
    tmp_file=$(mktemp)
    TEMP_FILES+=("$tmp_file")
    if "$@" > "$tmp_file" 2>&1; then
        printf "  \033[32m✓\033[0m %s\n" "$description"
        rm -f "$tmp_file"
        return 0
    else
        local exit_code=$?
        printf "  \033[31m✗\033[0m %s (exit %d)\n" "$description" "$exit_code"
        echo "--- Output ---"
        cat "$tmp_file"
        echo "--- End ---"
        rm -f "$tmp_file"
        return "$exit_code"
    fi
}

PASSED=()
FAILED=()

echo "Running tests..."
echo ""

# Run each suite (adapt commands to project)
if run_silent "core tests" ./gradlew :core:test; then
    PASSED+=("core")
else
    FAILED+=("core")
fi

if run_silent "api tests" ./gradlew :api:test; then
    PASSED+=("api")
else
    FAILED+=("api")
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$(( ${#PASSED[@]} + ${#FAILED[@]} ))
if [ ${#FAILED[@]} -eq 0 ]; then
    printf "All %d suite(s) passed.\n" "$TOTAL"
else
    FAILED_NAMES=$(IFS=', '; echo "${FAILED[*]}")
    printf "%d failed, %d passed (failed: %s)\n" "${#FAILED[@]}" "${#PASSED[@]}" "$FAILED_NAMES"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with failure if any suite failed
[ ${#FAILED[@]} -eq 0 ]
```

## Invocation Patterns

| User says | Action |
|-----------|--------|
| "run tests" / "run the tests" | Auto-detect framework, run all tests |
| "run tests for auth module" | Run specific module/package only |
| "test auth.test.ts" | Run single test file |
| "run tests silently" | Same as "run tests" (always silent) |
| "run tests with full output" | Bypass skill, run directly |

## Edge Cases

- **Test command not found** (e.g., no `./gradlew`): Show clear error, don't guess alternatives
- **User wants verbose output**: If they explicitly ask for full output or use `--info`/`--debug`/`--verbose`, bypass the silent wrapper and run the command directly
- **Timeout**: Don't add artificial timeouts — the test framework and Bash tool have their own

## Integration

### Project-level CLAUDE.md

```markdown
## Testing
When running tests, always use the `silent-test-runner` skill to keep context clean.
Only failed test output should appear in the conversation.
```

### QA agent instructions

```markdown
## Running Tests (MANDATORY)
**ALWAYS use the `silent-test-runner` skill when running tests.**
Never run raw test commands (e.g., `./gradlew test`, `npm test`) directly —
this floods the context with passing test output. The skill suppresses passing
output and only shows failures.
```
