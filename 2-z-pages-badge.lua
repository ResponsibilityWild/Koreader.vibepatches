--[[
    Page Count Badge – filename / Calibre metadata source
    ======================================================
    Displays a page-count badge on every book cover in CoverBrowser
    Mosaic view, for ALL books (including ones never opened).

    Page count is resolved in this priority order:
      1. Calibre "pages" custom column in BookInfoManager DB
         (populated automatically if you sync via Calibre Wireless or
          calibredb export — the column must be named "pages" in Calibre)
      2. Filename pattern  …(123)…  or  …p(123)…  or  …[123p]…
         Examples:
           "Cat in a Hat - p(123).epub"    → 123
           "Dune (412).epub"               → 412
           "Foundation [688p].epub"        → 688

    Compatibility
    ─────────────
    • Works with vanilla KOReader CoverBrowser plugin
    • Works alongside simpleui.koplugin  (file is named 3-… so it
      runs AFTER simpleui's 2-… patches and paints on top of them,
      replacing simpleui's native KO page-count badge for unread books)

    Installation
    ────────────
    Copy this file to:   <koreader>/patches/2-z-pages-badge-filename.lua

    Customisation
    ─────────────
    Edit the preferences block below.
]]

local Blitbuffer = require("ffi/blitbuffer")

-- stylua: ignore start
--========================== [[Edit your preferences here]] ================================
local page_font_size      = 0.95                       -- 0–1, relative to corner_mark_size
local page_text_color     = Blitbuffer.COLOR_BLACK     -- text colour
local border_thickness    = 2                          -- 0–5
local border_corner_radius = 0                         -- 0–20 (0 = square corners)
local border_color        = Blitbuffer.COLOR_DARK_GRAY -- badge border colour
local background_color    = Blitbuffer.COLOR_WHITE     -- badge fill colour
local move_from_border    = 8                          -- padding from cover edge (pts)
local show_for_read_books = true                       -- true = show badge on ALL books,
                                                       -- false = unread only
--==========================================================================================
-- stylua: ignore end

local Font          = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget    = require("ui/widget/textwidget")
local Screen        = require("device").screen
local logger        = require("logger")

-- ──────────────────────────────────────────────────────────────────────────────
-- Helper: extract page count from a filepath
-- ──────────────────────────────────────────────────────────────────────────────
local function pageCountFromFilepath(filepath)
    if not filepath then return nil end
    -- Strip directory, keep basename
    local basename = filepath:match("([^/\\]+)$") or filepath

    -- Pattern 1: p(123) or P(123) – your naming convention
    local n = basename:match("[Pp]%((%d+)%)")
    if n then return tonumber(n) end

    -- Pattern 2: bare (123) near end of name, before extension
    n = basename:match("%((%d+)%)[^%(%)]*%.[^%.]+$")
    if n then return tonumber(n) end

    -- Pattern 3: [123p] or [123P]
    n = basename:match("%[(%d+)[Pp]%]")
    if n then return tonumber(n) end

    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Helper: try to get pages from BookInfoManager (Calibre "pages" column)
-- ──────────────────────────────────────────────────────────────────────────────
local function pageCountFromBookInfo(filepath)
    if not filepath then return nil end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then return nil end
    local ok2, bookinfo = pcall(function()
        return BookInfoManager:getBookInfo(filepath, false)
    end)
    if not ok2 or not bookinfo then return nil end
    -- Standard KO pages field (only populated after first open – we check anyway)
    if bookinfo.pages and bookinfo.pages > 0 then
        return bookinfo.pages
    end
    -- Calibre custom column named "pages" stored as a custom column string
    -- KOReader stores custom columns as bookinfo["custom_<name>"]
    local calibre_pages = bookinfo["custom_pages"] or bookinfo["pages_custom"]
    if calibre_pages then
        local n = tonumber(calibre_pages)
        if n and n > 0 then return n end
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main patch logic
-- ──────────────────────────────────────────────────────────────────────────────
local function applyPatch()
    -- Require mosaicmenu directly – works whether or not simpleui has already
    -- patched it, because require() returns the cached (already-patched) module.
    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok or not MosaicMenu then
        logger.warn("3-pages-badge-filename: could not require mosaicmenu, skipping")
        return
    end

    -- MosaicMenuItem is a local inside mosaicmenu.lua; we access it via the
    -- module-level function that builds items.  The safest approach in KOReader
    -- patching is to grab it from an already-instantiated item, but at load time
    -- no items exist yet.  Instead we use the documented userpatch upvalue helper
    -- if available, otherwise fall back to looking at the module table.
    local MosaicMenuItem

    -- Try userpatch upvalue approach (vanilla KOReader)
    local ok_up, userpatch = pcall(require, "userpatch")
    if ok_up and userpatch and userpatch.getUpValue then
        local ok_mi, mi = pcall(function()
            return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        end)
        if ok_mi and mi then
            MosaicMenuItem = mi
        end
    end

    -- Fallback: simpleui (and some custom builds) expose MosaicMenuItem on the
    -- module table under the key "MosaicMenuItem"
    if not MosaicMenuItem then
        MosaicMenuItem = MosaicMenu.MosaicMenuItem
    end

    -- Last resort: the module table itself might BE MosaicMenuItem (some forks)
    if not MosaicMenuItem and MosaicMenu.paintTo then
        MosaicMenuItem = MosaicMenu
    end

    if not MosaicMenuItem then
        logger.warn("3-pages-badge-filename: could not locate MosaicMenuItem, skipping")
        return
    end

    -- Guard against double-patching (safe across hot reloads)
    if MosaicMenuItem._patched_filename_pages_badge then return end
    MosaicMenuItem._patched_filename_pages_badge = true

    local origPaintTo = MosaicMenuItem.paintTo
    if not origPaintTo then
        logger.warn("2-z-pages-badge-filename: MosaicMenuItem has no paintTo, skipping")
        return
    end

    function MosaicMenuItem:paintTo(bb, x, y)
        -- Always call the original first (draws cover + any existing badges)
        origPaintTo(self, bb, x, y)

        -- Skip directories and deleted files
        if self.is_directory or self.file_deleted then return end

        -- Optionally skip already-read books
        if not show_for_read_books and self.been_opened then return end

        -- ── Resolve page count ────────────────────────────────────────────
        -- Priority 1: Calibre/BookInfoManager (gets Calibre "pages" column
        --             if populated, or KO's own count if book was opened)
        local page_count = pageCountFromBookInfo(self.filepath)

        -- Priority 2: filename pattern
        if not page_count or page_count == 0 then
            page_count = pageCountFromFilepath(self.filepath)
            -- Also try self.text (the display name) as a fallback
            if not page_count and self.text then
                page_count = self.text:match("[Pp]%((%d+)%)")
                    or self.text:match("%((%d+)%)[^%(%)]*$")
                    or self.text:match("%[(%d+)[Pp]%]")
                if page_count then page_count = tonumber(page_count) end
            end
        end

        if not page_count then return end

        -- ── Build badge widget ────────────────────────────────────────────
        -- corner_mark_size mirrors what the original coverbrowser uses
        local corner_mark_size = Screen:scaleBySize(10)
        local font_size = math.max(math.floor(corner_mark_size * page_font_size), 6)

        local pages_text_widget = TextWidget:new{
            text     = tostring(page_count) .. " p.",
            face     = Font:getFace("cfont", font_size),
            fgcolor  = page_text_color,
            bold     = true,
            padding  = Screen:scaleBySize(1),
        }

        local badge = FrameContainer:new{
            linesize   = Screen:scaleBySize(2),
            radius     = Screen:scaleBySize(border_corner_radius),
            color      = border_color,
            bordersize = border_thickness,
            background = background_color,
            padding    = Screen:scaleBySize(2),
            margin     = 0,
            pages_text_widget,
        }

        -- ── Compute position ──────────────────────────────────────────────
        -- self[1] is the UnderlineContainer
        -- self[1][1] is the widget inside it (FrameContainer or CenterContainer)
        -- self[1][1][1] is the cover image / FakeCover widget
        local target = self[1] and self[1][1] and self[1][1][1]
        if not target or not target.dimen then
            -- Fallback: use the item's own dimensions
            local badge_w = badge:getSize().w
            local badge_h = badge:getSize().h
            local pad     = Screen:scaleBySize(move_from_border)
            badge:paintTo(bb, x + pad, y + self.height - pad - badge_h)
            badge:free()
            return
        end

        -- Cover content bounds
        local cover_left   = x + math.floor((self.width  - target.dimen.w) / 2)
        local cover_bottom = y + self.height - math.floor((self.height - target.dimen.h) / 2)

        local badge_h = badge:getSize().h
        local pad     = Screen:scaleBySize(move_from_border)

        local pos_x = cover_left  + pad
        local pos_y = cover_bottom - pad - badge_h

        badge:paintTo(bb, pos_x, pos_y)
        badge:free()
    end

    logger.dbg("3-pages-badge-filename: MosaicMenuItem.paintTo patched successfully")
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
-- We register via userpatch if available (canonical KOReader way), but also
-- call applyPatch() directly as a fallback so it works even without userpatch.
local ok_up2, userpatch2 = pcall(require, "userpatch")
if ok_up2 and userpatch2 and userpatch2.registerPatchPluginFunc then
    userpatch2.registerPatchPluginFunc("coverbrowser", applyPatch)
else
    -- Direct apply – runs when this file is loaded by KOReader's patch loader
    applyPatch()
end
