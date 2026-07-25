--[[--
Double Tap Zoom plugin for KOReader
@module koplugin.holdzoom
@credits Francesco Tornambè
]]--
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local Settings = require("settings")
local Zoom = require("zoom")
local AutoRotate = require("autorotate")
local HorizontalMode = require("horizontalmode")
local BigView = require("bigview")
local Menu = require("menu")
local SUPPORTED_EXTENSIONS = {
    cbz = true,
    cbr = true,
    pdf = true,
}

-- DEV/TEST ONLY: emulates the "spread" (enter Big View, left/right side)
-- and "pinch" (exit Big View) gestures via keyboard, since these can't be
-- performed on a desktop/emulator without multitouch. Calls the same
-- handler functions the real gestures call — no fake touch events involved.
-- Flip to false (or just delete this block + setupDebugKeyEvents call
-- below) before shipping to a touch device.
local DEBUG_KEY_GESTURES = true

local HoldZoom = InputContainer:extend{
    name = "holdzoom",
    is_doc_only = true,
}

function HoldZoom:init()
    self.ui.menu:registerToMainMenu(self)
end

function HoldZoom:onReaderReady()
    Zoom:init(self.ui, Settings)
    Zoom:setupTouchZones(self.ui)
    AutoRotate:init(Settings)
    HorizontalMode:init(self.ui, Settings)
    HorizontalMode:setupTouchZones(self.ui)
    self.ui.horizontal_mode = HorizontalMode
    BigView:init(self.ui, Settings, Zoom, HorizontalMode)
    BigView:setupTouchZones(self.ui)
    self.ui.big_view = BigView

    if DEBUG_KEY_GESTURES and Device:hasKeyboard() then
        self:setupDebugKeyEvents()
    end
end

-- DEV/TEST ONLY, see DEBUG_KEY_GESTURES above.
-- S / D = two_finger_tap on the left / right half of the screen (enter
--         Big View with the corresponding page pair). Note: this only
--         actually does anything in-game when Zoom.trigger_gesture ==
--         "single_tap" (see BigView:onTwoFingerTap's gating).
-- P     = tap (exit Big View).
function HoldZoom:setupDebugKeyEvents()
    self.key_events.DebugBigViewEnterLeft = { {"Q"} }
    self.key_events.DebugBigViewEnterRight = { {"W"} }
    self.key_events.DebugBigViewExit = { {"E"} }
    logger.info("HoldZoom: [DEBUG] keyboard gesture mapper active (Q/W = enter left/right, E = exit)")
end

function HoldZoom:onDebugBigViewEnterLeft()
    local screen_h = Device.screen:getHeight()
    logger.info("HoldZoom: [DEBUG] simulating two_finger_tap on LEFT side")
    BigView:onTwoFingerTap({ pos = { x = 0, y = screen_h / 2 } })
    return true
end

function HoldZoom:onDebugBigViewEnterRight()
    local screen_w, screen_h = Device.screen:getWidth(), Device.screen:getHeight()
    logger.info("HoldZoom: [DEBUG] simulating two_finger_tap on RIGHT side")
    BigView:onTwoFingerTap({ pos = { x = screen_w - 1, y = screen_h / 2 } })
    return true
end

function HoldZoom:onDebugBigViewExit()
    logger.info("HoldZoom: [DEBUG] simulating tap (exit)")
    BigView:exit()
    return true
end

function HoldZoom:isComic()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return false end
    local ext = doc.file:match("%.([^%.]+)$")
    return ext and SUPPORTED_EXTENSIONS[ext:lower()] or false
end

function HoldZoom:onPageUpdate(pageno)
    if self:isComic() then
        if not HorizontalMode.active then
            AutoRotate:onPageUpdate(self.ui.document, pageno)
        end
    end
    if Zoom.expanded then
        Zoom:collapse()
    end
    HorizontalMode:onPageUpdate(pageno)
    BigView:onPageUpdate(pageno)
end

function HoldZoom:addToMainMenu(menu_items)
    menu_items.holdzoom = Menu:build(self, Zoom, AutoRotate, HorizontalMode, BigView, Settings)
end

function HoldZoom:onCloseDocument()
    Zoom:reset()
    if HorizontalMode.active then
        HorizontalMode:exitHorizontal()
    end
    if AutoRotate.enabled then
        AutoRotate:restorePortrait()
    end
    AutoRotate:reset()
    BigView:reset()
end

return HoldZoom
