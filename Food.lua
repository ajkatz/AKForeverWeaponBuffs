-- Food: your food buff, tracked beside the weapon buffs - the Well Fed of a raid night.
--
-- On Forever every food buff is called "Well Fed" (the user's word, 2026-10-06), so the row looks for that
-- one name on you and nothing else: no tables, nothing to learn. (A first version learned "the buff that
-- followed a meal" - and a quest item used before dinner taught it Cantation of Manifestation.)
--
-- A food buff is an aura on you, and on this client an aura is readable OUT OF COMBAT ONLY: in a fight
-- the list cannot be touched at all (measured by AKForeverCombatTimers, 2026-09-20: a lookup raises
-- "Auras cannot be accessed when secret while tainted", and UNIT_AURA's payload is secret). So the buff
-- is read whenever the fight is over, and in the fight the row counts on from the last reading - which
-- is all a food buff does in a fight anyway: nothing can renew it there.
--
-- The row cannot re-eat for you: eating needs you seated and out of a fight, so the row says "rebuff"
-- and leaves the meal to you - for half an hour, then it leaves until the next meal: a reminder, not a
-- red line for life on a character who ate one buff food while leveling. The big button never flashes
-- for it.
local _, ns = ...

local Food = {}
ns.Food = Food

local FOOD_NAME = "well fed"
local REFRESH_EPSILON = 3 -- seconds a timer must jump up to count as re-applied
local NAG_SECONDS = 1800  -- a buff that ran out is flagged this long, then the row leaves until the next meal
local MAX_AURAS = 60

Food.ROW_KEY = "FOOD"
Food.SLOT = { key = "FOOD", name = "Food", order = 9 } -- no label: the row says "Food", and no hand letters join it
Food.HINT = "Well Fed, the buff of a meal. No reapply: eating needs you seated and out of a fight."

Food.current = nil  -- { spellID, name, icon, duration, expiresAt }
Food.locked = nil   -- why the auras could not be read: "combat", "secret", "error: ...", "no aura API"
Food.lastRead = nil -- GetTime() of the last reading

------------------------------------------------------------------------
-- Reading the auras - every answer may be secret, none is looked at before ns.IsSecret cleared it
------------------------------------------------------------------------
local function readAuras()
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(get) ~= "function" then
        return nil, "no aura API"
    end
    local list = {}
    for index = 1, MAX_AURAS do
        local ok, aura = pcall(get, "player", index, "HELPFUL")
        if not ok then
            return nil, "error: " .. tostring(aura)
        end
        if ns.IsSecret(aura) then
            return nil, "secret"
        end
        if type(aura) ~= "table" then
            break
        end
        local name, spellID, duration, expires, icon = aura.name, aura.spellId, aura.duration, aura.expirationTime, aura.icon
        if ns.AnySecret(name, spellID, duration, expires, icon) then
            return nil, "secret"
        end
        if type(name) == "string" and type(expires) == "number" then
            list[#list + 1] = { spellID = spellID, name = name, duration = duration, expiresAt = expires, icon = icon }
        end
    end
    return list
end

-- the food buff on you: the one called Well Fed; of two (it happens for a moment when one meal follows
-- another) the one that runs out first
local function pickFood(list)
    local best
    for _, aura in ipairs(list) do
        if string.lower(aura.name) == FOOD_NAME then
            if not best or aura.expiresAt < best.expiresAt then
                best = aura
            end
        end
    end
    return best
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------
function Food:Refresh(reason)
    if not ns.db then
        return
    end
    if ns.inCombat then
        self.locked = "combat" -- the auras are closed to addons in a fight: the row counts on from the last reading
        return
    end
    local list, err = readAuras()
    if not list then
        if self.locked ~= err then
            self.locked = err
            ns:Log("food_locked", err)
        end
        return
    end
    if self.locked then
        ns:Log("food_unlocked", reason)
        self.locked = nil
    end
    local now = GetTime()
    local aura = pickFood(list)
    local previous = self.current
    local current = aura and { spellID = aura.spellID, name = aura.name, icon = aura.icon, duration = aura.duration, expiresAt = aura.expiresAt } or nil
    self.current, self.lastRead = current, now
    local changed = (previous and previous.spellID) ~= (current and current.spellID)
        or (previous ~= nil and current ~= nil and current.expiresAt > previous.expiresAt + REFRESH_EPSILON)
    if current then
        local prefs = ns.cdb.food
        if not prefs then
            -- the first food buff seen on this character starts the tracking, as the first weapon buff does
            prefs = { track = true }
            ns.cdb.food = prefs
            ns:Log("food_tracked", { id = current.spellID })
            ns:Fire("PREFS_CHANGED")
        end
        prefs.lastIcon = current.icon
        prefs.ranOutAt = nil
    elseif previous and ns.cdb.food and not ns.cdb.food.ranOutAt then
        ns.cdb.food.ranOutAt = time() -- gone before its time: cancelled, or you died
    end
    if changed then
        ns:Log("food_changed", { id = current and current.spellID, left = current and math.floor(current.expiresAt - now), why = reason })
        ns:Fire("FOOD_CHANGED")
    end
end

------------------------------------------------------------------------
-- The row, for Tracker:BuildRows - its status is its own, there is no desire table behind it
------------------------------------------------------------------------
function Food:Row(now, warnSeconds)
    local prefs = ns.cdb.food
    local current = self.current
    if current and current.expiresAt <= now then
        -- ran out (in a fight, say): the reading will say so when it can; the clock on the reminder starts
        if prefs and not prefs.ranOutAt then
            prefs.ranOutAt = time() - math.floor(now - current.expiresAt)
        end
        current = nil
    end
    if not prefs and not current then
        return nil -- never had one: no row
    end
    local row = { rowKey = self.ROW_KEY, slotKey = self.SLOT.key, typeKey = "FOOD", slot = self.SLOT, food = true }
    if current then
        row.entry = current
        row.remaining = math.max(0, current.expiresAt - now)
        row.fullDuration = math.max(type(current.duration) == "number" and current.duration or 0, row.remaining, 1)
        row.name, row.icon = current.name, current.icon
    end
    if prefs and prefs.track == false then
        row.untracked = true
        if current then
            row.status = "INFO"
        else
            row.status, row.placeholder = "UNTRACKED", true
        end
        row.icon = row.icon or prefs.lastIcon
        return row
    end
    row.desire = { key = "food:" .. FOOD_NAME, pinned = false }
    row.desiredName = "Well Fed"
    row.desiredIcon = prefs and prefs.lastIcon
    if not current then
        prefs.ranOutAt = prefs.ranOutAt or time()
        if time() - prefs.ranOutAt > NAG_SECONDS then
            return nil -- flagged long enough: the row leaves until the next meal
        end
        row.status = "MISSING"
    else
        row.status = (row.remaining <= warnSeconds) and "LOW" or "OK"
    end
    return row
end

------------------------------------------------------------------------
-- Preferences, per character: ns.cdb.food = { track, lastIcon, ranOutAt }
------------------------------------------------------------------------
local function prefs()
    local saved = ns.cdb.food or {}
    ns.cdb.food = saved
    return saved
end

function Food:SetAuto()
    prefs().track = true
    ns:Log("food_prefs", { track = true })
    self:Refresh("prefs")
    ns:Fire("PREFS_CHANGED")
end

function Food:SetNone()
    prefs().track = false
    ns:Log("food_prefs", { track = false })
    self:Refresh("prefs")
    ns:Fire("PREFS_CHANGED")
end

------------------------------------------------------------------------
-- The picker's entries and the row's tooltip, for the UI
------------------------------------------------------------------------
function Food:PickerOptions(row)
    return {
        {
            text = "Track Well Fed",
            checked = not row.untracked,
            select = function()
                Food:SetAuto()
            end,
        },
        {
            text = "Don't track this",
            checked = row.untracked and true or false,
            select = function()
                Food:SetNone()
            end,
        },
    }
end

local function formatTime(seconds)
    local format = ns.PlayerFrame and ns.PlayerFrame.FormatTime
    if format then
        return format(seconds)
    end
    return tostring(math.floor(seconds)) .. "s"
end

function Food:FillTooltip(tooltip, data)
    tooltip:SetText("Food")
    tooltip:AddLine(self.HINT, 0.7, 0.7, 0.7, true)
    if data.entry then
        tooltip:AddLine("Now: " .. (data.name or "Well Fed") .. " (" .. formatTime(data.remaining or 0) .. " left)", 1, 1, 1, true)
    else
        tooltip:AddLine("Now: nothing", 1, 1, 1)
    end
    if self.locked == "combat" then
        tooltip:AddLine("In a fight the buffs cannot be read: counting on from the last look.", 0.6, 0.6, 0.6, true)
    end
    if data.untracked then
        tooltip:AddLine("Not tracked", 0.6, 0.6, 0.6)
    else
        tooltip:AddLine("Tracking: Well Fed - rebuff for half an hour after it runs out, then the row leaves until the next meal", 1, 0.82, 0, true)
    end
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
ns:OnPlayerUnit("UNIT_AURA", function()
    Food:Refresh("UNIT_AURA")
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    Food:Refresh("entering world")
end)

ns:Listen("LOGIN", function()
    Food:Refresh("login")
end)

ns:Listen("COMBAT_END", function()
    Food:Refresh("combat end")
end)

ns:RegisterCommand("food", "the food buff row: /wb food on | off", function(rest)
    local word = string.lower(string.match(rest or "", "^%s*(%S*)") or "")
    if word == "on" then
        Food:SetAuto()
        ns:Print("the food buff is tracked: Well Fed, with a rebuff reminder for half an hour after it runs out.")
    elseif word == "off" then
        Food:SetNone()
        ns:Print("the food buff is not tracked - |cffffd100/wb food on|r brings it back.")
    else
        local saved = ns.cdb.food
        local state
        if not saved then
            state = "not seen on this character yet - eat something that leaves Well Fed and the row appears."
        elseif saved.track == false then
            state = "not tracked (|cffffd100/wb food on|r)."
        else
            state = "tracked."
        end
        ns:Print("food buff:", state)
        local current = Food.current
        local now = current and ("Well Fed, " .. formatTime(math.max(0, current.expiresAt - GetTime())) .. " left") or "nothing"
        ns:Print("now:", now .. (Food.locked and (" (auras not readable: " .. Food.locked .. ")") or ""))
    end
end)
