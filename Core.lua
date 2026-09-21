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
-- Saved variables
------------------------------------------------------------------------
local OPTION_DEFAULTS = {
    shown = true,
    showWhenEmpty = false, -- hidden until a weapon buff is applied or tracked
    partyPanel = true,
    partyGrowUp = false,   -- the party panel sits on top of your own frame and grows upwards
    warnSeconds = 60,
}

-- "Name - Realm", with the realm squeezed ("Classic Beta PvE" -> "ClassicBetaPvE").
-- The squeeze matters: on a fresh login UnitFullName has no realm yet and
-- GetRealmName() gives the spaced display name, while after a /reload
-- UnitFullName gives the normalized one. Unsqueezed, that is two profiles.
local function squeezeRealm(realm)
    return (string.gsub(realm, "[%s%-]", ""))
end

local function characterKey()
    local name, realm
    if UnitFullName then
        name, realm = UnitFullName("player")
    end
    if not name then
        name = UnitName("player")
    end
    if not realm or realm == "" then
        realm = GetRealmName and GetRealmName()
    end
    return (name or "Unknown") .. " - " .. squeezeRealm(realm or "Unknown")
end

-- 2.0.1 wrote unsqueezed keys: fold those profiles into the canonical one.
-- The canonical profile wins; the other only fills gaps.
local function mergeCharacterProfiles(chars)
    local renames = {}
    for key in pairs(chars) do
        local name, realm = string.match(key, "^(.-) %- (.+)$")
        local canonical = name and (name .. " - " .. squeezeRealm(realm))
        if canonical and canonical ~= key then
            renames[key] = canonical
        end
    end
    for key, canonical in pairs(renames) do
        local source, target = chars[key], chars[canonical]
        if type(target) ~= "table" then
            chars[canonical] = source
        elseif type(source) == "table" then
            for field, value in pairs(source) do
                local existing = target[field]
                if existing == nil or (type(existing) == "table" and next(existing) == nil) then
                    target[field] = value
                end
            end
        end
        chars[key] = nil
    end
end

-- Everything lives in ONE account-wide table; per-character data sits under
-- db.chars[name - realm]. One file is also what makes the WoW: Forever beta
-- workaround possible: that client writes SavedVariables but never reads them
-- back, so the optional AKForeverWeaponBuffs_SavedState companion addon loads the saved
-- file as code before us (see tools/Install-SavedStateBridge.ps1).
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
    mergeCharacterProfiles(db.chars)
    local key = characterKey()
    local cdb = db.chars[key]
    if type(cdb) ~= "table" then
        -- 2.0.0 kept this in SavedVariablesPerCharacter: adopt it once, for the
        -- first character that shows up with it.
        if type(WeaponBuffsCharDB) == "table" and not db.legacyAdopted then
            cdb = WeaponBuffsCharDB
            db.legacyAdopted = true
        else
            cdb = {}
        end
        db.chars[key] = cdb
    end
    ns.characterKey = key

    -- Account wide: knowledge about the game.
    db.schema = db.schema or 1
    db.sources = db.sources or {}           -- [enchantID] = source that applies it
    db.enchantNames = db.enchantNames or {} -- [enchantID] = display name
    db.pulsed = db.pulsed or {}             -- [enchantID] = true for totem style buffs
    db.durations = db.durations or {}       -- [enchantID] = full duration in seconds (largest seen)
    db.itemSpells = db.itemSpells or {}     -- [use spellID] = itemID
    db.loads = (db.loads or 0) + 1

    -- Per character: what this character wants.
    cdb.desired = cdb.desired or {}         -- [setup][rowKey] = { key, pinned } | { none }
    cdb.options = cdb.options or {}

    ns.db, ns.cdb = db, cdb
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
    ns:Fire("DB_READY")
end)

ns:On("PLAYER_LOGIN", function()
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
