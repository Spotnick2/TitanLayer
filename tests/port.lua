-- Run from the addon directory: lua tests/port.lua
local clock, map = 10000, 10
local guids = {}
local secret = {}
local button
local scheduled = {}
local settings = { ScanNameplates = true, AnnounceChannel = "PRINT" }

function wipe(t) for k in pairs(t) do t[k] = nil end end
function strsplit(delim, s)
    local result = {}
    for field in (s .. delim):gmatch("(.-)" .. delim) do
        result[#result + 1] = field
    end
    return unpack(result)
end
function issecretvalue(v) return v == secret end
function UnitGUID(unit) return guids[unit] end
function UnitOnTaxi() return false end
function IsInInstance() return false end
function GetServerTime() return clock end
function GetRealmName() return "TestRealm" end
function TitanGetVar(_, key) return settings[key] end
function TitanPanelButton_UpdateButton() end
function TitanPanelButton_OnShow() end
function TitanUtils_GetHighlightText(s) return s end
function TitanUtils_GetColoredText(s) return s end
RED_FONT_COLOR = {}
function CreateFrame(_, name)
    local frame = { events = {}, scripts = {} }
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetFrameStrata() end
    function frame:SetScript(event, handler) self.scripts[event] = handler end
    if name then _G[name] = frame; button = frame end
    return frame
end
C_Map = { GetBestMapForUnit = function() return map end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() end }
C_Timer = { After = function(_, fn) scheduled[#scheduled + 1] = fn end }
SlashCmdList = {}

local function guid(zone)
    return "Creature-0-4621-0-" .. zone .. "-5624-0008392ED7"
end
local function event(name, ...)
    assert(button.events[name], "event not registered: " .. name)
    button.scripts.OnEvent(button, name, ...)
end
local function layer()
    -- The plugin's text callback is the user-visible layer value.
    return select(2, button.registry.buttonTextFunction("Layer"))
end
local function contains(value)
    assert(layer():find(value, 1, true), "expected " .. value .. " in " .. layer())
end

TitanLayerDB = { layers = { [999] = clock }, realms = {
    TestRealm = { [10] = { [100] = clock, [200] = clock, [400] = clock - 7200 } },
} }
dofile("TitanLayer.lua")
assert(TitanLayerDB.layers[999], "saved variables were touched before ADDON_LOADED")
event("ADDON_LOADED", "TitanLayer")
button.scripts.OnShow(button)
assert(TitanLayerDB.layers == nil, "flat legacy sightings cannot be mapped")
assert(TitanLayerDB.realms.TestRealm[10][400] == nil, "expired sighting survived")
contains("?")

guids.target = guid(200)
event("PLAYER_TARGET_CHANGED")
contains("2")
assert(TitanLayerDB.realms.TestRealm[10][200] == clock, "sighting was not persisted")

map, guids.target = 11, nil
event("ZONE_CHANGED_NEW_AREA")
contains("?")
guids.nameplate1 = guid(300)
event("NAME_PLATE_UNIT_ADDED", "nameplate1")
contains("?")
assert(TitanLayerDB.realms.TestRealm[11] == nil, "nameplate invented a map's layer")
guids.target = guid(300)
event("PLAYER_TARGET_CHANGED")
contains("1")
guids.target = guid(100)
event("PLAYER_TARGET_CHANGED")
contains("1")
assert(not TitanLayerDB.realms.TestRealm[11][100], "other map's zone was accepted")

guids.target = secret
event("PLAYER_TARGET_CHANGED")
contains("1")

event("GROUP_JOINED")
contains("?")
guids.target = guid(300)
assert(#scheduled == 3)
scheduled[1]()
contains("1")

SlashCmdList.TITANLAYER("reset")
contains("?")
assert(next(TitanLayerDB.realms.TestRealm) == nil, "reset left saved sightings")
print("TitanLayer Forever port checks passed")
