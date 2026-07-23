--[[--
Zoom module for Double Tap Zoom plugin.
Double Tap (or Single Tap, if configured) anywhere on the page to zoom into
a grid cell (computed dynamically from the touch position). While zoomed:
tap left/right to move between cells, swipe up/down to adjust zoom level,
repeat the trigger gesture to exit.
@module holdzoom.zoom
]]--

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

local Zoom = {
    enabled = true,
    zoom_power = 1.0,
    expanded = false,
    center_x = nil,
    center_y = nil,
    original_zoom_mode = nil,
    base_zoom = nil,             -- fit-page zoom captured when entering zoom mode
    current_cell = nil,          -- current cell index (1..grid_cols*grid_rows)
    grid_cols = 2,
    grid_rows = 2,
    ui = nil,
    -- Fixed content dimensions captured once when entering zoom mode.
    -- They stay constant even when zoom_power changes.
    content_w = nil,
    content_h = nil,
}

function Zoom:init(ui, Settings)
    self.ui = ui
    self.enabled = Settings:get("zoom_enabled")
    self.default_zoom_power = Settings:get("zoom_power")
    self.zoom_power = self.default_zoom_power
    self.grid_cols = Settings:get("grid_cols") or 2
    self.grid_rows = Settings:get("grid_rows") or 2
    self.trigger_gesture = Settings:get("zoom_trigger_gesture") or "double_tap"
    self.current_cell = nil
    self.expanded = false
    self.center_x = nil
    self.center_y = nil
    self.original_zoom_mode = nil
    self.base_zoom = nil
    self.content_w = nil
    self.content_h = nil
    logger.info("Zoom: initialized with default_zoom_power=", self.default_zoom_power,
        "grid=", self.grid_cols, "x", self.grid_rows,
        "trigger_gesture=", self.trigger_gesture)
end

function Zoom:reset()
    self.expanded = false
    self.center_x = nil
    self.center_y = nil
    self.original_zoom_mode = nil
    self.current_cell = nil
    self.base_zoom = nil
    self.content_w = nil
    self.content_h = nil
    logger.info("Zoom: reset")
end

function Zoom:setupTouchZones(ui)
    self.ui = ui
    if not Device:isTouchDevice() then return end

    local full_screen = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }

    local zones = {
        -- Double tap to enter/exit zoom
        {
            id = "holdzoom_doubletap",
            ges = "double_tap",
            screen_zone = full_screen,
            handler = function(ges) return self:onDoubleTap(ges) end,
        },
        -- Tap left/right to navigate cells
        {
            id = "holdzoom_tap",
            ges = "tap",
            screen_zone = full_screen,
            handler = function(ges) return self:onTap(ges) end,
        },
        -- Swipe up/down to adjust zoom level
        {
            id = "holdzoom_swipe",
            ges = "swipe",
            screen_zone = full_screen,
            handler = function(ges) return self:onSwipe(ges) end,
        },
    }

    ui:registerTouchZones(zones)
    logger.info("Zoom: touch zones registered")
end

-- Returns the actual page-rendering area (width, height).
-- When zoomed, we use the captured dimensions to keep consistency.
function Zoom:getContentDimensions()
    if self.expanded and self.content_w and self.content_h then
        return self.content_w, self.content_h
    end
    local zooming = self.ui and self.ui.zooming
    if zooming and zooming.dimen and zooming.dimen.w and zooming.dimen.h then
        return zooming.dimen.w, zooming.dimen.h
    end
    return Screen:getWidth(), Screen:getHeight()
end

-- Returns the cell index (1..total) for a given touch position (page-space coordinates).
function Zoom:cellFromPos(pos)
    if not pos then return nil end
    local w, h = self:getContentDimensions()
    local col = math.floor(pos.x / (w / self.grid_cols)) + 1
    local row = math.floor(pos.y / (h / self.grid_rows)) + 1
    col = math.max(1, math.min(col, self.grid_cols))
    row = math.max(1, math.min(row, self.grid_rows))
    local cell = (row - 1) * self.grid_cols + col
    return cell
end

-- Calculate center coordinates for a given cell using the fixed content dimensions.
function Zoom:calcCenterForCell(cell)
    local col = (cell - 1) % self.grid_cols
    local row = math.floor((cell - 1) / self.grid_cols)
    local cell_w = self.content_w / self.grid_cols
    local cell_h = self.content_h / self.grid_rows
    return col * cell_w + cell_w / 2, row * cell_h + cell_h / 2
end

-- Determine the cell index from the current center position.
function Zoom:getCellFromCenter()
    if not self.center_x or not self.center_y or not self.content_w or not self.content_h then
        return nil
    end
    local col = math.floor(self.center_x / (self.content_w / self.grid_cols)) + 1
    local row = math.floor(self.center_y / (self.content_h / self.grid_rows)) + 1
    col = math.min(col, self.grid_cols)
    row = math.min(row, self.grid_rows)
    return (row - 1) * self.grid_cols + col
end

function Zoom:onDoubleTap(ges)
    if self.trigger_gesture ~= "double_tap" then return false end
    return self:handleZoomGesture(ges, "double tap")
end

function Zoom:onTap(ges)
    if self.trigger_gesture ~= "single_tap" then return false end
    return self:handleZoomGesture(ges, "single tap")
end

function Zoom:handleZoomGesture(ges, source)
    if not self.enabled then return false end
    local pos = ges and ges.pos
    if not pos then return false end
    if self.expanded then
        logger.info("Zoom: ", source, " -> collapse")
        self:collapse()
        return true
    end
    local cell = self:cellFromPos(pos)
    if cell then
        logger.info("Zoom: ", source, " -> zoomToCell", cell)
        self:zoomToCell(cell)
    end
    return true
end

-- Swipe up while zoomed: increase zoom (towards the configurable max).
-- Swipe down while zoomed: back to the default zoom level.
-- Any other direction (left/right) is left alone, e.g. for page turning.
-- The swipe start position is converted from screen-space to page-space
-- so the zoom adjustment applies to the cell actually being viewed.
function Zoom:onSwipe(ges)
    if not self.expanded then return false end
    local direction = ges and ges.direction
    local pos = ges and ges.pos

    if pos then
        local page_x, page_y = self:screenPosToPagePos(pos)
        local cell = self:cellFromPos({x = page_x, y = page_y})
        if cell and cell ~= self.current_cell then
            self.current_cell = cell
            self.center_x, self.center_y = self:calcCenterForCell(cell)
            logger.info("Zoom: onSwipe: updated current_cell to", cell)
        end
    end

    if direction == "north" then
        self:increaseZoomStep()
        return true
    elseif direction == "south" then
        self:decreaseZoomStep()
        return true
    end
    return false
end

function Zoom:updateZoomCenter()
    local view = self.ui.view
    if view and view.SetZoomCenter then
        local scale = self.base_zoom * self.zoom_power
        -- KOReader expects coordinates in points (1/2 pixel), hence the *2 factor
        view:SetZoomCenter(self.center_x * scale * 2, self.center_y * scale * 2)
    else
        logger.info("Zoom: updateZoomCenter: view or SetZoomCenter missing")
    end
end

-- Zoom into the specified cell (1..total)
function Zoom:zoomToCell(cell)
    local view = self.ui.view
    local zooming = self.ui.zooming
    if not view or not zooming then
        logger.info("Zoom: zoomToCell: view or zooming missing")
        return
    end

    if not self.expanded then
        -- Capture content dimensions once when entering zoom mode.
        self.content_w, self.content_h = self:getContentDimensions()
        self.original_zoom_mode = zooming.zoom_mode
        self.base_zoom = zooming.zoom or 1
        self.expanded = true
        logger.info("Zoom: entering zoom mode, content=(", self.content_w, ",", self.content_h, ") base_zoom=", self.base_zoom)

        -- Switch to "free" zoom mode without triggering KOReader's SetZoomMode event.
        -- This avoids a crash in koptoptions.lua if the user opens the config dialog.
        zooming.zoom_mode = "free"
        view.zoom_mode = "free"
    end

    self.current_cell = cell
    self.center_x, self.center_y = self:calcCenterForCell(cell)

    local new_zoom = self.base_zoom * self.zoom_power
    zooming.zoom = new_zoom

    view:onZoomUpdate(new_zoom)
    self:updateZoomCenter()

    self.ui:handleEvent(Event:new("RedrawCurrentView"))
    UIManager:setDirty(view, "full")

    logger.info("Zoom: zoomed to cell", cell, "zoom_power=", self.zoom_power)
end

function Zoom:collapse()
    local zooming = self.ui.zooming
    if not zooming then return end

    self.expanded = false
    self.current_cell = nil
    self.base_zoom = nil
    self.content_w = nil
    self.content_h = nil
    self.zoom_power = self.default_zoom_power

    -- Restore the original zoom mode via event.
    self.ui:handleEvent(Event:new("SetZoomMode", self.original_zoom_mode or "page"))
    self.original_zoom_mode = nil

    self.ui:handleEvent(Event:new("RedrawCurrentView"))
    UIManager:setDirty(self.ui.view, "full")

    logger.info("Zoom: collapsed")
end

function Zoom:toggle()
    self.enabled = not self.enabled
    if not self.enabled and self.expanded then
        self:collapse()
    end
    return self.enabled
end

function Zoom:setZoomPower(value)
    self.default_zoom_power = value
    self.zoom_power = value

    if self.expanded then
        self:updateZoomFactor(value)
    end
end

function Zoom:setGrid(cols, rows)
    self.grid_cols = cols
    self.grid_rows = rows
end

function Zoom:setTriggerGesture(gesture)
    self.trigger_gesture = gesture
    logger.info("Zoom: setTriggerGesture:", gesture)
end

-- Update the zoom factor (zoom_power) and recalculate the center
-- based on the current cell (derived from center_x/y).
function Zoom:updateZoomFactor(new_factor)
    if not self.expanded then return end

    self.zoom_power = new_factor

    local cell_from_center = self:getCellFromCenter()
    if cell_from_center then
        self.current_cell = cell_from_center
    end
    if self.current_cell then
        self.center_x, self.center_y = self:calcCenterForCell(self.current_cell)
    end

    local view = self.ui.view
    local zooming = self.ui.zooming
    if not view or not zooming then
        logger.info("Zoom: updateZoomFactor: view or zooming missing")
        return
    end

    local new_zoom = self.base_zoom * self.zoom_power
    zooming.zoom = new_zoom
    view:onZoomUpdate(new_zoom)
    self:updateZoomCenter()
    UIManager:setDirty(view, "full")

    logger.info("Zoom: updateZoomFactor: zoom_power=", self.zoom_power, "cell=", self.current_cell)
end

function Zoom:increaseZoomStep()
    local step = 0.25
    local max_zoom = 3.0
    local new = math.min(self.zoom_power + step, max_zoom)
    if new ~= self.zoom_power then
        self:updateZoomFactor(new)
    end
end

function Zoom:decreaseZoomStep()
    local step = 0.25
    local min_zoom = self.default_zoom_power
    local new = math.max(self.zoom_power - step, min_zoom)
    if new ~= self.zoom_power then
        self:updateZoomFactor(new)
    end
end

-- Converts a screen-space touch position into page-space coordinates,
-- accounting for the current zoom level and viewport center.
-- Falls back to identity mapping when not zoomed (screen == page).
-- NOTE: content_w/content_h are already in screen-space units at zoom_power=1
-- (base_zoom is baked into them via getContentDimensions), so only zoom_power
-- is needed here — NOT base_zoom * zoom_power (that would double-apply base_zoom).
function Zoom:screenPosToPagePos(pos)
    if not self.expanded then
        return pos.x, pos.y
    end
    local scale = self.zoom_power
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local page_x = self.center_x + (pos.x - screen_w / 2) / scale
    local page_y = self.center_y + (pos.y - screen_h / 2) / scale
    page_x = math.max(0, math.min(page_x, self.content_w))
    page_y = math.max(0, math.min(page_y, self.content_h))
    return page_x, page_y
end

return Zoom
