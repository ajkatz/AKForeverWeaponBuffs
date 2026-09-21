-- Comms: tell the party what is on our weapons, and remember what they told us.
--
-- The game does not let one player read another player's temporary weapon
-- enchants, so everyone running AKForeverWeaponBuffs broadcasts their own. That is how a
-- shaman sees who is actually receiving Windfury Totem (a "pulsed" enchant) and
-- whose own oil/stone/poison is blocking it.
--
-- Wire format (addon channel, prefix "WeaponBuffs", max 255 bytes):
--   U1^<entry>;<entry>...   state update; an empty list means "no weapon buffs"
--   R1                      request: everyone answers with a U1
-- entry = slot,type,enchantID,secondsLeft,iconID,flags,name
--   slot  M|O|R           type  I(mbue)|T(emporary)|<raw key>
--   flags bit 1 = self applied (sender knows its source), bit 2 = pulsed
local _, ns = ...

local Enchants, Sources = ns.Enchants, ns.Sources

local Comms = {}
ns.Comms = Comms

local PREFIX = "WeaponBuffs"
local MAX_MESSAGE = 250
local MAX_NAME = 28
local SEND_INTERVAL = 2      -- seconds between our own updates
local REQUEST_INTERVAL = 10
local RETRY_INTERVAL = 3

local FLAG_SELF, FLAG_PULSED = 1, 2

local SLOT_CODES = { MH = "M", OH = "O", RG = "R" }
local SLOT_KEYS = { M = "MH", O = "OH", R = "RG" }
local TYPE_CODES = { IMBUE = "I", TEMPORARY = "T" }
local TYPE_KEYS = { I = "IMBUE", T = "TEMPORARY" }

Comms.roster = {}   -- [full name] = { entries = {...}, at = GetTime() }
Comms.stats = { sent = 0, received = 0, failed = 0, lockedOut = 0, lastResult = nil }

local dirty = false
local lastSendAt = 0
local lastRequestAt = 0
local sendScheduled = false

------------------------------------------------------------------------
-- Encoding
------------------------------------------------------------------------
local function cleanName(name)
    if type(name) ~= "string" then
        return ""
    end
    name = string.gsub(name, "[,;%^|]", " ")
    if #name > MAX_NAME then
        -- cut, then drop a possibly split multi-byte character
        name = string.sub(name, 1, MAX_NAME)
        name = string.gsub(name, "[\192-\255][\128-\191]*$", "")
    end
    return name
end

function Comms.Encode(entries, withNames)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = table.concat({
            SLOT_CODES[entry.slotKey] or "M",
            TYPE_CODES[entry.typeKey] or entry.typeKey,
            tonumber(entry.enchantID) or 0,
            math.max(0, math.floor(entry.secondsLeft or 0)),
            tonumber(entry.iconID) or 0,
            tonumber(entry.flags) or 0,
            withNames and cleanName(entry.name) or "",
        }, ",")
    end
    return "U1^" .. table.concat(parts, ";")
end

function Comms.Decode(text, now)
    local version, payload = string.match(text, "^U(%d+)%^(.*)$")
    if version ~= "1" then
        return nil
    end
    local entries = {}
    for chunk in string.gmatch(payload, "[^;]+") do
        local slot, typeCode, enchantID, seconds, iconID, flags, name =
            string.match(chunk, "^(%a),([^,]+),(%d+),(%d+),(%d+),(%d+),(.*)$")
        local slotKey = slot and SLOT_KEYS[slot]
        if slotKey then
            flags = tonumber(flags) or 0
            seconds = tonumber(seconds) or 0
            iconID = tonumber(iconID) or 0
            entries[#entries + 1] = {
                slotKey = slotKey,
                typeKey = TYPE_KEYS[typeCode] or typeCode,
                enchantID = tonumber(enchantID) or 0,
                secondsLeft = seconds,
                expiresAt = now + seconds,
                iconID = iconID ~= 0 and iconID or nil,
                selfApplied = flags % 2 == 1,
                pulsed = math.floor(flags / 2) % 2 == 1,
                name = name ~= "" and name or nil,
            }
        end
    end
    return entries
end

local function ownEntries()
    local now = GetTime()
    local entries = {}
    for _, entry in pairs(Enchants.rows) do
        local flags = 0
        if Sources:GetForEnchant(entry.enchantID) then
            flags = flags + FLAG_SELF
        end
        if Sources:IsPulsed(entry.enchantID) then
            flags = flags + FLAG_PULSED
        end
        entries[#entries + 1] = {
            slotKey = entry.slotKey,
            typeKey = entry.typeKey,
            enchantID = entry.enchantID,
            secondsLeft = entry.expiresAt - now,
            iconID = entry.iconID,
            flags = flags,
            name = Sources:GetEnchantName(entry.enchantID),
        }
    end
    table.sort(entries, function(a, b)
        if a.slotKey ~= b.slotKey then
            return a.slotKey < b.slotKey
        end
        return a.typeKey < b.typeKey
    end)
    return entries
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------
function Comms:Channel()
    if not IsInGroup() then
        return nil
    end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    end
    return "PARTY" -- inside a raid this is our own subgroup: exactly totem range
end

local function inMessagingLockdown()
    local check = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not check then
        return false
    end
    local ok, locked = pcall(check)
    return ok and locked and true or false
end

-- true on success; false means "try again later"
local function transmit(text, channel, target)
    if inMessagingLockdown() then
        Comms.stats.lockedOut = Comms.stats.lockedOut + 1
        return false
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel, target)
    Comms.stats.lastResult = ok and tostring(result) or ("error: " .. tostring(result))
    -- Modern clients return Enum.SendAddonMessageResult (0 = Success), older ones a boolean.
    if ok and (result == nil or result == true or result == 0) then
        Comms.stats.sent = Comms.stats.sent + 1
        return true
    end
    Comms.stats.failed = Comms.stats.failed + 1
    ns:Log("comms_send_failed", Comms.stats.lastResult)
    return false
end

function Comms:Flush()
    sendScheduled = false
    local channel = self:Channel()
    if not channel then
        dirty = false
        return
    end
    local entries = ownEntries()
    local text = Comms.Encode(entries, true)
    if #text > MAX_MESSAGE then
        text = Comms.Encode(entries, false)
    end
    if transmit(text, channel) then
        dirty = false
        lastSendAt = GetTime()
    else
        dirty = true
    end
end

-- Coalesce bursts of changes into one message per SEND_INTERVAL.
function Comms:QueueUpdate()
    dirty = true
    if sendScheduled then
        return
    end
    sendScheduled = true
    local wait = math.max(0.2, SEND_INTERVAL - (GetTime() - lastSendAt))
    C_Timer.After(wait, function()
        ns.SafeCall(Comms.Flush, Comms)
    end)
end

function Comms:RequestStates()
    local channel = self:Channel()
    local now = GetTime()
    if not channel or now - lastRequestAt < REQUEST_INTERVAL then
        return
    end
    lastRequestAt = now
    transmit("R1", channel)
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local function normalizeSender(sender)
    if Ambiguate then
        return Ambiguate(sender, "none")
    end
    return sender
end

local function onAddonMessage(_, prefix, text, channel, sender)
    if ns.AnySecret(prefix, text, sender) or prefix ~= PREFIX then
        return
    end
    sender = normalizeSender(sender)
    Comms.stats.received = Comms.stats.received + 1
    local isSelf = sender == GetUnitName("player", true) or sender == UnitName("player")

    if text == "R1" then
        if not isSelf then
            C_Timer.After(0.2 + math.random() * 1.0, function()
                Comms:QueueUpdate()
            end)
        end
        return
    end

    local entries = Comms.Decode(text, GetTime())
    if not entries then
        return
    end
    if isSelf and channel ~= "WHISPER" then
        return -- our own broadcast echoed back
    end
    Comms.roster[sender] = { entries = entries, at = GetTime(), loopback = isSelf or nil }
    ns:Log("comms_update", { from = sender, n = #entries })
    ns:Fire("ROSTER_CHANGED")
end

-- Forget members who left; returns how many group members there are now.
local function pruneRoster()
    local present = {}
    local count = 0
    if IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                present[GetUnitName(unit, true)] = true
                count = count + 1
            end
        end
    end
    local changed = false
    for name, state in pairs(Comms.roster) do
        if not present[name] and not state.loopback then
            Comms.roster[name] = nil
            changed = true
        end
    end
    if changed then
        ns:Fire("ROSTER_CHANGED")
    end
    return count
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
local knownMembers = 0

ns:Listen("LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        ns:Log("comms_prefix", { ok = ok, result = tostring(result) })
    end
    ns:On("CHAT_MSG_ADDON", onAddonMessage)

    C_Timer.NewTicker(RETRY_INTERVAL, function()
        if dirty and not sendScheduled then
            ns.SafeCall(Comms.Flush, Comms)
        end
    end)
end)

ns:Listen("ENCHANTS_CHANGED", function()
    Comms:QueueUpdate()
end)

ns:Listen("ENCHANT_APPLIED", function(_, entry, info)
    -- A re-applied long buff changes its timer for everyone watching; totem
    -- pulses refresh every few seconds and are not worth a message each.
    if info.refresh and not Sources:IsPulsed(entry.enchantID) then
        Comms:QueueUpdate()
    end
end)

ns:Listen("SOURCES_CHANGED", function()
    Comms:QueueUpdate() -- names and flags may have improved
end)

ns:On("GROUP_ROSTER_UPDATE", function()
    local members = pruneRoster()
    if members > knownMembers then
        Comms:RequestStates()
        Comms:QueueUpdate()
    end
    knownMembers = members
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    knownMembers = pruneRoster()
    if knownMembers > 0 then
        Comms:RequestStates()
        Comms:QueueUpdate()
    end
end)

ns:Listen("COMBAT_END", function()
    if dirty then
        Comms:QueueUpdate()
    end
end)

ns:RegisterCommand("comms", "show party sharing status; '/wb comms test' whispers your own state to yourself", function(rest)
    if rest == "test" then
        local me = GetUnitName("player", true)
        local ok = transmit(Comms.Encode(ownEntries(), true), "WHISPER", me)
        ns:Print("loopback test sent:", ok and "ok" or "FAILED", "- result", tostring(Comms.stats.lastResult))
        return
    end
    local stats = Comms.stats
    ns:Print("channel", tostring(Comms:Channel()), "| sent", stats.sent, "| received", stats.received,
        "| failed", stats.failed, "| lockdown skips", stats.lockedOut, "| last result", tostring(stats.lastResult))
    for name, state in pairs(Comms.roster) do
        local names = {}
        for _, entry in ipairs(state.entries) do
            names[#names + 1] = entry.slotKey .. "=" .. (entry.name or ("#" .. entry.enchantID)) .. (entry.pulsed and "*" or "")
        end
        print("   " .. name .. ": " .. (#names > 0 and table.concat(names, ", ") or "no weapon buffs"))
    end
end)
