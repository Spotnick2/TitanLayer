-- **************************************************************************
-- * TitanLayer.lua
-- *
-- * A lightweight Titan Panel plugin that displays your current server layer.
-- * Detects layers via NPC GUID parsing (same technique as NovaWorldBuffs).
-- * Can also read from NWB if it's loaded, for seamless transition.
-- **************************************************************************

-- ******************************** Constants *******************************
local TITAN_LAYER_ID = "Layer"
local TITAN_BUTTON = "TitanPanel" .. TITAN_LAYER_ID .. "Button"

local ADDON_NAME = "TitanLayer"
local VERSION = "1.1.0"

-- ******************************** Variables *******************************
local currentZoneID = 0
local currentMapID = nil
local knownLayers = {}       -- sightings on the player's current map
local sortedLayers = {}      -- sorted zoneIDs on that map
local realmMaps = {}         -- { [uiMapID] = { [zoneID] = lastSeen } }
local layerExpireTime = 7200 -- 2 hours, layers reset on server restarts

-- Companion/pet creature NPC IDs to ignore (common ones that travel with the player)
local ignoredCreatures = {}

-- ******************************** Utility *********************************

-- Secret values cannot be compared or converted by addon Lua.
local function Plain(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

local function LiveMap()
    local mapID = C_Map and C_Map.GetBestMapForUnit and Plain(C_Map.GetBestMapForUnit("player"))
    return type(mapID) == "number" and mapID or nil
end

local function ServerTime()
    local now = Plain(GetServerTime())
    return type(now) == "number" and now or nil
end

--- Sort the known layers table and rebuild the sorted index.
local function RebuildSortedLayers()
    wipe(sortedLayers)
    for zoneID in pairs(knownLayers) do
        table.insert(sortedLayers, zoneID)
    end
    table.sort(sortedLayers)
end

--- Get the layer number for a given zoneID.
---@param zoneID number
---@return number layerNum (0 if not found)
local function GetLayerNumForZoneID(zoneID)
    for i, id in ipairs(sortedLayers) do
        if id == zoneID then
            return i
        end
    end
    return 0
end

local function SelectMap(mapID)
    if mapID == currentMapID then return end
    currentMapID = mapID
    currentZoneID = 0
    knownLayers = mapID and realmMaps[mapID] or {}
    RebuildSortedLayers()
end

local function CurrentLayer()
    local mapID = LiveMap()
    if not mapID then return 0 end
    SelectMap(mapID)
    local now = ServerTime()
    if not now then return 0 end
    local changed = false
    for id, seen in pairs(knownLayers) do
        if now - seen >= layerExpireTime then
            knownLayers[id] = nil
            changed = true
        end
    end
    if changed then RebuildSortedLayers() end
    return GetLayerNumForZoneID(currentZoneID)
end

--- Try to read the layer from NovaWorldBuffs if it is loaded.
---@return number|nil layerNum from NWB, or nil if unavailable
local function GetNWBLayer()
    local layer = Plain(NWB_CurrentLayer)
    if type(layer) == "number" and layer > 0 then
        return layer
    end
    layer = NWB and Plain(NWB.currentLayer)
    if type(layer) == "number" and layer > 0 then
        return layer
    end
    return nil
end

--- Parse a unit's GUID and extract the zoneID (server instance ID).
--- Creature GUIDs look like: "Creature-0-SERVER-INSTANCE-ZONE-NPC-SPAWN"
---@param unit string
---@return number|nil zoneID
---@return boolean isCreature
local function GetZoneIDFromUnit(unit)
    local guid = Plain(UnitGUID(unit))
    if type(guid) ~= "string" then
        return nil, false
    end

    local unitType, _, _, _, zoneID, npcID = strsplit("-", guid)
    if unitType ~= "Creature" then
        return nil, false
    end

    local npcNum = tonumber(npcID)
    if npcNum and ignoredCreatures[npcNum] then
        return nil, false
    end

    return tonumber(zoneID), true
end

--- Process a unit to detect/update layer info.
---@param unit string
local function ProcessUnit(unit, confirmOnly)
    unit = Plain(unit)
    if type(unit) ~= "string" then return end
    if Plain(UnitOnTaxi("player")) == true or Plain(IsInInstance()) == true then
        return
    end

    local zoneID, isCreature = GetZoneIDFromUnit(unit)
    local mapID = LiveMap()
    local now = ServerTime()
    if not zoneID or not isCreature or not mapID or not now then
        return
    end

    SelectMap(mapID)
    local wasKnown = knownLayers[zoneID] and now - knownLayers[zoneID] < layerExpireTime
    if not wasKnown then
        -- Nameplates can belong to the map across a border. A target or
        -- mouseover can add a new ID unless another map already owns it.
        if confirmOnly then return end
        for otherMap, ids in pairs(realmMaps) do
            if otherMap ~= mapID and ids[zoneID] and now - ids[zoneID] < layerExpireTime then
                return
            end
        end
    end

    if not realmMaps[mapID] then
        realmMaps[mapID] = {}
        knownLayers = realmMaps[mapID]
    end
    knownLayers[zoneID] = now
    for id, seen in pairs(knownLayers) do
        if type(seen) ~= "number" or now - seen >= layerExpireTime then
            knownLayers[id] = nil
        end
    end
    RebuildSortedLayers()

    currentZoneID = zoneID
    -- Update the Titan button
    TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
    return true
end

local function RescanUnits()
    if ProcessUnit("target") or ProcessUnit("mouseover") then return end
    if TitanGetVar(TITAN_LAYER_ID, "ScanNameplates") then
        for i = 1, 40 do
            if ProcessUnit("nameplate" .. i, true) then return end
        end
    end
end

local function LoadSavedLayers()
    local db = type(TitanLayerDB) == "table" and TitanLayerDB or {}
    local saved = type(db.realms) == "table" and db.realms or {}
    local realm = Plain(GetRealmName())
    if type(realm) ~= "string" then realm = "?" end
    local now = ServerTime()
    local clean = {}
    local maps = type(saved[realm]) == "table" and saved[realm] or {}
    for mapID, ids in pairs(maps) do
        if type(mapID) == "number" and type(ids) == "table" then
            for zoneID, seen in pairs(ids) do
                if type(zoneID) == "number" and type(seen) == "number"
                    and (not now or now - seen < layerExpireTime) then
                    clean[mapID] = clean[mapID] or {}
                    clean[mapID][zoneID] = seen
                end
            end
        end
    end
    -- The old flat list has no realm or map, so it cannot be ranked safely.
    db.layers = nil
    saved[realm] = clean
    db.realms = saved
    TitanLayerDB = db
    realmMaps = clean
    currentMapID = nil
    SelectMap(LiveMap())
end

-- ******************************** NWB Passive Listener ********************
-- Eavesdrop on NovaWorldBuffs guild addon messages to learn total layer count
-- without needing NWB installed. NWB users broadcast their current layer via
-- the "NWB" addon prefix using LibSerialize + LibDeflate + AceComm framing.

local libDeflate = LibStub and LibStub("LibDeflate", true)
local libSerialize = LibStub and LibStub("LibSerialize", true)
local aceSerializer = LibStub and LibStub("AceSerializer-3.0", true)

local NWB_PREFIX = "NWB"
local nwbListenerReady = (libDeflate ~= nil and libSerialize ~= nil)

-- Track layer numbers reported by guild members
local nwbGuildLayers = {}     -- { [playerName] = layerNum }
local nwbMaxLayer = 0         -- highest layer number seen from NWB comms
local nwbLayerCounts = {}     -- { [layerNum] = count } how many guildies per layer

local function ResetLayers()
    wipe(realmMaps)
    currentMapID = nil
    SelectMap(LiveMap())
    wipe(nwbGuildLayers)
    wipe(nwbLayerCounts)
    nwbMaxLayer = 0
    TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
end

-- AceComm multi-part reassembly buffer
local multipartSpool = {}     -- { [key] = string or {string, string, ...} }

--- Reassemble AceComm multi-part messages.
--- AceComm framing: \001 = first, \002 = next, \003 = last, \004 = escape, no prefix = single.
---@param message string raw addon message
---@param distribution string
---@param sender string
---@return string|nil complete Complete message if ready, nil if still assembling
local function HandleAceCommFraming(message, distribution, sender)
    local control, rest = string.match(message, "^([\001-\009])(.*)")
    if not control then
        -- Single-part message, complete
        return message
    end

    local key = NWB_PREFIX .. "\t" .. distribution .. "\t" .. sender

    if control == "\001" then
        -- First part
        multipartSpool[key] = rest
        return nil
    elseif control == "\002" then
        -- Middle part
        local old = multipartSpool[key]
        if not old then return nil end
        if type(old) ~= "table" then
            multipartSpool[key] = { old, rest }
        else
            table.insert(old, rest)
        end
        return nil
    elseif control == "\003" then
        -- Last part
        local old = multipartSpool[key]
        multipartSpool[key] = nil
        if not old then return nil end
        if type(old) == "table" then
            table.insert(old, rest)
            return table.concat(old)
        else
            return old .. rest
        end
    elseif control == "\004" then
        -- Escape: strip control, rest is full message
        return rest
    end

    return nil
end

--- Decode an NWB addon message through the full pipeline.
---@param rawMessage string The AceComm-reassembled payload
---@return string|nil deserialized The original string NWB built, or nil on failure
local function DecodeNWBMessage(rawMessage)
    if not nwbListenerReady then return nil end

    -- Step 1: Decode from addon channel encoding
    local decoded = libDeflate:DecodeForWoWAddonChannel(rawMessage)
    if not decoded then return nil end

    -- Step 2: Decompress
    local decompressed = libDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil end

    -- Step 3: Deserialize (try LibSerialize first, fall back to AceSerializer)
    local success, deserialized = libSerialize:Deserialize(decompressed)
    if not success then
        if aceSerializer then
            success, deserialized = aceSerializer:Deserialize(decompressed)
        end
        if not success then return nil end
    end

    return deserialized
end

--- Simple string split with optional max count (mirrors NWB:explode).
---@param div string delimiter
---@param str string input
---@param count number|nil max splits
---@return table
local function Explode(div, str, count)
    if div == "" then return {} end
    local pos, arr = 0, {}
    local index = 0
    for st, sp in function() return string.find(str, div, pos, true) end do
        index = index + 1
        table.insert(arr, string.sub(str, pos, st - 1))
        pos = sp + 1
        if count and index == count then
            table.insert(arr, string.sub(str, pos))
            return arr
        end
    end
    table.insert(arr, string.sub(str, pos))
    return arr
end

--- Rebuild layer counts from guild layer data.
local function RebuildNWBLayerCounts()
    wipe(nwbLayerCounts)
    nwbMaxLayer = 0
    for _, layerNum in pairs(nwbGuildLayers) do
        nwbLayerCounts[layerNum] = (nwbLayerCounts[layerNum] or 0) + 1
        if layerNum > nwbMaxLayer then
            nwbMaxLayer = layerNum
        end
    end
end

--- Process a decoded NWB message and extract layer info.
---@param deserialized string
---@param sender string
local function ProcessNWBMessage(deserialized, sender)
    if type(deserialized) ~= "string" then return end

    local args = Explode(" ", deserialized, 4)
    if not args[3] then return end

    -- args[3] contains "<value>-<layerNum>" where layerNum is the sender's current layer
    local _, layerStr = strsplit("-", args[3], 2)
    if not layerStr then return end

    local layerNum = tonumber(layerStr)
    if not layerNum or layerNum < 0 or layerNum > 50 then return end

    -- Normalize sender name
    if not string.match(sender, "-") then
        sender = sender .. "-" .. GetNormalizedRealmName()
    end

    if layerNum == 0 then
        -- Player reported no layer (just entered, phase change, etc.)
        nwbGuildLayers[sender] = nil
    else
        nwbGuildLayers[sender] = layerNum
    end

    RebuildNWBLayerCounts()
    TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
end

--- Handle a raw CHAT_MSG_ADDON event for the NWB prefix.
---@param message string
---@param distribution string
---@param sender string
local function OnNWBAddonMessage(message, distribution, sender)
    if distribution ~= "GUILD" then return end

    -- Skip our own messages
    local me = UnitName("player")
    local meRealm = me .. "-" .. GetNormalizedRealmName()
    if sender == me or sender == meRealm then return end

    -- Reassemble AceComm framing
    local complete = HandleAceCommFraming(message, distribution, sender)
    if not complete then return end

    -- Decode through the NWB pipeline
    local deserialized = DecodeNWBMessage(complete)
    if not deserialized then return end

    -- Extract layer info
    ProcessNWBMessage(deserialized, sender)
end

-- ******************************** Titan Plugin Functions *******************

---Generate the plugin button text
---@param id string
---@return string label
---@return string value
local function GetButtonText(id)
    local layerNum = CurrentLayer()
    local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")

    if useNWB then
        local nwbLayer = GetNWBLayer()
        if nwbLayer then
            layerNum = nwbLayer
        end
    end

    local text
    if layerNum > 0 then
        local display = tostring(layerNum)
        -- Show "X/Y" if we know total layers from NWB comms
        if useNWB and GetNWBLayer() and nwbMaxLayer > 0 then
            display = display .. "/" .. nwbMaxLayer
        end
        text = TitanUtils_GetHighlightText(display)
    else
        if TitanGetVar(TITAN_LAYER_ID, "ShowColoredText") then
            text = TitanUtils_GetColoredText("?", RED_FONT_COLOR)
        else
            text = TitanUtils_GetHighlightText("?")
        end
    end

    return "Layer: ", text
end

---Generate tooltip text
---@return string
local function GetTooltipText()
    local text = ""

    -- Current layer
    local layerNum = CurrentLayer()
    local nwbLayer = GetNWBLayer()
    local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")

    if useNWB and nwbLayer then
        layerNum = nwbLayer
    end

    if layerNum > 0 then
        local layerDisplay = tostring(layerNum)
        if useNWB and nwbLayer and nwbMaxLayer > 0 then
            layerDisplay = layerDisplay .. " of " .. nwbMaxLayer
        end
        text = text .. TitanUtils_GetNormalText("Current Layer: ")
            .. TitanUtils_GetColoredText(layerDisplay, {r = 0, g = 1, b = 0})
    else
        text = text .. TitanUtils_GetNormalText("Current Layer: ")
            .. TitanUtils_GetColoredText("Unknown", {r = 1, g = 0.5, b = 0})
    end

    -- Zone ID info
    if TitanGetVar(TITAN_LAYER_ID, "ShowZoneID") and CurrentLayer() > 0 then
        text = text .. "\n" .. TitanUtils_GetNormalText("Zone ID: ")
            .. TitanUtils_GetHighlightText(tostring(currentZoneID))
    end

    -- NWB guild layer distribution (from passive listening)
    if nwbMaxLayer > 0 then
        local totalTracked = 0
        for _, _ in pairs(nwbGuildLayers) do
            totalTracked = totalTracked + 1
        end
        text = text .. "\n\n" .. TitanUtils_GetNormalText("Server Layers (via NWB guild comms):")
        for i = 1, nwbMaxLayer do
            local count = nwbLayerCounts[i] or 0
            local marker = ""
            if nwbLayer == i then
                marker = " |cff00ff00<-- You|r"
            end
            text = text .. "\n  " .. TitanUtils_GetHighlightText("Layer " .. i)
                .. "  |cff989898(" .. count .. " guildies)|r" .. marker
        end
        text = text .. "\n  |cff989898" .. totalTracked .. " guild members tracked|r"
    elseif #sortedLayers > 0 then
        -- Fallback: show our own GUID-detected layers
        text = text .. "\n\n" .. TitanUtils_GetNormalText("Known Layers On This Map:")
        for i, zoneID in ipairs(sortedLayers) do
            local marker = ""
            if zoneID == currentZoneID then
                marker = " |cff00ff00<-- You|r"
            end
            text = text .. "\n  " .. TitanUtils_GetHighlightText("Layer " .. i)
                .. "  |cff989898(" .. zoneID .. ")|r" .. marker
        end
    end

    -- NWB installed status
    if nwbLayer then
        text = text .. "\n\n|cff989898NWB addon reports: Layer " .. nwbLayer .. "|r"
    end

    -- Listener status
    if nwbListenerReady then
        text = text .. "\n|cff989898NWB listener: |cff00ff00active|r"
    else
        text = text .. "\n|cff989898NWB listener: |cffff6666unavailable (missing libs)|r"
    end

    -- Hint
    text = text .. "\n\n" .. TitanUtils_GetGreenText("Target any NPC to detect your layer.")
    text = text .. "\n|cff989898GUID layer numbers are local to your sightings on this map.|r"
    text = text .. "\n" .. TitanUtils_GetGreenText("Left-click to announce layer in chat.")

    return text
end

---Handle registered events
---@param self Button
---@param event string
---@param ... any
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        LoadSavedLayers()
        self:UnregisterEvent("ADDON_LOADED")
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED"
        or event == "PLAYER_CONTROL_GAINED" then
        RescanUnits()
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "PLAYER_TARGET_CHANGED" then
        ProcessUnit("target")

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ProcessUnit("mouseover")

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unitID = ...
        ProcessUnit(unitID, true)

    elseif event == "GROUP_JOINED" or event == "GROUP_LEFT" then
        -- The layer hop can occur after the group event.
        currentZoneID = 0
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
        for _, delay in ipairs({ 5, 15, 30 }) do
            C_Timer.After(delay, function()
                currentZoneID = 0
                RescanUnits()
                TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
            end)
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        currentZoneID = 0
        SelectMap(LiveMap())
        RescanUnits()
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        if LiveMap() ~= currentMapID then
            SelectMap(LiveMap())
            RescanUnits()
            TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
        end

    elseif event == "UNIT_PHASE" then
        local unit = ...
        if Plain(unit) == "player" then
            currentZoneID = 0
            TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        if prefix == NWB_PREFIX and nwbListenerReady then
            OnNWBAddonMessage(message, distribution, sender)
        end
    end
end

---Left-click: announce layer in chat
---@param self Button
---@param button string
local function OnClick(self, button)
    if button == "LeftButton" then
        local layerNum = CurrentLayer()
        local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")
        if useNWB then
            local nwbLayer = GetNWBLayer()
            if nwbLayer then
                layerNum = nwbLayer
            end
        end

        if layerNum > 0 then
            local msg = "Currently on Layer " .. layerNum
            if CurrentLayer() > 0 and TitanGetVar(TITAN_LAYER_ID, "ShowZoneID") then
                msg = msg .. " (ID: " .. currentZoneID .. ")"
            end

            local chatType = TitanGetVar(TITAN_LAYER_ID, "AnnounceChannel") or "SAY"
            if chatType == "PRINT" then
                print("|cff33ff99TitanLayer:|r " .. msg)
            elseif chatType == "PARTY" then
                if IsInGroup() then
                    SendChatMessage(msg, "PARTY")
                else
                    print("|cff33ff99TitanLayer:|r " .. msg .. " (not in a group)")
                end
            elseif chatType == "GUILD" then
                if IsInGuild() then
                    SendChatMessage(msg, "GUILD")
                else
                    print("|cff33ff99TitanLayer:|r " .. msg .. " (not in a guild)")
                end
            else
                SendChatMessage(msg, "SAY")
            end
        else
            print("|cff33ff99TitanLayer:|r Layer not yet detected. Target any NPC!")
        end
    end
end

---Generate right-click menu
local function PrepareMenu()
    local info
    local level = TitanPanelRightClickMenu_GetDropdownLevel()

    if level == 1 then
        TitanPanelRightClickMenu_AddTitle(TitanPlugins[TITAN_LAYER_ID].menuText)

        -- Announce channel submenu
        TitanPanelRightClickMenu_AddSpacer()
        TitanPanelRightClickMenu_AddTitle("Left-Click Announce:")

        local channels = {
            { text = "Local Print (self only)", value = "PRINT" },
            { text = "Say",                    value = "SAY" },
            { text = "Party",                  value = "PARTY" },
            { text = "Guild",                  value = "GUILD" },
        }
        for _, ch in ipairs(channels) do
            info = {}
            info.text = ch.text
            info.func = function()
                TitanSetVar(TITAN_LAYER_ID, "AnnounceChannel", ch.value)
            end
            info.checked = (TitanGetVar(TITAN_LAYER_ID, "AnnounceChannel") == ch.value)
            info.keepShownOnClick = 1
            TitanPanelRightClickMenu_AddButton(info, level)
        end

        TitanPanelRightClickMenu_AddSpacer()

        -- Show zone ID option
        info = {}
        info.text = "Show Zone ID in Tooltip"
        info.func = function()
            TitanToggleVar(TITAN_LAYER_ID, "ShowZoneID")
        end
        info.checked = TitanGetVar(TITAN_LAYER_ID, "ShowZoneID")
        info.keepShownOnClick = 1
        TitanPanelRightClickMenu_AddButton(info, level)

        -- Prefer NWB option
        info = {}
        info.text = "Prefer NovaWorldBuffs Data"
        info.func = function()
            TitanToggleVar(TITAN_LAYER_ID, "PreferNWB")
            TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
        end
        info.checked = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")
        info.keepShownOnClick = 1
        TitanPanelRightClickMenu_AddButton(info, level)

        -- Nameplate scanning
        info = {}
        info.text = "Scan Nameplates (passive detection)"
        info.func = function()
            TitanToggleVar(TITAN_LAYER_ID, "ScanNameplates")
            local btn = _G[TITAN_BUTTON]
            if btn then
                if TitanGetVar(TITAN_LAYER_ID, "ScanNameplates") then
                    btn:RegisterEvent("NAME_PLATE_UNIT_ADDED")
                else
                    btn:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
                end
            end
        end
        info.checked = TitanGetVar(TITAN_LAYER_ID, "ScanNameplates")
        info.keepShownOnClick = 1
        TitanPanelRightClickMenu_AddButton(info, level)

        TitanPanelRightClickMenu_AddSpacer()

        -- Reset layer data
        info = {}
        info.text = "|cffff6666Reset Layer Data|r"
        info.func = function()
            ResetLayers()
            print("|cff33ff99TitanLayer:|r This realm's layer data has been reset.")
        end
        info.notCheckable = true
        TitanPanelRightClickMenu_AddButton(info, level)

        TitanPanelRightClickMenu_AddSpacer()
        TitanPanelRightClickMenu_AddControlVars(TITAN_LAYER_ID)
    end
end

---Register the plugin
---@param self Button
local function OnLoad(self)
    self.registry = {
        id = TITAN_LAYER_ID,
        category = "Information",
        version = VERSION,
        menuText = "Layer",
        menuTextFunction = PrepareMenu,
        buttonTextFunction = GetButtonText,
        tooltipTitle = "Server Layer",
        tooltipTextFunction = GetTooltipText,
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        iconWidth = 16,
        notes = "Displays your current server layer on Titan Panel.\n"
            .. "- Detects layers from target and mouseover NPC GUIDs; nameplates confirm known IDs.\n"
            .. "- Passively listens to NovaWorldBuffs guild comms for total layer count.\n"
            .. "- Shows Layer X/Y when using NWB's layer number and guild data is available.\n"
            .. "- Left-click to announce your current layer in chat.\n"
            .. "- Right-click to configure announce channel and display options.\n"
            .. "- Layer sightings are scoped to your realm and map, and expire after 2 hours.\n"
            .. "- Use /titanlayer or /tlayer to print current layer info.\n"
            .. "- Use /titanlayer reset to clear this realm's stored layer data.",
        controlVariables = {
            ShowIcon = true,
            ShowLabelText = true,
            ShowColoredText = true,
            DisplayOnRightSide = true,
        },
        savedVariables = {
            ShowIcon = 1,
            ShowLabelText = 1,
            ShowColoredText = 1,
            DisplayOnRightSide = false,
            ShowZoneID = false,
            PreferNWB = false,
            ScanNameplates = true,
            AnnounceChannel = "PRINT",
        },
    }

    -- Register NWB addon message prefix for passive listening
    if nwbListenerReady then
        C_ChatInfo.RegisterAddonMessagePrefix(NWB_PREFIX)
    end

    self:RegisterEvent("ADDON_LOADED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
end

---Show handler
---@param self Button
local function OnShow(self)
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:RegisterEvent("GROUP_JOINED")
    self:RegisterEvent("GROUP_LEFT")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("ZONE_CHANGED")
    self:RegisterEvent("ZONE_CHANGED_INDOORS")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_CONTROL_GAINED")
    self:RegisterEvent("UNIT_PHASE")

    if nwbListenerReady then
        self:RegisterEvent("CHAT_MSG_ADDON")
    end

    if TitanGetVar(TITAN_LAYER_ID, "ScanNameplates") then
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    end

    TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
end

---Hide handler
---@param self Button
local function OnHide(self)
    self:UnregisterEvent("PLAYER_TARGET_CHANGED")
    self:UnregisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:UnregisterEvent("GROUP_JOINED")
    self:UnregisterEvent("GROUP_LEFT")
    self:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    self:UnregisterEvent("ZONE_CHANGED")
    self:UnregisterEvent("ZONE_CHANGED_INDOORS")
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    self:UnregisterEvent("PLAYER_CONTROL_GAINED")
    self:UnregisterEvent("UNIT_PHASE")
    self:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    self:UnregisterEvent("CHAT_MSG_ADDON")
end

-- ******************************** Frame Creation ***************************

local function Create_Frames()
    if _G[TITAN_BUTTON] then
        return
    end

    local container = CreateFrame("Frame", nil, UIParent)

    local window = CreateFrame("Button", TITAN_BUTTON, container, "TitanPanelComboTemplate")
    window:SetFrameStrata("FULLSCREEN")
    OnLoad(window)

    window:SetScript("OnShow", function(self)
        OnShow(self)
        TitanPanelButton_OnShow(self)
    end)
    window:SetScript("OnHide", function(self)
        OnHide(self)
    end)
    window:SetScript("OnEvent", function(self, event, ...)
        OnEvent(self, event, ...)
    end)
    window:SetScript("OnClick", function(self, button)
        OnClick(self, button)
        TitanPanelButton_OnClick(self, button)
    end)
end

Create_Frames()

-- ******************************** Slash Command ****************************
SLASH_TITANLAYER1 = "/titanlayer"
SLASH_TITANLAYER2 = "/tlayer"
SlashCmdList["TITANLAYER"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        ResetLayers()
        print("|cff33ff99TitanLayer:|r This realm's layer data has been reset.")
    else
        local layerNum = CurrentLayer()
        if layerNum > 0 then
            local display = "Layer " .. layerNum
            if TitanGetVar(TITAN_LAYER_ID, "PreferNWB") and GetNWBLayer() and nwbMaxLayer > 0 then
                display = display .. " of " .. nwbMaxLayer
            end
            print("|cff33ff99TitanLayer:|r You are on " .. display
                .. (currentZoneID > 0 and (" (Zone ID: " .. currentZoneID .. ")") or ""))
        else
            print("|cff33ff99TitanLayer:|r Layer not yet detected. Target any NPC!")
        end
        print("|cff33ff99TitanLayer:|r GUID-detected layers on this map: " .. #sortedLayers)
        if nwbListenerReady then
            local tracked = 0
            for _ in pairs(nwbGuildLayers) do tracked = tracked + 1 end
            print("|cff33ff99TitanLayer:|r NWB listener: active, " .. tracked .. " guildies tracked, " .. nwbMaxLayer .. " layers seen")
        else
            print("|cff33ff99TitanLayer:|r NWB listener: unavailable (missing libs)")
        end
        print("|cff33ff99TitanLayer:|r Use /titanlayer reset to clear layer data.")
    end
end
