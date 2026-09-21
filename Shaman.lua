-- Shaman extra carried over from SodShamanWeaponBuffs: the skinning-knife swap trick for dual wield
-- imbues. Isolated here so it can be redesigned without touching the rest.
-- (The shield charge counter that also lived here was taken out in v2.0.3: attic/shield-charge-counter.)
local _, ns = ...

local Tracker = ns.Tracker

local Shaman = {}
ns.Shaman = Shaman

local function isShaman()
    return ns.playerClass == "SHAMAN"
end

------------------------------------------------------------------------
-- Skinning-knife swap (dual wield)
--
-- Ported 1:1 from the Season of Discovery addon. There, an imbue cast lands on
-- the main hand unless the main hand already carries that same imbue, so fixing
-- only one hand meant overwriting the other. Parking a Skinning Knife in the
-- hand you want to protect avoids that. Whether Forever targets imbues the same
-- way is NOT yet verified - see the test plan in README.md.
------------------------------------------------------------------------
local KNIFE_ITEM_ID = 7005

local function hasKnife()
    return ((C_Item.GetItemCount and C_Item.GetItemCount(KNIFE_ITEM_ID)) or 0) >= 1
end

local function itemIcon(itemID)
    return C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
end

-- The row in this hand whose tracked buff is a spell (an imbue).
local function imbueRow(rows, slotKey)
    for _, row in ipairs(rows) do
        if row.slotKey == slotKey and row.desiredSource and row.desiredSource.kind == "spell" then
            return row
        end
    end
    return nil
end

local function isCorrect(row)
    return row.entry ~= nil and row.source ~= nil and row.source.key == row.desire.key
end

local function rememberWeapons()
    ns.cdb.dwWeapons = ns.cdb.dwWeapons or {}
    local mainID, offID = GetInventoryItemID("player", 16), GetInventoryItemID("player", 17)
    if mainID and mainID ~= KNIFE_ITEM_ID then
        ns.cdb.dwWeapons.MH = mainID
    end
    if offID and offID ~= KNIFE_ITEM_ID then
        ns.cdb.dwWeapons.OH = offID
    end
end

local function equipWeaponAction(slotKey)
    local itemID = ns.cdb.dwWeapons and ns.cdb.dwWeapons[slotKey]
    if not itemID then
        return nil
    end
    local invSlot = slotKey == "MH" and 16 or 17
    return {
        kind = "macro",
        macrotext = "/equipslot " .. invSlot .. " item:" .. itemID,
        icon = itemIcon(itemID),
        label = slotKey,
        title = "Re-equip your weapon",
        description = "Swaps your real weapon back in; its imbue kept ticking in your bags.",
    }
end

local function equipKnifeAction(slotKey)
    local invSlot = slotKey == "MH" and 16 or 17
    return {
        kind = "macro",
        macrotext = "/equipslot " .. invSlot .. " item:" .. KNIFE_ITEM_ID,
        icon = itemIcon(KNIFE_ITEM_ID),
        label = slotKey,
        title = "Skinning Knife swap",
        description = "Parks a Skinning Knife in this hand so the next imbue cannot overwrite the good one.",
    }
end

function Shaman:DecorateRows(rows, setup)
    if not isShaman() or setup ~= "DW" then
        return
    end
    rememberWeapons()
    local mainID, offID = GetInventoryItemID("player", 16), GetInventoryItemID("player", 17)
    local knifeSlot = (mainID == KNIFE_ITEM_ID and "MH") or (offID == KNIFE_ITEM_ID and "OH") or nil
    if not knifeSlot then
        return
    end
    local other = imbueRow(rows, knifeSlot == "MH" and "OH" or "MH")
    local otherCorrect = other and isCorrect(other) or false
    for _, row in ipairs(rows) do
        if row.slotKey == knifeSlot and row.desire then
            row.status = "KNIFE"
            row.knifeText = otherCorrect and "Equip weapon" or "Rebuff other"
        end
    end
end

function Shaman:ChooseFix(rows, setup)
    if not isShaman() or setup ~= "DW" then
        return nil
    end
    local mh, oh = imbueRow(rows, "MH"), imbueRow(rows, "OH")
    if not (mh and oh) then
        return nil
    end

    local mainID, offID = GetInventoryItemID("player", 16), GetInventoryItemID("player", 17)
    if mainID == KNIFE_ITEM_ID then
        if isCorrect(oh) then
            return equipWeaponAction("MH") or Tracker:ActionForRow(mh)
        end
        return Tracker:ActionForRow(oh)
    elseif offID == KNIFE_ITEM_ID then
        if isCorrect(mh) then
            return equipWeaponAction("OH") or Tracker:ActionForRow(oh)
        end
        return Tracker:ActionForRow(mh)
    end

    local mhNeedsFix, ohNeedsFix = not isCorrect(mh), not isCorrect(oh)
    if mhNeedsFix then
        if not mh.entry then
            return Tracker:ActionForRow(mh)
        elseif not oh.entry then
            return Tracker:ActionForRow(oh)
        elseif hasKnife() and oh.source and oh.source.key == mh.desire.key then
            return equipKnifeAction("OH")
        end
        return Tracker:ActionForRow(mh)
    elseif ohNeedsFix then
        if not oh.entry then
            return Tracker:ActionForRow(oh)
        elseif hasKnife() then
            return equipKnifeAction("MH")
        end
        return Tracker:ActionForRow(oh)
    end

    -- Both hands are right: offer whichever runs out first.
    if (mh.remaining or 0) <= (oh.remaining or 0) then
        return Tracker:ActionForRow(mh)
    end
    return Tracker:ActionForRow(oh)
end
