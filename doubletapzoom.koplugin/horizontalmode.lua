--[[--
Horizontal Mode module for Double Tap Zoom plugin.
Splits a manga/comic page in half (top/bottom) and rotates the screen 90°,
so it can be read on narrow e-readers without zooming, or to view more
detail on small-to-medium screens than the standard grid zoom allows.

Reuses the Viewport module (pan/zoom engine shared with Zoom) for the
top/bottom crop, and the same rotation mechanism as AutoRotate for the
screen orientation change.
@module holdzoom.horizontalmode
]]--

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Viewport = require("viewport")
local Screen = Device.screen

local HorizontalMode = {
    enabled = false,            -- feature enabled in settings
    active = false,             -- currently in split view
    half = "top",               -- "top" | "bottom" - currently visible half
    split_ratio = 0.55,         -- fraction of page height shown per half (with overlap)
    return_to_vertical = false, -- if true, exit horizontal mode on every page turn
    rotation_direction = "cw",  -- "cw" | "ccw", shared with AutoRotate's setting
    pre_rotation_mode = nil,    -- rotation mode to restore on exit
    pending_half = nil,         -- "top" | "bottom", set right before a page change onPageUpdate knows which half to render on arrival
    ui = nil,
}

function HorizontalMode:init(ui, Settings)
    self.ui = ui
    self.enabled = Settings:get("horizontal_mode_enabled") or false
    self.split_ratio = Settings:get("horizontal_split_ratio") or 0.55
    self.return_to_vertical = Settings:get("horizontal_return_to_vertical") or false

    local clockwise = Settings:get("rotate_clockwise")
    if clockwise == nil then clockwise = true end  -- match AutoRotate's own default
    self.rotation_direction = clockwise and "cw" or "ccw"

    self.active = false
    self.half = "top"
    self.pre_rotation_mode = nil
    logger.info("HorizontalMode: initialized, enabled=", self.enabled,
        "split_ratio=", self.split_ratio, "rotation_direction=", self.rotation_direction)
end

function HorizontalMode:setupTouchZones(ui)
    self.ui = ui
    if not Device:isTouchDevice() then return end

    local full_screen = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }

    ui:registerTouchZones({
        {
            id = "horizontalmode_swipe",
            ges = "swipe",
            screen_zone = full_screen,
            -- Needs to take priority over the standard page-turn swipe zones
            -- (readerpaging/readerrolling) while active.
            handler = function(ges) return self:onSwipe(ges) end,
        },
    })
    logger.info("HorizontalMode: touch zones registered")
end

-- Called from Zoom:onRotateTrigger. Zoom is expected to already be
-- collapsed at this point (Viewport can only have one active owner).
function HorizontalMode:toggle(pos)
    if not self.enabled then return false end
    self.active = not self.active
    if self.active then
        self:enterHorizontal()
    else
        self:exitHorizontal()
    end
    return true
end

function HorizontalMode:enterHorizontal()
    self.half = "top"

    local new_rotation = (self.rotation_direction == "cw")
        and Screen.DEVICE_ROTATED_CLOCKWISE
        or Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE

    self.pre_rotation_mode = Screen:getRotationMode()
    logger.info("HorizontalMode: pre-rotation dimen=", Screen:getWidth(), "x", Screen:getHeight())

    UIManager:broadcastEvent(Event:new("SetRotationMode", new_rotation))

    -- DEBUG: check whether SetRotationMode is applied synchronously or not.
    -- If dimen below is already swapped compared to the log above, the
    -- sequential call to renderHalf() right after is safe. If not, we need
    -- to hook a post-resize event instead of calling renderHalf() inline.
    logger.info("HorizontalMode: immediately after broadcast, dimen=", Screen:getWidth(), "x", Screen:getHeight())

    self:renderHalf("top")
end

function HorizontalMode:exitHorizontal()
    self.active = false
    Viewport:leave()

    if self.pre_rotation_mode then
        Screen:setRotationMode(self.pre_rotation_mode)
        UIManager:broadcastEvent(Event:new("SetRotationMode", self.pre_rotation_mode))
        self.pre_rotation_mode = nil
    end

    logger.info("HorizontalMode: exited")
end

-- Physical swipe stays on its physical axis (screen is not OS-rotated, see
-- earlier design discussion): with the device held still, the user makes a
-- physically horizontal swipe to move between halves/pages. We intercept
-- that swipe here instead of letting it reach the normal page-turn handler.
function HorizontalMode:onSwipe(ges)
    if not self.active then return false end
    local direction = ges and ges.direction
    if direction ~= "west" and direction ~= "east" then
        return false -- vertical swipe, let it fall through to normal behavior
    end

    -- "Forward" (west vs east) depends on rotation_direction: content
    -- rotated CW scrolls in the opposite physical direction from content
    -- rotated CCW to move forward through top->bottom.
    local forward
    if self.rotation_direction == "cw" then
        forward = (direction == "west")
    else
        forward = (direction == "east")
    end

    if forward then
        self:goNextHalf()
    else
        self:goPrevHalf()
    end
    return true
end

function HorizontalMode:goNextHalf()
    if self.half == "top" then
        self.half = "bottom"
        self:renderHalf("bottom")
        return
    end
    -- was on "bottom": move to the next page, entering it from the top
    self.pending_half = "top"
    self.ui:handleEvent(Event:new("GotoViewRel", 1))
end

function HorizontalMode:goPrevHalf()
    if self.half == "bottom" then
        self.half = "top"
        self:renderHalf("top")
        return
    end
    -- was on "top": move to the previous page, entering it from the bottom
    self.pending_half = "bottom"
    self.ui:handleEvent(Event:new("GotoViewRel", -1))
end

-- Centralized entry point for every page change while horizontal mode is
-- active, regardless of how the page change happened (our own swipe
-- handling, standard tap zones, hardware keys, progress bar, etc.).
function HorizontalMode:onPageUpdate(pageno)
    if not self.active then return end

    if self.return_to_vertical then
        self:exitHorizontal()
        return
    end

    local half = self.pending_half or "top"
    self.pending_half = nil
    self.half = half
    self:renderHalf(half)
end

function HorizontalMode:renderHalf(half)
    if not Viewport.active then
        if not Viewport:enter(self.ui, "horizontal") then return end
    end
    local content_w, content_h = Viewport.content_w, Viewport.content_h
    logger.info("HorizontalMode: renderHalf captured content_w/h=", content_w, content_h)

    -- Vertical split with overlap: "top" half is centered at
    -- split_ratio/2, "bottom" half at (1 - split_ratio/2). E.g.
    -- split_ratio = 0.55 -> top center at 27.5% of height, bottom center
    -- at 72.5%.
    local center_x = content_w / 2
    local center_y
    if half == "top" then
        center_y = content_h * (self.split_ratio / 2)
    else
        center_y = content_h * (1 - self.split_ratio / 2)
    end

    -- zoom_power such that split_ratio of the page height fills the screen
    local zoom_power = 1 / self.split_ratio

    Viewport:setCenter(center_x, center_y, zoom_power)
    logger.info("HorizontalMode: renderHalf", half, "center=(", center_x, ",", center_y,
        ") zoom_power=", zoom_power)
end

function HorizontalMode:toggleReturnToVertical()
    self.return_to_vertical = not self.return_to_vertical
    return self.return_to_vertical
end

function HorizontalMode:setSplitRatio(value)
    self.split_ratio = value
    if self.active then
        self:renderHalf(self.half)
    end
end

return HorizontalMode
