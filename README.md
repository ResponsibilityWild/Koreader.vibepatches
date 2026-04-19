# KOReader Page Count Badge Patch

Display page counts on book covers in KOReader's CoverBrowser Mosaic view, sourced from Calibre metadata or filename patterns.

⚠️ **Disclaimer:** This is a vibecoded patch. I'm sharing it as-is at people's request. Don't expect updates or fixes—use at your own risk.

---

## Installation

1. Download `2-z-pages-badge.lua` from this repo
2. Copy it to `.adds/koreader/patches/` on your e-reader
3. Restart KOReader

## Setting Up Page Data

Choose one method:

**Option A: Calibre metadata**
- Install Calibre's **Count Pages** plugin
- Run it on your library
- Sync to your e-reader

**Option B: Filename pattern**
- Rename files with the page count: `Book Title - p(123).epub` or `Book Title (412).pdf` or `Book Title [688p].mobi`

## Result

Page count badges will appear in the bottom corner of book covers in Mosaic view.
