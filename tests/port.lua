-- WoW Forever layer detection (#3): the GUID's server field, votes, SHARD_TRANSFER.
-- Run from the addon directory: lua tests/port.lua
local clock, now, map = 10000, 1000, 10
local guids = {}
local controlled = {}
local secret = {}
local button
local scheduled = {}
local settings = { ScanNameplates = true, AnnounceChannel = "PRINT" }
-- uiMapID -> { mapType, parentMapID } (absent: GetMapInfo returns nil)
local mapInfo = {}

function wipe(t) for k in pairs(t) do t[k] = nil end end
function strsplit(delim, s)
    local result = {}
    for field in (s .. delim):gmatch("(.-)" .. delim) do
        result[#result + 1] = field
    end
    return unpack(result)
end
function GetBuildInfo() return "1.60.1", "70938", "", 16001 end
function issecretvalue(v) return v == secret end
function UnitGUID(unit) return guids[unit] end
function UnitPlayerControlled(unit) return controlled[unit] == true end
function UnitOnTaxi() return false end
function IsInInstance() return false end
function GetServerTime() return clock end
function GetTime() return now end
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
-- C_Map.GetMapInfo(uiMapID) -> UiMapDetails { mapID, name, mapType, parentMapID, flags } (70938 dump).
C_Map = {
    GetBestMapForUnit = function() return map end,
    GetMapInfo = function(id)
        local i = mapInfo[id]
        return i and { mapID = id, name = "map", mapType = i[1], parentMapID = i[2], flags = 0 } or nil
    end,
}
C_ChatInfo = { RegisterAddonMessagePrefix = function() end }
C_Timer = { After = function(delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end }
SlashCmdList = {}

-- A new creature on a layer, with its own spawn and its own zone field
-- (which says nothing about the layer on Forever).
local spawn = 0
local function npc(layer, kind)
    spawn = spawn + 1
    return string.format("%s-0-%d-0-%d-5624-%010X", kind or "Creature", layer, 76000 + spawn, spawn)
end
local function event(name, ...)
    assert(button.events[name], "event not registered: " .. name)
    button.scripts.OnEvent(button, name, ...)
end
local function layer()
    -- The plugin's text callback is the user-visible layer value.
    return select(2, button.registry.buttonTextFunction("Layer"))
end
local function is(value, what)
    assert(layer() == value, what .. ": expected " .. value .. ", got " .. layer())
end
local function target(guid) guids.target = guid; event("PLAYER_TARGET_CHANGED") end
local function plate(i, guid) guids["nameplate" .. i] = guid; event("NAME_PLATE_UNIT_ADDED", "nameplate" .. i) end
local function saved() return TitanLayerDB.realms.TestRealm end

-- Sightings saved before #3 hold zone ids: dropped once.
TitanLayerDB = { layers = { [999] = clock }, realms = {
    TestRealm = { [10] = { [76067] = clock } },
} }
dofile("TitanLayer.lua")
event("ADDON_LOADED", "TitanLayer")
button.scripts.OnShow(button)
assert(TitanLayerDB.v == 2, "format stamped")
assert(TitanLayerDB.layers == nil, "flat legacy sightings dropped")
assert(next(saved()) == nil, "zone-id sightings dropped")
assert(button.events.SHARD_TRANSFER, "SHARD_TRANSFER registered")
assert(not button.events.GROUP_JOINED and not button.events.GROUP_LEFT, "a group change resets nothing")
is("?", "unknown at first")

-- One creature isn't proof; a second that agrees is.
saved()[10] = { [5000] = clock }
map = 11; event("ZONE_CHANGED_NEW_AREA")
map = 10; event("ZONE_CHANGED_NEW_AREA")   -- back in zone 10: its saved sighting is read
target(npc(6843))
is("?", "one creature")
event("PLAYER_TARGET_CHANGED")
is("?", "the same creature doesn't vote twice")
plate(1, npc(6843))
is("2", "two agree (5000 < 6843)")
assert(saved()[10][6843] == clock, "sighting saved")

-- Changing a known layer takes 3 of the last 5.
plate(2, npc(4500))
plate(3, npc(4500))
is("2", "two for another layer: kept")
plate(4, npc(4500))
is("1", "three of five: changed")

-- The same creature seen again keeps the layer fresh (a layer seen all along never expires).
local seenAgain = guids.nameplate4
clock = clock + 7000
plate(4, seenAgain)
assert(saved()[10][4500] == clock, "a creature that already voted refreshes the sighting")
clock = clock + 300
is("1", "still known 2 h after the first sighting")

-- Totems and guardians don't vote; vehicles do.
event("UNIT_PHASE", "player")
is("?", "own phase change: unknown")
controlled.target = true
target(npc(4500))
plate(5, npc(4500))
is("?", "a player-controlled creature doesn't vote")
controlled.target = nil
target(npc(4500, "Vehicle"))
is("1", "a vehicle votes")
guids.target = secret
event("PLAYER_TARGET_CHANGED")
is("1", "a secret GUID changes nothing")

-- SHARD_TRANSFER: the game moved us. Creatures that voted before, even with
-- no unit token at the move, and those in view don't vote for 10 s.
local old1, old2 = npc(4500), npc(4500)
plate(6, old1); plate(7, old2)
guids = { target = npc(4500) }
scheduled = {}
event("SHARD_TRANSFER")
is("?", "moved: unknown")
assert(#scheduled == 3, "three looks scheduled")
now = now + 1
plate(6, old1); plate(7, old2)
event("PLAYER_TARGET_CHANGED")
is("?", "old creatures back within 10 s: no vote")
plate(8, npc(7000)); plate(9, npc(7000))
is("2", "two creatures of the new layer (4500 < 7000; 5000 and 6843 expired)")
-- After 10 s the units in view vote again: the last look reads them.
event("UNIT_PHASE", "player")
now = now + 11
for _, s in ipairs(scheduled) do if s.delay > 10 then s.fn() end end
is("1", "the last look: three old creatures outvote two")

-- Layers are a zone's: a building's map inside the zone keeps the layer.
mapInfo = { [10] = { 3, 1 }, [1] = { 2, 0 }, [21] = { 5, 20 }, [20] = { 4, 10 } }
map = 21
event("ZONE_CHANGED_INDOORS")
is("1", "a micro map inside the zone: kept")
plate(10, npc(4500))
assert(saved()[21] == nil, "filed under the zone, not the building")

-- Another zone: unknown; votes cast in one zone don't count in the next.
map = 11
guids = {}
event("ZONE_CHANGED_NEW_AREA")
is("?", "new zone: unknown")
target(npc(4500))
map = 12
plate(1, npc(4500))
is("?", "one vote per zone")
plate(2, npc(4500))
is("1", "two in this zone")

-- Codex review on #4: back on a map after one where nothing was read, its
-- creatures vote again.
guids = {}
event("ZONE_CHANGED_NEW_AREA")
local a1, a2 = npc(4600), npc(4600)
plate(3, a1); plate(4, a2)
local here = layer()
assert(here ~= "?", "baseline: known on map 12")
map, guids = 13, {}
event("ZONE_CHANGED_INDOORS")
is("?", "another map, nothing to read")
map, guids = 12, { nameplate3 = a1, nameplate4 = a2 }
event("ZONE_CHANGED_INDOORS")
is(here, "back on map 12: the same creatures vote again")

-- ...and a second move keeps the first move's creatures out until their own
-- 10 s are up, even when they're out of view at the second one.
guids = {}
event("ZONE_CHANGED_NEW_AREA")
local o1, o2 = npc(4700), npc(4700)
plate(5, o1); plate(6, o2)
assert(layer() ~= "?", "baseline: known")
guids, scheduled = {}, {}
event("SHARD_TRANSFER")
now = now + 3
event("SHARD_TRANSFER")
now = now + 1
plate(5, o1); plate(6, o2)
is("?", "4 s after the first move: its creatures still don't vote")
now = now + 7
plate(5, o1); plate(6, o2)
assert(layer() ~= "?", "11 s after the first move: they vote again")
guids, scheduled = {}, {}

SlashCmdList.TITANLAYER("reset")
is("?", "reset: unknown")
assert(next(saved()) == nil, "reset left saved sightings")
print("TitanLayer Forever checks passed")
