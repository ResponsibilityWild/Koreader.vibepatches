--[[
    Page Count Badge – Calibre metadata.calibre + filename source
    ==============================================================
    Displays a page-count badge on every book cover in CoverBrowser
    Mosaic view, for ALL books (including ones never opened).

    Page count is resolved in this priority order:
      1.  Calibre's  metadata.calibre  JSON file (written to the root of your
          device by Calibre during USB or wireless transfer).
          The patch reads  user_metadata["#pages"]["#value#"]  from that file,
          which is exactly where Calibre stores a custom column named "#pages".
          NOTE: your Calibre custom column lookup name must be  #pages
          (Calibre prefixes all custom column lookup names with #).

      2.  Filename pattern – any of:
            "Cat in a Hat - p(123).epub"    →  p(123)
            "Dune (412).epub"               →  (412)
            "Foundation [688p].epub"        →  [688p]

    The  metadata.calibre  file is parsed once per KOReader session and the
    results are cached in memory keyed by the book's  lpath  (its path relative
    to the Calibre library root on the device). This means there is no repeated
    disk I/O after the first cover render.

    Compatibility
    ─────────────
    • Works with vanilla KOReader CoverBrowser plugin
    • Works alongside simpleui.koplugin  (named 2-z-… so it runs AFTER
      simpleui's own patches and paints its badge on top)

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
local page_font_size       = 0.95                       -- 0–1, relative to corner_mark_size
local page_text_color      = Blitbuffer.COLOR_BLACK     -- text colour
local border_thickness     = 2                          -- 0–5
local border_corner_radius = 0                          -- 0–20 (0 = square corners)
local border_color         = Blitbuffer.COLOR_DARK_GRAY -- badge border colour
local background_color     = Blitbuffer.COLOR_WHITE     -- badge fill colour
local move_from_border     = 8                          -- padding from cover edge (pts)
local show_for_read_books  = true                       -- true = badge on ALL books,
                                                        -- false = unread/in-progress only
-- Lookup name of your Calibre custom column (must include the leading #):
local calibre_pages_column = "#pages"
--==========================================================================================
-- stylua: ignore end

local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget     = require("ui/widget/textwidget")
local Screen         = require("device").screen
local logger         = require("logger")

-- ──────────────────────────────────────────────────────────────────────────────
-- Calibre metadata.calibre cache
-- ──────────────────────────────────────────────────────────────────────────────
-- Maps  lpath (relative path on device) → page count (integer or false)
-- false means "we looked and found nothing" so we don't look again.
local calibre_cache = nil   -- nil = not yet loaded; table = loaded

-- Possible locations for metadata.calibre on Kobo and other devices.
local METADATA_CALIBRE_CANDIDATES = {
    "/mnt/onboard/metadata.calibre",        -- Kobo (most common)
    "/mnt/onboard/.metadata.calibre",       -- Kobo (hidden variant)
    "/sdcard/metadata.calibre",             -- Android
    "/storage/emulated/0/metadata.calibre",
}

local function loadCalibreCache()
    if calibre_cache then return end   -- already loaded this session
    calibre_cache = {}

    -- Find the metadata file
    local meta_path
    for _, candidate in ipairs(METADATA_CALIBRE_CANDIDATES) do
        local f = io.open(candidate, "r")
        if f then
            f:close()
            meta_path = candidate
            break
        end
    end

    if not meta_path then
        logger.dbg("2-z-pages-badge: no metadata.calibre found, Calibre lookup disabled")
        return
    end

    -- KOReader ships rapidjson for JSON parsing
    local ok_json, rapidjson = pcall(require, "rapidjson")
    if not ok_json then
        logger.warn("2-z-pages-badge: rapidjson not available, Calibre lookup disabled")
        return
    end

    local ok_data, data = pcall(rapidjson.load, meta_path)
    if not ok_data or type(data) ~= "table" then
        logger.warn("2-z-pages-badge: failed to parse", meta_path)
        return
    end

    local col   = calibre_pages_column   -- e.g. "#pages"
    local count = 0

    for _, book in ipairs(data) do
        -- lpath is the book's path relative to the Calibre library root on
        -- the device, e.g. "Author Name/Book Title (123)/Book Title - Author.epub"
        local lpath = book.lpath
        if lpath then
            local pages = nil

            -- user_metadata holds all custom columns.
            -- Format: user_metadata["#colname"] = { ["#value#"] = <value>, ... }
            local um = book.user_metadata
            if um and um[col] then
                local raw = um[col]["#value#"]
                if raw ~= nil then
                    pages = tonumber(raw)
                end
            end

            -- Cache the result (false = looked, found nothing – don't retry)
            calibre_cache[lpath] = pages or false
            if pages then count = count + 1 end
        end
    end

    logger.dbg("2-z-pages-badge: loaded", count, "page counts from", meta_path)
end

-- Device root prefixes to strip when converting an absolute path → lpath
local DEVICE_ROOTS = {
    "/mnt/onboard/",
    "/sdcard/",
    "/storage/emulated/0/",
}

local function pageCountFromCalibre(filepath)
    if not filepath then return nil end

    loadCalibreCache()
    if not next(calibre_cache) then return nil end   -- cache is empty, nothing to look up

    -- Try to strip a known device root to get the lpath
    local lpath
    for _, root in ipairs(DEVICE_ROOTS) do
        if filepath:sub(1, #root) == root then
            lpath = filepath:sub(#root + 1)
            break
        end
    end

    if lpath then
        local val = calibre_cache[lpath]
        if val and val > 0 then return val end
        return nil
    end

    -- Unknown root prefix – fall back to substring matching
    for key, val in pairs(calibre_cache) do
        if filepath:find(key, 1, true) then
            return (val and val > 0) and val or nil
        end
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Helper: extract page count from a filepath / display name
-- ──────────────────────────────────────────────────────────────────────────────
local function parsePagePattern(s)
    if not s then return nil end
    local n
    n = s:match("[Pp]%((%d+)%)")          -- p(123) or P(123)
    if n then return tonumber(n) end
    n = s:match("%((%d+)%)[^%(%)]*%.[^%.]+$")  -- (123) before extension
    if n then return tonumber(n) end
    n = s:match("%[(%d+)[Pp]%]")          -- [123p] or [123P]
    if n then return tonumber(n) end
    return nil
end

local function pageCountFromFilename(filepath, display_text)
    local basename = filepath and (filepath:match("([^/\\]+)$") or filepath)
    return parsePagePattern(basename) or parsePagePattern(display_text)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main patch
-- ──────────────────────────────────────────────────────────────────────────────
local function applyPatch()
    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok or not MosaicMenu then
        logger.warn("2-z-pages-badge: could not require mosaicmenu, skipping")
        return
    end

    local MosaicMenuItem

    -- Try userpatch upvalue approach (vanilla KOReader)
    local ok_up, userpatch = pcall(require, "userpatch")
    if ok_up and userpatch and userpatch.getUpValue then
        local ok_mi, mi = pcall(function()
            return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        end)
        if ok_mi and mi then MosaicMenuItem = mi end
    end

    -- Fallback: simpleui exposes MosaicMenuItem on the module table
    if not MosaicMenuItem then
        MosaicMenuItem = MosaicMenu.MosaicMenuItem
    end

    -- Last resort: the module itself is the item class
    if not MosaicMenuItem and MosaicMenu.paintTo then
        MosaicMenuItem = MosaicMenu
    end

    if not MosaicMenuItem then
        logger.warn("2-z-pages-badge: could not locate MosaicMenuItem, skipping")
        return
    end

    if MosaicMenuItem._patched_filename_pages_badge then return end
    MosaicMenuItem._patched_filename_pages_badge = true

    local origPaintTo = MosaicMenuItem.paintTo
    if not origPaintTo then
        logger.warn("2-z-pages-badge: MosaicMenuItem has no paintTo, skipping")
        return
    end

    function MosaicMenuItem:paintTo(bb, x, y)
        origPaintTo(self, bb, x, y)

        if self.is_directory or self.file_deleted then return end
        if not show_for_read_books and self.been_opened then return end

        -- ── Resolve page count ─────────────────────────────────────────────
        -- Priority 1: Calibre metadata.calibre (custom #pages column)
        local page_count = pageCountFromCalibre(self.filepath)

        -- Priority 2: filename / display-name pattern
        if not page_count then
            page_count = pageCountFromFilename(self.filepath, self.text)
        end

        if not page_count then return end

        -- ── Build badge ────────────────────────────────────────────────────
        local corner_mark_size = Screen:scaleBySize(10)
        local font_size = math.max(math.floor(corner_mark_size * page_font_size), 6)

        local pages_text_widget = TextWidget:new{
            text    = tostring(page_count) .. " p.",
            face    = Font:getFace("cfont", font_size),
            fgcolor = page_text_color,
            bold    = true,
            padding = Screen:scaleBySize(1),
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

        -- ── Position badge at bottom-left of cover ─────────────────────────
        local target = self[1] and self[1][1] and self[1][1][1]
        local pad    = Screen:scaleBySize(move_from_border)

        if not target or not target.dimen then
            -- Fallback: bottom-left of the whole item
            badge:paintTo(bb, x + pad, y + self.height - pad - badge:getSize().h)
            badge:free()
            return
        end

        local cover_left   = x + math.floor((self.width  - target.dimen.w) / 2)
        local cover_bottom = y + self.height - math.floor((self.height - target.dimen.h) / 2)

        badge:paintTo(bb, cover_left + pad, cover_bottom - pad - badge:getSize().h)
        badge:free()
    end

    logger.dbg("2-z-pages-badge: MosaicMenuItem.paintTo patched successfully")
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Registration
-- ──────────────────────────────────────────────────────────────────────────────
local ok_up2, userpatch2 = pcall(require, "userpatch")
if ok_up2 and userpatch2 and userpatch2.registerPatchPluginFunc then
    userpatch2.registerPatchPluginFunc("coverbrowser", applyPatch)
else
    applyPatch()
end
