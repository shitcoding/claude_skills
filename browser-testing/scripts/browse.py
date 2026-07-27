#!/usr/bin/env python3
"""
browse.py — Quick page inspector via headed Chrome + CDP.

Invoke through the `bt` wrapper (it bootstraps the venv):
    bt URL                          # Inspect page
    bt URL --responsive             # Check responsive layout
    bt URL --accessibility          # Accessibility checks
    bt URL --seo                    # SEO checks
    bt URL --audit                  # Full audit (all checks)
    bt URL --screenshot             # Take screenshot
    bt URL --find "search button"   # Find elements
    bt URL --eval "document.title"  # Evaluate JS
    bt --compare URL_A URL_B        # Compare two pages
    bt --tabs                       # List open tabs
    bt --close-others [URL]         # Close all tabs but one
"""

import argparse
import asyncio
import contextlib
import io
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from connect import (
    Browser, format_inspection, format_responsive, format_comparison,
    format_lighthouse, run_lighthouse, CDP_PORT,
)

# Lines worth surfacing in the --out digest. Matched CASE-SENSITIVELY and in sync
# with the formatters in connect.py: real problems are printed in upper case
# (BROKEN, FAILED, HIDDEN, WARNING), while benign states print lower case — so
# "hamburger menu: hidden" and "main: not found", which are normal on most pages,
# must not eat the digest budget.
SIGNALS = re.compile(
    r"BROKEN|WARNING|FAILED|HIDDEN|HORIZONTAL SCROLL|DIFF: "
    r"|\[(error|pageerror|warning)\]"
    r"|^\s*HTTP \d{3} "
    r"|^\s*(critical|serious|moderate|minor|unknown): "
    r"|^\s*(Broken images|Console errors|Failed requests): "  # compare, only printed when non-zero
    r"|Screenshot saved"
)
DIGEST_LIMIT = 15


def emit_digest(text: str, out_path: Path) -> None:
    """Write the full report to disk; print only path + signal lines to stdout."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text)
    lines = text.splitlines()
    hits = [ln for ln in lines if SIGNALS.search(ln)]
    print(f"Report written to {out_path} ({len(text)} bytes, {len(lines)} lines)")
    if not hits:
        print("No problem signals found in the report.")
        return
    print(f"--- {len(hits)} signal line(s) ---")
    for ln in hits[:DIGEST_LIMIT]:
        print(ln)
    if len(hits) > DIGEST_LIMIT:
        print(f"... and {len(hits) - DIGEST_LIMIT} more — read the file for the rest.")


async def main():
    parser = argparse.ArgumentParser(
        description="Quick page inspector via headed Chrome + CDP",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  bt https://example.com                     # Inspect page
  bt https://example.com --audit             # Full audit
  bt --compare https://a.com https://b.com   # Compare two pages
""")
    parser.add_argument("url", nargs="?", help="URL to inspect")
    parser.add_argument("--compare", nargs=2, metavar=("URL_A", "URL_B"),
                        help="Compare two pages")
    parser.add_argument("--responsive", action="store_true",
                        help="Check responsive layout at all breakpoints")
    parser.add_argument("--accessibility", action="store_true",
                        help="Run accessibility checks")
    parser.add_argument("--seo", action="store_true",
                        help="Run SEO checks")
    parser.add_argument("--audit", action="store_true",
                        help="Full audit: inspect + responsive + accessibility + SEO")
    parser.add_argument("--screenshot", action="store_true",
                        help="Take screenshot")
    parser.add_argument("--full-screenshot", action="store_true",
                        help="Take full-page screenshot")
    parser.add_argument("--find", metavar="DESC",
                        help="Find elements matching description")
    parser.add_argument("--eval", dest="js_eval", metavar="JS",
                        help="Evaluate JavaScript expression")
    parser.add_argument("--selector", metavar="CSS",
                        help="Show computed styles for this CSS selector")
    parser.add_argument("--tabs", action="store_true",
                        help="List open tabs")
    parser.add_argument("--close-others", action="store_true",
                        help="Close all tabs except the most recently opened one")
    parser.add_argument("--out", metavar="FILE",
                        help="Write the full report to FILE; print only a digest")
    parser.add_argument("--png", action="store_true",
                        help="Screenshot as PNG instead of JPEG (exact pixels/transparency)")
    parser.add_argument("--quality", type=int, default=80,
                        help="JPEG screenshot quality (default 80)")
    parser.add_argument("--lighthouse", action="store_true",
                        help="Run a Lighthouse audit (needs Node.js)")
    parser.add_argument("--lh-categories", default="seo",
                        help="Lighthouse categories (default: seo)")

    args = parser.parse_args()

    if not args.url and not args.compare and not args.tabs and not args.close_others:
        parser.print_help()   # deliberately before any stdout capture
        sys.exit(1)

    if not args.out:
        await run(args)
        return

    # Capture whatever the branches print, then digest it. try/finally so a raising
    # branch still writes what it produced instead of losing the partial report.
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            await run(args)
    finally:
        emit_digest(buf.getvalue(), Path(args.out))


async def run(args):
    """Everything below prints to stdout; --out captures it. Any subprocess started
    from here MUST capture its own output — redirect_stdout only swaps Python's
    sys.stdout, so an uncaptured child would write past the digest to the terminal."""
    async with Browser() as b:

        if args.tabs:
            tabs = await b.list_tabs()
            print(f"=== Open Tabs ({len(tabs)}) ===")
            for t in tabs:
                print(f"  {t['title'][:60]}  [{t['url'][:80]}]")
            return

        if args.close_others:
            # Keep the tab matching args.url if given; otherwise the last non-blank tab.
            keep = None
            if args.url:
                for p in b.context.pages:
                    if p.url.rstrip("/") == args.url.rstrip("/"):
                        keep = p
                        break
                if keep is None:
                    print(f"WARNING: {args.url} is not open; keeping the last non-blank tab.")
            closed = await b.close_other_tabs(keep=keep)
            remaining = await b.list_tabs()
            print(f"Closed {closed} tabs. {len(remaining)} remaining.")
            return

        if args.compare:
            result = await b.compare_pages(args.compare[0], args.compare[1])
            print(format_comparison(result))
            return

        # reload=True: each CLI call is a fresh question about the page's CURRENT state.
        page = await b.get_page(args.url, reload=True)
        await b.wait_for_network_idle(page)

        if args.find:
            elements = await b.find_elements(page, args.find)
            print(f"=== Found {len(elements)} matches for \"{args.find}\" ===")
            for el in elements[:15]:
                print(f"  [{el['score']}] <{el['tag']}> \"{el['text'][:60]}\" selector=\"{el['selector']}\"")
            return

        if args.js_eval:
            result = await b.evaluate(page, args.js_eval)
            if isinstance(result, (dict, list)):
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(result)
            return

        if args.screenshot or args.full_screenshot:
            path = await b.screenshot_page(
                page, full_page=args.full_screenshot,
                fmt="png" if args.png else "jpeg", quality=args.quality)
            print(f"Screenshot saved: {path}")
            return

        if args.lighthouse:
            print(format_lighthouse(run_lighthouse(
                page.url, categories=args.lh_categories, cdp_port=CDP_PORT)))
            return

        if args.audit:
            info = await b.inspect_page(page)
            print(format_inspection(info))

            print("\n" + "=" * 60 + "\n")
            results = await b.check_responsive(page)
            print(format_responsive(results))

            print("=" * 60 + "\n")
            print(Browser.format_accessibility(await b.check_accessibility(page)))

            print(f"\n{'=' * 60}\n")
            seo = await b.check_seo(page)
            print("=== SEO Check ===")
            for issue in seo["issues"]:
                print(f"  [{issue['type']}] {issue['msg']}")
            print(f"  Meta: title=\"{seo['meta'].get('title', '')}\"")
            print(f"  Meta: description=\"{seo['meta'].get('description', '')[:80]}\"")
            return

        if args.selector:
            styles = await b.get_computed_styles(page, args.selector)
            print(f"=== Computed Styles for \"{args.selector}\" ===")
            for k, v in styles.items():
                if k != "_rect":
                    print(f"  {k}: {v}")
            return

        if args.responsive:
            results = await b.check_responsive(page)
            print(format_responsive(results))
            return

        if args.accessibility:
            print(Browser.format_accessibility(await b.check_accessibility(page)))
            return

        if args.seo:
            seo = await b.check_seo(page)
            print("=== SEO Check ===")
            print(f"Meta: {json.dumps(seo['meta'], ensure_ascii=False, indent=2)}")
            for issue in seo["issues"]:
                print(f"  [{issue['type']}] {issue['msg']}")
            return

        # Default: inspect
        info = await b.inspect_page(page)
        print(format_inspection(info))


if __name__ == "__main__":
    asyncio.run(main())
