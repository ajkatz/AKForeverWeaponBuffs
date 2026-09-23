-- Sources: learns WHAT applies each weapon enchant, with no hardcoded ID tables.
--
-- When an enchant appears on a weapon we look at what the player just cast:
--   * an item use-spell that belongs to something in the bags  -> item source
--   * a spell from the spellbook                               -> spell source
-- and only accept the pairing when the enchant's tooltip name agrees with the
-- candidate's name ("Windfury Weapon" ~ "Windfury 4") - or, failing that, when
-- the buff wears that candidate's own icon. A fishing lure needs the second way:
-- the enchant it leaves calls itself "Fishing Lure" and never once mentions the
-- Shiny Bauble that made it, but it does carry the bauble's icon.
-- Short lived enchants (totem pulses such as Windfury Totem) are never
-- learned: they are "pulsed", which is also what the party panel uses to show
-- who is getting Windfury.
local _, ns = ...

local Sources = {}
ns.Sources = Sources

local ATTRIBUTION_DELAY = 0.25 -- let the cast event and tooltip catch up
local CAST_WINDOW_BEFORE = 2.0
local CAST_WINDOW_AFTER = 0.35
local MIN_SELF_DURATION = 60   -- anything shorter is a pulsed (totem) buff
local CAST_LOG_MAX = 8

local castLog = {}

------------------------------------------------------------------------
-- Name matching
------------------------------------------------------------------------
local function significantWords(text)
    local words = {}
    for word in string.gmatch(string.lower(text), "[^%s%p%d]+") do
        if #word >= 4 then
            words[#words + 1] = word
        end
    end
    return words
end

local function commonPrefixLength(a, b)
    local limit = math.min(#a, #b)
    for i = 1, limit do
        if string.byte(a, i) ~= string.byte(b, i) then
            return i - 1
        end
    end
    return limit
end

-- "Dense Sharpening Stone" ~ "Sharpened (+8 Damage)", "Windfury Weapon" ~ "Windfury 4"
function Sources.NamesOverlap(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local wordsB = significantWords(b)
    for _, wordA in ipairs(significantWords(a)) do
        for _, wordB in ipairs(wordsB) do
            if wordA == wordB or commonPrefixLength(wordA, wordB) >= 5 then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Tooltip: the only place the client tells us an enchant's name
------------------------------------------------------------------------
local EXCLUDED_PREFIXES = {}
for _, globalName in ipairs({ "ITEM_SPELL_TRIGGER_ONUSE", "ITEM_SPELL_TRIGGER_ONEQUIP", "ITEM_SPELL_TRIGGER_ONPROC" }) do
    local text = _G[globalName]
    if type(text) == "string" and text ~= "" then
        EXCLUDED_PREFIXES[#EXCLUDED_PREFIXES + 1] = text
    end
end

local function isExcludedLine(text)
    for _, prefix in ipairs(EXCLUDED_PREFIXES) do
        if string.sub(text, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

-- Lines shaped like "Windfury 4 (29 min)" -> { name = "Windfury 4", raw = ... }
function Sources:ReadEnchantLines(invSlot)
    local lines = {}
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then
        return lines
    end
    local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", invSlot)
    if not ok or type(data) ~= "table" or ns.IsSecret(data) or type(data.lines) ~= "table" then
        return lines
    end
    for _, line in ipairs(data.lines) do
        local text = type(line) == "table" and line.leftText
        if type(text) == "string" and not ns.IsSecret(text) and #text <= 80 and not isExcludedLine(text) then
            local name = string.match(text, "^(.-)%s*%(%d+%s*[^%d%(%)]+%)$")
            if name and name ~= "" then
                lines[#lines + 1] = { name = name, raw = text, lineType = line.type }
            end
        end
    end
    return lines
end

------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------
function Sources:GetForEnchant(enchantID)
    return ns.db.sources[enchantID]
end

function Sources:IsPulsed(enchantID)
    return ns.db.pulsed[enchantID] and true or false
end

function Sources:GetByKey(key)
    if not key then
        return nil
    end
    local best, bestID
    for enchantID, source in pairs(ns.db.sources) do
        if source.key == key and (not bestID or enchantID > bestID) then
            best, bestID = source, enchantID
        end
    end
    return best
end

-- Unique sources (by key) usable for a row type, for the picker.
function Sources:ListForType(typeKey)
    local seen, list = {}, {}
    for _, source in pairs(ns.db.sources) do
        if not seen[source.key] and (not typeKey or not source.typeKey or source.typeKey == typeKey) then
            seen[source.key] = true
            list[#list + 1] = source
        end
    end
    table.sort(list, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return list
end

function Sources:Forget(key)
    local removed = 0
    for enchantID, source in pairs(ns.db.sources) do
        if source.key == key then
            ns.db.sources[enchantID] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        ns:Log("source_forgotten", key)
        ns:Fire("SOURCES_CHANGED")
    end
    return removed
end

function Sources:GetDisplay(source)
    local name, icon
    if source.kind == "item" then
        name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(source.itemID)
        icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(source.itemID)
    else
        name = C_Spell.GetSpellName and C_Spell.GetSpellName(source.spellID)
        icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(source.spellID)
    end
    return name or source.name or "?", icon or source.icon
end

-- available, count (count only for items)
function Sources:GetAvailability(source)
    if source.kind == "item" then
        local count = (C_Item.GetItemCount and C_Item.GetItemCount(source.itemID)) or 0
        return count > 0, count
    end
    return Sources.IsKnownSpell(source.spellID), nil
end

function Sources:GetEnchantName(enchantID)
    local source = ns.db.sources[enchantID]
    if source then
        return (Sources:GetDisplay(source))
    end
    return ns.db.enchantNames[enchantID]
end

function Sources.IsKnownSpell(spellID)
    if not spellID then
        return false
    end
    local book = C_SpellBook
    local check = book and (book.IsSpellKnownOrInSpellBook or book.IsSpellKnown or book.IsSpellInSpellBook)
    if check then
        local ok, known = pcall(check, spellID)
        return ok and known and true or false
    end
    if IsPlayerSpell then
        return IsPlayerSpell(spellID) and true or false
    end
    return false
end

------------------------------------------------------------------------
-- Bag index: [use spellID] = itemID, so a cast can be traced to an item even
-- after the last one in the stack was consumed.
------------------------------------------------------------------------
local indexedItems = {}

function Sources:IndexBags()
    if not (C_Container and C_Container.GetContainerNumSlots and C_Item and C_Item.GetItemSpell) then
        return
    end
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID and not indexedItems[itemID] then
                local _, spellID = C_Item.GetItemSpell(itemID)
                if spellID then
                    ns.db.itemSpells[spellID] = itemID
                    indexedItems[itemID] = true
                elseif C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(itemID) then
                    indexedItems[itemID] = true -- loaded, simply has no use effect
                elseif C_Item.RequestLoadItemDataByID then
                    C_Item.RequestLoadItemDataByID(itemID) -- retried on the next bag update
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Attribution
------------------------------------------------------------------------
local function describeCast(spellID)
    local itemID = ns.db.itemSpells[spellID]
    local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if itemID then
        local itemName = C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
        return { kind = "item", itemID = itemID, spellID = spellID, name = itemName or spellName, altName = spellName }
    end
    if Sources.IsKnownSpell(spellID) and spellName then
        return { kind = "spell", spellID = spellID, name = spellName }
    end
    return nil
end

local function candidatesAround(appliedAt)
    local candidates = {}
    for i = #castLog, 1, -1 do
        local cast = castLog[i]
        if cast.t >= appliedAt - CAST_WINDOW_BEFORE and cast.t <= appliedAt + CAST_WINDOW_AFTER then
            local candidate = describeCast(cast.spellID)
            if candidate then
                candidates[#candidates + 1] = candidate
            end
        end
    end
    return candidates
end

-- Tooltip lines on this weapon that no other enchant already explains.
local function unclaimedLines(entry, lines)
    local unclaimed = {}
    for _, line in ipairs(lines) do
        local claimed = false
        for _, other in pairs(ns.Enchants.rows) do
            if other.rowKey ~= entry.rowKey and other.invSlot == entry.invSlot then
                local otherName = Sources:GetEnchantName(other.enchantID)
                if otherName and Sources.NamesOverlap(otherName, line.name) then
                    claimed = true
                end
            end
        end
        if not claimed then
            unclaimed[#unclaimed + 1] = line
        end
    end
    return unclaimed
end

local function learn(entry, candidate, how)
    local name = candidate.name
    local source = {
        kind = candidate.kind,
        spellID = candidate.spellID,
        itemID = candidate.itemID,
        name = name,
        typeKey = entry.typeKey,
        icon = entry.iconID,
        key = candidate.kind == "item" and ("item:" .. candidate.itemID) or ("spell:" .. name),
        how = how,
    }
    ns.db.sources[entry.enchantID] = source
    ns:Log("source_learned", { id = entry.enchantID, key = source.key, row = entry.rowKey, how = how })
    ns:Fire("SOURCES_CHANGED")
    return source
end

-- The icon the client hands us with the buff is the icon of the thing that made it: that is how a fishing
-- lure gives itself away, since its name never will.
local function iconOf(candidate)
    local icon
    if candidate.kind == "item" then
        icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(candidate.itemID)
    else
        icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(candidate.spellID)
    end
    if icon and not ns.IsSecret(icon) then
        return icon
    end
end

local function attribute(entry, appliedAt, inCombatAtApply)
    local enchantID = entry.enchantID
    if ns.db.sources[enchantID] then
        return
    end

    local lines = unclaimedLines(entry, Sources:ReadEnchantLines(entry.invSlot))
    local candidates = candidatesAround(appliedAt)

    -- 1) a candidate whose name agrees with a tooltip line
    local chosen, tooltipName, how
    for _, line in ipairs(lines) do
        for _, candidate in ipairs(candidates) do
            if Sources.NamesOverlap(line.name, candidate.name) or Sources.NamesOverlap(line.name, candidate.altName) then
                chosen, tooltipName, how = candidate, line.name, "the names agree"
                break
            end
        end
        if chosen then
            break
        end
    end
    if not tooltipName and #lines == 1 then
        tooltipName = lines[1].name
    end

    -- 2) no tooltip to check against: only trust quiet, out of combat moments,
    --    where nothing but the player's own cast puts a long buff on a weapon
    if not chosen and #lines == 0 and not inCombatAtApply then
        chosen, how = candidates[1], "nothing else put a buff on that weapon" -- most recent cast
    end

    -- 3) the names do not agree and never will - a fishing lure leaves "Fishing Lure (10 min)" on the pole
    --    and says nothing about the Shiny Bauble that made it. The icon does: the buff wears the icon of
    --    whatever made it, so an icon matching something used a moment ago settles it. (A potion drunk as
    --    a poison lands has neither the name nor the icon, and is still left alone.)
    if not chosen and entry.iconID and not ns.IsSecret(entry.iconID) then
        for _, candidate in ipairs(candidates) do -- most recent first
            if iconOf(candidate) == entry.iconID then
                chosen, how = candidate, "the buff wears its icon"
                break
            end
        end
    end

    if tooltipName and not ns.db.enchantNames[enchantID] then
        ns.db.enchantNames[enchantID] = tooltipName
        ns:Fire("SOURCES_CHANGED")
    end

    if chosen then
        local source = learn(entry, chosen, how)
        ns:Fire("SOURCE_APPLIED", entry.rowKey, source)
    else
        ns:Log("source_unknown", { id = enchantID, row = entry.rowKey, candidates = #candidates, lines = #lines, icon = entry.iconID })
    end
end

------------------------------------------------------------------------
-- Full durations: the client only reports time LEFT, so the length of a buff is
-- whatever we saw at its longest. Keeping the maximum (rather than the latest)
-- means a half-expired weapon swapped back in does not shrink the timer bar.
------------------------------------------------------------------------
local DURATION_STEP = 5 -- round to the nearest 5s: absorbs detection lag (1799.2 -> 1800)
                        -- and float jitter (3600.0000000002 must not become 3605)

local function recordDuration(enchantID, seconds)
    local rounded = math.floor(seconds / DURATION_STEP + 0.5) * DURATION_STEP
    if rounded > (ns.db.durations[enchantID] or 0) then
        ns.db.durations[enchantID] = rounded
    end
end

-- Scale for a timer bar. Never smaller than what is left right now, so a buff we
-- first meet mid-way (already up at login) starts as a full bar.
function Sources:GetFullDuration(enchantID, remaining)
    local full = ns.db.durations[enchantID] or 0
    if full < remaining then
        full = remaining
    end
    return math.max(full, 1)
end

ns:Listen("ENCHANT_APPLIED", function(_, entry, info)
    local enchantID = entry.enchantID
    local duration = entry.expiresAt - info.at
    recordDuration(enchantID, duration)

    -- Pulsed = (re)applied with under a minute on the clock, by something we never
    -- saw the player cast. A login snapshot proves nothing either way, and one
    -- long application clears a wrong verdict (e.g. a weapon swapped back in
    -- with 40s left on its imbue).
    if duration >= MIN_SELF_DURATION then
        if ns.db.pulsed[enchantID] then
            ns.db.pulsed[enchantID] = nil
            ns:Fire("SOURCES_CHANGED")
        end
    elseif not info.initial and not ns.db.sources[enchantID] and not ns.db.pulsed[enchantID] then
        ns.db.pulsed[enchantID] = true
        ns:Log("pulsed_learned", { id = enchantID, duration = math.floor(duration) })
        ns:Fire("SOURCES_CHANGED")
    end

    local known = ns.db.sources[enchantID]
    if known then
        if not info.initial then
            ns:Fire("SOURCE_APPLIED", entry.rowKey, known)
        end
        return
    end

    local pulsed = ns.db.pulsed[enchantID]
    local inCombatAtApply = ns.inCombat
    C_Timer.After(ATTRIBUTION_DELAY, function()
        ns.SafeCall(function()
            -- A refresh of a buff we could not explain yet (it was already there at
            -- login, say) is as good a moment to learn it as a first application.
            if pulsed or info.initial then
                -- Nothing to learn, but a name for the display is still welcome.
                if not ns.db.enchantNames[enchantID] then
                    local lines = unclaimedLines(entry, Sources:ReadEnchantLines(entry.invSlot))
                    if #lines == 1 then
                        ns.db.enchantNames[enchantID] = lines[1].name
                        ns:Fire("SOURCES_CHANGED")
                    end
                end
                return
            end
            attribute(entry, info.at, inCombatAtApply)
        end)
    end)
end)

ns:OnPlayerUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
    if ns.IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    castLog[#castLog + 1] = { spellID = spellID, t = GetTime() }
    if #castLog > CAST_LOG_MAX then
        table.remove(castLog, 1)
    end
end)

ns:On("BAG_UPDATE_DELAYED", function()
    Sources:IndexBags()
end)

ns:Listen("LOGIN", function()
    Sources:IndexBags()
end)

ns:RegisterCommand("forget", "forget everything learned about which spell/item applies which buff", function()
    local count = 0
    for enchantID in pairs(ns.db.sources) do
        ns.db.sources[enchantID] = nil
        count = count + 1
    end
    for enchantID in pairs(ns.db.pulsed) do
        ns.db.pulsed[enchantID] = nil
    end
    for enchantID in pairs(ns.db.durations) do
        ns.db.durations[enchantID] = nil
    end
    ns:Print("forgot", count, "learned buff sources.")
    ns:Fire("SOURCES_CHANGED")
end)
