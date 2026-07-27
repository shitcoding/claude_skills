#!/usr/bin/env python3
"""
connect.py — Connect to headed Chrome via CDP for browser automation.

Library module — the CLI lives in browse.py. Invoke both through the `bt` wrapper.

    from connect import Browser
    async with Browser() as b:
        page = await b.get_page("https://example.com")
        info = await b.inspect_page(page)
        print(info)
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from collections import OrderedDict
from pathlib import Path
from typing import Any

from playwright.async_api import async_playwright, Page, BrowserContext, Browser as PwBrowser

# ─── Config ──────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent.resolve()
SKILL_DIR = SCRIPT_DIR.parent
SETUP_SCRIPT = SCRIPT_DIR / "setup_chrome.sh"
CDP_PORT = int(os.environ.get("CDP_PORT", "9333"))
SCREENSHOT_DIR = Path(os.environ.get("BT_SCREENSHOT_DIR", SKILL_DIR / "tmp_screenshots"))

DEFAULT_WIDTH = 1280
DEFAULT_HEIGHT = 720

# Tabs that hold nothing worth keeping.
BLANK_URLS = ("about:blank", "chrome://newtab/", "chrome://new-tab-page/")

# Cap on recorded network failures per page — bounds memory and context.
NETWORK_LIMIT = 100
CONSOLE_LIMIT = 200

BREAKPOINTS = {
    "mobile": {"width": 375, "height": 812, "label": "Mobile (iPhone)"},
    "tablet": {"width": 768, "height": 1024, "label": "Tablet (iPad)"},
    "desktop": {"width": 1280, "height": 720, "label": "Desktop"},
    "wide": {"width": 1920, "height": 1080, "label": "Wide Desktop"},
}


def _ensure_chrome_running(cdp_port: int = CDP_PORT) -> bool:
    """Check if Chrome is running on CDP port; auto-launch if not."""
    try:
        urllib.request.urlopen(f"http://localhost:{cdp_port}/json/version", timeout=2)
        return True
    except Exception:
        pass
    print(f"Chrome not running on port {cdp_port}, launching...", file=sys.stderr)
    try:
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT)],
            capture_output=True, text=True, timeout=45,
            env={**os.environ, "CDP_PORT": str(cdp_port)},
        )
    except subprocess.TimeoutExpired:
        print("Chrome launch timed out after 45s", file=sys.stderr)
        return False
    if result.returncode != 0:
        print(f"Failed to launch Chrome: {result.stderr}", file=sys.stderr)
        return False
    try:
        urllib.request.urlopen(f"http://localhost:{cdp_port}/json/version", timeout=2)
        return True
    except Exception:
        print("Chrome launched but CDP not responding", file=sys.stderr)
        return False


# ─── Browser Context Manager ────────────────────────────────────────────

class Browser:
    """Context manager for CDP browser connection.

    Usage:
        async with Browser() as b:
            page = await b.get_page("https://example.com")
            info = await b.inspect_page(page)
    """

    def __init__(self, cdp_port: int = CDP_PORT):
        self.cdp_port = cdp_port
        self._pw = None
        self._pw_instance = None
        self._browser: PwBrowser | None = None
        self._context: BrowserContext | None = None
        self._created_context = False
        self._watch: OrderedDict[Page, dict] = OrderedDict()

    async def __aenter__(self):
        if not _ensure_chrome_running(self.cdp_port):
            raise RuntimeError(f"Cannot connect to Chrome on port {self.cdp_port}")

        self._pw = async_playwright()
        self._pw_instance = await self._pw.__aenter__()
        self._browser = await self._pw_instance.chromium.connect_over_cdp(
            f"http://localhost:{self.cdp_port}"
        )

        # CRITICAL: Reuse existing default context to preserve login cookies
        if self._browser.contexts:
            self._context = self._browser.contexts[0]
            self._created_context = False
        else:
            self._context = await self._browser.new_context()
            self._created_context = True

        return self

    async def __aexit__(self, *args):
        # Do NOT close pages — tabs persist for user visibility
        if self._created_context and self._context:
            await self._context.close()
        if self._pw:
            await self._pw.__aexit__(*args)

    @property
    def context(self) -> BrowserContext:
        return self._context

    # ── Tab management ───────────────────────────────────────────────

    async def list_tabs(self) -> list[dict]:
        """List all open tabs."""
        tabs = []
        for page in self._context.pages:
            tabs.append({
                "url": page.url,
                "title": await page.title(),
            })
        return tabs

    async def close_other_tabs(self, keep: Page = None) -> int:
        """Close every tab except `keep` — blank tabs included. Returns count closed.

        With keep=None, prefer the page this process most recently worked on —
        Playwright's page order is creation order, not activity, so the last entry
        of self._context.pages is a poor guess for "current". Falls back to the last
        non-blank tab. One tab always survives: closing the final tab quits Chrome.
        """
        pages = list(self._context.pages)
        if keep is None or keep not in pages:
            touched = [p for p in self._watch if p in pages]
            non_blank = [p for p in pages if p.url not in BLANK_URLS]
            candidates = touched or non_blank or pages
            keep = candidates[-1] if candidates else None

        closed = 0
        for page in pages:
            if page is not keep:
                await page.close()
                # Drop the watch entry too, or long --python sessions accumulate
                # buffers and listener closures for tabs that no longer exist.
                self._watch.pop(page, None)
                closed += 1
        return closed

    def _watch_page(self, page: Page) -> dict:
        """Attach console/pageerror/network listeners once per page; return its buffers.

        Must be attached BEFORE navigation — the messages and failed requests emitted
        during page load are the interesting ones, and neither has retroactive history.

        Returns {"console": [...], "network": [...], "dropped": int}.
        """
        buf = self._watch.get(page)
        if buf is not None:
            # Re-touching moves the page to the end: dict order is what
            # close_other_tabs() uses to guess the "current" tab.
            self._watch.move_to_end(page)
            return buf
        buf = {"console": [], "network": [], "dropped": 0}

        def add_net(entry):
            if len(buf["network"]) >= NETWORK_LIMIT:
                buf["dropped"] += 1
                return
            buf["network"].append(entry)

        def add_console(entry):
            # Same bound as the network buffer: an error loop (setInterval throwing)
            # must not grow this forever in a long --python session.
            if len(buf["console"]) < CONSOLE_LIMIT:
                buf["console"].append(entry)

        def on_console(msg):
            if msg.type in ("error", "warning"):
                add_console({"type": msg.type, "text": msg.text})

        def on_response(response):
            if response.status >= 400:
                add_net({"status": response.status, "method": response.request.method,
                         "kind": response.request.resource_type,
                         "url": response.url[:200]})

        def on_requestfailed(request):
            failure = request.failure or ""
            # Aborted requests are routine (cancelled lazy-load images, AbortController
            # fetches, in-flight requests when an SPA re-navigates) and are not errors.
            if "ERR_ABORTED" in failure:
                return
            add_net({"status": None, "method": request.method,
                     "kind": request.resource_type, "url": request.url[:200],
                     "failure": failure})

        page.on("console", on_console)
        page.on("pageerror", lambda err: add_console(
            {"type": "pageerror", "text": str(err)}))
        page.on("response", on_response)
        page.on("requestfailed", on_requestfailed)
        page.on("close", lambda _p: self._watch.pop(page, None))
        self._watch[page] = buf
        return buf

    def _reset_watch(self, page: Page) -> None:
        """Clear a page's buffers before re-navigating, so a reused tab does not
        report failures from its previous contents."""
        buf = self._watch.get(page)
        if buf is not None:
            buf["console"].clear()
            buf["network"].clear()
            buf["dropped"] = 0

    async def get_page(self, url: str, wait_until: str = "domcontentloaded",
                       timeout: int = 30000, reload: bool = False) -> Page:
        """Find existing tab matching URL or navigate to it.

        Reuses an existing tab if the URL matches, otherwise creates a new tab.
        Pass reload=True to re-fetch a reused tab — otherwise "inspect, fix the
        site, inspect again" silently re-reads the pre-fix DOM. One-shot CLI calls
        reload; multi-step flows keep the tab as-is so page state survives.
        """
        # Try to find existing tab with this exact URL
        for page in self._context.pages:
            if page.url == url or page.url.rstrip("/") == url.rstrip("/"):
                self._watch_page(page)
                if reload:
                    self._reset_watch(page)
                    await page.reload(wait_until=wait_until, timeout=timeout)
                    await page.wait_for_timeout(500)
                return page

        # No matching tab — find a blank tab or create new
        page = None
        for p in self._context.pages:
            if p.url in BLANK_URLS:
                page = p
                break
        if not page:
            page = await self._context.new_page()

        self._watch_page(page)
        self._reset_watch(page)
        await page.goto(url, wait_until=wait_until, timeout=timeout)
        await page.wait_for_timeout(1000)
        return page

    # ── Page inspection ──────────────────────────────────────────────

    async def inspect_page(self, page: Page) -> dict:
        """Return structured dict of the page state.

        Console errors and network failures are only those seen since this process
        attached to the page (see _watch_page) — a tab that was already open before
        this run reports an empty list, not a clean bill of health.
        """
        watch = self._watch_page(page)

        result = await page.evaluate("""() => {
            const getRect = (el) => {
                const r = el.getBoundingClientRect();
                return {x: Math.round(r.x), y: Math.round(r.y),
                        w: Math.round(r.width), h: Math.round(r.height)};
            };
            const isVisible = (el) => {
                const style = getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
            };
            const truncate = (s, n=120) => s && s.length > n ? s.slice(0, n) + '...' : s;

            // Meta tags
            const meta = {};
            document.querySelectorAll('meta').forEach(m => {
                const name = m.getAttribute('name') || m.getAttribute('property') || '';
                const content = m.getAttribute('content') || '';
                if (name && content) meta[name] = truncate(content, 200);
            });

            // Headings
            const headings = [];
            document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(h => {
                if (!isVisible(h)) return;
                const style = getComputedStyle(h);
                headings.push({
                    tag: h.tagName.toLowerCase(),
                    text: truncate(h.textContent.trim()),
                    fontSize: style.fontSize,
                    color: style.color,
                    rect: getRect(h),
                });
            });

            // Interactive elements
            const interactive = [];
            document.querySelectorAll('a[href], button, input, select, textarea').forEach(el => {
                if (!isVisible(el)) return;
                const tag = el.tagName.toLowerCase();
                const item = {
                    tag,
                    text: truncate(el.textContent?.trim() || el.value || ''),
                    rect: getRect(el),
                };
                if (tag === 'a') {
                    item.href = el.getAttribute('href') || '';
                    item.text = truncate(el.textContent?.trim() || el.getAttribute('aria-label') || '');
                }
                if (tag === 'input' || tag === 'textarea') {
                    item.type = el.type || 'text';
                    item.placeholder = el.placeholder || '';
                    item.name = el.name || '';
                    item.value = truncate(el.value || '');
                }
                if (tag === 'select') {
                    item.name = el.name || '';
                    item.options = [...el.options].slice(0, 10).map(o => o.text.trim());
                }
                if (tag === 'button') {
                    item.text = truncate(el.textContent?.trim() || el.getAttribute('aria-label') || '');
                    item.disabled = el.disabled;
                }
                const ariaLabel = el.getAttribute('aria-label');
                if (ariaLabel) item.ariaLabel = truncate(ariaLabel);
                interactive.push(item);
            });

            // Images
            const images = [];
            document.querySelectorAll('img').forEach(img => {
                if (!isVisible(img)) return;
                const r = getRect(img);
                if (r.w < 10 || r.h < 10) return;
                images.push({
                    src: truncate(img.src, 200),
                    alt: img.alt || '',
                    loaded: img.complete && img.naturalWidth > 0,
                    naturalWidth: img.naturalWidth,
                    naturalHeight: img.naturalHeight,
                    rect: r,
                });
            });

            // Forms
            const forms = [];
            document.querySelectorAll('form').forEach(form => {
                const fields = [];
                form.querySelectorAll('input, select, textarea').forEach(f => {
                    fields.push({
                        tag: f.tagName.toLowerCase(),
                        type: f.type || '',
                        name: f.name || '',
                        placeholder: f.placeholder || '',
                    });
                });
                forms.push({
                    action: form.action || '',
                    method: form.method || 'get',
                    fields,
                });
            });

            // Viewport
            const viewport = {
                width: window.innerWidth,
                height: window.innerHeight,
                scrollHeight: document.documentElement.scrollHeight,
                scrollWidth: document.documentElement.scrollWidth,
            };

            return {
                url: location.href,
                title: document.title,
                viewport,
                meta,
                headings,
                interactive,
                images,
                forms,
            };
        }""")

        result["console_errors"] = list(watch["console"])
        result["network_errors"] = list(watch["network"])
        result["network_dropped"] = watch["dropped"]
        return result

    # ── Element finding ──────────────────────────────────────────────

    async def find_elements(self, page: Page, description: str) -> list[dict]:
        """Find elements matching a natural-language description.

        Searches by: text content, aria-label, placeholder, name, class, id, href.
        """
        return await page.evaluate("""(description) => {
            const desc = description.toLowerCase();
            const matches = [];
            const isVisible = (el) => {
                const style = getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') return false;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
            };
            const getRect = (el) => {
                const r = el.getBoundingClientRect();
                return {x: Math.round(r.x), y: Math.round(r.y),
                        w: Math.round(r.width), h: Math.round(r.height)};
            };

            const score = (el) => {
                let s = 0;
                const text = (el.textContent || '').trim().toLowerCase();
                const ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
                const placeholder = (el.getAttribute('placeholder') || '').toLowerCase();
                const name = (el.getAttribute('name') || '').toLowerCase();
                const id = (el.id || '').toLowerCase();
                const className = (el.className?.toString() || '').toLowerCase();
                const href = (el.getAttribute('href') || '').toLowerCase();
                const tag = el.tagName.toLowerCase();

                const words = desc.split(/\\s+/);
                for (const w of words) {
                    if (text.includes(w)) s += 3;
                    if (ariaLabel.includes(w)) s += 4;
                    if (placeholder.includes(w)) s += 4;
                    if (name.includes(w)) s += 2;
                    if (id.includes(w)) s += 2;
                    if (className.includes(w)) s += 1;
                    if (href.includes(w)) s += 2;
                    if (tag === w) s += 2;
                }
                return s;
            };

            const candidates = document.querySelectorAll(
                'a, button, input, select, textarea, h1, h2, h3, h4, h5, h6, ' +
                'img, [role], [aria-label], nav, header, footer, main, aside, section'
            );

            for (const el of candidates) {
                if (!isVisible(el)) continue;
                const s = score(el);
                if (s > 0) {
                    matches.push({
                        score: s,
                        tag: el.tagName.toLowerCase(),
                        text: (el.textContent || '').trim().slice(0, 100),
                        ariaLabel: el.getAttribute('aria-label') || '',
                        id: el.id || '',
                        className: (el.className?.toString() || '').slice(0, 100),
                        href: el.getAttribute('href') || '',
                        rect: getRect(el),
                        selector: el.id ? '#' + el.id :
                                  el.className ? el.tagName.toLowerCase() + '.' +
                                    el.className.toString().split(' ')[0] :
                                  el.tagName.toLowerCase(),
                    });
                }
            }

            matches.sort((a, b) => b.score - a.score);
            return matches.slice(0, 20);
        }""", description)

    # ── JS evaluation ────────────────────────────────────────────────

    async def evaluate(self, page: Page, expression: str) -> Any:
        """Safe JS evaluation wrapper."""
        try:
            return await page.evaluate(expression)
        except Exception as e:
            return {"error": str(e)}

    # ── Screenshots ──────────────────────────────────────────────────

    @staticmethod
    def _safe_resize(path: str, max_side: int = 2000, quality: int = 85) -> str:
        """Downscale image in place if either dimension exceeds max_side. Returns path.

        Raises if an oversized image could not be shrunk: handing the agent a
        >2000px image crashes its session, so failing loudly is the safer outcome.
        """
        from PIL import Image

        try:
            with Image.open(path) as img:
                if max(img.size) <= max_side:
                    return path
                fmt = img.format
                img.thumbnail((max_side, max_side))
                # Re-save JPEG above Chrome's capture quality — this is the second
                # lossy encode, and Pillow's default of 75 would visibly compound it.
                if fmt == "JPEG":
                    img.save(path, quality=quality)
                else:
                    img.save(path)
        except Exception as e:
            raise RuntimeError(
                f"Screenshot {path} exceeds {max_side}px and could not be resized "
                f"({e}). Do NOT read it into context — resize or delete it first."
            ) from e
        return path

    @staticmethod
    def _shot_path(prefix: str, fmt: str) -> Path:
        SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        # Millisecond suffix: two shots in the same second must not overwrite each
        # other, or the agent reads the wrong image.
        stamp = time.strftime("%Y%m%d_%H%M%S") + f"_{int(time.time() * 1000) % 1000:03d}"
        return SCREENSHOT_DIR / f"{prefix}_{stamp}.{'jpg' if fmt == 'jpeg' else 'png'}"

    async def screenshot_page(self, page: Page, full_page: bool = False,
                              fmt: str = "jpeg", quality: int = 80) -> str:
        """Screenshot the page; JPEG at CSS scale by default. Returns file path.

        scale="css" captures at CSS pixels instead of device pixels — on a HiDPI
        display the default would be 2x, i.e. a 1280px viewport yielding a 2560px
        file that then has to be downscaled. JPEG is ~3-5x smaller than PNG for the
        same thing the agent reads. Use fmt="png" when exact pixels matter.
        """
        path = self._shot_path("page", fmt)
        opts = {"path": str(path), "full_page": full_page, "type": fmt, "scale": "css"}
        if fmt == "jpeg":  # Playwright rejects quality for PNG
            opts["quality"] = quality
        await page.screenshot(**opts)
        return self._safe_resize(str(path))

    async def screenshot_element(self, page: Page, selector: str,
                                 fmt: str = "jpeg", quality: int = 80) -> str:
        """Screenshot one element; JPEG at CSS scale by default. Returns file path."""
        element = await page.query_selector(selector)
        if not element:
            raise ValueError(f"Element not found: {selector}")
        path = self._shot_path("element", fmt)
        opts = {"path": str(path), "type": fmt, "scale": "css"}
        if fmt == "jpeg":
            opts["quality"] = quality
        await element.screenshot(**opts)
        return self._safe_resize(str(path))

    # ── CSS inspection ───────────────────────────────────────────────

    async def get_computed_styles(self, page: Page, selector: str,
                                  properties: list[str] | None = None) -> dict:
        """Return computed CSS properties for an element."""
        if properties is None:
            properties = [
                "display", "position", "width", "height", "margin", "padding",
                "color", "background-color", "font-size", "font-family",
                "font-weight", "line-height", "text-align", "overflow",
                "z-index", "opacity", "visibility", "flex-direction",
                "justify-content", "align-items", "grid-template-columns",
            ]
        return await page.evaluate("""({selector, properties}) => {
            const el = document.querySelector(selector);
            if (!el) return {error: 'Element not found: ' + selector};
            const style = getComputedStyle(el);
            const result = {};
            for (const p of properties) {
                result[p] = style.getPropertyValue(p);
            }
            result._rect = (() => {
                const r = el.getBoundingClientRect();
                return {x: Math.round(r.x), y: Math.round(r.y),
                        w: Math.round(r.width), h: Math.round(r.height)};
            })();
            return result;
        }""", {"selector": selector, "properties": properties})

    # ── Responsive testing ───────────────────────────────────────────

    async def check_responsive(self, page: Page,
                                breakpoints: dict | None = None) -> dict:
        """Resize viewport through breakpoints and capture layout state at each."""
        if breakpoints is None:
            breakpoints = BREAKPOINTS

        # Measure from the page itself: a CDP-attached tab reports viewport_size None
        # (it follows the real window), so there'd be nothing to restore afterwards and
        # the tab would stay pinned at the last breakpoint — making every later
        # inspection report that fake viewport as fact.
        original_size = page.viewport_size or await page.evaluate(
            "() => ({width: window.innerWidth, height: window.innerHeight})"
        )
        results = {}

        for name, bp in breakpoints.items():
            await page.set_viewport_size({"width": bp["width"], "height": bp["height"]})
            await page.wait_for_timeout(500)

            info = await page.evaluate("""() => {
                const isVisible = (el) => {
                    const style = getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') return false;
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0;
                };

                const header = document.querySelector('header, [class*="header"]');
                const nav = document.querySelector('nav, [class*="nav"]');
                const footer = document.querySelector('footer, [class*="footer"]');
                const main = document.querySelector('main, [class*="main-content"], [class*="content"]');

                const check = (el, label) => {
                    if (!el) return {label, exists: false};
                    const r = el.getBoundingClientRect();
                    return {
                        label,
                        exists: true,
                        visible: isVisible(el),
                        width: Math.round(r.width),
                        height: Math.round(r.height),
                        overflowX: r.width > window.innerWidth,
                    };
                };

                const hasHorizontalScroll = document.documentElement.scrollWidth > window.innerWidth;
                const visibleLinks = [...document.querySelectorAll('a[href]')].filter(isVisible).length;
                const visibleButtons = [...document.querySelectorAll('button')].filter(isVisible).length;
                const visibleImages = [...document.querySelectorAll('img')].filter(el => {
                    return isVisible(el) && el.getBoundingClientRect().width > 10;
                }).length;

                const hamburger = document.querySelector(
                    '[class*="burger"], [class*="hamburger"], [class*="menu-toggle"], ' +
                    'button[aria-label*="menu"], button[aria-label*="Menu"]'
                );

                return {
                    viewport: {width: window.innerWidth, height: window.innerHeight},
                    scrollWidth: document.documentElement.scrollWidth,
                    hasHorizontalScroll,
                    header: check(header, 'header'),
                    nav: check(nav, 'nav'),
                    footer: check(footer, 'footer'),
                    main: check(main, 'main'),
                    hamburgerMenu: hamburger ? {visible: isVisible(hamburger)} : null,
                    counts: {links: visibleLinks, buttons: visibleButtons, images: visibleImages},
                };
            }""")

            results[name] = {"breakpoint": bp, "inspection": info}

        await page.set_viewport_size(original_size)
        return results

    # ── Interaction helpers ──────────────────────────────────────────

    async def click(self, page: Page, selector: str, timeout: int = 5000):
        """Click an element."""
        await page.click(selector, timeout=timeout)

    async def fill(self, page: Page, selector: str, value: str, timeout: int = 5000):
        """Fill an input field."""
        await page.fill(selector, value, timeout=timeout)

    async def scroll_to(self, page: Page, position: str = "bottom"):
        """Scroll to position: 'top', 'bottom', or pixel offset."""
        if position == "top":
            await page.evaluate("window.scrollTo(0, 0)")
        elif position == "bottom":
            await page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
        else:
            await page.evaluate(f"window.scrollTo(0, {int(position)})")
        await page.wait_for_timeout(500)

    async def wait_for_network_idle(self, page: Page, timeout: int = 10000):
        """Wait for network to settle."""
        try:
            await page.wait_for_load_state("networkidle", timeout=timeout)
        except Exception:
            pass

    # ── Comparison ───────────────────────────────────────────────────

    async def compare_pages(self, url_a: str, url_b: str) -> dict:
        """Compare two pages (e.g. staging vs production).

        Read-only on both — just fetches and inspects, no modifications.
        """
        page_a = await self.get_page(url_a, reload=True)
        await self.wait_for_network_idle(page_a)
        info_a = await self.inspect_page(page_a)

        page_b = await self.get_page(url_b, reload=True)
        await self.wait_for_network_idle(page_b)
        info_b = await self.inspect_page(page_b)

        comparison = {
            "page_a": {
                "url": info_a["url"],
                "title": info_a["title"],
                "headings_count": len(info_a["headings"]),
                "links_count": len([e for e in info_a["interactive"] if e["tag"] == "a"]),
                "images_count": len(info_a["images"]),
                "broken_images": len([i for i in info_a["images"] if not i["loaded"]]),
                "console_errors": info_a["console_errors"],
                "network_errors": info_a.get("network_errors", []),
            },
            "page_b": {
                "url": info_b["url"],
                "title": info_b["title"],
                "headings_count": len(info_b["headings"]),
                "links_count": len([e for e in info_b["interactive"] if e["tag"] == "a"]),
                "images_count": len(info_b["images"]),
                "broken_images": len([i for i in info_b["images"] if not i["loaded"]]),
                "console_errors": info_b["console_errors"],
                "network_errors": info_b.get("network_errors", []),
            },
            "differences": [],
        }

        a, b = comparison["page_a"], comparison["page_b"]
        if a["title"] != b["title"]:
            comparison["differences"].append(f"Title: A='{a['title']}' vs B='{b['title']}'")
        if a["headings_count"] != b["headings_count"]:
            comparison["differences"].append(f"Headings: A={a['headings_count']} vs B={b['headings_count']}")
        if abs(a["links_count"] - b["links_count"]) > 3:
            comparison["differences"].append(f"Links differ: A={a['links_count']} vs B={b['links_count']}")
        if abs(a["images_count"] - b["images_count"]) > 3:
            comparison["differences"].append(f"Images differ: A={a['images_count']} vs B={b['images_count']}")
        if a["broken_images"] > 0:
            comparison["differences"].append(f"Page A has {a['broken_images']} broken images")
        if b["broken_images"] > 0:
            comparison["differences"].append(f"Page B has {b['broken_images']} broken images")
        if len(a["network_errors"]) != len(b["network_errors"]):
            comparison["differences"].append(
                f"WARNING: failed requests differ: A={len(a['network_errors'])} "
                f"vs B={len(b['network_errors'])}")

        headings_a = [h["text"] for h in info_a["headings"] if h["tag"] in ("h1", "h2")]
        headings_b = [h["text"] for h in info_b["headings"] if h["tag"] in ("h1", "h2")]
        if headings_a != headings_b:
            comparison["differences"].append(f"H1/H2 differ: A={headings_a[:5]} vs B={headings_b[:5]}")

        if not comparison["differences"]:
            comparison["differences"].append("No significant differences detected")

        return comparison

    # ── Accessibility check ──────────────────────────────────────────

    async def check_accessibility(self, page: Page) -> dict:
        """Run an axe-core accessibility audit against the page.

        axe-core is the canonical implementation (it is what Lighthouse uses); the
        hand-rolled heuristics this replaced were a strict subset of its rules.

        Audits the TOP FRAME only — the script is injected into the main frame's
        main world, so same-origin iframes are not covered.
        """
        try:
            from axe_playwright_python.async_playwright import Axe
        except ImportError as e:
            raise RuntimeError(
                "axe-core is not installed in this skill's venv. Run:\n"
                "  bt --reinstall\n"
                f"(original error: {e})"
            ) from e

        # page.evaluate() runs via CDP Runtime.evaluate, which is exempt from the
        # page's CSP — add_script_tag would be blocked on any strict-CSP site.
        # Request "incomplete" too so we can report needs-review items exist.
        results = await Axe().run(
            page, options={"resultTypes": ["violations", "incomplete"]}
        )
        response = results.response
        order = {"critical": 0, "serious": 1, "moderate": 2, "minor": 3}
        issues = []
        for v in response.get("violations", []):
            nodes = v.get("nodes", [])
            targets = []
            for node in nodes[:3]:
                # target entries nest arbitrarily deep for iframe/shadow-DOM paths;
                # flatten fully or the selector renders as a Python list repr.
                def flatten(t):
                    if isinstance(t, list):
                        for item in t:
                            yield from flatten(item)
                    else:
                        yield str(t)

                sel = " ".join(flatten(node.get("target", [])))
                targets.append(sel[:80])
            issues.append({
                "id": v.get("id", ""),
                "impact": v.get("impact") or "unknown",
                "help": v.get("help", ""),
                "nodes": len(nodes),
                "targets": targets,
            })
        issues.sort(key=lambda i: (order.get(i["impact"], 9), -i["nodes"]))
        return {
            "issues": issues,
            "summary": {
                "violations": len(issues),
                "affectedNodes": sum(i["nodes"] for i in issues),
                "needsReview": len(response.get("incomplete", [])),
                "engine": (response.get("testEngine") or {}).get("version", "axe-core"),
            },
        }

    @staticmethod
    def format_accessibility(result: dict, limit: int = 20) -> str:
        """Format an axe result compactly. Impact words are digest signal markers."""
        s = result["summary"]
        lines = [
            "=== Accessibility (axe-core %s) ===" % s.get("engine", ""),
            f"  {s['violations']} violations across {s['affectedNodes']} nodes; "
            f"{s['needsReview']} items need manual review",
        ]
        for i in result["issues"][:limit]:
            lines.append(f"  {i['impact']}: {i['id']} — {i['help']} ({i['nodes']} nodes)")
            for t in i["targets"]:
                lines.append(f"      {t}")
        if len(result["issues"]) > limit:
            lines.append(f"  ... and {len(result['issues']) - limit} more violation types")
        if not result["issues"]:
            lines.append("  No violations found (axe rules only; not a guarantee of accessibility)")
        return "\n".join(lines)

    # ── SEO check ────────────────────────────────────────────────────

    async def check_seo(self, page: Page) -> dict:
        """Run basic SEO checks."""
        return await page.evaluate("""() => {
            const issues = [];
            const meta = {};

            const title = document.title;
            if (!title) issues.push({type: 'error', msg: 'Missing page title'});
            else if (title.length > 60) issues.push({type: 'warning', msg: 'Title too long (' + title.length + ' chars, recommend < 60)'});
            meta.title = title;

            const desc = document.querySelector('meta[name="description"]');
            if (!desc || !desc.content) issues.push({type: 'error', msg: 'Missing meta description'});
            else if (desc.content.length > 160) issues.push({type: 'warning', msg: 'Meta description too long (' + desc.content.length + ' chars)'});
            meta.description = desc?.content || '';

            const ogTitle = document.querySelector('meta[property="og:title"]');
            const ogDesc = document.querySelector('meta[property="og:description"]');
            const ogImage = document.querySelector('meta[property="og:image"]');
            if (!ogTitle) issues.push({type: 'warning', msg: 'Missing og:title'});
            if (!ogImage) issues.push({type: 'warning', msg: 'Missing og:image'});
            meta.ogTitle = ogTitle?.content || '';
            meta.ogDescription = ogDesc?.content || '';
            meta.ogImage = ogImage?.content || '';

            const canonical = document.querySelector('link[rel="canonical"]');
            if (!canonical) issues.push({type: 'warning', msg: 'Missing canonical link'});
            meta.canonical = canonical?.href || '';

            const h1s = document.querySelectorAll('h1');
            if (h1s.length === 0) issues.push({type: 'error', msg: 'No H1 heading'});
            if (h1s.length > 1) issues.push({type: 'warning', msg: h1s.length + ' H1 headings (recommend 1)'});
            meta.h1 = [...h1s].map(h => h.textContent.trim()).join(' | ');

            const imgs = document.querySelectorAll('img');
            const noAlt = [...imgs].filter(i => !i.alt && i.getBoundingClientRect().width > 20).length;
            if (noAlt > 0) issues.push({type: 'warning', msg: noAlt + '/' + imgs.length + ' visible images missing alt text'});

            const jsonLd = document.querySelectorAll('script[type="application/ld+json"]');
            meta.structuredData = jsonLd.length > 0;
            if (jsonLd.length === 0) issues.push({type: 'info', msg: 'No JSON-LD structured data found'});

            return {issues, meta};
        }""")


# ─── Lighthouse (optional, needs Node) ───────────────────────────────────

def run_lighthouse(url: str, categories: str = "seo",
                   cdp_port: int = CDP_PORT, timeout: int = 180) -> dict:
    """Run Lighthouse against our already-running Chrome. Returns parsed results.

    Attaching with --port (rather than letting Lighthouse launch its own Chrome) is
    what makes this usable on logged-in and basic-auth-protected pages.

    --disable-storage-reset is MANDATORY, not optional: by default Lighthouse calls
    Storage.clearDataForOrigin AND Network.clearBrowserCache both before and after a
    run, which unregisters service workers, wipes CacheStorage for the origin and
    clears the whole browser disk cache. Older Lighthouse versions cleared
    localStorage too — where SPA session tokens live. This skill's entire value is a
    persistent logged-in profile, so never drop this flag.
    """
    if shutil.which("lighthouse"):
        cmd = ["lighthouse"]
    elif shutil.which("npx"):
        cmd = ["npx", "-y", "lighthouse"]
    else:
        return {"error": "Lighthouse needs Node.js. Install it, or `npm i -g lighthouse`."}

    cmd += [
        url,
        f"--port={cdp_port}",
        f"--only-categories={categories}",
        "--output=json",
        "--output-path=stdout",
        "--disable-storage-reset",       # see docstring — protects the login session
        "--disable-full-page-screenshot",  # keeps a large base64 blob out of the JSON
        "--no-enable-error-reporting",
        "--quiet",
    ]
    # start_new_session: `npx` spawns node as a child, and subprocess timeouts kill
    # only the direct child. An orphaned Lighthouse would keep driving our Chrome over
    # CDP, so kill the whole process group.
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        proc.communicate()
        return {"error": f"Lighthouse timed out after {timeout}s"}

    if proc.returncode != 0 and not stdout.strip().startswith("{"):
        return {"error": f"Lighthouse failed: {stderr.strip()[:400]}"}
    try:
        lhr = json.loads(stdout)
    except json.JSONDecodeError:
        return {"error": f"Could not parse Lighthouse output: {stdout[:200]}"}
    # A non-zero exit can still emit a valid LHR carrying runtimeError — reporting its
    # empty scores as a clean result would be a silent lie.
    runtime_error = lhr.get("runtimeError") or {}
    if runtime_error.get("code") and runtime_error.get("code") != "NO_ERROR":
        return {"error": f"Lighthouse runtime error [{runtime_error['code']}]: "
                         f"{runtime_error.get('message', '')[:300]}"}

    scores = {k: v.get("score") for k, v in (lhr.get("categories") or {}).items()}
    failed = []
    for audit in (lhr.get("audits") or {}).values():
        score = audit.get("score")
        # score is None for informational/manual/notApplicable audits — comparing
        # None < 0.9 raises TypeError, so filter before comparing.
        if score is None or score >= 0.9:
            continue
        failed.append({
            "title": audit.get("title", ""),
            "description": (audit.get("description") or "").split(". ")[0][:160],
            "score": score,
        })
    failed.sort(key=lambda a: a["score"])
    return {"url": lhr.get("finalDisplayedUrl", url), "scores": scores, "failed": failed}


def format_lighthouse(result: dict) -> str:
    if result.get("error"):
        return f"=== Lighthouse ===\n  WARNING: {result['error']}"
    lines = [f"=== Lighthouse: {result['url']} ==="]
    for cat, score in result["scores"].items():
        lines.append(f"  {cat}: {'n/a' if score is None else round(score * 100)}")
    if result["failed"]:
        lines.append(f"  --- {len(result['failed'])} audits below 0.9 ---")
        for a in result["failed"][:25]:
            lines.append(f"  WARNING: [{a['score']:.2f}] {a['title']} — {a['description']}")
        if len(result["failed"]) > 25:
            lines.append(f"  ... and {len(result['failed']) - 25} more")
    else:
        lines.append("  No audits below 0.9")
    return "\n".join(lines)


# ─── Output Formatters ───────────────────────────────────────────────────

def format_inspection(info: dict) -> str:
    """Format inspection result as structured text."""
    lines = []
    lines.append(f"=== Page: {info['url']} ===")
    lines.append(f"Title: {info['title']}")
    vp = info["viewport"]
    lines.append(f"Viewport: {vp['width']}x{vp['height']} (scroll: {vp['scrollWidth']}x{vp['scrollHeight']})")
    lines.append("")

    if info.get("meta"):
        lines.append("=== Meta Tags ===")
        for k, v in list(info["meta"].items())[:15]:
            lines.append(f"  {k}: {v}")
        lines.append("")

    if info.get("headings"):
        lines.append("=== Headings ===")
        for h in info["headings"]:
            lines.append(f"  {h['tag']}: \"{h['text']}\" ({h['fontSize']}, {h['color']})")
        lines.append("")

    if info.get("interactive"):
        lines.append(f"=== Interactive Elements ({len(info['interactive'])}) ===")
        for el in info["interactive"][:50]:
            tag = el["tag"]
            if tag == "a":
                lines.append(f"  link: \"{el['text']}\" href=\"{el.get('href', '')}\" ({el['rect']['w']}x{el['rect']['h']})")
            elif tag == "button":
                disabled = " DISABLED" if el.get("disabled") else ""
                lines.append(f"  button: \"{el['text']}\"{disabled} ({el['rect']['w']}x{el['rect']['h']})")
            elif tag in ("input", "textarea"):
                lines.append(f"  {tag}[{el.get('type', 'text')}]: name=\"{el.get('name', '')}\" placeholder=\"{el.get('placeholder', '')}\" ({el['rect']['w']}x{el['rect']['h']})")
            elif tag == "select":
                lines.append(f"  select: name=\"{el.get('name', '')}\" options={el.get('options', [])[:3]}")
        lines.append("")

    if info.get("images"):
        broken = [i for i in info["images"] if not i["loaded"]]
        lines.append(f"=== Images ({len(info['images'])} total, {len(broken)} broken) ===")
        if broken:
            for img in broken[:10]:
                lines.append(f"  BROKEN: src=\"{img['src']}\" alt=\"{img['alt']}\"")
        for img in info["images"][:20]:
            status = "loaded" if img["loaded"] else "BROKEN"
            alt_note = f" alt=\"{img['alt']}\"" if img["alt"] else " NO-ALT"
            lines.append(f"  img: {status}{alt_note} {img['naturalWidth']}x{img['naturalHeight']} ({img['rect']['w']}x{img['rect']['h']})")
        if len(info["images"]) > 20:
            lines.append(f"  ... and {len(info['images']) - 20} more")
        lines.append("")

    if info.get("forms"):
        lines.append(f"=== Forms ({len(info['forms'])}) ===")
        for form in info["forms"]:
            lines.append(f"  form: action=\"{form['action']}\" method=\"{form['method']}\"")
            for f in form["fields"]:
                lines.append(f"    {f['tag']}[{f['type']}] name=\"{f['name']}\" placeholder=\"{f['placeholder']}\"")
        lines.append("")

    if info.get("console_errors"):
        lines.append(f"=== Console Errors ({len(info['console_errors'])}) ===")
        for err in info["console_errors"][:10]:
            lines.append(f"  [{err['type']}] {err['text']}")
        lines.append("")

    net = info.get("network_errors") or []
    if net:
        lines.append(f"=== Failed Network Requests ({len(net)}) ===")
        for r in net[:20]:
            # "HTTP 500" / "FAILED" prefixes are the digest's signal markers — keep
            # them in sync with SIGNALS in browse.py.
            if r.get("status"):
                lines.append(f"  HTTP {r['status']} {r['kind']} {r['method']} {r['url']}")
            else:
                lines.append(f"  FAILED {r['kind']} {r['method']} {r['url']} ({r.get('failure', '')})")
        if len(net) > 20:
            lines.append(f"  ... and {len(net) - 20} more")
        if info.get("network_dropped"):
            lines.append(f"  ... {info['network_dropped']} further failures not recorded (cap {NETWORK_LIMIT})")
        lines.append("")

    return "\n".join(lines)


def format_responsive(results: dict) -> str:
    """Format responsive check results."""
    lines = ["=== Responsive Layout Check ===", ""]
    for name, data in results.items():
        bp = data["breakpoint"]
        info = data["inspection"]
        lines.append(f"--- {bp['label']} ({bp['width']}x{bp['height']}) ---")

        if info.get("hasHorizontalScroll"):
            lines.append(f"  WARNING: HORIZONTAL SCROLL (scrollWidth: {info['scrollWidth']})")

        for key in ("header", "nav", "footer", "main"):
            el = info.get(key, {})
            if not el.get("exists"):
                lines.append(f"  {key}: not found")
            elif not el.get("visible"):
                lines.append(f"  {key}: HIDDEN")
            else:
                overflow = " WARNING: OVERFLOWS" if el.get("overflowX") else ""
                lines.append(f"  {key}: {el['width']}x{el['height']}{overflow}")

        if info.get("hamburgerMenu"):
            vis = "visible" if info["hamburgerMenu"]["visible"] else "hidden"
            lines.append(f"  hamburger menu: {vis}")

        counts = info.get("counts", {})
        lines.append(f"  visible: {counts.get('links', 0)} links, {counts.get('buttons', 0)} buttons, {counts.get('images', 0)} images")
        lines.append("")

    return "\n".join(lines)


def format_comparison(comp: dict) -> str:
    """Format comparison results."""
    lines = ["=== Page Comparison ===", ""]

    for key in ("page_a", "page_b"):
        data = comp[key]
        lines.append(f"--- {data['url']} ---")
        lines.append(f"  Title: {data['title']}")
        lines.append(f"  Headings: {data['headings_count']}, Links: {data['links_count']}, Images: {data['images_count']}")
        if data["broken_images"]:
            lines.append(f"  Broken images: {data['broken_images']}")
        if data["console_errors"]:
            lines.append(f"  Console errors: {len(data['console_errors'])}")
        if data.get("network_errors"):
            lines.append(f"  Failed requests: {len(data['network_errors'])}")
        lines.append("")

    lines.append("--- DIFFERENCES ---")
    for d in comp["differences"]:
        # "DIFF:" is a digest signal marker (see SIGNALS in browse.py) — a clean
        # comparison deliberately carries no marker.
        lines.append(f"  {d}" if d.startswith("No significant") else f"  DIFF: {d}")
    lines.append("")
    return "\n".join(lines)
