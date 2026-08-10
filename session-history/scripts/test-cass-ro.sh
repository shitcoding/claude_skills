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
