---
name: markdown-to-pdf
description: "Export Markdown files to PDF with selectable visual themes. Use when asked to turn a .md file into a PDF, produce a PDF report or deliverable from Markdown, print Markdown, or apply a different look to an exported document. Renders through pandoc + a CSS theme + headless Chrome, so tables, code blocks and non-Latin scripts (Cyrillic, Greek, CJK) come out right; no LaTeX. Checks its own output, because a PDF that builds is not a PDF that is correct."
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/md2pdf *)
---

# Markdown → PDF

A PDF is just a rendered web page printed to paper. This skill does exactly that:
**pandoc → HTML with a CSS theme inlined → headless Chrome `--print-to-pdf`**. Styling is ordinary
CSS, so anything the browser can render, the PDF gets.

## Usage

```bash
scripts/md2pdf report.md                      # -> report.pdf, bundled "print" theme, A4
scripts/md2pdf -t github report.md            # a different theme
scripts/md2pdf --list-themes                  # what themes resolve on this machine
scripts/md2pdf a.md b.md c.md                 # batch; each gets its own PDF
scripts/md2pdf --lang ru -o out.pdf report.md
```

| Flag | Effect |
|---|---|
| `-t, --theme NAME\|PATH` | bundled theme name, or a path to any `.css` (default `print`) |
| `-o, --output PATH` | output file (single input only; default: alongside the input) |
| `--title TEXT` | override the leading-H1 title |
| `--lang CODE` | sets `<html lang>` — worth setting for correct hyphenation |
| `--no-page-breaks` | don't start a new page at each top-level heading |
| `--keep-html` | keep the intermediate HTML next to the PDF (debugging) |
| `--no-verify` | skip the output checks |
| `--browser PATH` | override browser detection (also `MD2PDF_BROWSER`) |

## Requirements

- **pandoc** — `brew install pandoc` / `apt install pandoc`. The only hard prerequisite.
- **A Chromium-family browser** — Chrome, Chromium, Brave or Edge. Resolved automatically:
  macOS `/Applications` first, then PATH (`google-chrome`, `chromium`, `brave-browser`, …).
- Nothing else. The `print` theme ships with the skill.

No LaTeX, no venv, no Python packages — the script is stdlib only.

## Themes

`--theme NAME` resolves against the skill's own `themes/` directory. A value containing `/` or
ending in `.css` is used as a path, so any stylesheet on disk works.

The bundled **`print`** theme is A4 with tight margins, a 10.5px base and compact tables — built for
client reports on paper. `--list-themes` shows what ships with the skill.

A theme is plain CSS with one requirement: its rules must be scoped to `#write`, the element this
skill wraps the document in.

**Paper size comes from the theme**, not from a flag. A theme's own `@media print { @page { size … } }`
is what Chrome honours. A theme that declares no `@page` gets Chrome's default, US Letter — the
verifier warns when that happens.

## Titles

The document's leading `#` heading becomes the title and is **removed from the body**, so it does not
render twice. YAML front matter is stepped over when looking for it. A document opening with prose, or
with a setext heading, simply gets no extracted title and is left untouched — pass `--title` to force one.

## Verification

Silent success is this domain's failure mode: the LaTeX route that was tried first exits 0 while
dropping every Cyrillic glyph. So every export is checked, and `--no-verify` is opt-out:

- **Structure of the generated HTML** — the `#write` wrapper is present, pandoc's default stylesheet
  has not leaked in, the inlined theme is not HTML-escaped. These three catch the bugs that otherwise
  produce a plausible-looking, wrong PDF.
- **The PDF is complete** — ends with `%%EOF`, is not a stub.
- **Page size** — `/MediaBox` read out of the PDF bytes, compared against what the theme's `@page` asked for.

Not checked (needs a browser driver, deliberately out of scope): the *rendered* content width. The
HTML structure checks stand in for it.

## Notes

- **Linux is unverified.** The browser resolver handles it, but this has only been run on macOS. In a
  container, set `MD2PDF_BROWSER_ARGS=--no-sandbox`.
- Chrome writes harmless `task_policy_set` noise to stderr on macOS. Its output is never the evidence;
  the PDF is.
- Chrome 153 headless does not exit when given a non-default `--user-data-dir`, even after writing the
  PDF. The skill uses a throwaway profile anyway — so it never touches the user's real Chrome profile —
  and stops the browser itself once the PDF is provably complete.

## Check

```bash
./check-md2pdf.sh        # dependency-free assertions; exports a real PDF
```
