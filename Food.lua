-- Food: your food (and drink) buff, tracked beside the weapon buffs - the Well Fed of a raid night.
--
-- A food buff is an aura on you, and on this client an aura is readable OUT OF COMBAT ONLY: in a fight
-- the list cannot be touched at all (measured by AKForeverCombatTimers, 2026-09-20: a lookup raises
-- "Auras cannot be accessed when secret while tainted", and UNIT_AURA's payload is secret). So the buff
-- is read whenever the fight is over, and in the fight the row counts on from the last reading - which
-- is all a food buff does in a fight anyway: nothing can renew it there.
--
-- Which buffs are food? One name is built in, "Well Fed", the name most foods give their buff. The rest
-- is learned the way weapon buffs are: a buff that turns up on you within seconds of eating or drinking
-- something from the bags (an item of the Food & Drink kind) and lasts minutes is a food buff from then
-- on - Blessed Sunfruit, Rumsey Rum Black Label, a Forever feast. One meal teaches one buff, the first
-- to turn up. The row cannot re-eat for you: eating needs you seated and out of a fight, so the row says
-- "rebuff" and leaves the meal to you - and the big button never flashes for it.
local _, ns = ...

local Food = {}
ns.Food = Food

local MIN_DURATION = 300  -- seconds: a food buff lasts minutes; shorter is the eating itself, or a snack's heal
local MEAL_WINDOW = 12    -- seconds after a meal in which a new buff is taken for its buff (some foods want ten seconds of eating)
local REFRESH_EPSILON = 3 -- seconds a timer must jump up to count as re-applied
local MAX_AURAS = 60
local MEALS_MAX = 6
local ITEM_CLASS_CONSUMABLE = 0
local SUBCLASS_FOOD_AND_DRINK, SUBCLASS_GENERIC = 5, 0
local SEED_NAMES = { ["well fed"] = true }

Food.ROW_KEY = "FOOD"
Food.SLOT = { key = "FOOD", name = "Food", order = 9 } -- no label: the row says "Food", and no hand letters join it
Food.HINT = "Well Fed and the like, learned from what you eat or drink. No reapply: eating needs you seated."

Food.current = nil  -- { spellID, name, icon, duration, expiresAt }
Food.locked = nil   -- why the auras could not be read: "combat", "secret", "error: ...", "no aura API"
Food.lastRead = nil -- GetTime() of the last reading
Food.meals = {}     -- { at, itemID, name, used } - what was eaten or drunk lately, newest last
local snapshot = {} -- [spellID] = expiresAt at the last reading: what is new since

------------------------------------------------------------------------
-- What counts as food
------------------------------------------------------------------------
local function lowerName(name)
    return type(name) == "string" and string.lower(name) or nil
end

local function isFoodBuff(aura)
    if ns.db.foodBuffs[aura.spellID] then
        return true
    end
    local lower = lowerName(aura.name)
    return lower ~= nil and (SEED_NAMES[lower] or ns.db.foodNames[lower]) and true or false
end

-- an item you eat or drink: Consumable, of the Food & Drink kind (or the plain kind older data uses)
local function isFoodItem(itemID)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(getInstant) ~= "function" then
        return false
    end
    local ok, _, _, _, _, _, classID, subclassID = pcall(getInstant, itemID)
    if not ok or ns.AnySecret(classID, subclassID) then
        return false
    end
    return classID == ITEM_CLASS_CONSUMABLE and (subclassID == SUBCLASS_FOOD_AND_DRINK or subclassID == SUBCLASS_GENERIC)
end

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
        local name, spellID, duration, expires, icon, source = aura.name, aura.spellId, aura.duration, aura.expirationTime, aura.icon, aura.sourceUnit
        if ns.AnySecret(name, spellID, duration, expires, icon, source) then
            return nil, "secret"
        end
        if type(spellID) == "number" and type(expires) == "number" then
            list[#list + 1] = { spellID = spellID, name = name, duration = duration, expiresAt = expires, icon = icon, source = source }
        end
    end
    return list
end

------------------------------------------------------------------------
-- Meals: an item of the food kind used a moment ago explains the buff that follows
------------------------------------------------------------------------
local function mealBefore(at)
    for index = #Food.meals, 1, -1 do
        local meal = Food.meals[index]
        if not meal.used and meal.at <= at + 0.5 and meal.at >= at - MEAL_WINDOW then
            return meal
        end
    end
    return nil
end

local function learnFrom(list, now)
    for _, aura in ipairs(list) do
        local previous = snapshot[aura.spellID]
        local fresh = not previous or aura.expiresAt > previous + REFRESH_EPSILON
        local own = aura.source == nil or aura.source == "player"
        if fresh and own and type(aura.duration) == "number" and aura.duration >= MIN_DURATION then
            local known = ns.db.foodBuffs[aura.spellID]
            if not known or not known.itemID then
                local meal = mealBefore(now)
                if meal then
                    meal.used = true
                    ns.db.foodBuffs[aura.spellID] = {
                        name = aura.name, icon = aura.icon, itemID = meal.itemID, itemName = meal.name, how = "followed a meal",
                    }
                    ns:Log("food_learned", { id = aura.spellID, name = aura.name, item = meal.itemID })
                    ns:Fire("SOURCES_CHANGED")
                end
            end
        end
    end
end

-- the food buff to show: the pinned one when it is on, else the one that runs out first
local function pickFood(list)
    local pinned = ns.cdb.food and ns.cdb.food.pinned
    local best
    for _, aura in ipairs(list) do
        if isFoodBuff(aura) then
            if pinned and aura.spellID == pinned then
                return aura
            end
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
    if not (ns.db and ns.db.foodBuffs) then
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
    learnFrom(list, now)
    local aura = pickFood(list)
    local previous = self.current
    local current = aura and { spellID = aura.spellID, name = aura.name, icon = aura.icon, duration = aura.duration, expiresAt = aura.expiresAt } or nil
    self.current, self.lastRead = current, now
    snapshot = {}
    for _, each in ipairs(list) do
        snapshot[each.spellID] = each.expiresAt
    end
    local changed = (previous and previous.spellID) ~= (current and current.spellID)
        or (previous ~= nil and current ~= nil and current.expiresAt > previous.expiresAt + REFRESH_EPSILON)
    if current then
        local prefs = ns.cdb.food
        if not prefs then
            -- the first food buff seen on this character starts the tracking, as the first weapon buff does
            prefs = { track = true }
            ns.cdb.food = prefs
            ns:Log("food_tracked", { id = current.spellID, name = current.name })
            ns:Fire("PREFS_CHANGED")
        end
        prefs.lastName, prefs.lastIcon, prefs.lastSpellID = current.name, current.icon, current.spellID
    end
    if changed then
        ns:Log("food_changed", {
            id = current and current.spellID, name = current and current.name,
            left = current and math.floor(current.expiresAt - now), why = reason,
        })
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
        current = nil -- ran out (in a fight, say): the reading will say so when it can
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
    local pinned = prefs and prefs.pinned
    local known = pinned and ns.db.foodBuffs[pinned]
    row.desire = { key = pinned and ("food:" .. pinned) or "food:any", pinned = pinned and true or false }
    row.desiredName = (known and known.name) or (prefs and prefs.lastName) or "food buff"
    row.desiredIcon = (known and known.icon) or (prefs and prefs.lastIcon)
    if not current then
        row.status = "MISSING"
    elseif pinned and current.spellID ~= pinned then
        row.status = "WRONG"
    else
        row.status = (row.remaining <= warnSeconds) and "LOW" or "OK"
    end
    return row
end

------------------------------------------------------------------------
-- Preferences, per character: ns.cdb.food = { track, pinned, lastName, lastIcon, lastSpellID }
------------------------------------------------------------------------
local function prefs()
    local saved = ns.cdb.food or {}
    ns.cdb.food = saved
    return saved
end

function Food:SetAuto()
    local saved = prefs()
    saved.track, saved.pinned = true, nil
    ns:Log("food_prefs", { track = true })
    self:Refresh("prefs") -- the pick follows the preference at once (out of a fight)
    ns:Fire("PREFS_CHANGED")
end

function Food:Pin(spellID)
    local saved = prefs()
    saved.track, saved.pinned = true, spellID
    ns:Log("food_prefs", { track = true, pinned = spellID })
    self:Refresh("prefs") -- the pick follows the preference at once (out of a fight)
    ns:Fire("PREFS_CHANGED")
end

function Food:SetNone()
    local saved = prefs()
    saved.track, saved.pinned = false, nil
    ns:Log("food_prefs", { track = false })
    self:Refresh("prefs") -- the pick follows the preference at once (out of a fight)
    ns:Fire("PREFS_CHANGED")
end

function Food:Forget(spellID)
    if not ns.db.foodBuffs[spellID] then
        return false
    end
    ns.db.foodBuffs[spellID] = nil
    if ns.cdb.food and ns.cdb.food.pinned == spellID then
        ns.cdb.food.pinned = nil
    end
    ns:Log("food_forgotten", spellID)
    ns:Fire("SOURCES_CHANGED")
    return true
end

function Food:ForgetAll()
    local count = 0
    for spellID in pairs(ns.db.foodBuffs) do
        ns.db.foodBuffs[spellID] = nil
        count = count + 1
    end
    for lower in pairs(ns.db.foodNames) do
        ns.db.foodNames[lower] = nil
    end
    if ns.cdb.food then
        ns.cdb.food.pinned = nil
    end
    ns:Log("food_forgotten", "all")
    ns:Fire("SOURCES_CHANGED")
    return count
end

-- a buff the addon never saw follow a meal, named by hand: /wb food add <name>
function Food:AddName(name)
    local lower = lowerName(name)
    if not lower or lower == "" then
        return false
    end
    ns.db.foodNames[lower] = true
    ns:Log("food_name_added", lower)
    ns:Fire("SOURCES_CHANGED")
    return true
end

-- what is known, sorted by name, for the picker and /wb food
function Food:Learned()
    local list = {}
    for spellID, known in pairs(ns.db.foodBuffs) do
        list[#list + 1] = { spellID = spellID, name = known.name, icon = known.icon, itemName = known.itemName }
    end
    table.sort(list, function(a, b)
        if (a.name or "") ~= (b.name or "") then
            return (a.name or "") < (b.name or "")
        end
        return (a.itemName or "") < (b.itemName or "")
    end)
    return list
end

------------------------------------------------------------------------
-- The picker's entries and the row's tooltip, for the UI
------------------------------------------------------------------------
function Food:PickerOptions(row)
    local saved = ns.cdb.food
    local options = {}
    options[#options + 1] = {
        text = "Auto: any food buff",
        checked = not row.untracked and not (saved and saved.pinned),
        select = function()
            Food:SetAuto()
        end,
    }
    for _, known in ipairs(self:Learned()) do
        local text = known.name or ("spell " .. known.spellID)
        if known.itemName then
            text = text .. " |cffaaaaaa(" .. known.itemName .. ")|r"
        end
        local spellID = known.spellID
        options[#options + 1] = {
            text = text,
            icon = known.icon,
            checked = saved and saved.pinned == spellID or false,
            select = function()
                Food:Pin(spellID)
            end,
            forget = function()
                Food:Forget(spellID)
            end,
        }
    end
    options[#options + 1] = {
        text = "Don't track this",
        checked = row.untracked and true or false,
        select = function()
            Food:SetNone()
        end,
    }
    return options
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
        tooltip:AddLine("Now: " .. (data.name or "food buff") .. " (" .. formatTime(data.remaining or 0) .. " left)", 1, 1, 1, true)
    else
        tooltip:AddLine("Now: nothing", 1, 1, 1)
    end
    if self.locked == "combat" then
        tooltip:AddLine("In a fight the buffs cannot be read: counting on from the last look.", 0.6, 0.6, 0.6, true)
    end
    if data.untracked then
        tooltip:AddLine("Not tracked", 0.6, 0.6, 0.6)
    elseif data.desire and data.desire.pinned then
        tooltip:AddLine("Tracking: " .. (data.desiredName or "?") .. " (pinned)", 1, 0.82, 0, true)
    else
        tooltip:AddLine("Tracking: any food buff (auto - whatever you eat)", 1, 0.82, 0, true)
    end
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" or not ns.db then
        return
    end
    local itemID = ns.db.itemSpells[spellID]
    if not itemID or not isFoodItem(itemID) then
        return
    end
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if ns.IsSecret(name) then
        name = nil
    end
    local meals = Food.meals
    meals[#meals + 1] = { at = GetTime(), itemID = itemID, name = name }
    if #meals > MEALS_MAX then
        table.remove(meals, 1)
    end
    ns:Log("meal", { item = itemID, name = name })
end)

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

ns:RegisterCommand("food", "the food buff row: /wb food on | off | forget | add <buff name>", function(rest)
    local word, argument = string.match(rest or "", "^(%S*)%s*(.-)%s*$")
    word = string.lower(word or "")
    if word == "on" then
        Food:SetAuto()
        ns:Print("the food buff is tracked: whatever you eat, Well Fed and the like.")
    elseif word == "off" then
        Food:SetNone()
        ns:Print("the food buff is not tracked - |cffffd100/wb food on|r brings it back.")
    elseif word == "forget" then
        local count = Food:ForgetAll()
        ns:Print("forgot", count, "learned food buffs and every added name; Well Fed is still known by name.")
    elseif word == "add" and argument ~= "" then
        Food:AddName(argument)
        ns:Print("\"" .. argument .. "\" counts as a food buff from now on.")
    else
        local saved = ns.cdb.food
        local state
        if not saved then
            state = "not seen on this character yet - eat something that leaves a buff and the row appears."
        elseif saved.track == false then
            state = "not tracked (|cffffd100/wb food on|r)."
        elseif saved.pinned then
            local known = ns.db.foodBuffs[saved.pinned]
            state = "pinned to " .. (known and known.name or ("spell " .. saved.pinned)) .. "."
        else
            state = "tracked - any food buff."
        end
        ns:Print("food buff:", state)
        local current = Food.current
        local now = current and (current.name .. ", " .. formatTime(math.max(0, current.expiresAt - GetTime())) .. " left") or "nothing"
        ns:Print("now:", now .. (Food.locked and (" (auras not readable: " .. Food.locked .. ")") or ""))
        local names = {}
        for _, known in ipairs(Food:Learned()) do
            names[#names + 1] = (known.name or "?") .. (known.itemName and (" (" .. known.itemName .. ")") or "")
        end
        for lower in pairs(ns.db.foodNames) do
            names[#names + 1] = lower .. " (added)"
        end
        ns:Print("known:", #names > 0 and table.concat(names, ", ") or "nothing learned yet", "- and Well Fed by name.")
        ns:Print("|cffffd100/wb food on|r, |cffffd100off|r, |cffffd100forget|r, |cffffd100add <buff name>|r")
    end
end)
