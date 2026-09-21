-- Tracker: what the player WANTS on each weapon (auto-learned or pinned), how
-- the current state compares to it, and which single action the fix button
-- should offer next.
local _, ns = ...

local Enchants, Sources = ns.Enchants, ns.Sources

local Tracker = {}
ns.Tracker = Tracker

-- Setups that never teach us a preference (a lure on a fishing pole is not
-- something to nag about once the real weapon is back).
local NO_LEARN_SETUPS = { NONE = true, FISHING = true }

local NEEDS_ACTION = { MISSING = true, WRONG = true }
local URGENT = { MISSING = true, WRONG = true, LOW = true, KNIFE = true }

------------------------------------------------------------------------
-- Desires: ns.cdb.desired[setup][rowKey] = { key, pinned } | { none = true }
------------------------------------------------------------------------
function Tracker:GetDesire(setup, rowKey)
    local bySetup = ns.cdb.desired[setup]
    return bySetup and bySetup[rowKey]
end

local function setDesire(setup, rowKey, desire)
    ns.cdb.desired[setup] = ns.cdb.desired[setup] or {}
    ns.cdb.desired[setup][rowKey] = desire
    ns:Log("desire", {
        setup = setup,
        row = rowKey,
        key = desire and desire.key,
        pinned = desire and desire.pinned,
        none = desire and desire.none,
    })
    ns:Fire("PREFS_CHANGED")
end

-- Always want this buff here; applying something else is flagged as wrong.
function Tracker:Pin(setup, rowKey, sourceKey)
    setDesire(setup, rowKey, { key = sourceKey, pinned = true })
end

-- Follow whatever was applied last.
function Tracker:SetAuto(setup, rowKey)
    local current = self:GetDesire(setup, rowKey)
    local key = current and current.key
    if not key then
        local entry = Enchants.rows[rowKey]
        local source = entry and Sources:GetForEnchant(entry.enchantID)
        key = source and source.key
    end
    if key then
        setDesire(setup, rowKey, { key = key, pinned = false })
    else
        setDesire(setup, rowKey, nil)
    end
end

-- Never remind about this row.
function Tracker:SetNone(setup, rowKey)
    setDesire(setup, rowKey, { none = true })
end

ns:Listen("SOURCE_APPLIED", function(_, rowKey, source)
    local setup = Enchants:GetSetup()
    if NO_LEARN_SETUPS[setup] then
        return
    end
    local desire = Tracker:GetDesire(setup, rowKey)
    if desire and (desire.pinned or desire.none) then
        return
    end
    if desire and desire.key == source.key then
        return
    end
    -- Dual wield + spell: the GAME picks the hand an imbue lands on, so a cast
    -- meant for the other hand can overwrite this one. Following that would
    -- silently drop the buff the player wanted here; keep the old preference and
    -- let the row show WRONG instead. (Items are aimed at a weapon by hand, so
    -- those are always deliberate.) Changing a hand's imbue is a picker action.
    if desire and desire.key and setup == "DW" and source.kind == "spell" then
        ns:Log("desire_kept", { row = rowKey, kept = desire.key, landed = source.key })
        return
    end
    setDesire(setup, rowKey, { key = source.key, pinned = false })
end)

------------------------------------------------------------------------
-- Rows: union of what is on the weapons and what should be
------------------------------------------------------------------------
local function compareRows(a, b)
    if a.slot.order ~= b.slot.order then
        return a.slot.order < b.slot.order
    end
    local typeA = Enchants.TYPE_ORDER[a.typeKey] or 9
    local typeB = Enchants.TYPE_ORDER[b.typeKey] or 9
    if typeA ~= typeB then
        return typeA < typeB
    end
    return a.rowKey < b.rowKey
end

local function splitRowKey(rowKey)
    local slotKey, typeKey = string.match(rowKey, "^([^:]+):([^#]+)")
    return slotKey, typeKey
end

function Tracker:BuildRows()
    local now = GetTime()
    local setup = Enchants:GetSetup()
    local warnSeconds = ns:GetOption("warnSeconds")
    local rows, byKey = {}, {}

    for rowKey, entry in pairs(Enchants.rows) do
        local remaining = math.max(0, entry.expiresAt - now)
        local row = {
            rowKey = rowKey,
            slotKey = entry.slotKey,
            typeKey = entry.typeKey,
            slot = Enchants.SLOT_BY_KEY[entry.slotKey],
            entry = entry,
            remaining = remaining,
            fullDuration = Sources:GetFullDuration(entry.enchantID, remaining),
            source = Sources:GetForEnchant(entry.enchantID),
            pulsed = Sources:IsPulsed(entry.enchantID),
            name = Sources:GetEnchantName(entry.enchantID),
            icon = entry.iconID,
        }
        rows[#rows + 1] = row
        byKey[rowKey] = row
    end

    for rowKey, desire in pairs(ns.cdb.desired[setup] or {}) do
        local slotKey, typeKey = splitRowKey(rowKey)
        local slot = slotKey and Enchants.SLOT_BY_KEY[slotKey]
        if slot then
            local row = byKey[rowKey]
            if desire.none then
                if row then
                    row.untracked = true
                end
            elseif desire.key and Enchants:IsSlotBuffable(slotKey) then
                local desiredSource = Sources:GetByKey(desire.key)
                if desiredSource then
                    if not row then
                        row = { rowKey = rowKey, slotKey = slotKey, typeKey = typeKey, slot = slot }
                        rows[#rows + 1] = row
                        byKey[rowKey] = row
                    end
                    row.desire = desire
                    row.desiredSource = desiredSource
                    row.desiredName, row.desiredIcon = Sources:GetDisplay(desiredSource)
                end
            end
        end
    end

    for _, row in ipairs(rows) do
        if row.entry and row.desire then
            if row.source and row.source.key == row.desire.key then
                row.status = (row.remaining <= warnSeconds) and "LOW" or "OK"
            else
                row.status = "WRONG"
            end
        elseif row.entry then
            row.status = "INFO"
        else
            row.status = "MISSING"
        end
    end

    if ns.Shaman and ns.Shaman.DecorateRows then
        ns.Shaman:DecorateRows(rows, setup)
    end

    table.sort(rows, compareRows)
    return rows, setup
end

function Tracker:IsUrgent(rows)
    for _, row in ipairs(rows) do
        if URGENT[row.status] and (row.desire or row.status == "KNIFE") then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Fix action: the one thing the secure button should do right now
------------------------------------------------------------------------
function Tracker:ActionForRow(row)
    if not (row and row.desiredSource) then
        return nil
    end
    return {
        kind = "apply",
        source = row.desiredSource,
        slot = row.slot,
        rowKey = row.rowKey,
        urgent = URGENT[row.status] and true or false,
    }
end

function Tracker:ChooseFix(rows, setup)
    if ns.Shaman and ns.Shaman.ChooseFix then
        local action = ns.Shaman:ChooseFix(rows, setup)
        if action then
            return action
        end
    end

    local best, bestScore
    for _, row in ipairs(rows) do
        if row.desire and row.desiredSource then
            local score
            if NEEDS_ACTION[row.status] then
                score = -1000000 + row.slot.order -- main hand first
            else
                score = row.remaining or 1000000
            end
            if not bestScore or score < bestScore then
                best, bestScore = row, score
            end
        end
    end
    return self:ActionForRow(best)
end
