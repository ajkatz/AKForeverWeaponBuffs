-- Diagnostics: '/wb diag' snapshots everything we assume about this client into
-- SavedVariables (AKForeverWeaponBuffsDB.diag), so a /reload turns a play session into a
-- bug report. WoW: Forever is a beta on a moving API - this is how the addon's
-- assumptions get re-tested when Blizzard changes something.
local _, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

-- Every client API the addon relies on (dotted paths into _G).
local API_PATHS = {
    "C_Item.GetWeaponEnchantInfo", "GetWeaponEnchantInfo",
    "C_Item.GetItemInfoInstant", "C_Item.GetItemSpell", "C_Item.GetItemCount",
    "C_Item.GetItemNameByID", "C_Item.GetItemIconByID", "C_Item.IsItemDataCachedByID",
    "C_Item.RequestLoadItemDataByID",
    "C_Spell.GetSpellName", "C_Spell.GetSpellTexture", "C_Spell.CancelItemTempEnchantment",
    "C_SpellBook.IsSpellKnownOrInSpellBook", "C_SpellBook.IsSpellKnown", "C_SpellBook.IsSpellInSpellBook",
    "IsPlayerSpell",
    "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemID",
    "C_TooltipInfo.GetInventoryItem",
    "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.InChatMessagingLockdown",
    "C_UnitAuras.GetPlayerAuraBySpellID", "C_UnitAuras.GetAuraDataByIndex", "AuraUtil.FindAuraByName", "UnitBuff",
    "C_Secrets.ShouldAurasBeSecret", "issecretvalue", "canaccessvalue",
    "C_Timer.After", "C_Timer.NewTicker", "C_AddOns.GetAddOnMetadata",
    "GetInventoryItemID", "Ambiguate", "GetUnitName", "IsInGroup", "InCombatLockdown",
    "C_Macro.RunMacroText", "UseInventoryItem", "SpellCanTargetItem",
}

local function resolve(path)
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then
            return nil
        end
        value = value[part]
    end
    return value
end

-- Deep copy that is safe to hand to the SavedVariables writer.
local function sanitize(value, depth)
    depth = depth or 0
    if ns.IsSecret(value) then
        return "<secret>"
    end
    local kind = type(value)
    if kind == "table" then
        if depth >= 6 then
            return "<too deep>"
        end
        local copy = {}
        for k, v in pairs(value) do
            local key = k
            if ns.IsSecret(k) then
                key = "<secret key>"
            elseif type(k) ~= "string" and type(k) ~= "number" then
                key = tostring(k)
            end
            copy[key] = sanitize(v, depth + 1)
        end
        return copy
    elseif kind == "string" or kind == "number" or kind == "boolean" then
        return value
    elseif kind == "nil" then
        return nil
    end
    return "<" .. kind .. ">"
end

local function packResults(ok, ...)
    if not ok then
        return { error = tostring((...)) }
    end
    local results = { n = select("#", ...) }
    for i = 1, results.n do
        results[i] = sanitize((select(i, ...)))
    end
    return results
end

-- Call a client API and keep whatever came back, error included.
local function try(fn, ...)
    return packResults(pcall(fn, ...))
end

function Diagnostics:Collect()
    local version, build, buildDate, tocVersion = GetBuildInfo()
    local report = {
        addonVersion = ns.version,
        capturedAt = date("%Y-%m-%d %H:%M:%S"),
        build = { version = version, build = build, date = buildDate, toc = tocVersion },
        project = { id = WOW_PROJECT_ID, mainline = WOW_PROJECT_MAINLINE, classic = WOW_PROJECT_CLASSIC },
        locale = GetLocale(),
        class = ns.playerClass,
        level = UnitLevel("player"),
        inCombat = InCombatLockdown() and true or false,
        savedVariableLoads = ns.db.loads, -- stays at 1 forever if the client never reads SavedVariables back
        savedStateSource = ns.savedStateSource, -- "client", "bridge addon" or "none ..."
        character = ns.characterKey,
        unknownEvents = sanitize(ns.unknownEvents),
        errors = sanitize(ns.errors),
        blockedActions = sanitize(ns.blockedActions), -- should stay empty
    }

    report.api = {}
    for _, path in ipairs(API_PATHS) do
        report.api[path] = type(resolve(path))
    end

    report.enums = {
        WeaponSlot = sanitize(Enum and Enum.WeaponSlot),
        ItemEnchantType = sanitize(Enum and Enum.ItemEnchantType),
        SendAddonMessageResult = sanitize(Enum and Enum.SendAddonMessageResult),
    }

    report.lockdowns = {
        chatMessaging = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and try(C_ChatInfo.InChatMessagingLockdown) or "n/a",
        aurasSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret and try(C_Secrets.ShouldAurasBeSecret) or "n/a",
    }

    report.weapons = {}
    for _, slot in ipairs(ns.Enchants.SLOTS) do
        local itemID, equipLoc, classID, subclassID = ns.Enchants:GetEquipInfo(slot.invSlot)
        local info = {
            itemID = itemID,
            equipLoc = equipLoc,
            classID = classID,
            subclassID = subclassID,
            tooltipEnchantLines = sanitize(ns.Sources:ReadEnchantLines(slot.invSlot)),
        }
        if C_Item and C_Item.GetWeaponEnchantInfo then
            info.rawEnchants = try(C_Item.GetWeaponEnchantInfo, slot.weaponSlot)
        end
        if C_TooltipInfo and C_TooltipInfo.GetInventoryItem and itemID then
            local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slot.invSlot)
            if ok and type(data) == "table" and not ns.IsSecret(data) and type(data.lines) == "table" then
                info.tooltipLines = {}
                for index, line in ipairs(data.lines) do
                    if type(line) == "table" then
                        info.tooltipLines[index] = { text = sanitize(line.leftText), lineType = sanitize(line.type) }
                    end
                end
            else
                info.tooltipLines = { error = ok and "unreadable" or tostring(data) }
            end
        end
        report.weapons[slot.key] = info
    end

    report.state = {
        setup = ns.Enchants:GetSetup(),
        enchantsLocked = ns.Enchants.locked,
        rows = sanitize(ns.Enchants.rows),
        desired = sanitize(ns.cdb.desired),
        sources = sanitize(ns.db.sources),
        enchantNames = sanitize(ns.db.enchantNames),
        pulsed = sanitize(ns.db.pulsed),
        durations = sanitize(ns.db.durations),
        comms = sanitize(ns.Comms.stats),
        roster = sanitize(ns.Comms.roster),
        fixAction = ns.PlayerFrame.action and sanitize({
            kind = ns.PlayerFrame.action.kind,
            key = ns.PlayerFrame.action.source and ns.PlayerFrame.action.source.key,
            slot = ns.PlayerFrame.action.slot and ns.PlayerFrame.action.slot.key,
            macrotext = ns.PlayerFrame.action.macrotext,
            pending = ns.PlayerFrame.actionPending,
        }) or "none",
    }

    report.log = sanitize(ns.sessionLog)
    return report
end

function Diagnostics:Save()
    ns.db.diag = self:Collect()
    return ns.db.diag
end

ns:RegisterCommand("diag", "snapshot API + addon state into SavedVariables (then /reload and share the file)", function()
    local report = Diagnostics:Save()
    local missing = {}
    for path, kind in pairs(report.api) do
        if kind == "nil" then
            missing[#missing + 1] = path
        end
    end
    table.sort(missing)
    local errorCount = 0
    for _ in pairs(ns.errors) do
        errorCount = errorCount + 1
    end
    ns:Print("diagnostics captured: build", report.build.version, "toc", report.build.toc,
        "| setup", report.state.setup, "| errors", errorCount, "| log entries", #ns.sessionLog)
    ns:Print("missing APIs (expected: the legacy ones):", #missing > 0 and table.concat(missing, ", ") or "none")
    ns:Print("now type |cffffd100/reload|r - the report is written to WTF\\Account\\<account>\\SavedVariables\\AKForeverWeaponBuffs.lua")
end)

-- Keep a report even if nobody asked for one: logout and /reload both write it.
ns:On("PLAYER_LOGOUT", function()
    Diagnostics:Save()
end)
