--[[--
Double Tap Zoom plugin for KOReader
@module koplugin.holdzoom
@credits Francesco Tornambè
]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")

local Settings = require("settings")
local Zoom = require("zoom")
local AutoRotate = require("autorotate")
local Menu = require("menu")

local SUPPORTED_EXTENSIONS = {
    cbz = true,
    cbr = true,
    pdf = true,
}

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
end

function HoldZoom:isComic()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return false end
    local ext = doc.file:match("%.([^%.]+)$")
    return ext and SUPPORTED_EXTENSIONS[ext:lower()] or false
end

function HoldZoom:onPageUpdate(pageno)
    if self:isComic() then
        AutoRotate:onPageUpdate(self.ui.document, pageno)
    end

    if Zoom.expanded then
        Zoom:collapse()
    end
end

function HoldZoom:addToMainMenu(menu_items)
    menu_items.holdzoom = Menu:build(self, Zoom, AutoRotate, Settings)
end

function HoldZoom:onCloseDocument()
    Zoom:reset()
    if AutoRotate.enabled then
        AutoRotate:restorePortrait()
    end
    AutoRotate:reset()
end

return HoldZoom
