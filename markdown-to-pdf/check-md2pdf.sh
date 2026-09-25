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

echo "== relative assets and body-text false positives"
python3 - "$TMP/img.png" <<'MKPNG' || fatal "cannot write the png fixture"
import zlib, struct, sys
W, H = 32, 16
rows = b"".join(b"\x00" + bytes((10, 20, 200)) * W for _ in range(H))
def ch(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n"
       + ch(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + ch(b"IDAT", zlib.compress(rows, 9)) + ch(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
MKPNG
cat > "$TMP/assets.md" <<'MD' || fatal "cannot write fixture"
# Assets And Prose

![a chart](img.png)

This paragraph deliberately mentions body{max-width: 36em}, which is a symptom to look
for in the stylesheet and must never be looked for in the body.
MD
[[ -s "$TMP/img.png" ]] || fatal "png fixture is empty"

out="$("$MD2PDF" "$TMP/assets.md" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "a document whose body mentions max-width:36em still exports" \
  || bad "false positive on body prose (rc=$rc)" "$out"

# The intermediate HTML must render beside the Markdown, or relative images resolve
# against the wrong directory and are dropped with no error.
embedded="$(python3 -c '
import re, sys
d = open(sys.argv[1], "rb").read()
print(len(re.findall(rb"/Width\s+32[^>]{0,80}?/Height\s+16", d)
       or re.findall(rb"/Height\s+16[^>]{0,80}?/Width\s+32", d)))' "$TMP/assets.pdf" 2>/dev/null)"
[[ "$embedded" == "1" ]] && ok "a relative image is embedded without --keep-html" \
  || bad "the relative image did not reach the PDF (matches=$embedded)"

[[ ! -e "$TMP/assets.md2pdf-tmp.html" ]] && ok "the intermediate HTML is cleaned up" \
  || bad "left behind $TMP/assets.md2pdf-tmp.html"

echo "== heading orphan control (--keep-lines)"
"$MD2PDF" --keep-html -o "$TMP/kl.pdf" "$TMP/basic.md" >/dev/null 2>&1 || fatal "keep-lines export failed"
klhtml="$(cat "$TMP/kl.html")"
have "$klhtml" "1rlh" && ok "the heading reserve is emitted by default" || bad "no reserve rule"
have "$klhtml" "h1 + * + *" \
  && ok "the heading is bound to its second following sibling too" || bad "no sibling-chain rule"

"$MD2PDF" --keep-html --keep-lines 0 -o "$TMP/kl0.pdf" "$TMP/basic.md" >/dev/null 2>&1 \
  || fatal "--keep-lines 0 export failed"
have "$(cat "$TMP/kl0.html")" "1rlh" \
  && bad "--keep-lines 0 still emitted the reserve" || ok "--keep-lines 0 drops it"

out="$("$MD2PDF" --keep-lines -1 "$TMP/basic.md" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "a negative --keep-lines is rejected" || bad "negative keep-lines accepted"

# Behavioural: a heading whose section opens with an intro line and an unsplittable
# table must not be left behind when the table jumps to the next page.
if command -v pdftotext >/dev/null && command -v pdfinfo >/dev/null; then
  { echo "# Orphan Case"; echo
    for i in $(seq 1 34); do
      echo "Filler line $i. lorem ipsum dolor sit amet consectetur adipiscing elit sed do."; echo
    done
    echo "## Stranded Heading"; echo
    echo "An introductory sentence before the table."; echo
    echo "| A | B | C |"; echo "|---|---|---|"
    for i in $(seq 1 8); do echo "| r$i | value $i | $((i * 137)) |"; done
    echo; echo "Trailing text."
  } > "$TMP/orphan.md" || fatal "cannot write orphan fixture"

  heading_page() {  # prints the page number the heading lands on
    local pdf="$1" n p
    n=$(pdfinfo "$pdf" | sed -n 's/^Pages: *//p')
    for ((p = 1; p <= n; p++)); do
      if [[ "$(pdftotext -f "$p" -l "$p" "$pdf" - 2>/dev/null)" == *"Stranded Heading"* ]]; then
        echo "$p"; return
      fi
    done
    echo 0
  }

  "$MD2PDF" --keep-lines 0 -o "$TMP/orphan-off.pdf" "$TMP/orphan.md" >/dev/null 2>&1 \
    || fatal "orphan-off export failed"
  "$MD2PDF" -o "$TMP/orphan-on.pdf" "$TMP/orphan.md" >/dev/null 2>&1 \
    || fatal "orphan-on export failed"
  off="$(heading_page "$TMP/orphan-off.pdf")"
  on="$(heading_page "$TMP/orphan-on.pdf")"
  # The fixture is tuned so the table does not fit on page 1. Without the rule the
  # heading stays behind on page 1; with it, it travels with its table.
  [[ "$off" == "1" ]] \
    && ok "fixture reproduces the orphan with --keep-lines 0 (heading on page $off)" \
    || bad "fixture no longer strands the heading (page $off) -- retune it, the test below is vacuous otherwise"
  [[ "$on" -gt "$off" ]] \
    && ok "the heading travels with its table by default (page $off -> $on)" \
    || bad "the heading was still stranded on page $on"
else
  echo "  SKIP heading-orphan behaviour: pdftotext/pdfinfo not installed (brew install poppler)"
fi

echo "== a run of stacked headings is never split across pages"
have "$klhtml" ":has(+ :is(" \
  && ok "consecutive headings have their reserve suppressed" \
  || bad "no :has() suppression -- stacked headings will each reserve and get split"

if command -v pdftotext >/dev/null && command -v pdfinfo >/dev/null; then
  { echo "# Stack Probe"; echo
    for i in $(seq 1 36); do
      echo "Filler line $i. lorem ipsum dolor sit amet consectetur adipiscing elit sed do."; echo
    done
    echo "## Heading levels"; echo
    echo "### Heading level 3"; echo
    echo "#### Heading level 4"; echo
    echo "##### Heading level 5"; echo
    echo "###### Heading level 6"; echo
    echo "Body text under the deepest heading."
  } > "$TMP/stack.md" || fatal "cannot write stack fixture"

  run_pages() {   # prints one "page:count" per page holding stacked headings
    local pdf="$1" n p c
    n=$(pdfinfo "$pdf" | sed -n 's/^Pages: *//p')
    for ((p = 1; p <= n; p++)); do
      c=$(pdftotext -f "$p" -l "$p" "$pdf" - 2>/dev/null | grep -cE 'Heading level [3-6]')
      [[ "$c" -gt 0 ]] && printf '%s:%s ' "$p" "$c"
    done
  }

  "$MD2PDF" -o "$TMP/stack.pdf" "$TMP/stack.md" >/dev/null 2>&1 || fatal "stack export failed"
  got="$(run_pages "$TMP/stack.pdf")"
  [[ "$(echo "$got" | wc -w | tr -d ' ')" == "1" ]] \
    && ok "the h3-h6 run stays on one page ($got)" \
    || bad "the heading run was split across pages ($got)"

  # Non-vacuity: with the suppression removed, this same fixture MUST split --
  # otherwise the assertion above proves nothing.
  cp -R "$SKILL_DIR" "$TMP/nosupp" || fatal "cannot copy the skill"
  python3 - "$TMP/nosupp/templates/print.html5" <<'STRIP' || fatal "cannot strip the suppression"
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index("      /* A heading directly followed by another heading must NOT reserve")
j = s.index("      }", s.index(":has(+ :is(", i)) + len("      }\n")
open(p, "w").write(s[:i] + s[j:])
STRIP
  "$TMP/nosupp/scripts/md2pdf" -o "$TMP/stack-bad.pdf" "$TMP/stack.md" >/dev/null 2>&1 \
    || fatal "stripped-copy export failed"
  bad_got="$(run_pages "$TMP/stack-bad.pdf")"
  [[ "$(echo "$bad_got" | wc -w | tr -d ' ')" -gt 1 ]] \
    && ok "without the suppression the same fixture does split ($bad_got)" \
    || bad "fixture no longer discriminates ($bad_got) -- retune it, the test above is vacuous"
else
  echo "  SKIP stacked-heading behaviour: pdftotext/pdfinfo not installed (brew install poppler)"
fi

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
