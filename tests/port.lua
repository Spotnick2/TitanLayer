-- WoW Forever: no layer detection since the 2026-11-20 server hotfix (NPC
-- GUIDs no longer tell the layer, GlassPanel #169). The button says "off",
-- nothing is read, saved or listened to, and old sightings are dropped.
-- Run from the addon directory: lua tests/port.lua
local guids, button, chat = {}, nil, {}
local settings = { ScanNameplates = true, AnnounceChannel = "PRINT", PreferNWB = true }
local prefixes = {}

function wipe(t) for k in pairs(t) do t[k] = nil end end
function strsplit(delim, s)
    local result = {}
    for field in (s .. delim):gmatch("(.-)" .. delim) do
        result[#result + 1] = field
    end
    return unpack(result)
end
function GetBuildInfo() return "1.60.1", "71037", "", 16001 end
function issecretvalue() return false end
-- Counted: on Forever no GUID is read at all (Codex on #8).
local reads = 0
function UnitGUID(unit) reads = reads + 1 return guids[unit] end
function UnitPlayerControlled() return false end
function UnitOnTaxi() return false end
function IsInInstance() return false end
function GetServerTime() return 10000 end
function GetTime() return 1000 end
function GetRealmName() return "" end            -- hidden since the hotfix
function GetNormalizedRealmName() return "" end
function UnitName() return "Zoruka", "Sumner" end
function TitanGetVar(_, key) return settings[key] end
function TitanPanelButton_UpdateButton() end
function TitanPanelButton_OnShow() end
function TitanPanelButton_OnClick() end
function TitanUtils_GetHighlightText(s) return s end
function TitanUtils_GetNormalText(s) return s end
function TitanUtils_GetGreenText(s) return s end
function TitanUtils_GetColoredText(s) return s end
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    chat[#chat + 1] = table.concat(parts, " ")
end
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
C_Map = { GetBestMapForUnit = function() return 1429 end }
C_ChatInfo = { RegisterAddonMessagePrefix = function(p) prefixes[p] = true end }
C_Timer = { After = function() end }
SlashCmdList = {}
-- What the listener would need, so its absence is the addon's choice.
local lib = {}
LibStub = function() return lib end

local function fire(name, ...) button.scripts.OnEvent(button, name, ...) end
local function text() return select(2, button.registry.buttonTextFunction("Layer")) end
local function said() return chat[#chat] or "" end

-- Saved sightings: nothing to keep.
TitanLayerDB = { v = 2, realms = { TestRealm = { [10] = { [6843] = 10000 } }, [""] = { [10] = { [5000] = 10000 } } } }
dofile("TitanLayer.lua")
fire("ADDON_LOADED", "TitanLayer")
assert(next(TitanLayerDB) == nil, "saved sightings dropped")

-- Nothing registered beyond the load events, not even the NWB prefix.
button.scripts.OnShow(button)
for event in pairs(button.events) do
    assert(event == "PLAYER_ENTERING_WORLD", "registered on Forever: " .. event)
end
assert(not prefixes.NWB, "the NWB prefix registered on Forever")

-- The button says off, and two NPCs that agree (as #3 read them) change nothing.
assert(text() == "off", "button: " .. tostring(text()))
guids.target = "Creature-0-6843-0-76001-5624-0000000001"
guids.mouseover = "Creature-0-6843-0-76002-5624-0000000002"
fire("PLAYER_TARGET_CHANGED"); fire("UPDATE_MOUSEOVER_UNIT"); fire("PLAYER_ENTERING_WORLD")
assert(text() == "off", "an NPC changed the button: " .. tostring(text()))
assert(next(TitanLayerDB) == nil, "an NPC was saved")
assert(reads == 0, "a GUID was read on Forever (" .. reads .. " reads)")

-- The tooltip, a click and the slash command explain why.
local tip = button.registry.tooltipTextFunction()
assert(tip:find("off on WoW Forever", 1, true) and tip:find("20 November 2026", 1, true), "tooltip: " .. tip)
assert(not tip:find("Target", 1, true), "the tooltip still asks for a target")
button.scripts.OnClick(button, "LeftButton")
assert(said():find("no longer", 1, true), "click: " .. said())
SlashCmdList.TITANLAYER("")
assert(said():find("no longer", 1, true), "slash: " .. said())
SlashCmdList.TITANLAYER("reset")
assert(said():find("no longer", 1, true), "slash reset: " .. said())
assert(button.registry.notes:find("20 November 2026", 1, true), "notes")

print = function(...) io.stdout:write(table.concat({ ... }, " "), "\n") end
print("TitanLayer Forever checks passed")
