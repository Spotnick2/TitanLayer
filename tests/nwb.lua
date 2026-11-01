-- The NovaWorldBuffs listener against hostile guild addon messages (audit, #1).
-- Run from the addon directory: lua tests/nwb.lua
-- The embedded libraries load in plain Lua 5.1; real framed messages go
-- through the registered CHAT_MSG_ADDON handler, like tests/port.lua. The
-- listener's state is read the way a player reads it: /titanlayer's
-- "N guildies tracked, M layers seen" line.

-- WoW's aliases the libraries and the addon use.
strmatch, strfind, strsub, strlen = string.match, string.find, string.sub, string.len
strbyte, strchar, strrep, strlower, strupper = string.byte, string.char, string.rep, string.lower, string.upper
format, tinsert, tremove = string.format, table.insert, table.remove
function strjoin(d, ...) return table.concat({ ... }, d) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
-- WoW's strsplit: `pieces` caps the count; the last piece keeps the rest.
function strsplit(delim, s, pieces)
    local out, pos = {}, 1
    while true do
        if pieces and #out == pieces - 1 then out[#out + 1] = s:sub(pos) break end
        local a, b = s:find(delim, pos, true)
        if not a then out[#out + 1] = s:sub(pos) break end
        out[#out + 1] = s:sub(pos, a - 1)
        pos = b + 1
    end
    return unpack(out)
end

local clock, now, map = 10000, 1000, 10
local guids, secret, button, scheduled, chat = {}, {}, nil, {}, {}
local settings = { ScanNameplates = false, AnnounceChannel = "PRINT", PreferNWB = false }
local realm = "TestRealm"
function issecretvalue(v) return v == secret end
function UnitGUID(unit) return guids[unit] end
function UnitName() return "Me" end
function UnitOnTaxi() return false end
function IsInInstance() return false end
function GetServerTime() return clock end
function GetTime() return now end
function GetRealmName() return realm end
function GetNormalizedRealmName() return realm end
function TitanGetVar(_, key) return settings[key] end
function TitanPanelButton_UpdateButton() end
function TitanPanelButton_OnShow() end
function TitanUtils_GetHighlightText(s) return s end
function TitanUtils_GetNormalText(s) return s end
function TitanUtils_GetColoredText(s) return s end
RED_FONT_COLOR = {}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    chat[#chat + 1] = table.concat(parts, " ")
end
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

dofile("Lib/LibStub/LibStub.lua")
dofile("Lib/LibDeflate/LibDeflate.lua")
dofile("Lib/LibSerialize/LibSerialize.lua")
dofile("Lib/AceSerializer-3.0.lua")
local LD, LS, AS = LibStub("LibDeflate"), LibStub("LibSerialize"), LibStub("AceSerializer-3.0")

TitanLayerDB = {}
dofile("TitanLayer.lua")
local function event(name, ...)
    assert(button.events[name], "event not registered: " .. name)
    button.scripts.OnEvent(button, name, ...)
end
event("ADDON_LOADED", "TitanLayer")
button.scripts.OnShow(button)
assert(button.events.CHAT_MSG_ADDON, "the listener is on (the libraries loaded)")

local checks, failed = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failed = failed + 1; io.stderr:write("FAIL: " .. what .. "\n") end
end

-- The listener's state as /titanlayer reports it: guildies tracked, layers seen.
local function status()
    chat = {}
    SlashCmdList.TITANLAYER("")
    for _, line in ipairs(chat) do
        local n, m = line:match("([%d%.%-]+) guildies tracked, ([%d%.%-]+) layers seen")
        if n then return tonumber(n), tonumber(m) end
    end
end
local function layers() return select(2, status()) end
-- What NWB sends: a string "<cmd> <version> <x>-<layer> <rest>", serialised,
-- deflated and encoded for the addon channel.
-- (One value each: the library's encoder also returns a length, which would
-- land in the next argument of a call like deliver(report(3)).)
local function encode(str) return (LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(str)))) end
local function report(layer, extra) return (encode("data 2.59 abc-" .. tostring(layer) .. " " .. (extra or "x"))) end
-- AceComm framing: one message when it fits (escaped when it would start with
-- a control byte), else \001 first, \002 middle, \003 last.
local function frames(enc, size)
    size = size or 254
    if #enc <= size + 1 then
        if enc:find("^[\001-\009]") then return { "\004" .. enc } end
        return { enc }
    end
    local out, pos = { "\001" .. enc:sub(1, size) }, size + 1
    while #enc - pos + 1 > size do
        out[#out + 1] = "\002" .. enc:sub(pos, pos + size - 1)
        pos = pos + size
    end
    out[#out + 1] = "\003" .. enc:sub(pos)
    return out
end
local function deliver(frame, dist, sender) event("CHAT_MSG_ADDON", "NWB", frame, dist or "GUILD", sender or "Guildie-TestRealm") end
local function send(enc, dist, sender, size) for _, f in ipairs(frames(enc, size)) do deliver(f, dist, sender) end end
-- A seeded generator (its own, so every platform tries the same inputs) and
-- content that doesn't compress, for messages of a chosen encoded size.
local seed = 20261031
local function rnd(k) seed = (seed * 48271) % 2147483647 return seed % k + 1 end
local function noise(k) local t = {} for i = 1, k do t[i] = string.char(rnd(256) - 1) end return table.concat(t) end

-- A report, through the event.
send(report(3))
local n, m = status()
check(n == 1 and m == 3, "a report: one guildie on layer 3 (" .. tostring(n) .. ", " .. tostring(m) .. ")")
send(report(5), nil, "Other-TestRealm")
n, m = status(); check(n == 2 and m == 5, "a second guildie: the highest layer seen")
send(report(0), nil, "Other-TestRealm")
n, m = status(); check(n == 1 and m == 3, "a 0 clears that guildie")
send(report(5), nil, "Other")
n, m = status(); check(n == 2 and m == 5, "a sender without a realm is the same guildie with one")
send(report(0), nil, "Other-TestRealm")
n, m = status(); check(n == 1 and m == 3, "(cleared by the realm-qualified name)")

-- Ignored: other channels, own messages, other prefixes, the AceSerializer
-- fallback accepted.
send(report(7), "RAID"); check(layers() == 3, "RAID ignored")
send(report(7), "WHISPER"); check(layers() == 3, "WHISPER ignored")
send(report(7), nil, "Me"); check(layers() == 3, "own name ignored")
send(report(7), nil, "Me-TestRealm"); check(layers() == 3, "own name-realm ignored")
event("CHAT_MSG_ADDON", "OTHER", report(7), "GUILD", "Guildie-TestRealm"); check(layers() == 3, "another prefix ignored")
send((LD:EncodeForWoWAddonChannel(LD:CompressDeflate(AS:Serialize("data 2.59 abc-4 x")))))
check(layers() == 4, "an AceSerializer-format report is read through the fallback")
send(encode({ "not", "a", "string" })); check(layers() == 4, "a serialised table is ignored")
send(encode("data 2.59")); check(layers() == 4, "a report with no third field is ignored")
send(encode("data 2.59 abc x")); check(layers() == 4, "a third field without a layer is ignored")

-- A multipart report assembles.
local long = report(2, noise(600))
check(#frames(long) >= 3, "the long report takes several frames")
send(long); n, m = status(); check(n == 1 and m == 2, "a multipart report assembles and updates")

-- The range: 51 and -1 refused, 50 accepted.
send(report(51)); check(layers() == 2, "51 refused")
send(report(-1)); check(layers() == 2, "-1 refused")
send(report(50)); check(layers() == 50, "50 accepted")
send(report(2)); check(layers() == 2, "(back to 2)")

-- T1: a layer that isn't an integer. A fraction is refused; a NaN (what
-- tonumber("nan") gives on a C99 runtime; the client's is unmeasured, so the
-- test plays that runtime) never reaches the tables, where it would throw as
-- a key after being stored, and poison every later message.
send(report("2.5")); m = layers(); check(m == 2, "a fractional layer is refused (layers seen " .. tostring(m) .. ")")
local realTonumber = tonumber
tonumber = function(v, ...) if v == "nan" then return 0 / 0 end return realTonumber(v, ...) end
local ok, err = pcall(send, report("nan"))
tonumber = realTonumber
check(ok, "a NaN layer doesn't throw (" .. tostring(err) .. ")")
ok, err = pcall(send, report(6))
check(ok, "the next report doesn't throw either (" .. tostring(err) .. ")")
n, m = status(); check(n == 1 and m == 6, "and it counts (" .. tostring(n) .. ", " .. tostring(m) .. ")")

-- T2 + T3: a budget of encoded bytes per message, on every frame kind, before
-- anything is decoded (LibDeflate has no output cap: what we retain and
-- inflate is bounded by what we accept).
local BUDGET = 4096
-- Reports of tunable encoded size.
local under, over
for k = 2800, 4600 do
    local e = report(9, noise(k))
    if #e <= BUDGET and (not under or #e > #under) then under = e end
    if #e > BUDGET and (not over or #e < #over) then over = e end
    if under and #under == BUDGET and over and #over == BUDGET + 1 then break end
end
check(under and over, "reports on both sides of the budget were made")
send(under); check(layers() == 9, "a report of " .. #under .. " encoded bytes (budget " .. BUDGET .. ") is accepted")
send(report(2)); check(layers() == 2, "(back to 2)")
send(over); check(layers() == 2, "a report of " .. #over .. " encoded bytes is refused as multipart")
deliver(over); check(layers() == 2, "a single frame over the budget is refused")
deliver("\004" .. over); check(layers() == 2, "an escaped frame over the budget is refused")
-- What was refused isn't retained: a sender who never finishes.
collectgarbage(); local before = collectgarbage("count")
deliver("\001" .. noise(254))
for _ = 1, 400 do deliver("\002" .. noise(254)) end   -- ~100 KB if kept
collectgarbage(); local grown = collectgarbage("count") - before
check(grown < 20, "an unfinished sender retains at most the budget (" .. math.floor(grown) .. " KB kept)")
deliver("\003" .. noise(10)); check(layers() == 2, "its last part assembles nothing")

-- A partial message older than 60 s is dropped at the next NWB message; a
-- fresh one still assembles.
send(report(0)); check(layers() == 0, "(cleared)")
local parts = frames(long)   -- layer 2, several frames
deliver(parts[1])
now = now + 61
send(report(8), nil, "Other-TestRealm")
for i = 2, #parts do deliver(parts[i]) end
n, m = status(); check(n == 1 and m == 8, "a stale partial message never assembles (" .. tostring(n) .. " tracked, " .. tostring(m) .. ")")
deliver(parts[1])
now = now + 30
send(report(8), nil, "Other-TestRealm")
for i = 2, #parts do deliver(parts[i]) end
n, m = status(); check(n == 2 and m == 8, "a fresh partial message still assembles (" .. tostring(n) .. " tracked)")
send(report(0), nil, "Other-TestRealm")

-- A small encoded message that inflates a lot is under the budget and must
-- decode without a throw: the budget bounds, it doesn't break legit traffic.
local inflating = report(7, string.rep("\0", 400000))
check(#inflating < BUDGET, "400 KB of zeros encode under the budget (" .. #inflating .. " bytes)")
ok, err = pcall(send, inflating)
check(ok, "it decodes without a throw (" .. tostring(err) .. ")")
check(layers() == 7, "and counts")

-- T4: a realm name that can't be read skips the message instead of throwing.
GetNormalizedRealmName = function() return nil end
ok, err = pcall(send, report(9))
GetNormalizedRealmName = function() return realm end
check(ok, "a nil realm name doesn't throw (" .. tostring(err) .. ")")
check(layers() == 7, "and the message is skipped")

-- Garbage: random bytes under random framing, from several senders. Never a
-- throw, and the state is untouched.
local throws = 0
for _ = 1, 300 do
    local control = ({ "", "\001", "\002", "\003", "\004", "\005", "\009" })[rnd(7)]
    if not pcall(deliver, control .. noise(rnd(300)), "GUILD", "G" .. rnd(5) .. "-TestRealm") then throws = throws + 1 end
end
check(throws == 0, "garbage never throws (" .. throws .. " of 300)")
n, m = status(); check(n == 1 and m == 7, "garbage changed nothing (" .. tostring(n) .. ", " .. tostring(m) .. ")")
-- A damaged report: raw deflate has no checksum, so a corrupted byte can still
-- yield a readable header with another layer. Never a throw, and what it
-- leaves is a layer like any other: an integer within the range.
for _ = 1, 100 do
    local r = report(rnd(60) - 5, noise(rnd(40)))
    local i = rnd(#r)
    if not pcall(send, r:sub(1, i - 1) .. string.char(rnd(256) - 1) .. r:sub(i + 1)) then throws = throws + 1 end
end
check(throws == 0, "a damaged report never throws (" .. throws .. " of 100)")
n, m = status()
check(n <= 1 and m % 1 == 0 and m >= 0 and m <= 50, "what a damaged report leaves is a layer like any other (" .. tostring(n) .. ", " .. tostring(m) .. ")")

io.stdout:write(string.format("TitanLayer NWB listener checks: %d passed, %d failed\n", checks - failed, failed))
os.exit(failed == 0 and 0 or 1)
