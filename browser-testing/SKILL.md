---
name: browser-testing
description: "Visual inspection and testing of any website via headed Chrome + CDP. Use to check how pages look, test UI flows, inspect DOM elements, check responsive layouts, run accessibility/SEO audits, and compare two pages (staging vs production). Provides direct programmatic DOM access — much faster and more accurate than screenshot-based testing."
---

# Browser Testing Skill

Inspect, test, and compare web pages using a headed Chrome instance connected via CDP (Chrome DevTools Protocol). This gives you direct programmatic DOM access — structured text output instead of screenshot-based reasoning.

## How It Works

1. **Headed Chrome** runs with `--remote-debugging-port=9333` and a persistent profile (login sessions survive restart)
2. **Playwright `connect_over_cdp()`** connects to Chrome and reuses the default context (preserving cookies/auth)
3. **JS evaluation** (`page.evaluate()`) extracts structured page data: headings, links, images, forms, meta tags, console errors
4. **Auto-launch**: Chrome starts automatically if not running when you invoke the scripts
5. **Auto-bootstrap**: the `bt` wrapper creates the Python venv on first run
6. **Always fresh**: each CLI call reloads the page, so after you change the site the next check reflects the change (the `--python` API keeps tab state instead — pass `reload=True` to `get_page()` when you want a re-fetch)

It drives **your real Chrome install** — no bundled browser download, no `playwright install`.

## Entry Point

One script does everything. Set it as a variable at the start of a session:

```bash
BT="$HOME/.claude/skills/browser-testing/scripts/bt"
```

If the skill is installed per-project instead of globally, use `.claude/skills/browser-testing/scripts/bt`.

**First run** creates `.venv/` and installs playwright, pillow and axe-core (~20s). Requires `python3` (3.10+) and Chrome/Chromium. If a dependency ever goes missing, `"$BT" --reinstall` rebuilds the venv.

## Quick Reference

### Inspect a page
```bash
"$BT" https://example.com
```

### Responsive layout check
```bash
"$BT" https://example.com --responsive
```

### Full audit (inspect + responsive + accessibility + SEO)
```bash
"$BT" https://example.com --audit
```

### Compare two pages
```bash
"$BT" --compare https://staging.example.com https://example.com
```

### Find elements by description
```bash
"$BT" https://example.com --find "search button"
```

### Take screenshot
JPEG at CSS scale by default — far smaller in context than PNG, and it sidesteps the
HiDPI 2x capture that used to force a downscale.
```bash
"$BT" https://example.com --screenshot
"$BT" https://example.com --full-screenshot
"$BT" https://example.com --screenshot --png          # exact pixels / transparency
"$BT" https://example.com --screenshot --quality 60   # smaller still
```

### Write a big report to disk instead of into context
Prints only the file path plus lines that signal a real problem (broken images,
console errors, failed requests, axe violations, overflow). Use it for `--audit` and
for any page you expect to be large.
```bash
"$BT" https://example.com --audit --out /tmp/audit.txt
```

### Lighthouse audit (optional, needs Node.js)
```bash
"$BT" https://example.com --lighthouse
"$BT" https://example.com --lighthouse --lh-categories seo,accessibility,performance
```

### Evaluate JavaScript
```bash
"$BT" https://example.com --eval "document.querySelectorAll('img').length"
```

### Get computed styles
```bash
"$BT" https://example.com --selector "header"
```

### Accessibility check (axe-core)
```bash
"$BT" https://example.com --accessibility
```
Runs the real axe-core engine, not heuristics. Takes a few seconds (5-10s on very
large DOMs). Audits the **top frame only** — iframes are not covered. "0 violations"
means no axe rule fired, which is not the same as "accessible".

### SEO check only
```bash
"$BT" https://example.com --seo
```

### List open tabs
```bash
"$BT" --tabs
```

## Complex Interactions (Python module)

For multi-step flows (click, fill, navigate, then inspect), use `connect.py` as a module via `--python` (which puts the skill's scripts on `PYTHONPATH` for you):

```bash
"$BT" --python -c "
import asyncio
from connect import Browser, format_inspection

async def main():
    async with Browser() as b:
        page = await b.get_page('https://example.com/search')
        await b.fill(page, 'input[name=q]', 'test query')
        await b.click(page, 'button[type=submit]')
        await page.wait_for_timeout(2000)
        info = await b.inspect_page(page)
        print(format_inspection(info))

asyncio.run(main())
"
```

### Available Browser methods:
- `get_page(url)` — Navigate to URL (reuses existing tab if matching)
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
- `close_other_tabs(keep=page)` — Close all tabs except the specified one

## Chrome Management

```bash
# Check if Chrome is running
"$BT" --status

# Start Chrome (usually auto-starts — use this to open specific URLs)
"$BT" --start https://example.com

# Stop Chrome gracefully (cookies/logins persist; tabs do not)
"$BT" --stop

# Login mode (opens Chrome so the user can log in manually; session is saved)
"$BT" --login https://admin.example.com
```

## Configuration

All optional — defaults work out of the box:

| Env var | Default | Purpose |
|---|---|---|
| `CDP_PORT` | `9333` | CDP port. Change if it collides with another CDP Chrome. |
| `BT_CHROME_PROFILE` | `<skill>/config/chrome-profile` | Profile dir. Set per-project for isolated logins. |
| `CHROME_BIN` | auto-detected | Path to any Chromium-based browser. |
| `BT_SCREENSHOT_DIR` | `<skill>/tmp_screenshots` | Where screenshots are written. |

## Workflow Guidelines

### When asked "check how the website looks":
1. Run `"$BT" <URL>`
2. Analyze output for: broken images, console errors, missing headings/content, layout issues
3. Report findings concisely

### When asked to test specific functionality:
1. Navigate to the page
2. Use `--find` to locate elements
3. For multi-step flows, use the `--python` module approach with click/fill/inspect

### When asked to check responsive layout:
1. Run `--responsive`
2. Check for: horizontal overflow, hidden elements, hamburger menu visibility, element count changes

### When asked to compare pages:
1. Run `--compare URL_A URL_B` (read-only on both)
2. Report differences in content, layout, broken images, console errors

## CRITICAL Rules

### Screenshot size limit — MANDATORY
**Before reading any screenshot into context, check its dimensions. If either width or height exceeds 2000 pixels, resize it BEFORE reading.** Images larger than 2000px on any side will cause a context error that forces session restart.

The `screenshot_page()` and `screenshot_element()` methods auto-resize images >2000px with Pillow (longest side constrained, aspect ratio preserved). This is enforced in code — you don't need to resize manually when using the skill's Python API or CLI. If a resize ever fails, the call raises instead of returning a path: **never read a screenshot the tool refused to hand you.**

Note that a Retina/HiDPI display captures at `deviceScaleFactor` 2, so a "1280px-wide" screenshot really is 2560px. This triggers constantly — it is not an edge case.

**If you take screenshots via other means** (e.g. manual Playwright calls), always resize before reading:
```bash
"$BT" --python -c "from PIL import Image; im=Image.open('/path/shot.jpg'); im.thumbnail((2000,2000)); im.save('/path/shot.jpg')"
```

This applies to ALL screenshots read into Claude's context. No exceptions.

### Tab cleanup — MANDATORY
**Close tabs after EACH inspection.** Do NOT accumulate open tabs across multiple inspections. After you finish inspecting/screenshotting a page, close the tab before navigating to the next URL.

**Cleanup rules:**
1. **Never run `--close-others` in background.** Always run in foreground so you can verify it worked. Background cleanup silently fails and you won't know tabs are still open.
2. **Always verify after cleanup.** Run `"$BT" --tabs` after `--close-others` to confirm tabs were actually closed. If tabs persist, try again or escalate.
3. **Max 2-3 tabs open.** If you have more, stop and clean up before proceeding.
4. **If cleanup gets stuck**, `"$BT" --stop` is the hard reset — tabs never survive a restart.

```bash
# Close all tabs except the most recently opened one (FOREGROUND only)
"$BT" --close-others

# Verify cleanup worked
"$BT" --tabs

# Or keep a specific URL open
"$BT" --close-others https://the-page-im-testing.com
```

### CDP session warning
If you use low-level CDP calls (e.g. `page.context.new_cdp_session(page)` for user-agent override), **close that tab entirely afterward** — don't try to reuse it. CDP overrides can leave Playwright in an inconsistent state where `close_other_tabs()` silently fails.

### Session end — MANDATORY
**When you are done with all browser inspections, stop Chrome:**
```bash
"$BT" --stop
```
Do NOT leave Chrome running with accumulated tabs after the testing workflow is complete. Chrome auto-launches on next use, so stopping it costs nothing.

## Important Notes

- **Chrome runs headed** — opens a visible window on the user's screen. Can be minimized.
- **Auto-launch**: Chrome starts automatically if not running. No need to ask the user.
- **Persistent auth, non-persistent tabs**: cookies/logins live in the profile and survive restarts; **tabs do not**. Chrome is launched with session restore disabled, so `--stop` followed by any command always gives a clean single-tab browser. If tabs ever pile up, `--stop` is the reset.
- **Read-only on production**: Never modify, click forms, or submit on production. Only inspect/read.
- **Prefer DOM over screenshots**: Structured text from `inspect_page()` is faster and better for reasoning. Use screenshots only when the user explicitly needs a visual.
- **Failed network requests** are reported alongside console errors: any response with status >= 400, plus network-level failures (DNS, connection refused, CORS). Cancelled requests (`ERR_ABORTED`) are ignored as routine. This catches the "page looks fine but the API returned 500" case that DOM inspection alone misses.
- **Lighthouse** runs against this same Chrome, so it works on logged-in and basic-auth pages. It is invoked with `--disable-storage-reset` so it cannot wipe the session; it closes its own tab on success (only a crash or the 180s timeout leaves one behind). Performance scores from an attached, unthrottled browser are **not** comparable to CI Lighthouse numbers — treat SEO/accessibility as the meaningful categories here.
- **Console errors are only captured from the moment this tool opens the page.** An empty `console_errors` list on a tab that was already open (or navigated by hand) means "nothing observed", not "the page is clean". To be sure, close the tab and re-navigate with the skill.
- **Platform**: macOS and Linux (bash + `pgrep`/`lsof`/`curl`). On Windows use WSL.
- **Separate CDP port (9333)**: Won't collide with other tools that default to Chrome's usual 9222.
- **Mobile layouts with SSR device detection**: on sites that pick a layout server-side from the user agent, resizing the viewport alone will NOT switch layouts. Use CDP `Network.setUserAgentOverride` + `page.reload()`, take the screenshot, then close that tab. Don't reset the UA on the same tab — open a fresh tab for desktop inspection.
- **Login throttling**: when a login attempt fails, read the response before retrying. Many apps rate-limit login; never loop login attempts.
