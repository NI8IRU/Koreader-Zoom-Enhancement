--[[--
Big View module for Double Tap Zoom plugin.

Shows the current page and one adjacent page (previous or next, depending
on which side of the screen the gesture starts on) side by side in
landscape, so the reader can appreciate double-page artwork/panoramas that
span two pages of a comic or manga.

By design this is intentionally minimal: no zoom, no pan, no scroll. It is
a static overlay composed of two independently rendered, full pages. Any
page turn, or the reverse gesture, closes it.

Trigger: "two_finger_tap" gesture (two fingers touching the screen) opens Big View.
Exit: "single_tap" gesture or closing the document.

Unlike Zoom/HorizontalMode, Big View does not use the shared Viewport
module at all: it renders its own pages via Document:getPagePart() and
displays them in a standalone full-screen widget shown through
UIManager:show(), completely independent from KOReader's live view/zoom
state.
@module holdzoom.bigview
]]--

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local Screen = Device.screen

-- The full-screen overlay widget itself. Built fresh every time Big View
-- is entered (its content depends on the current page pair) and discarded
-- on exit; there's no persistent widget state between activations.
local BigViewWidget = InputContainer:extend{
    left_bb = nil,
    right_bb = nil,
    left_x = 0,
    left_y = 0,
    right_x = 0,
    right_y = 0,
    on_exit = nil, -- callback invoked when the widget wants to close itself
}

function BigViewWidget:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

local Blitbuffer = require("ffi/blitbuffer")

function BigViewWidget:paintTo(bb, x, y)
    -- Solid black background across the whole widget first: covers any
    -- gap left by aspect-ratio letterboxing around each half-page, and
    -- (more importantly) any leftover stale pixels if self.dimen doesn't
    -- exactly match what actually needs repainting.
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    if self.left_bb then
        bb:blitFrom(self.left_bb, x + self.left_x, y + self.left_y, 0, 0,
            self.left_bb:getWidth(), self.left_bb:getHeight())
    end
    if self.right_bb then
        bb:blitFrom(self.right_bb, x + self.right_x, y + self.right_y, 0, 0,
            self.right_bb:getWidth(), self.right_bb:getHeight())
    end
end

function BigViewWidget:onTap()
    if self.on_exit then self.on_exit() end
    return true
end

local BigView = {
    enabled = false,
    active = false,
    ui = nil,
    zoom = nil,             -- reference to the Zoom module, collapsed before entering
    horizontal_mode = nil,  -- reference to the HorizontalMode module, exited before entering
    rotation_direction = "cw",
    pre_rotation_mode = nil,
    current_pageno = nil,
    widget = nil,
}

function BigView:init(ui, Settings, Zoom, HorizontalMode)
    self.ui = ui
    self.zoom = Zoom
    self.horizontal_mode = HorizontalMode
    self.enabled = Settings:get("bigview_enabled") or false

    -- Shares the same rotation direction setting as AutoRotate/HorizontalMode.
    local clockwise = Settings:get("rotate_clockwise")
    if clockwise == nil then clockwise = true end
    self.rotation_direction = clockwise and "cw" or "ccw"

    self.active = false
    self.pre_rotation_mode = nil
    -- Seed immediately from whatever's available, instead of waiting for
    -- the first onPageUpdate, so the gesture works right after opening a
    -- book too. document:getCurrentPage() isn't present on every Document
    -- subclass; ReaderPaging (fixed-layout docs: PDF/CBZ/CBR) keeps the
    -- current page on itself instead, as ui.paging.current_page.
    if ui.document and ui.document.getCurrentPage then
        self.current_pageno = ui.document:getCurrentPage()
        logger.info("BigView: seeded current_pageno from document:getCurrentPage()")
    elseif ui.paging and ui.paging.current_page then
        self.current_pageno = ui.paging.current_page
        logger.info("BigView: seeded current_pageno from ui.paging.current_page")
    elseif ui.rolling and ui.rolling.current_page then
        self.current_pageno = ui.rolling.current_page
        logger.info("BigView: seeded current_pageno from ui.rolling.current_page")
    else
        self.current_pageno = nil
        logger.info("BigView: could not seed current_pageno at init, " ..
            "will wait for the first onPageUpdate")
    end
    self.widget = nil
    logger.info("BigView: initialized, enabled=", self.enabled,
        "rotation_direction=", self.rotation_direction, "current_pageno=", self.current_pageno)
end

function BigView:setupTouchZones(ui)
    self.ui = ui
    if not Device:isTouchDevice() then return end

    local full_screen = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    ui:registerTouchZones({
        {
            id = "bigview_twofingertap",
            ges = "two_finger_tap",
            screen_zone = full_screen,
            handler = function(ges) return self:onTwoFingerTap(ges) end,
        },
    })
    logger.info("BigView: touch zones registered (two_finger_tap)")
end

function BigView:toggleEnabled()
    self.enabled = not self.enabled
    if not self.enabled and self.active then
        self:exit()
    end
    return self.enabled
end

-- Tracks the current page and closes Big View on every page turn: it's
-- meant as a momentary "peek", not a persistent reading mode.
function BigView:onPageUpdate(pageno)
    self.current_pageno = pageno
    if self.active then
        self:exit()
    end
end

-- Only usable when two_finger_tap is otherwise free: Zoom's own
-- two_finger_tap handler triggers HorizontalMode's rotate whenever
-- Zoom.trigger_gesture == "double_tap" (see ROTATE_TRIGGER_MAP in
-- zoom.lua). Big View only claims this gesture when Zoom's trigger is
-- "single_tap" (which frees two_finger_tap, since the rotate trigger
-- becomes a one-finger double_tap in that case).
function BigView:onTwoFingerTap(ges)
    if not self.zoom or self.zoom.trigger_gesture ~= "single_tap" then
        return false
    end
    return self:onEnterGesture(ges)
end

function BigView:onEnterGesture(ges)
    if not self.enabled then
        logger.info("BigView: onEnterGesture ignored, BigView is disabled (check the menu)")
        return false
    end
    if self.active then
        logger.info("BigView: onEnterGesture ignored, already active")
        return false
    end

    local document = self.ui and self.ui.document
    if not document then
        logger.info("BigView: onEnterGesture ignored, no document (self.ui.document is nil)")
        return false
    end
    if not self.current_pageno then
        logger.info("BigView: onEnterGesture ignored, current_pageno is nil (no onPageUpdate seen yet?)")
        return false
    end

    local pos = ges and ges.pos
    if not pos then
        logger.info("BigView: onEnterGesture ignored, ges.pos missing")
        return false
    end

    local page_count = document.getPageCount and document:getPageCount()
    if not page_count then
        logger.info("BigView: onEnterGesture ignored, could not get page_count " ..
            "(document:getPageCount missing or returned nil)")
        return false
    end

    logger.info("BigView: onEnterGesture proceeding, current_pageno=", self.current_pageno,
        "page_count=", page_count, "pos.x=", pos.x)

    local gesture_side = (pos.x < Screen:getWidth() / 2) and "left" or "right"

    -- Reads the document's own reading-order setting (used for manga/RTL
    -- tap-zone and swipe handling) instead of keeping a separate plugin
    -- setting, so this always matches whatever the user has configured.
    local is_rtl = self.ui.doc_settings and self.ui.doc_settings:readSetting("inverse_reading_order") or false
    local start_side = is_rtl and "right" or "left"

    -- The side reading "starts" from peeks backward (the older page pair,
    -- N-1/N); the opposite side peeks forward (N/N+1). The older page of
    -- whichever pair is picked always ends up rendered on the start side.
    local older_pageno, newer_pageno
    if gesture_side == start_side then
        older_pageno, newer_pageno = self.current_pageno - 1, self.current_pageno
    else
        older_pageno, newer_pageno = self.current_pageno, self.current_pageno + 1
    end

    if older_pageno < 1 or newer_pageno > page_count then
        logger.info("BigView: page pair out of bounds (", older_pageno, ",", newer_pageno, "), ignoring")
        return false
    end
    logger.info("BigView: page pair in bounds, older=", older_pageno, "newer=", newer_pageno,
        "gesture_side=", gesture_side, "start_side=", start_side)

    -- Collapse other holdzoom features first. Big View doesn't touch
    -- Viewport at all, so there's no ownership clash, but showing Big
    -- View on top of an already-expanded Zoom or an active Horizontal
    -- Mode would be confusing, so we clear those first.
    if self.zoom and self.zoom.expanded then
        self.zoom:collapse()
    end
    if self.horizontal_mode and self.horizontal_mode.active then
        self.horizontal_mode:exitHorizontal()
    end

    local left_pageno, right_pageno
    if start_side == "left" then
        left_pageno, right_pageno = older_pageno, newer_pageno
    else
        left_pageno, right_pageno = newer_pageno, older_pageno
    end

    self:enter(left_pageno, right_pageno)
    return true
end

function BigView:enter(left_pageno, right_pageno)
    local document = self.ui.document

    self.pre_rotation_mode = Screen:getRotationMode()
    local new_rotation = (self.rotation_direction == "cw")
        and Screen.DEVICE_ROTATED_CLOCKWISE
        or Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
    Screen:setRotationMode(new_rotation)
    UIManager:broadcastEvent(Event:new("SetRotationMode", new_rotation))

    -- Screen:getWidth/getHeight() now reflect the rotated (landscape)
    -- logical dimensions; the two pages are laid out directly in this
    -- space, left/right, with no further coordinate translation needed.
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local half_w = math.floor(screen_w / 2)

    local left_bb, left_w, left_h = self:renderPageFit(document, left_pageno, half_w, screen_h)
    local right_bb, right_w, right_h = self:renderPageFit(document, right_pageno, half_w, screen_h)

    if not left_bb and not right_bb then
        logger.warn("BigView: failed to render both pages, aborting enter")
        if self.pre_rotation_mode then
            Screen:setRotationMode(self.pre_rotation_mode)
            UIManager:broadcastEvent(Event:new("SetRotationMode", self.pre_rotation_mode))
            self.pre_rotation_mode = nil
        end
        return
    end

    local widget = BigViewWidget:new{}
    widget.left_bb = left_bb
    widget.right_bb = right_bb
    -- Center each rendered page within its half both horizontally and
    -- vertically, in case its aspect ratio doesn't exactly fill the box.
    widget.left_x = left_bb and math.floor((half_w - left_w) / 2) or 0
    widget.left_y = left_bb and math.floor((screen_h - left_h) / 2) or 0
    widget.right_x = half_w + (right_bb and math.floor((half_w - right_w) / 2) or 0)
    widget.right_y = right_bb and math.floor((screen_h - right_h) / 2) or 0
    widget.on_exit = function() self:exit() end

    self.widget = widget
    self.active = true
    UIManager:show(widget)
    -- Force a full (not partial) refresh of the ENTIRE screen, not just
    -- this widget's own dimen: after a rotation-mode change, a partial
    -- refresh can leave stale pixels around the edges uncovered.
    UIManager:setDirty("all", "full")
    logger.info("BigView: entered and UIManager:show() called, pages=(", left_pageno, ",", right_pageno,
        ") left_bb=", left_bb ~= nil, "right_bb=", right_bb ~= nil)
end

-- Renders a full page, scaled (preserving aspect ratio) to fit within
-- box_w x box_h. Returns the BlitBuffer plus its actual rendered width/height.
-- rotation is left at 0: physical orientation is handled by the screen
-- rotation mode set in :enter(), not by rotating the rendered content.
function BigView:renderPageFit(document, pageno, box_w, box_h)
    local page_size = document:getNativePageDimensions(pageno)
    if not page_size or page_size.w == 0 or page_size.h == 0 then
        logger.warn("BigView: could not get native dimensions for page", pageno)
        return nil
    end

    local zoom = math.min(box_w / page_size.w, box_h / page_size.h)
    local rect = Geom:new{ x = 0, y = 0, w = page_size.w, h = page_size.h }

    -- getPagePart() isn't available on every Document subclass/build; try
    -- it first (it's the simplest API when present), then fall back to
    -- the lower-level renderPage(), which is what KOReader's own view
    -- uses internally to draw pages and should always be present. It
    -- returns a tile object whose .bb field is the actual BlitBuffer
    -- (on some builds it may return the BlitBuffer directly instead).
    local bb
    if document.getPagePart then
        local ok, result = pcall(function()
            return document:getPagePart(pageno, rect, zoom, 0)
        end)
        if ok then
            bb = result
        else
            logger.info("BigView: getPagePart raised:", result)
        end
    end

    if not bb and document.renderPage then
        local ok, tile = pcall(function()
            -- gamma must be a real number here: document.lua builds a
            -- cache key by concatenating it, and nil blows that up.
            return document:renderPage(pageno, rect, zoom, 0, 1)
        end)
        if ok and tile then
            bb = tile.bb or tile
        else
            logger.info("BigView: renderPage raised or returned nothing:", tile)
        end
    end

    if not bb then
        logger.warn("BigView: no working render method found for page", pageno,
            "(tried getPagePart, renderPage)")
        -- Diagnostic dump: list callable methods on the document object so
        -- we can pick the right API name for this KOReader build/version.
        local mt = getmetatable(document)
        local index = mt and mt.__index
        if type(index) == "table" then
            local names = {}
            for k, v in pairs(index) do
                if type(v) == "function" and (k:lower():find("page") or k:lower():find("render")) then
                    table.insert(names, k)
                end
            end
            logger.info("BigView: document methods containing 'page'/'render':", table.concat(names, ", "))
        end
        return nil
    end
    return bb, bb:getWidth(), bb:getHeight()
end

function BigView:exit()
    if not self.active then return end
    self.active = false

    if self.widget then
        UIManager:close(self.widget)
        self.widget = nil
    end

    if self.pre_rotation_mode then
        Screen:setRotationMode(self.pre_rotation_mode)
        UIManager:broadcastEvent(Event:new("SetRotationMode", self.pre_rotation_mode))
        self.pre_rotation_mode = nil
    end

    if self.ui and self.ui.view then
        UIManager:setDirty("all", "full")
    end
    logger.info("BigView: exited")
end

-- Called from the menu alongside AutoRotate:setDirection()/
-- HorizontalMode:setRotationDirection(), since rotation_direction is
-- otherwise only read once, at :init() time.
function BigView:setRotationDirection(clockwise)
    self.rotation_direction = clockwise and "cw" or "ccw"
end

-- Called from HoldZoom:onCloseDocument, as a safety net (mirrors
-- AutoRotate:reset/Zoom:reset).
function BigView:reset()
    if self.active then
        self:exit()
    end
    self.pre_rotation_mode = nil
    self.current_pageno = nil
end

return BigView
