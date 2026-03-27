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
local VERSION = "1.0.0"

-- ******************************** Variables *******************************
local currentLayerNum = 0
local currentZoneID = 0
local knownLayers = {}       -- { [zoneID] = true } for the current session
local sortedLayers = {}      -- sorted list of known zoneIDs for consistent numbering
local lastJoinedGroup = 0
local lastZoneChange = 0
local layerExpireTime = 7200 -- 2 hours, layers reset on server restarts

-- Companion/pet creature NPC IDs to ignore (common ones that travel with the player)
local ignoredCreatures = {}

-- ******************************** Utility *********************************

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

--- Try to read the layer from NovaWorldBuffs if it is loaded.
---@return number|nil layerNum from NWB, or nil if unavailable
local function GetNWBLayer()
    if NWB_CurrentLayer and NWB_CurrentLayer > 0 then
        return NWB_CurrentLayer
    end
    if NWB and NWB.currentLayer and NWB.currentLayer > 0 then
        return NWB.currentLayer
    end
    return nil
end

--- Parse a unit's GUID and extract the zoneID (server instance ID).
--- Creature GUIDs look like: "Creature-0-ZONEID-0-0-NPCID-SPAWNUID"
---@param unit string
---@return number|nil zoneID
---@return boolean isCreature
local function GetZoneIDFromUnit(unit)
    local guid = UnitGUID(unit)
    if not guid then
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
local function ProcessUnit(unit)
    if UnitOnTaxi("player") or IsInInstance() then
        return
    end

    local zoneID, isCreature = GetZoneIDFromUnit(unit)
    if not zoneID or not isCreature then
        return
    end

    -- Register this zoneID if we haven't seen it
    if not knownLayers[zoneID] then
        knownLayers[zoneID] = GetServerTime()
        RebuildSortedLayers()

        -- Persist to saved variables
        if TitanLayerDB and TitanLayerDB.layers then
            TitanLayerDB.layers[zoneID] = GetServerTime()
        end
    end

    currentZoneID = zoneID
    currentLayerNum = GetLayerNumForZoneID(zoneID)

    -- Update the Titan button
    TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
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
    local layerNum = 0
    local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")

    -- Try NWB first if user wants it
    if useNWB then
        local nwbLayer = GetNWBLayer()
        if nwbLayer then
            layerNum = nwbLayer
        else
            layerNum = currentLayerNum
        end
    else
        layerNum = currentLayerNum
    end

    local text
    if layerNum > 0 then
        local display = tostring(layerNum)
        -- Show "X/Y" if we know total layers from NWB comms
        if nwbMaxLayer > 0 then
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
    local layerNum = currentLayerNum
    local nwbLayer = GetNWBLayer()
    local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")

    if useNWB and nwbLayer then
        layerNum = nwbLayer
    end

    if layerNum > 0 then
        local layerDisplay = tostring(layerNum)
        if nwbMaxLayer > 0 then
            layerDisplay = layerDisplay .. " of " .. nwbMaxLayer
        end
        text = text .. TitanUtils_GetNormalText("Current Layer: ")
            .. TitanUtils_GetColoredText(layerDisplay, {r = 0, g = 1, b = 0})
    else
        text = text .. TitanUtils_GetNormalText("Current Layer: ")
            .. TitanUtils_GetColoredText("Unknown", {r = 1, g = 0.5, b = 0})
    end

    -- Zone ID info
    if TitanGetVar(TITAN_LAYER_ID, "ShowZoneID") and currentZoneID > 0 then
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
            if layerNum == i then
                marker = " |cff00ff00<-- You|r"
            end
            text = text .. "\n  " .. TitanUtils_GetHighlightText("Layer " .. i)
                .. "  |cff989898(" .. count .. " guildies)|r" .. marker
        end
        text = text .. "\n  |cff989898" .. totalTracked .. " guild members tracked|r"
    elseif #sortedLayers > 0 then
        -- Fallback: show our own GUID-detected layers
        text = text .. "\n\n" .. TitanUtils_GetNormalText("Known Layers This Session:")
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
    text = text .. "\n" .. TitanUtils_GetGreenText("Left-click to announce layer in chat.")

    return text
end

---Handle registered events
---@param self Button
---@param event string
---@param ... any
local function OnEvent(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        lastZoneChange = GetServerTime()
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "PLAYER_TARGET_CHANGED" then
        ProcessUnit("target")

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ProcessUnit("mouseover")

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unitID = ...
        if unitID then
            ProcessUnit(unitID)
        end

    elseif event == "GROUP_JOINED" or event == "GROUP_LEFT" then
        lastJoinedGroup = GetServerTime()
        -- Reset current layer on group change (may have changed layer)
        currentLayerNum = 0
        currentZoneID = 0
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        lastZoneChange = GetServerTime()
        -- Don't reset layer, it may still be valid, but trigger an update
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)

    elseif event == "UNIT_PHASE" then
        local unit = ...
        if UnitIsGroupLeader(unit) then
            currentLayerNum = 0
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
        local layerNum = currentLayerNum
        local useNWB = TitanGetVar(TITAN_LAYER_ID, "PreferNWB")
        if useNWB then
            local nwbLayer = GetNWBLayer()
            if nwbLayer then
                layerNum = nwbLayer
            end
        end

        if layerNum > 0 then
            local msg = "Currently on Layer " .. layerNum
            if currentZoneID > 0 and TitanGetVar(TITAN_LAYER_ID, "ShowZoneID") then
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
            wipe(knownLayers)
            wipe(sortedLayers)
            wipe(nwbGuildLayers)
            wipe(nwbLayerCounts)
            nwbMaxLayer = 0
            currentLayerNum = 0
            currentZoneID = 0
            if TitanLayerDB then
                wipe(TitanLayerDB.layers)
            end
            TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
            print("|cff33ff99TitanLayer:|r All layer data has been reset.")
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
            .. "- Detects layers automatically via NPC GUIDs (target, mouseover, nameplates).\n"
            .. "- Passively listens to NovaWorldBuffs guild comms for total layer count.\n"
            .. "- Shows Layer X/Y on bar when guild layer data is available.\n"
            .. "- Left-click to announce your current layer in chat.\n"
            .. "- Right-click to configure announce channel and display options.\n"
            .. "- Layer data persists across reloads and expires after 2 hours.\n"
            .. "- Use /titanlayer or /tlayer to print current layer info.\n"
            .. "- Use /titanlayer reset to clear all stored layer data.",
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

    -- Initialize saved variables
    if not TitanLayerDB then
        TitanLayerDB = { layers = {} }
    end
    if not TitanLayerDB.layers then
        TitanLayerDB.layers = {}
    end

    -- Load persisted layers (prune expired ones)
    local now = GetServerTime()
    for zoneID, timestamp in pairs(TitanLayerDB.layers) do
        if (now - timestamp) < layerExpireTime then
            knownLayers[zoneID] = timestamp
        else
            TitanLayerDB.layers[zoneID] = nil
        end
    end
    RebuildSortedLayers()

    -- Register NWB addon message prefix for passive listening
    if nwbListenerReady then
        C_ChatInfo.RegisterAddonMessagePrefix(NWB_PREFIX)
    end

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
        wipe(knownLayers)
        wipe(sortedLayers)
        wipe(nwbGuildLayers)
        wipe(nwbLayerCounts)
        nwbMaxLayer = 0
        currentLayerNum = 0
        currentZoneID = 0
        if TitanLayerDB then
            wipe(TitanLayerDB.layers)
        end
        TitanPanelButton_UpdateButton(TITAN_LAYER_ID)
        print("|cff33ff99TitanLayer:|r All layer data has been reset.")
    else
        local layerNum = currentLayerNum
        if layerNum > 0 then
            local display = "Layer " .. layerNum
            if nwbMaxLayer > 0 then
                display = display .. " of " .. nwbMaxLayer
            end
            print("|cff33ff99TitanLayer:|r You are on " .. display
                .. (currentZoneID > 0 and (" (Zone ID: " .. currentZoneID .. ")") or ""))
        else
            print("|cff33ff99TitanLayer:|r Layer not yet detected. Target any NPC!")
        end
        print("|cff33ff99TitanLayer:|r GUID-detected layers: " .. #sortedLayers)
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
