---
name: browser-testing
description: "Visual inspection and testing of any website via headless Chrome + CDP. Use to check how pages look, test UI flows, inspect DOM elements, read a page's accessibility snapshot, check responsive layouts, run accessibility/SEO audits, and compare two pages (staging vs production). Direct programmatic DOM access — faster and more accurate than screenshot-based testing. Never opens a window or steals focus; each project gets its own isolated Chrome."
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/bt *)
---

# Browser Testing Skill

Inspect, test, and compare web pages using your real Chrome install, run **headless** and
driven over CDP (Chrome DevTools Protocol). Structured text output instead of screenshot-based
reasoning. No window ever opens, so the user's work is never interrupted.

## How It Works

1. **Headless Chrome** runs with a persistent profile (login sessions survive restart) and a
   CDP port. Its user agent is rewritten to the normal Chrome UA, so sites that block
   `HeadlessChrome` still work.
2. **Per-project isolation**: profile dir and port are derived from the project's git root, so
   sessions in different projects run separate Chromes with separate cookies and can run at the
   same time. A port already held by *another* project's Chrome is refused, never attached to.
3. **Playwright `connect_over_cdp()`** reuses the default context (preserving cookies/auth).
4. **JS evaluation** extracts structured page data: headings, links, images, forms, meta tags,
   console errors, failed requests.
5. **Auto-launch**: Chrome starts automatically if not running. **Auto-bootstrap**: the `bt`
   wrapper creates the Python venv on first run.
6. **Self-cleaning tabs**: every one-shot CLI call closes the tab it used. `--python` flows close
   the tabs they opened when the block exits (unless `keep_pages=True`).
7. **Always fresh**: each CLI call loads the page in a new tab, so after you change the site the
   next check reflects the change — and parallel calls never share a tab.

It drives **your real Chrome install** — no bundled browser download, no `playwright install`.

## Entry Point

One script does everything; always invoke it by its literal path (shell variables don't survive
between commands, and only the literal path is pre-approved):

```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com
```

`${CLAUDE_SKILL_DIR}` is substituted by Claude Code when this skill is loaded. If you are reading
this file from disk and see it literally, it means this file's own directory. Installations whose
path contains a space are not supported by the pre-approved pattern.

**First run** creates `.venv/` and installs playwright, pillow and axe-core (~20s). Requires
`python3` (3.10+) and Chrome/Chromium. If a dependency ever goes missing,
`${CLAUDE_SKILL_DIR}/scripts/bt --reinstall` rebuilds the venv.

## Quick Reference

### Inspect a page
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com
```

### Accessibility snapshot — what can I interact with?
The page as a screen reader sees it: every control as `role "name"`, nested, in a few hundred
tokens. Use it before multi-step flows; every line is a ready-made target for
`click`/`fill` via a `role=` selector (see below).
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --snapshot
```

### Responsive layout check
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --responsive
```

### Full audit (inspect + responsive + accessibility + SEO)
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --audit
```

### Compare two pages
```bash
${CLAUDE_SKILL_DIR}/scripts/bt --compare https://staging.example.com https://example.com
```

### Find elements by description
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --find "search button"
```

### Take screenshot
JPEG by default — far smaller in context than PNG. Headless captures at 1× (no Retina 2×).
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --screenshot
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --full-screenshot
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --screenshot --png          # exact pixels / transparency
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --screenshot --quality 60   # smaller still
```

### Write a big report to disk instead of into context
Prints only the file path plus lines that signal a real problem (broken images,
console errors, failed requests, axe violations, overflow). Use it for `--audit` and
for any page you expect to be large.
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --audit --out /tmp/audit.txt
```

### Lighthouse audit (optional, needs Node.js)
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --lighthouse
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --lighthouse --lh-categories seo,accessibility,performance
```

### Evaluate JavaScript
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --eval "document.querySelectorAll('img').length"
```

### Get computed styles
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --selector "header"
```

### Accessibility check (axe-core)
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --accessibility
```
Runs the real axe-core engine, not heuristics. Takes a few seconds (5-10s on very
large DOMs). Audits the **top frame only** — iframes are not covered. "0 violations"
means no axe rule fired, which is not the same as "accessible".

### SEO check only
```bash
${CLAUDE_SKILL_DIR}/scripts/bt https://example.com --seo
```

### List open tabs
```bash
${CLAUDE_SKILL_DIR}/scripts/bt --tabs
```

## Complex Interactions (Python module)

For multi-step flows (click, fill, navigate, then inspect), use `connect.py` as a module via
`--python` (which puts the skill's scripts on `PYTHONPATH` for you). Take a `--snapshot` first
and target controls by role and accessible name — no CSS guessing:

```bash
${CLAUDE_SKILL_DIR}/scripts/bt --python -c "
import asyncio
from connect import Browser, format_inspection

async def main():
    async with Browser() as b:
        page = await b.get_page('https://example.com/search')
        await b.fill(page, 'role=textbox[name=\"Search\"]', 'test query')
        await b.click(page, 'role=button[name=\"Search\"]')
        await page.wait_for_timeout(2000)
        info = await b.inspect_page(page)
        print(format_inspection(info))

asyncio.run(main())
"
```

Selectors are Playwright's: `role=button[name="Save"]`, `text=Save`, plain CSS, `xpath=`.

Tabs opened inside the block (popups included) are closed when it exits. To carry page state
into a later `--python` round (a login in progress, a multi-page wizard), open with
`Browser(keep_pages=True)` and reuse the same URL in the next round — `get_page()` finds the
existing tab. Pass `reload=True` when you want a re-fetch instead.

### Available Browser methods:
- `get_page(url, reload=False, fresh=False)` — Navigate to URL (reuses a matching tab; `fresh=True` always opens a new one)
- `inspect_page(page)` — Full structured page inspection
- `find_elements(page, description)` — Find elements by natural language
- `evaluate(page, js_expression)` — Execute JavaScript
- `screenshot_page(page, full_page=False, fmt="jpeg", quality=80)` — returns file path
- `screenshot_element(page, selector, fmt="jpeg", quality=80)` — screenshot one element
- `get_computed_styles(page, selector)` — CSS computed styles
- `check_responsive(page)` — Test at 4 breakpoints (mobile/tablet/desktop/wide)
- `compare_pages(url_a, url_b)` — Compare two pages (read-only)
- `check_accessibility(page)` — axe-core audit; `Browser.format_accessibility(result)` renders it
- `run_lighthouse(url, categories, cdp_port)` / `format_lighthouse(result)` — module-level
- `check_seo(page)` — SEO audit
- `click(page, selector)` — Click element
- `fill(page, selector, value)` — Fill input
- `scroll_to(page, position)` — Scroll ('top', 'bottom', or pixel offset)
- `wait_for_network_idle(page)` — Wait for network to settle
- `list_tabs()` — List all open tabs
- `release_page(page)` — Close a tab now (blanks it instead if it is the last one)
- `close_other_tabs(keep=page)` — Close all tabs except the specified one

## Chrome Management

```bash
# Is Chrome running, which profile/port, is it ours?
${CLAUDE_SKILL_DIR}/scripts/bt --status

# Start Chrome (usually auto-starts; only needed to warm it up)
${CLAUDE_SKILL_DIR}/scripts/bt --start

# Stop Chrome gracefully (cookies/logins persist; tabs do not)
${CLAUDE_SKILL_DIR}/scripts/bt --stop

# Login mode: opens a VISIBLE window so the user can log in; the session is saved
${CLAUDE_SKILL_DIR}/scripts/bt --login https://admin.example.com
```

`--login` is the one command that shows a window. It swaps the running headless Chrome for a
headed one on the same profile. Tell the user the window is open and **wait for them to say
they are done**; then run `--stop`, and the next command relaunches headless with the saved
cookies.

Logins are **per project** (each project has its own profile): a site logged in for project A
must be logged in once more for project B. The same applies to a git worktree — it is a
different root, so it gets its own profile.

## Configuration

All optional — defaults work out of the box:

| Env var | Default | Purpose |
|---|---|---|
| `CDP_PORT` | derived: `9340 + hash(project root) % 60` | CDP port. Set only to resolve a reported port collision. |
| `BT_CHROME_PROFILE` | derived: `~/.claude/browser-testing-profiles/<project>-<hash>` | Profile dir (cookies/logins). |
| `BT_HEADED` | unset | `1` = visible window (to watch the agent, or for sites that fingerprint headless). Takes effect on the next launch — `--stop` first if Chrome is already running. |
| `CHROME_BIN` | auto-detected | Path to any Chromium-based browser. |
| `BT_SCREENSHOT_DIR` | `<skill>/tmp_screenshots` | Where screenshots are written. |

Don't put these on the command line as `VAR=… bt …` — a leading assignment defeats the
pre-approved command pattern. They belong in the environment (`settings.local.json` `env`).

## Workflow Guidelines

### When asked "check how the website looks":
1. Run `${CLAUDE_SKILL_DIR}/scripts/bt <URL>`
2. Analyze output for: broken images, console errors, failed requests, missing headings/content, layout issues
3. Report findings concisely

### When asked to test specific functionality:
1. `--snapshot` the page to see its controls by role and name
2. For multi-step flows, use the `--python` module with `role=` selectors, then `inspect_page`

### When asked to check responsive layout:
1. Run `--responsive`
2. Check for: horizontal overflow, hidden elements, hamburger menu visibility, element count changes

### When asked to compare pages:
1. Run `--compare URL_A URL_B` (read-only on both)
2. Report differences in content, layout, broken images, console errors

## CRITICAL Rules

### Screenshot size limit — MANDATORY
**Before reading any screenshot into context, check its dimensions. If either width or height
exceeds 2000 pixels, resize it BEFORE reading.** Images larger than 2000px on any side cause a
context error that forces a session restart.

`screenshot_page()` and `screenshot_element()` auto-resize images >2000px with Pillow. This is
enforced in code — you don't need to resize manually when using the skill's Python API or CLI.
If a resize ever fails, the call raises instead of returning a path: **never read a screenshot
the tool refused to hand you.** Full-page screenshots of long pages still exceed 2000px in
height and are resized.

**If you take screenshots via other means** (e.g. manual Playwright calls), always resize before reading:
```bash
${CLAUDE_SKILL_DIR}/scripts/bt --python -c "from PIL import Image; im=Image.open('/path/shot.jpg'); im.thumbnail((2000,2000)); im.save('/path/shot.jpg')"
```

### Tabs
Tabs clean themselves up: CLI calls close their tab, `--python` blocks close what they opened.
If `--tabs` ever shows leftovers (a `keep_pages=True` round you're done with), run
`--close-others`; `--stop` is the hard reset — tabs never survive a restart.

### CDP session warning
If you use low-level CDP calls (e.g. `page.context.new_cdp_session(page)` for user-agent
override), **close that tab entirely afterward** — don't try to reuse it. CDP overrides can
leave Playwright in an inconsistent state where `close_other_tabs()` silently fails.

### Session end
When the user says the browser work is finished, run `${CLAUDE_SKILL_DIR}/scripts/bt --stop`.
It is invisible either way, but a headless Chrome still holds ~300 MB; stopping is free since
the next call relaunches it. Don't stop it between tasks in a session — another session in
the same project may be using the same Chrome.

## Important Notes

- **Headless, never visible, never steals focus.** The user keeps working while you test. Set
  `BT_HEADED=1` in the environment when they want to watch, or when a site fingerprints
  headless beyond the UA (rare; the client-hint brands already read as normal Chrome).
- **One Chrome per project.** Profile and port derive from the git root, so parallel sessions
  in different projects don't share cookies or tabs. Running from a subdirectory of the same
  repo lands on the same Chrome.
- **"port … answers CDP, but no Chrome is running our profile"** means another project's Chrome
  (or some other CDP service) holds this port. Set `CDP_PORT` to a free port in this project's
  `settings.local.json` `env` — never attach to it.
- **Persistent auth, non-persistent tabs**: cookies/logins live in the profile and survive
  restarts; tabs do not.
- **Read-only on production**: Never modify, click forms, or submit on production. Only inspect/read.
- **Prefer DOM over screenshots**: `--snapshot` and `inspect_page()` are faster and better for
  reasoning. Use screenshots only when the user explicitly needs a visual.
- **Failed network requests** are reported alongside console errors: any response with status
  >= 400, plus network-level failures (DNS, connection refused, CORS). Cancelled requests
  (`ERR_ABORTED`) are ignored as routine. This catches the "page looks fine but the API
  returned 500" case that DOM inspection alone misses.
- **Lighthouse** runs against this same Chrome, so it works on logged-in and basic-auth pages.
  It is invoked with `--disable-storage-reset` so it cannot wipe the session; it closes its own
  tab on success. Performance scores from an attached, unthrottled browser are **not**
  comparable to CI Lighthouse numbers — treat SEO/accessibility as the meaningful categories.
- **Console errors are only captured from the moment this tool opens the page.** An empty
  `console_errors` list on a tab that was already open means "nothing observed", not "the page
  is clean". Close the tab and re-navigate with the skill to be sure.
- **Platform**: macOS and Linux (bash + `pgrep`/`lsof`/`curl`). On Windows use WSL.
- **Mobile layouts with SSR device detection**: on sites that pick a layout server-side from the
  user agent, resizing the viewport alone will NOT switch layouts. Use CDP
  `Network.setUserAgentOverride` + `page.reload()`, take the screenshot, then close that tab.
  Don't reset the UA on the same tab — open a fresh tab for desktop inspection.
- **Login throttling**: when a login attempt fails, read the response before retrying. Many apps
  rate-limit login; never loop login attempts.
