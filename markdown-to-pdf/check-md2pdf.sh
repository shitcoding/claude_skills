#!/usr/bin/env bash
# Dependency-free assertions for markdown-to-pdf.
# Everything happens in a temp dir; no user files and no real browser profile are touched.
# `assertion && ok ... || bad ...` is the deliberate idiom throughout: ok/bad always
# succeed, so the || branch runs only when the assertion itself failed.
# shellcheck disable=SC2015
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MD2PDF="$SKILL_DIR/scripts/md2pdf"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-md2pdf.XXXXXX")"
trap '[[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; }
have() { [[ "$1" == *"$2"* ]] && return 0 || return 1; }

fatal() { printf 'fixture failure: %s\n' "$1" >&2; exit 2; }

# ---------------------------------------------------------------- fixtures
cat > "$TMP/basic.md" <<'MD' || fatal "cannot write fixture"
# Заголовок отчёта

Абзац.

- пункт

# Второй раздел

Текст.
MD

cat > "$TMP/frontmatter.md" <<'MD' || fatal "cannot write fixture"
---
author: someone
---

# Title After Front Matter

Body.
MD

cat > "$TMP/prose.md" <<'MD' || fatal "cannot write fixture"
This document opens with prose, not a heading.

## Only a level two heading
MD

[[ -s "$TMP/basic.md" && -s "$TMP/frontmatter.md" && -s "$TMP/prose.md" ]] \
  || fatal "fixtures did not land in $TMP"
[[ -x "$MD2PDF" ]] || fatal "$MD2PDF is not executable"

echo "== interface"
out="$("$MD2PDF" --help 2>&1)"
have "$out" "--no-page-breaks" && ok "--help lists the flags" || bad "--help" "$out"

out="$("$MD2PDF" --list-themes 2>&1)"
have "$out" "print" && ok "--list-themes finds the bundled print theme" || bad "--list-themes" "$out"

out="$("$MD2PDF" -t definitely-not-a-theme "$TMP/basic.md" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && have "$out" "not found" \
  && ok "an unknown theme is a hard error" || bad "unknown theme rc=$rc" "$out"

out="$("$MD2PDF" -o "$TMP/x.pdf" "$TMP/basic.md" "$TMP/prose.md" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "--output with several inputs is rejected" || bad "--output guard rc=$rc" "$out"

echo "== title handling"
"$MD2PDF" --keep-html "$TMP/basic.md" >/dev/null 2>&1 || fatal "basic export failed"
html="$(cat "$TMP/basic.html")"
n=$(sed -n '/<body>/,$p' "$TMP/basic.html" | grep -c 'Заголовок отчёта')
[[ "$n" == "1" ]] && ok "the leading H1 becomes the title exactly once in the body" \
  || bad "leading H1 appears $n times in the body (expected 1)"
have "$html" "<title>Заголовок отчёта</title>" \
  && ok "the H1 also becomes the document title" || bad "no <title> from the H1"

"$MD2PDF" --keep-html "$TMP/frontmatter.md" >/dev/null 2>&1 || fatal "front-matter export failed"
n=$(sed -n '/<body>/,$p' "$TMP/frontmatter.html" | grep -c 'Title After Front Matter')
[[ "$n" == "1" ]] && ok "front matter is stepped over to find the H1" \
  || bad "front-matter title appears $n times in the body (expected 1)"

"$MD2PDF" --keep-html "$TMP/prose.md" >/dev/null 2>&1 || fatal "prose export failed"
have "$(cat "$TMP/prose.html")" "This document opens with prose" \
  && ok "a document opening with prose keeps its first line" || bad "prose first line was eaten"

echo "== generated HTML (the checks that stand in for measuring the page)"
have "$html" '<div id="write">' \
  && ok "the #write wrapper is present (every theme rule is scoped to it)" \
  || bad "no #write wrapper"
have "$html" 'li > p' \
  && ok "theme child selectors survive verbatim (--include-in-header, not -M)" \
  || bad "theme child selectors missing -- is the CSS going through -M metadata again?"
head="${html%%</head>*}"
have "$head" '&gt;' && bad "the inlined CSS is HTML-escaped" \
  || ok "the inlined CSS is not HTML-escaped"
if [[ "$html" =~ max-width:[[:space:]]*36em ]]; then
  bad "pandoc's default stylesheet leaked in (body{max-width:36em})"
else
  ok "pandoc's default stylesheet is absent"
fi

have "$html" 'page-break-before: always' \
  && ok "page breaks before top headings are on by default" || bad "no page-break rule"
"$MD2PDF" --keep-html --no-page-breaks -o "$TMP/nb.pdf" "$TMP/basic.md" >/dev/null 2>&1 \
  || fatal "--no-page-breaks export failed"
have "$(cat "$TMP/nb.html")" 'page-break-before: always' \
  && bad "--no-page-breaks did not drop the rule" || ok "--no-page-breaks drops the rule"

echo "== the PDF"
[[ -s "$TMP/basic.pdf" ]] && ok "a PDF is produced" || bad "no PDF at $TMP/basic.pdf"
tail -c 2048 "$TMP/basic.pdf" | grep -q '%%EOF' \
  && ok "the PDF is complete (%%EOF present)" || bad "the PDF has no %%EOF marker"
mb="$(python3 - "$TMP/basic.pdf" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
for b in set(re.findall(rb'/MediaBox\s*\[([^\]]+)\]', d)):
    v = [float(x) for x in b.split()]
    print("%.0fx%.0f" % (abs(v[2]-v[0]), abs(v[3]-v[1])))
PY
)"
[[ "$mb" == "595x842" ]] && ok "page size is A4, as the bundled theme's @page asks ($mb pt)" \
  || bad "page size is $mb pt, expected 595x842 (A4)"
# The page count is the only evidence that the print CSS reached the PDF and not
# merely the HTML: basic.md has two top-level headings, so the page-break rule must
# split it in two, and --no-page-breaks must not.
count_pages() { python3 -c '
import re, sys
print(len(re.findall(rb"/Type\s*/Page[^s]", open(sys.argv[1], "rb").read())))' "$1"; }
pages="$(count_pages "$TMP/basic.pdf")"
[[ "$pages" == "2" ]] && ok "page breaks put the two top headings on two pages" \
  || bad "expected 2 pages with page breaks on, got $pages"
pages="$(count_pages "$TMP/nb.pdf")"
[[ "$pages" == "1" ]] && ok "--no-page-breaks keeps them on one page" \
  || bad "expected 1 page with --no-page-breaks, got $pages"

echo "== the structural checks actually fire (negative tests)"
# Copy the skill and break its template: if these stay green, the checks above are vacuous.
cp -R "$SKILL_DIR" "$TMP/broken" || fatal "cannot copy the skill"
perl -0pi -e 's/<div id="write">//' "$TMP/broken/templates/print.html5" \
  || fatal "cannot patch the template"
out="$("$TMP/broken/scripts/md2pdf" -o "$TMP/b1.pdf" "$TMP/basic.md" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && have "$out" "#write wrapper is missing" \
  && ok "a missing #write wrapper is caught" || bad "missing wrapper not caught (rc=$rc)" "$out"

cp -R "$SKILL_DIR" "$TMP/broken2" || fatal "cannot copy the skill"
perl -0pi -e 's|<style>|<style>body{max-width:36em}|' "$TMP/broken2/templates/print.html5" \
  || fatal "cannot patch the template"
out="$("$TMP/broken2/scripts/md2pdf" -o "$TMP/b2.pdf" "$TMP/basic.md" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && have "$out" "36em" \
  && ok "a leaked body{max-width:36em} is caught" || bad "36em leak not caught (rc=$rc)" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
