--[[--
Menu module for Double Tap Zoom plugin.
@module holdzoom.menu
]]--

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Menu = {}

function Menu:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

local ZOOM_POWER_OPTIONS = { 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0 }
local TRIGGER_GESTURE_OPTIONS = {
    { id = "double_tap", text = _("Double tap") },
    { id = "single_tap", text = _("Single tap") },
}

function Menu:build(plugin, Zoom, AutoRotate, HorizontalMode, Settings)
    local self_menu = self

    local function isTriggerConflict(trigger_gesture, horizontal_enabled)
        return trigger_gesture == "double_tap" and horizontal_enabled
    end

    -- Trigger gesture
    local trigger_gesture_items = {}
    for _, opt in ipairs(TRIGGER_GESTURE_OPTIONS) do
        table.insert(trigger_gesture_items, {
            text = opt.text,
            checked_func = function() return Zoom.trigger_gesture == opt.id end,
            callback = function()
                if isTriggerConflict(opt.id, HorizontalMode.enabled) then
                    self_menu:showMessage(
                        "Cannot switch to Double tap: Horizontal mode is enabled.\n\n" ..
                        "Horizontal mode currently relies on Double tap being free " ..
                        "to trigger the two-finger-tap rotation gesture. " ..
                        "Disable Horizontal mode first.",
                        5
                    )
                    return
                end
                Zoom:setTriggerGesture(opt.id)
                if opt.id == "single_tap" then
                    self_menu:showMessage(
                        "Trigger: Single tap\n\n" ..
                        "Warning: this may conflict with other single-tap actions " ..
                        "(menu, toolbar, page turn) depending on the reader/document type.",
                        4
                    )
                else
                    self_menu:showMessage(string.format("Trigger: %s", opt.text), 1)
                end
            end,
            hold_callback = function()
                if isTriggerConflict(opt.id, HorizontalMode.enabled) then
                    self_menu:showMessage("Cannot set as default: Horizontal mode is enabled.", 3)
                    return
                end
                Zoom:setTriggerGesture(opt.id)
                Settings:set("zoom_trigger_gesture", opt.id)
                self_menu:showMessage(string.format("Default trigger: %s", opt.text))
            end,
        })
    end

    -- Zoom power submenu
    local zoom_power_items = {}
    for _, value in ipairs(ZOOM_POWER_OPTIONS) do
        local display = string.format("%.2fx", value):gsub("0+$",""):gsub("%.$","")
        table.insert(zoom_power_items, {
            text = display,
            checked_func = function() return Zoom.zoom_power == value end,
            callback = function()
                Zoom:setZoomPower(value)
                self_menu:showMessage(string.format("Zoom power: %s", display), 1)
            end,
            hold_callback = function()
                Zoom:setZoomPower(value)
                Settings:set("zoom_power", value)
                self_menu:showMessage(string.format("Default zoom power: %s", display))
            end,
        })
    end

    -- Grid columns submenu
    local grid_cols_items = {}
    for cols = 1, 6 do
        table.insert(grid_cols_items, {
            text = tostring(cols),
            checked_func = function() return Zoom.grid_cols == cols end,
            callback = function()
                Zoom:setGrid(cols, Zoom.grid_rows)
                Settings:set("grid_cols", cols)
                self_menu:showMessage(string.format("Columns: %d", cols), 1)
            end,
            hold_callback = function()
                Zoom:setGrid(cols, Zoom.grid_rows)
                Settings:set("grid_cols", cols)
                self_menu:showMessage(string.format("Default columns: %d", cols))
            end,
        })
    end

    -- Horizontal mode split ratio submenu
    local SPLIT_RATIO_OPTIONS = { 0.50, 0.55, 0.60, 0.65 }
    local split_ratio_items = {}
    for _, value in ipairs(SPLIT_RATIO_OPTIONS) do
        local display = string.format("%d%%", value * 100)
        table.insert(split_ratio_items, {
            text = display,
            checked_func = function() return HorizontalMode.split_ratio == value end,
            callback = function()
                HorizontalMode:setSplitRatio(value)
                self_menu:showMessage(string.format("Split ratio: %s", display), 1)
            end,
            hold_callback = function()
                HorizontalMode:setSplitRatio(value)
                Settings:set("horizontal_split_ratio", value)
                self_menu:showMessage(string.format("Default split ratio: %s", display))
            end,
        })
    end

    -- Grid rows submenu
    local grid_rows_items = {}
    for rows = 1, 6 do
        table.insert(grid_rows_items, {
            text = tostring(rows),
            checked_func = function() return Zoom.grid_rows == rows end,
            callback = function()
                Zoom:setGrid(Zoom.grid_cols, rows)
                Settings:set("grid_rows", rows)
                self_menu:showMessage(string.format("Rows: %d", rows), 1)
            end,
            hold_callback = function()
                Zoom:setGrid(Zoom.grid_cols, rows)
                Settings:set("grid_rows", rows)
                self_menu:showMessage(string.format("Default rows: %d", rows))
            end,
        })
    end

    return {
        text = _("Double Tap Zoom"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enable doubletap-to-zoom"),
                checked_func = function() return Zoom.enabled end,
                callback = function()
                    if not plugin:isComic() then
                        self_menu:showMessage("Open a CBZ, CBR or PDF file first.")
                        return
                    end
                    local enabled = Zoom:toggle()
                    self_menu:showMessage(enabled
                        and "Double Tap Zoom ON\nDouble Tap anywhere to zoom, Double Tap again to exit"
                        or "Double Tap Zoom OFF")
                end,
                hold_callback = function()
                    Settings:set("zoom_enabled", Zoom.enabled)
                    self_menu:showMessage("Double Tap Zoom default: " .. (Zoom.enabled and "ON" or "OFF"))
                end,
            },
            {
                text = _("Zoom power"),
                sub_item_table = zoom_power_items,
            },
            {
                text = _("Grid columns"),
                sub_item_table = grid_cols_items,
            },
            {
                text = _("Grid rows"),
                sub_item_table = grid_rows_items,
            },
            {
                text = _("Zoom trigger gesture"),
                sub_item_table = trigger_gesture_items,
            },
            {
                text = _("Auto-rotate landscape pages"),
                checked_func = function() return AutoRotate.enabled end,
                callback = function()
                    local enabled = AutoRotate:toggle()
                    self_menu:showMessage(enabled
                        and "Auto-rotate ON\nLandscape pages will rotate automatically"
                        or "Auto-rotate OFF")
                end,
                hold_callback = function()
                    Settings:set("autorotate_enabled", AutoRotate.enabled)
                    self_menu:showMessage("Auto-rotate default: " .. (AutoRotate.enabled and "ON" or "OFF"))
                end,
            },
            {
                text = _("Rotation direction"),
                sub_item_table = {
                    {
                        text = _("Clockwise (90°)"),
                        checked_func = function() return AutoRotate.clockwise end,
                        callback = function()
                            AutoRotate:setDirection(true)
                            self_menu:showMessage("Rotation: Clockwise", 1)
                        end,
                        hold_callback = function()
                            AutoRotate:setDirection(true)
                            Settings:set("rotate_clockwise", true)
                            self_menu:showMessage("Default rotation: Clockwise")
                        end,
                    },
                    {
                        text = _("Counter-clockwise (270°)"),
                        checked_func = function() return not AutoRotate.clockwise end,
                        callback = function()
                            AutoRotate:setDirection(false)
                            self_menu:showMessage("Rotation: Counter-clockwise", 1)
                        end,
                        hold_callback = function()
                            AutoRotate:setDirection(false)
                            Settings:set("rotate_clockwise", false)
                            self_menu:showMessage("Default rotation: Counter-clockwise")
                        end,
                    },
                },
            },
            {
                text = _("Horizontal reading mode"),
                sub_item_table = {
                    {
                        text = _("Enable horizontal mode"),
                        checked_func = function() return HorizontalMode.enabled end,
                        callback = function()
                            if isTriggerConflict(Zoom.trigger_gesture, not HorizontalMode.enabled) then
                                self_menu:showMessage(
                                    "Cannot enable: zoom trigger is set to Double tap.\n\n" ..
                                    "Horizontal mode would then trigger with a two-finger tap. " ..
                                    "Set the zoom trigger to Single tap first, or wait for the " ..
                                    "dedicated horizontal-mode trigger setting.",
                                    5
                                )
                                return
                            end
                            HorizontalMode.enabled = not HorizontalMode.enabled
                            self_menu:showMessage(HorizontalMode.enabled
                                and "Horizontal mode ON"
                                or "Horizontal mode OFF")
                        end,
                        hold_callback = function()
                            if isTriggerConflict(Zoom.trigger_gesture, not HorizontalMode.enabled) then
                                self_menu:showMessage("Cannot enable while zoom trigger is Double tap.", 3)
                                return
                            end
                            HorizontalMode.enabled = not HorizontalMode.enabled
                            Settings:set("horizontal_mode_enabled", HorizontalMode.enabled)
                            self_menu:showMessage("Horizontal mode default: " ..
                                (HorizontalMode.enabled and "ON" or "OFF"))
                        end,
                    },
                    {
                        text = _("Split ratio"),
                        sub_item_table = split_ratio_items,
                    },
                    {
                        text = _("Return to vertical after page turn"),
                        checked_func = function() return HorizontalMode.return_to_vertical end,
                        callback = function()
                            local enabled = HorizontalMode:toggleReturnToVertical()
                            self_menu:showMessage(enabled
                                and "Will return to vertical after each page turn"
                                or "Will stay in horizontal mode across pages")
                        end,
                        hold_callback = function()
                            HorizontalMode:toggleReturnToVertical()
                            Settings:set("horizontal_return_to_vertical", HorizontalMode.return_to_vertical)
                            self_menu:showMessage("Default: " ..
                                (HorizontalMode.return_to_vertical and "ON" or "OFF"))
                        end,
                    },
                },
            },
            {
                text = _("About"),
                callback = function()
                    self_menu:showMessage(
                        "Double Tap Zoom Plugin\n\n" ..
                        "Double Tap anywhere to zoom into that grid cell.\n" ..
                        "Double Tap to exit zoom.\n" ..
                        "Tap again (while zoomed) to jump to another cell (left/right side).\n\n" ..
                        "Hold a menu option to set it as default.\n\n" ..
                        "Supports: CBZ, CBR, PDF\n\n" ..
                        "Francesco Tornambè"
                    )
                end,
            },
        },
    }
end

return Menu
