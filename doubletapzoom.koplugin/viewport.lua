--[[--
Viewport module: shared pan/zoom primitives used by both the Zoom (grid
zoom) and HorizontalMode (split-page) features. Owns the "expanded"
viewport state so the two features can never be active at the same time
(HorizontalMode always collapses Zoom before taking over, see
Zoom:onRotateTrigger).
@module holdzoom.viewport
]]--

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

local Viewport = {
    ui = nil,
    active = false,          -- true while either Zoom or HorizontalMode owns the viewport
    owner = nil,             -- "zoom" | "horizontal", for logging / guard checks
    content_w = nil,
    content_h = nil,
    base_zoom = nil,
    original_zoom_mode = nil,
    center_x = nil,
    center_y = nil,
    zoom_power = 1.0,
}

-- Returns the page-rendering area (width, height) at base_zoom (zoom_power
-- = 1). Falls back to full screen size if the document/zooming module
-- isn't ready yet.
function Viewport:getContentDimensions(ui)
    if self.active and self.content_w and self.content_h then
        return self.content_w, self.content_h
    end
    local zooming = ui and ui.zooming
    if zooming and zooming.dimen and zooming.dimen.w and zooming.dimen.h then
        return zooming.dimen.w, zooming.dimen.h
    end
    return Screen:getWidth(), Screen:getHeight()
end

-- Enters "free zoom" mode and captures fixed content dimensions, base zoom
-- level and original zoom mode, so callers can pan/zoom without fighting
-- KOReader's own fit-page logic. No-op (returns false) if already active.
-- owner: "zoom" | "horizontal", used for logging/guard purposes only.
function Viewport:enter(ui, owner)
    if self.active then
        logger.warn("Viewport: enter() called while already active (owner=", self.owner, "), ignoring")
        return false
    end
    local view = ui.view
    local zooming = ui.zooming
    if not view or not zooming then
        logger.info("Viewport: enter: view or zooming missing")
        return false
    end

    self.ui = ui
    self.content_w, self.content_h = self:getContentDimensions(ui)
    self.original_zoom_mode = zooming.zoom_mode
    self.base_zoom = zooming.zoom or 1
    self.zoom_power = 1.0
    self.active = true
    self.owner = owner

    -- Switch to "free" zoom mode without triggering KOReader's SetZoomMode
    -- event, to avoid a crash in koptoptions.lua if the config dialog is
    -- opened while active (matches the previous Zoom-only behavior).
    zooming.zoom_mode = "free"
    view.zoom_mode = "free"

    logger.info("Viewport: entered, owner=", owner, "content=(", self.content_w, ",", self.content_h,
        ") base_zoom=", self.base_zoom)
    return true
end

-- Leaves free-zoom mode and restores the original zoom mode via event.
function Viewport:leave()
    if not self.active then return end
    local ui = self.ui

    ui:handleEvent(Event:new("SetZoomMode", self.original_zoom_mode or "page"))

    self.active = false
    self.owner = nil
    self.content_w = nil
    self.content_h = nil
    self.base_zoom = nil
    self.original_zoom_mode = nil
    self.center_x = nil
    self.center_y = nil
    self.zoom_power = 1.0

    ui:handleEvent(Event:new("RedrawCurrentView"))
    UIManager:setDirty(ui.view, "full")
    logger.info("Viewport: left")
end

-- Applies the given center (in content-space, i.e. at base_zoom /
-- zoom_power = 1) and zoom_power, updating KOReader's zoom state and
-- triggering a redraw.
function Viewport:setCenter(center_x, center_y, zoom_power)
    if not self.active then
        logger.info("Viewport: setCenter called while inactive, ignoring")
        return
    end
    local ui = self.ui
    local view = ui.view
    local zooming = ui.zooming
    if not view or not zooming then return end

    self.center_x = center_x
    self.center_y = center_y
    self.zoom_power = zoom_power or self.zoom_power

    local new_zoom = self.base_zoom * self.zoom_power
    zooming.zoom = new_zoom
    view:onZoomUpdate(new_zoom)

    -- SetZoomCenter(x, y) expects coordinates in page_area space, i.e. the
    -- page rendered at the TARGET zoom (new_zoom = base_zoom * zoom_power).
    -- center_x/center_y are in content-space (base_zoom, zoom_power = 1),
    -- so the conversion ratio is new_zoom / base_zoom = zoom_power
    -- (base_zoom cancels out). Same reasoning as the original Zoom module.
    if view.SetZoomCenter then
        view:SetZoomCenter(center_x * self.zoom_power, center_y * self.zoom_power)
    end

    ui:handleEvent(Event:new("RedrawCurrentView"))
    UIManager:setDirty(view, "full")
end

-- Converts a screen-space touch position into content-space coordinates,
-- accounting for the current zoom level and viewport. Falls back to
-- identity mapping when inactive (screen == page).
function Viewport:screenPosToPagePos(pos)
    if not self.active then
        return pos.x, pos.y
    end
    local view = self.ui.view
    local visible_area = view and view.visible_area
    if not visible_area then
        logger.info("Viewport: screenPosToPagePos: visible_area missing, falling back to center-based estimate")
        local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
        local page_x = self.center_x + (pos.x - screen_w / 2) / self.zoom_power
        local page_y = self.center_y + (pos.y - screen_h / 2) / self.zoom_power
        page_x = math.max(0, math.min(page_x, self.content_w))
        page_y = math.max(0, math.min(page_y, self.content_h))
        return page_x, page_y
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local page_area_x = visible_area.x + (pos.x / screen_w) * visible_area.w
    local page_area_y = visible_area.y + (pos.y / screen_h) * visible_area.h

    local content_x = page_area_x / self.zoom_power
    local content_y = page_area_y / self.zoom_power
    content_x = math.max(0, math.min(content_x, self.content_w))
    content_y = math.max(0, math.min(content_y, self.content_h))
    return content_x, content_y
end

return Viewport
