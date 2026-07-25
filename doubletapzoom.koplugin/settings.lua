--[[--
Settings module for Double Tap Zoom plugin.
@module holdzoom.settings
]]--

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local Settings = {}
local settings_file = DataStorage:getSettingsDir() .. "/holdzoom.lua"
local settings = nil

local DEFAULTS = {
    zoom_enabled = true,
    zoom_power = 1.50,
    autorotate_enabled = true,
    rotate_clockwise = true,
    grid_cols = 2,
    grid_rows = 2,
    horizontal_mode_enabled = false,
    horizontal_split_ratio = 0.55,
    horizontal_return_to_vertical = true,
    bigview_enabled = false,
}

function Settings:load()
    settings = LuaSettings:open(settings_file)
end

function Settings:get(key)
    if not settings then self:load() end
    local value = settings:readSetting(key)
    if value == nil then return DEFAULTS[key] end
    return value
end

function Settings:set(key, value)
    if not settings then self:load() end
    settings:saveSetting(key, value)
    settings:flush()
end

return Settings
