-- Read model: which timed enchants sit on the player's weapons right now.
--
-- WoW: Forever exposes C_Item.GetWeaponEnchantInfo(weaponSlot), which returns
-- a LIST of enchants per slot, each tagged with an Enum.ItemEnchantType
-- (Temporary, Imbue, ...). A weapon can therefore carry more than one timed
-- buff, so everything here is keyed by "row" = slot + enchant type.
local _, ns = ...

local Enchants = {}
ns.Enchants = Enchants

local REFRESH_EPSILON = 3 -- seconds a timer must jump up to count as re-applied

local WeaponSlot = (Enum and Enum.WeaponSlot) or {}

Enchants.SLOTS = {
    { key = "MH", label = "MH", name = _G.INVTYPE_WEAPONMAINHAND or "Main Hand", weaponSlot = WeaponSlot.MainHand or 0, invSlot = 16 },
    { key = "OH", label = "OH", name = _G.INVTYPE_WEAPONOFFHAND or "Off Hand", weaponSlot = WeaponSlot.OffHand or 1, invSlot = 17 },
    { key = "RG", label = "R", name = _G.INVTYPE_RANGED or "Ranged", weaponSlot = WeaponSlot.Ranged or 2, invSlot = 18 },
}
Enchants.SLOT_BY_KEY = {}
for order, slot in ipairs(Enchants.SLOTS) do
    slot.order = order
    Enchants.SLOT_BY_KEY[slot.key] = slot
end

-- Enum value -> "TEMPORARY" / "IMBUE" / ...
local TYPE_KEYS = {}
if Enum and Enum.ItemEnchantType then
    for name, value in pairs(Enum.ItemEnchantType) do
        TYPE_KEYS[value] = string.upper(name)
    end
end
local UNTRACKED_TYPES = { NONE = true, PERMANENT = true }

Enchants.TYPE_ORDER = { IMBUE = 1, TEMPORARY = 2 }
Enchants.TYPE_LABELS = { IMBUE = "Imbue", TEMPORARY = "Temporary" }

local function typeKeyOf(enchantType)
    if enchantType == nil then
        return "TEMPORARY"
    end
    return TYPE_KEYS[enchantType] or ("TYPE" .. tostring(enchantType))
end

Enchants.rows = {}       -- [rowKey] = entry
Enchants.locked = nil    -- reason string while the API refuses to tell us
Enchants.initialized = false

------------------------------------------------------------------------
-- Raw reads
------------------------------------------------------------------------
local function addEntry(rows, slot, enchantType, enchantID, timeLeftMs, charges, iconID, now)
    local typeKey = typeKeyOf(enchantType)
    if UNTRACKED_TYPES[typeKey] then
        return
    end
    if type(timeLeftMs) ~= "number" or timeLeftMs <= 0 then
        return
    end
    local rowKey = slot.key .. ":" .. typeKey
    local suffix = 1
    while rows[rowKey] do
        suffix = suffix + 1
        rowKey = slot.key .. ":" .. typeKey .. "#" .. suffix
    end
    rows[rowKey] = {
        rowKey = rowKey,
        slotKey = slot.key,
        typeKey = typeKey,
        invSlot = slot.invSlot,
        enchantType = enchantType,
        enchantID = enchantID or 0,
        iconID = iconID,
        charges = charges,
        expiresAt = now + timeLeftMs / 1000,
    }
end

-- Forever / Midnight-era API.
local function readModern(now)
    local rows = {}
    for _, slot in ipairs(Enchants.SLOTS) do
        local ok, list = pcall(C_Item.GetWeaponEnchantInfo, slot.weaponSlot)
        if not ok then
            return nil, "error: " .. tostring(list)
        end
        if ns.IsSecret(list) then
            return nil, "secret"
        end
        if type(list) == "table" then
            for _, info in pairs(list) do
                if ns.IsSecret(info) then
                    return nil, "secret"
                end
                if type(info) == "table" then
                    if ns.AnySecret(info.hasEnchant, info.enchantType, info.timeLeft, info.enchantID) then
                        return nil, "secret"
                    end
                    if info.hasEnchant then
                        local iconID = info.enchantIconID
                        -- 0 is this client's way of saying "no icon", and 0 is truthy in Lua
                        if ns.IsSecret(iconID) or iconID == 0 then
                            iconID = nil
                        end
                        local charges = info.charges
                        if ns.IsSecret(charges) then
                            charges = nil
                        end
                        addEntry(rows, slot, info.enchantType, info.enchantID, info.timeLeft, charges, iconID, now)
                    end
                end
            end
        end
    end
    return rows
end

-- Classic Era style global, kept as a fallback so the read model is not
-- welded to one client generation.
local function readLegacy(now)
    local rows = {}
    local results = { GetWeaponEnchantInfo() }
    for index, slot in ipairs(Enchants.SLOTS) do
        local base = (index - 1) * 4
        if results[base + 1] then
            addEntry(rows, slot, nil, results[base + 4], results[base + 2], results[base + 3], nil, now)
        end
    end
    return rows
end

local function readRaw(now)
    if C_Item and C_Item.GetWeaponEnchantInfo then
        return readModern(now)
    elseif GetWeaponEnchantInfo then
        return readLegacy(now)
    end
    return nil, "no weapon enchant API"
end

------------------------------------------------------------------------
-- Refresh + change detection
------------------------------------------------------------------------
function Enchants:Refresh(reason)
    local now = GetTime()
    local fresh, err = readRaw(now)
    if not fresh then
        if self.locked ~= err then
            self.locked = err
            ns:Log("enchants_locked", err)
            ns:Fire("ENCHANTS_LOCKED", err)
        end
        return
    end
    if self.locked then
        self.locked = nil
        ns:Log("enchants_unlocked", reason)
        ns:Fire("ENCHANTS_LOCKED", nil)
    end

    local old = self.rows
    local initial = not self.initialized
    local applied, removed = {}, {}
    local identityChanged = false

    for rowKey, entry in pairs(fresh) do
        local previous = old[rowKey]
        if not previous or previous.enchantID ~= entry.enchantID then
            identityChanged = true
            applied[#applied + 1] = { entry = entry, refresh = false }
        elseif entry.expiresAt > previous.expiresAt + REFRESH_EPSILON then
            applied[#applied + 1] = { entry = entry, refresh = true }
        end
    end
    for rowKey, previous in pairs(old) do
        if not fresh[rowKey] then
            identityChanged = true
            removed[#removed + 1] = previous
        end
    end

    self.rows = fresh
    self.initialized = true

    for _, change in ipairs(removed) do
        ns:Log("enchant_removed", { row = change.rowKey, id = change.enchantID })
        ns:Fire("ENCHANT_REMOVED", change)
    end
    for _, change in ipairs(applied) do
        local entry = change.entry
        ns:Log("enchant_applied", {
            row = entry.rowKey,
            id = entry.enchantID,
            left = math.floor(entry.expiresAt - now),
            refresh = change.refresh or nil,
            initial = initial or nil,
            why = reason,
        })
        ns:Fire("ENCHANT_APPLIED", entry, { refresh = change.refresh, initial = initial, at = now })
    end
    if identityChanged or initial then
        ns:Fire("ENCHANTS_CHANGED")
    end
end

------------------------------------------------------------------------
-- Equipped weapons
------------------------------------------------------------------------
local WEAPON_LOCS = {
    INVTYPE_WEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_2HWEAPON = true,
}
local RANGED_LOCS = {
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
}
local ITEM_CLASS_WEAPON = 2
local WEAPON_SUBCLASS_FISHING_POLE = 20

-- itemID, equipLoc, classID, subclassID, icon
function Enchants:GetEquipInfo(invSlot)
    local itemID = GetInventoryItemID("player", invSlot)
    if not itemID then
        return nil
    end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInstant then
        return itemID
    end
    local _, _, _, equipLoc, icon, classID, subclassID = getInstant(itemID)
    return itemID, equipLoc, classID, subclassID, icon
end

-- "NONE" | "1H" | "2H" | "DW" | "FISHING"
function Enchants:GetSetup()
    local mainID, mainLoc, mainClass, mainSubclass = self:GetEquipInfo(16)
    local offID, offLoc = self:GetEquipInfo(17)
    if mainID and mainClass == ITEM_CLASS_WEAPON and mainSubclass == WEAPON_SUBCLASS_FISHING_POLE then
        return "FISHING"
    end
    if offID and WEAPON_LOCS[offLoc] then
        return "DW"
    end
    if mainID and WEAPON_LOCS[mainLoc] then
        if mainLoc == "INVTYPE_2HWEAPON" then
            return "2H"
        end
        return "1H"
    end
    return "NONE"
end

-- Can this slot hold a weapon buff with what is equipped right now?
function Enchants:IsSlotBuffable(slotKey)
    local slot = self.SLOT_BY_KEY[slotKey]
    if not slot then
        return false
    end
    local itemID, equipLoc = self:GetEquipInfo(slot.invSlot)
    if not itemID then
        return false
    end
    if slotKey == "RG" then
        return RANGED_LOCS[equipLoc] and true or false
    end
    return WEAPON_LOCS[equipLoc] and true or false
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
local function refreshFrom(event)
    Enchants:Refresh(event)
end

ns:On("WEAPON_ENCHANT_CHANGED", refreshFrom)
ns:On("WEAPON_SLOT_CHANGED", refreshFrom)
ns:On("PLAYER_ENTERING_WORLD", refreshFrom)
ns:OnPlayerUnit("UNIT_INVENTORY_CHANGED", refreshFrom)
ns:On("PLAYER_EQUIPMENT_CHANGED", function(event, invSlot)
    if invSlot == 16 or invSlot == 17 or invSlot == 18 then
        Enchants:Refresh(event)
        ns:Fire("WEAPONS_CHANGED")
    end
end)

ns:Listen("LOGIN", function()
    Enchants:Refresh("login")
    -- Safety net: expiry and anything the events miss.
    C_Timer.NewTicker(1, function()
        ns.SafeCall(Enchants.Refresh, Enchants, "tick")
    end)
end)
