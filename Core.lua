-- AKForeverWeaponBuffs core: namespace, safe calls, event dispatch, message bus,
-- saved variables, session log and slash commands.
local ADDON_NAME, ns = ...

ns.name = ADDON_NAME

local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (getMetadata and getMetadata(ADDON_NAME, "Version")) or "dev"
if string.find(ns.version, "@", 1, true) then
    ns.version = "dev" -- a working copy: the packager has not replaced the @project-version@ token
end
ns.version = (string.gsub(ns.version, "^v", "")) -- release tags are "v2.1.0"; we print the "v" ourselves

local PRINT_PREFIX = "|cff7fbf4cAKForeverWeaponBuffs|r: "

function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    print(PRINT_PREFIX .. table.concat(parts, " "))
end

------------------------------------------------------------------------
-- Secret values. WoW: Forever runs the Midnight-era API, where some
-- values handed to addons in combat may be held but not inspected.
------------------------------------------------------------------------
local issecret = type(issecretvalue) == "function" and issecretvalue or nil

function ns.IsSecret(value)
    if issecret then
        return issecret(value) and true or false
    end
    return false
end

function ns.AnySecret(...)
    for i = 1, select("#", ...) do
        if ns.IsSecret((select(i, ...))) then
            return true
        end
    end
    return false
end

-- Human readable dump that never touches a secret value.
function ns.Describe(value, depth)
    depth = depth or 0
    if ns.IsSecret(value) then
        return "<secret>"
    end
    if type(value) ~= "table" then
        return tostring(value)
    end
    if depth >= 3 then
        return "{...}"
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = tostring(k) .. "=" .. ns.Describe(v, depth + 1)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

------------------------------------------------------------------------
-- Safe calls: one module failing must not take the others down, and
-- every distinct error is kept for /wb diag.
------------------------------------------------------------------------
ns.errors = {}

local function onError(err)
    err = tostring(err)
    local seen = ns.errors[err]
    ns.errors[err] = (seen or 0) + 1
    if not seen then
        -- Surface the first occurrence through the normal Lua error UI.
        local handler = geterrorhandler and geterrorhandler()
        if handler then
            handler(err)
        end
    end
    return err
end

function ns.SafeCall(fn, ...)
    return xpcall(fn, onError, ...)
end

------------------------------------------------------------------------
-- Session log (ring buffer), saved with /wb diag and on logout
------------------------------------------------------------------------
local LOG_MAX = 400
ns.sessionLog = {}
ns.debug = false

function ns:Log(kind, data)
    local log = ns.sessionLog
    log[#log + 1] = {
        t = math.floor(GetTime() * 100) / 100,
        k = kind,
        c = InCombatLockdown() and 1 or nil,
        d = data,
    }
    if #log > LOG_MAX then
        table.remove(log, 1)
    end
    if ns.debug then
        ns:Print("|cff888888[" .. kind .. "]|r", ns.Describe(data))
    end
end

------------------------------------------------------------------------
-- Internal message bus (modules talk through messages, not each other)
------------------------------------------------------------------------
local listeners = {}

function ns:Listen(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns:Fire(message, ...)
    local list = listeners[message]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], message, ...)
    end
end

------------------------------------------------------------------------
-- Game events. Registration is pcall'd so an event that a future client
-- drops shows up in /wb diag instead of breaking the addon at load.
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local unitFrame = CreateFrame("Frame")
local eventHandlers = {}
local unitHandlers = {}
ns.unknownEvents = {}

local function dispatch(handlers, event, ...)
    local list = handlers[event]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], event, ...)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    dispatch(eventHandlers, event, ...)
end)

unitFrame:SetScript("OnEvent", function(_, event, ...)
    dispatch(unitHandlers, event, ...)
end)

function ns:On(event, fn)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
            ns.unknownEvents[event] = true
        end
    end
    table.insert(eventHandlers[event], fn)
end

-- Unit events, delivered for the player only.
function ns:OnPlayerUnit(event, fn)
    if not unitHandlers[event] then
        unitHandlers[event] = {}
        if not pcall(unitFrame.RegisterUnitEvent, unitFrame, event, "player") then
            ns.unknownEvents[event] = true
        end
    end
    table.insert(unitHandlers[event], fn)
end

------------------------------------------------------------------------
-- Blocked actions. When addon code touches something reserved for Blizzard's
-- UI the client stops the call (no Lua error, so pcall sees nothing) and shows
-- the "has been blocked from an action" dialog. These events name the function;
-- keep them so /wb diag can say exactly what it was. (Known trigger in Forever:
-- registering COMBAT_LOG_EVENT_UNFILTERED - the combat log is closed to addons.)
------------------------------------------------------------------------
ns.blockedActions = {}

local function onActionBlocked(event, addonName, functionName)
    if addonName ~= ADDON_NAME then
        return
    end
    local entry = { event = event, fn = tostring(functionName), combat = InCombatLockdown() and true or false }
    ns.blockedActions[#ns.blockedActions + 1] = entry
    ns:Log("action_blocked", entry)
end

ns:On("ADDON_ACTION_FORBIDDEN", onActionBlocked)
ns:On("ADDON_ACTION_BLOCKED", onActionBlocked)

------------------------------------------------------------------------
-- Saved variables: ONE account-wide table, per-character data under db.chars["First Last - Realm"].
-- The account-wide part is bound at ADDON_LOADED, the character's profile at PLAYER_LOGIN, when the
-- client knows the character's name for sure (bindProfile).
------------------------------------------------------------------------
local OPTION_DEFAULTS = {
    shown = true,
    showWhenEmpty = false, -- hidden until a weapon buff is applied or tracked
    partyPanel = true,
    partyGrowUp = false,   -- the party panel sits on top of your own frame and grows upwards
    warnSeconds = 60,
}

-- Realm names are squeezed ("Classic Beta PvE" -> "ClassicBetaPvE"): GetRealmName() gives the spaced
-- display name, GetNormalizedRealmName() the squeezed one.
local function squeezeRealm(realm)
    return (string.gsub(realm, "[%s%-]", ""))
end

-- A string the addon may look at: not nil, not empty, not a secret value.
local function readable(value)
    if type(value) ~= "string" or value == "" or ns.IsSecret(value) then
        return nil
    end
    return value
end

local function realmName()
    local realm = GetNormalizedRealmName and readable(GetNormalizedRealmName())
    if not realm and GetRealmName then
        realm = readable(GetRealmName())
        realm = realm and squeezeRealm(realm)
    end
    return realm
end

-- "First Last - Realm": the character's full name and realm - or nil while the client does not know the
-- name yet (a cold login's ADDON_LOADED). Since client build 1.60.1.70170 (Oct 1 2026) WoW: Forever puts
-- the SURNAME where the realm used to be: UnitFullName("player") answers "Purrdee", "Bubson" where earlier
-- builds said "Purrdee Bubson", "ClassicBetaPvE". So whatever sits in the realm slot and is not the realm
-- is the surname, and both builds end up with the key the profiles were saved under all along.
local function characterKey()
    local name, slot
    if UnitFullName then
        name, slot = UnitFullName("player")
    end
    name = readable(name) or (UnitName and readable((UnitName("player"))))
    if not name then
        return nil
    end
    local realm = realmName()
    slot = readable(slot)
    if slot and realm and squeezeRealm(slot) ~= realm then
        name = name .. " " .. slot
    elseif slot and not realm then
        realm = squeezeRealm(slot)
    end
    if not realm then
        return nil
    end
    return name .. " - " .. realm
end

-- Missing values in `target` are filled from `source`, down into nested tables. Nothing that is already
-- in `target` is overwritten.
local function fillGaps(target, source)
    for field, value in pairs(source) do
        local existing = target[field]
        if existing == nil then
            target[field] = value
        elseif type(existing) == "table" and type(value) == "table" then
            fillGaps(existing, value)
        end
    end
end

-- The spellings earlier versions saved the same character under, best first:
--   "First - Last"               build 70170 before this version: the surname was taken for the realm;
--   "First Last - Spaced Realm"  an unsqueezed realm (2.0.1 wrote those);
--   "Unknown - Realm"            a cold login, the name not known yet when the addon loaded. Every character
--                                that logged in cold shares it, so it goes to the first one to log in after
--                                the update, to fill gaps only.
local function olderSpellings(chars, key)
    local name, realm = string.match(key, "^(.-) %- (.+)$")
    local found = {}
    local first, last = string.match(name, "^(%S+) (%S+)$")
    if first and type(chars[first .. " - " .. last]) == "table" then
        found[#found + 1] = first .. " - " .. last
    end
    local unsqueezed = {}
    for other in pairs(chars) do
        local otherName, otherRealm = string.match(other, "^(.-) %- (.+)$")
        if other ~= key and type(chars[other]) == "table" and otherName == name and otherRealm and squeezeRealm(otherRealm) == realm then
            unsqueezed[#unsqueezed + 1] = other
        end
    end
    table.sort(unsqueezed)
    for _, other in ipairs(unsqueezed) do
        found[#found + 1] = other
    end
    if type(chars["Unknown - " .. realm]) == "table" then
        found[#found + 1] = "Unknown - " .. realm
    end
    return found
end

-- The profile of the character logging in, bound at PLAYER_LOGIN: at ADDON_LOADED a cold login does not
-- know the name yet (that is where the "Unknown - Realm" profiles came from). Until then the stand-in from
-- initDB takes any early write; it is folded in here. A profile saved under an older spelling is adopted
-- once: this profile keeps what it has, the older ones fill its gaps and are removed.
local function bindProfile()
    local key = characterKey()
    if not key then
        ns:Log("profile", { key = false, note = "the client did not give the character's name at login" })
        return
    end
    local db = ns.db
    local chars = db.chars
    local adopted = olderSpellings(chars, key)
    local cdb = chars[key]
    if type(cdb) ~= "table" then
        -- 2.0.0 kept this in SavedVariablesPerCharacter: adopt it once, for the first character that shows
        -- up with nothing saved under any spelling.
        if #adopted == 0 and type(WeaponBuffsCharDB) == "table" and not db.legacyAdopted then
            cdb = WeaponBuffsCharDB
            db.legacyAdopted = true
        else
            cdb = {}
        end
        chars[key] = cdb
    end
    for _, old in ipairs(adopted) do
        fillGaps(cdb, chars[old])
        chars[old] = nil
    end
    if ns.cdb and ns.cdb ~= cdb then
        fillGaps(cdb, ns.cdb)
    end
    -- Per character: what this character wants.
    cdb.desired = cdb.desired or {}         -- [setup][rowKey] = { key, pinned } | { none }
    cdb.options = cdb.options or {}
    ns.characterKey, ns.cdb = key, cdb
    if #adopted > 0 then
        ns:Log("profile", { key = key, adopted = adopted })
    end
end

local function initDB()
    local bridge = AKForeverWeaponBuffs_SavedStateBridge
    if type(AKForeverWeaponBuffsDB) ~= "table" then
        AKForeverWeaponBuffsDB = {}
        ns.savedStateSource = "none (first run, or the client did not load it)"
    elseif type(bridge) == "table" and bridge.table == AKForeverWeaponBuffsDB then
        ns.savedStateSource = "bridge addon"
    else
        ns.savedStateSource = "client"
    end
    local db = AKForeverWeaponBuffsDB

    db.chars = db.chars or {}

    -- Account wide: knowledge about the game.
    db.schema = db.schema or 1
    db.sources = db.sources or {}           -- [enchantID] = source that applies it
    db.enchantNames = db.enchantNames or {} -- [enchantID] = display name
    db.pulsed = db.pulsed or {}             -- [enchantID] = true for totem style buffs
    db.durations = db.durations or {}       -- [enchantID] = full duration in seconds (largest seen)
    db.itemSpells = db.itemSpells or {}     -- [use spellID] = itemID
    db.loads = (db.loads or 0) + 1

    ns.db = db
    ns.cdb = { desired = {}, options = {} } -- a stand-in until bindProfile, at PLAYER_LOGIN
end

function ns:GetOption(key)
    local options = ns.cdb and ns.cdb.options
    local value = options and options[key]
    if value == nil then
        return OPTION_DEFAULTS[key]
    end
    return value
end

function ns:SetOption(key, value)
    ns.cdb.options[key] = value
    ns:Fire("OPTION_CHANGED", key, value)
end

------------------------------------------------------------------------
-- Slash commands: modules register their own sub-commands
------------------------------------------------------------------------
local commands, commandOrder = {}, {}

function ns:RegisterCommand(name, help, fn)
    commands[name] = { help = help, fn = fn }
    commandOrder[#commandOrder + 1] = name
end

SLASH_AKFOREVERWEAPONBUFFS1 = "/weaponbuffs"
SLASH_AKFOREVERWEAPONBUFFS2 = "/wb"
SLASH_AKFOREVERWEAPONBUFFS3 = "/fwb"
SlashCmdList["AKFOREVERWEAPONBUFFS"] = function(message)
    local name, rest = string.match(message or "", "^%s*(%S*)%s*(.-)%s*$")
    local command = commands[string.lower(name or "")]
    if command then
        ns.SafeCall(command.fn, rest or "")
        return
    end
    ns:Print("v" .. ns.version .. " commands:")
    for _, commandName in ipairs(commandOrder) do
        print("   |cffffd100/wb " .. commandName .. "|r - " .. commands[commandName].help)
    end
end

ns:RegisterCommand("debug", "toggle verbose logging to chat", function()
    ns.debug = not ns.debug
    ns:Print("debug logging", ns.debug and "on" or "off")
end)

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
ns.inCombat = false

ns:On("ADDON_LOADED", function(_, addonName)
    if addonName ~= ADDON_NAME then
        return
    end
    initDB()
end)

ns:On("PLAYER_LOGIN", function()
    bindProfile()
    ns:Fire("DB_READY") -- the saved tables, the character's profile included, are in place
    local _, classFile = UnitClass("player")
    ns.playerClass = classFile
    ns.inCombat = InCombatLockdown() and true or false
    ns:Log("login", {
        version = ns.version,
        class = classFile,
        character = ns.characterKey,
        loads = ns.db and ns.db.loads,
        savedState = ns.savedStateSource,
    })
    ns:Fire("LOGIN")
end)

ns:On("PLAYER_REGEN_DISABLED", function()
    ns.inCombat = true
    ns:Fire("COMBAT_START")
end)

ns:On("PLAYER_REGEN_ENABLED", function()
    ns.inCombat = false
    ns:Fire("COMBAT_END")
end)
