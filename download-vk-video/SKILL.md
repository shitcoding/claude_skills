---
name: download-vk-video
description: Use when the user wants to download a video from VK (vk.com, vk.ru). Handles yt-dlp VK extractor failures by extracting direct MP4 URLs from the VK embed page.
---

# Download VK Video

## Overview

VK videos cannot be reliably downloaded with `yt-dlp` — the VK extractor frequently breaks due to API changes (returns empty JSON). The workaround is to fetch VK's embed page directly and extract MP4 URLs from the HTML.

## When to Use

- User provides a VK video URL (vk.com or vk.ru)
- `yt-dlp` fails with `Failed to parse JSON` or similar VK extractor errors
- Any task involving downloading video content from VK

## Quick Reference

| Step | Command |
|------|---------|
| Extract video ID | Parse `oid` and `id` from URL (format: `video{oid}_{id}`) |
| Fetch embed page | `curl` the embed URL with browser User-Agent |
| Extract MP4 URLs | grep for `"mp4_1080"`, `"mp4_720"`, etc. |
| Download | `curl -L -o output.mp4 "<extracted_url>"` |

## Core Pattern

### Step 1: Extract Video Owner ID and Video ID

VK video URLs contain the video identifier in the format `video{OWNER_ID}_{VIDEO_ID}`.

Examples:
- `https://vk.ru/reactorradio?z=video-147215218_456245213%2F...` → oid=`-147215218`, id=`456245213`
- `https://vk.com/video-147215218_456245213` → oid=`-147215218`, id=`456245213`

### Step 2: Fetch the Embed Page and Extract MP4 URL

```bash
# Fetch embed page and extract highest quality MP4 URL
VIDEO_URL=$(curl -s -L \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
  "https://vk.com/video_ext.php?oid=${OID}&id=${ID}" \
  | grep -oE '"mp4_1080":"[^"]*"' \
  | head -1 \
  | sed 's/"mp4_1080":"//;s/"$//' \
  | sed 's/\\//g')
```

Available qualities (pick highest available): `mp4_1080`, `mp4_720`, `mp4_480`, `mp4_360`, `mp4_240`, `mp4_144`

If `mp4_1080` is empty, fall back to `mp4_720`, then `mp4_480`, etc.

### Step 3: Download the Video

```bash
curl -L \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
  -o "/path/to/output.mp4" \
  "${VIDEO_URL}"
```

## Complete One-Liner

```bash
OID="-147215218" && ID="456245213" && OUTPUT="video.mp4" && \
VIDEO_URL=$(curl -s -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  "https://vk.com/video_ext.php?oid=${OID}&id=${ID}" \
  | grep -oE '"mp4_1080":"[^"]*"|"mp4_720":"[^"]*"|"mp4_480":"[^"]*"' \
  | head -1 | sed 's/"mp4_[0-9]*":"//;s/"$//' | sed 's/\\//g') && \
curl -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  -o "${OUTPUT}" "${VIDEO_URL}"
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using `yt-dlp` directly for VK | VK extractor is frequently broken; use embed page method |
| Forgetting User-Agent header | VK returns different/empty content without a browser UA |
| Not unescaping backslashes | URLs from HTML contain `\/` — must `sed 's/\\//g'` |
| Trying yt-dlp with cookies | Even with `--cookies-from-browser`, the VK extractor still fails on JSON parsing |
| Not trying fallback qualities | Some videos don't have 1080p; cascade through available qualities |

## Notes

- VK videos are often large (several GB for long streams) — downloads may take minutes
- The embed page URLs have expiry timestamps; extract and download promptly
- This method works without VK authentication for public videos
- For private/restricted videos, this method may not work — the embed page may require auth
