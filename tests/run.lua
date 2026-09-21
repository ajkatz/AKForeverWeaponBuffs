-- AKForeverWeaponBuffs scenario tests. Run from the repo root:
--     lua tests/run.lua
-- Every scenario loads a fresh copy of the addon into the mock client, and fails
-- if the addon raised ANY Lua error along the way (caught or not).
package.path = "./tests/?.lua;" .. package.path
local Mock = require("wowmock")

local failures, passed = {}, 0
local current

local function check(condition, message)
    if not condition then
        error(message or "check failed", 2)
    end
end

local function equal(actual, expected, what)
    if actual ~= expected then
        error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function near(actual, expected, tolerance, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error((what or "value") .. ": expected about " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function scenario(name, fn)
    current = name
    local ok, err = xpcall(fn, debug.traceback)
    if ok and #Mock.errors > 0 then
        ok, err = false, "addon raised errors:\n      " .. table.concat(Mock.errors, "\n      ")
    end
    if ok and #Mock.forbiddenCalls > 0 then
        ok, err = false, "addon triggered a forbidden action (the client would show the 'blocked' dialog): "
            .. table.concat(Mock.forbiddenCalls, ", ")
    end
    if ok then
        passed = passed + 1
        Mock.realPrint("  ok    " .. name)
    else
        failures[#failures + 1] = name
        Mock.realPrint("  FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
end

-- Fixtures ----------------------------------------------------------------
local WF_SPELL, RB_SPELL, FT_SPELL, SS_SPELL = 8232, 8017, 8024, 1752
local OIL_ITEM, OIL_SPELL, POTION_ITEM, POTION_SPELL = 20748, 25123, 13446, 17534
local MACE_2H, AXE_1H, DAGGER_1H, SHIELD, POLE, KNIFE = 1001, 2001, 2002, 3001, 6256, 7005

local function fixtures(state)
    state.spells[WF_SPELL] = { name = "Windfury Weapon", icon = 136018, known = true }
    state.spells[RB_SPELL] = { name = "Rockbiter Weapon", icon = 136086, known = true }
    state.spells[FT_SPELL] = { name = "Flametongue Weapon", icon = 135814, known = true }
    state.spells[SS_SPELL] = { name = "Sinister Strike", icon = 136189, known = true }
    state.spells[OIL_SPELL] = { name = "Brilliant Mana Oil", icon = 134727, known = false }
    state.spells[POTION_SPELL] = { name = "Healing Potion", icon = 134834, known = false }
    state.items[MACE_2H] = { name = "Big Mace", equipLoc = "INVTYPE_2HWEAPON", classID = 2, subclassID = 5, icon = 1 }
    state.items[AXE_1H] = { name = "Axe", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 0, icon = 2 }
    state.items[DAGGER_1H] = { name = "Dagger", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 15, icon = 3 }
    state.items[SHIELD] = { name = "Shield", equipLoc = "INVTYPE_SHIELD", classID = 4, subclassID = 6, icon = 4 }
    state.items[POLE] = { name = "Fishing Pole", equipLoc = "INVTYPE_2HWEAPON", classID = 2, subclassID = 20, icon = 5 }
    state.items[KNIFE] = { name = "Skinning Knife", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 15, icon = 6, count = 0 }
    state.items[OIL_ITEM] = { name = "Brilliant Mana Oil", icon = 134727, spellID = OIL_SPELL, count = 3 }
    state.items[POTION_ITEM] = { name = "Major Healing Potion", icon = 134834, spellID = POTION_SPELL, count = 5 }
end

local function enchant(enchantType, enchantID, seconds, icon)
    return { hasEnchant = true, enchantType = enchantType, timeLeft = seconds * 1000, charges = 0, enchantID = enchantID, enchantIconID = icon or 136018 }
end
local IMBUE, TEMP = 3, 2

local function start(options, setup)
    options = options or {}
    options.login = false
    local ns, state = Mock.install(options)
    fixtures(state)
    if setup then
        setup(state)
    end
    Mock.fire("ADDON_LOADED", "AKForeverWeaponBuffs")
    Mock.fire("PLAYER_LOGIN")
    Mock.fire("PLAYER_ENTERING_WORLD", true, false)
    Mock.advance(0.1)
    return ns, state
end

-- Cast a shaman imbue and have it land on a weapon slot.
local function imbue(state, spellID, weaponSlot, enchantID, tooltipName, seconds)
    Mock.cast(spellID)
    local invSlot = weaponSlot == 0 and 16 or 17
    state.tooltips[invSlot] = { "Weapon", tooltipName .. " (30 min)" }
    Mock.setEnchants(weaponSlot, { enchant(IMBUE, enchantID, seconds or 1800) })
    Mock.advance(0.5)
end

local function rowByKey(ns, rowKey)
    for _, row in ipairs((ns.Tracker:BuildRows())) do
        if row.rowKey == rowKey then
            return row
        end
    end
end

Mock.realPrint("AKForeverWeaponBuffs tests")

-- Pure helpers ------------------------------------------------------------
scenario("name matching accepts real pairs and rejects coincidences", function()
    local ns = start()
    local overlap = ns.Sources.NamesOverlap
    check(overlap("Windfury Weapon", "Windfury 4"))
    check(overlap("Rockbiter Weapon", "Rockbiter 7"))
    check(overlap("Dense Sharpening Stone", "Sharpened (+8 Damage)"))
    check(overlap("Dense Weightstone", "Weighted (+8 Damage)"))
    check(overlap("Brilliant Mana Oil", "Brilliant Mana Oil"))
    check(overlap("Instant Poison VI", "Instant Poison VI"))
    check(not overlap("Sinister Strike", "Windfury Totem 3"))
    check(not overlap("Major Healing Potion", "Instant Poison VI"))
    check(not overlap(nil, "Windfury 4"))
end)

scenario("tooltip scan finds enchant lines and ignores item effects", function()
    local ns, state = start()
    state.tooltips[16] = {
        "Big Mace", "Two-Hand", "Durability 85 / 105",
        "Use: Restores 100 health. (5 Min Cooldown)",
        "Windfury 4 (29 min)", "Sharpened (+8 Damage) (12 sec)",
    }
    local lines = ns.Sources:ReadEnchantLines(16)
    equal(#lines, 2, "enchant lines")
    equal(lines[1].name, "Windfury 4")
    equal(lines[2].name, "Sharpened (+8 Damage)")
end)

scenario("wire format round-trips, sanitises names and respects the size cap", function()
    local ns = start()
    local entries = {
        { slotKey = "MH", typeKey = "IMBUE", enchantID = 283, secondsLeft = 1799.6, iconID = 136018, flags = 1, name = "Wind;fury, Wea^pon" },
        { slotKey = "OH", typeKey = "TEMPORARY", enchantID = 564, secondsLeft = 8, iconID = 136018, flags = 2, name = "Windfury Totem 3" },
    }
    local text = ns.Comms.Encode(entries, true)
    local decoded = ns.Comms.Decode(text, 5000)
    equal(#decoded, 2, "entries")
    equal(decoded[1].slotKey, "MH"); equal(decoded[1].typeKey, "IMBUE"); equal(decoded[1].enchantID, 283)
    equal(decoded[1].secondsLeft, 1799); equal(decoded[1].expiresAt, 6799); equal(decoded[1].selfApplied, true)
    equal(decoded[1].pulsed, false); equal(decoded[1].name, "Wind fury  Wea pon")
    equal(decoded[2].pulsed, true); equal(decoded[2].selfApplied, false); equal(decoded[2].typeKey, "TEMPORARY")

    equal(#ns.Comms.Decode("U1^", 0), 0, "empty update")
    equal(ns.Comms.Decode("U2^whatever", 0), nil, "unknown version")
    equal(ns.Comms.Decode("garbage", 0), nil, "garbage")

    local long = {}
    for i = 1, 4 do
        long[i] = { slotKey = "MH", typeKey = "TEMPORARY", enchantID = 123456789, secondsLeft = 3600, iconID = 1234567, flags = 3,
            name = string.rep("\195\169", 40) } -- 80 bytes of 2-byte characters
    end
    local capped = ns.Comms.Encode(long, true)
    check(#capped <= 255, "message too long: " .. #capped)
    check(not capped:find("\195$") and not capped:find("\195[,;]"), "split UTF-8 character")
end)

-- Learning ----------------------------------------------------------------
scenario("shaman imbue: learned from the cast, tracked, reapply wired, reminders fire", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    equal(ns.Enchants:GetSetup(), "2H")
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")

    local source = ns.db.sources[283]
    check(source, "source not learned")
    equal(source.key, "spell:Windfury Weapon")
    local desire = ns.Tracker:GetDesire("2H", "MH:IMBUE")
    check(desire and desire.key == "spell:Windfury Weapon" and desire.pinned == false, "desire not auto-learned")

    local row = rowByKey(ns, "MH:IMBUE")
    equal(row.status, "OK"); equal(row.name, "Windfury Weapon")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("type"), "spell")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Windfury Weapon")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("target-slot"), 16)
    check(not ns.Tracker:IsUrgent((ns.Tracker:BuildRows())), "should not be urgent yet")

    Mock.advance(1750)
    state.enchants[0] = { enchant(IMBUE, 283, 49) }
    Mock.advance(1)
    equal(rowByKey(ns, "MH:IMBUE").status, "LOW")
    check(ns.Tracker:IsUrgent((ns.Tracker:BuildRows())), "should be urgent under 60s")

    Mock.setEnchants(0, {})
    Mock.advance(1)
    equal(rowByKey(ns, "MH:IMBUE").status, "MISSING")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Windfury Weapon")
end)

scenario("consumable: learned as an item and applied to the right weapon slot", function()
    local ns, state = start({ class = "MAGE" }, function(s)
        s.equipment[16] = AXE_1H
        s.bags = { POTION_ITEM, OIL_ITEM }
    end)
    Mock.fire("BAG_UPDATE_DELAYED")
    Mock.cast(OIL_SPELL)
    state.tooltips[16] = { "Axe", "Brilliant Mana Oil (30 min)" }
    Mock.setEnchants(0, { enchant(TEMP, 2629, 1800, 134727) })
    Mock.advance(0.5)

    local source = ns.db.sources[2629]
    check(source, "oil not learned")
    equal(source.kind, "item"); equal(source.key, "item:" .. OIL_ITEM)
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("type"), "item")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("item"), "item:" .. OIL_ITEM)
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("target-slot"), 16)
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), nil)
end)

scenario("totem pulse: shown as pulsed, never learned, never nagged, unrelated casts ignored", function()
    local ns, state = start({ class = "ROGUE" }, function(s) s.equipment[16] = DAGGER_1H end)
    Mock.cast(SS_SPELL)
    state.tooltips[16] = { "Dagger", "Windfury Totem 3 (10 sec)" }
    Mock.setEnchants(0, { enchant(TEMP, 564, 10) })
    Mock.advance(0.5)

    check(ns.db.pulsed[564], "not marked pulsed")
    equal(ns.db.sources[564], nil, "pulsed buff must not be learned")
    equal(ns.Tracker:GetDesire("1H", "MH:TEMPORARY"), nil, "no desire from a totem")
    local row = rowByKey(ns, "MH:TEMPORARY")
    equal(row.status, "INFO"); equal(row.pulsed, true); equal(row.name, "Windfury Totem 3")
    check(not ns.Tracker:IsUrgent((ns.Tracker:BuildRows())))
end)

scenario("a login snapshot with a short timer proves nothing; a long one clears 'pulsed'", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = MACE_2H
        s.enchants[0] = { enchant(IMBUE, 283, 40) } -- logged in with 40s left on a real imbue
    end)
    equal(ns.db.pulsed[283], nil, "login snapshot must not mark pulsed")

    -- weapon swapped out and back in with 35s left: wrongly looks pulsed...
    Mock.setEnchants(0, {})
    Mock.advance(1)
    Mock.setEnchants(0, { enchant(IMBUE, 283, 35) })
    Mock.advance(1)
    check(ns.db.pulsed[283], "short unexplained application is treated as pulsed")
    -- ...until the player really casts it
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    equal(ns.db.pulsed[283], nil, "long application clears pulsed")
    check(ns.db.sources[283], "and the source is learned")
end)

scenario("name mismatch blocks attribution (potion drunk as a poison lands)", function()
    local ns, state = start({ class = "ROGUE" }, function(s)
        s.equipment[16] = DAGGER_1H
        s.bags = { POTION_ITEM }
    end)
    Mock.fire("BAG_UPDATE_DELAYED")
    Mock.cast(POTION_SPELL)
    state.tooltips[16] = { "Dagger", "Instant Poison VI (30 min)" }
    Mock.setEnchants(0, { enchant(TEMP, 625, 1800) })
    Mock.advance(0.5)
    equal(ns.db.sources[625], nil, "potion must not be learned as the poison's source")
    equal(ns.db.enchantNames[625], "Instant Poison VI", "but the display name is kept")
end)

scenario("pinned buff flags a different one as WRONG; auto follows the last applied", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    imbue(state, RB_SPELL, 0, 29, "Rockbiter 1")
    equal(ns.Tracker:GetDesire("2H", "MH:IMBUE").key, "spell:Rockbiter Weapon", "auto follows")

    ns.Tracker:Pin("2H", "MH:IMBUE", "spell:Windfury Weapon")
    equal(rowByKey(ns, "MH:IMBUE").status, "WRONG")
    imbue(state, RB_SPELL, 0, 29, "Rockbiter 1")
    equal(ns.Tracker:GetDesire("2H", "MH:IMBUE").key, "spell:Windfury Weapon", "pin survives other applications")

    ns.Tracker:SetNone("2H", "MH:IMBUE")
    local row = rowByKey(ns, "MH:IMBUE")
    equal(row.status, "INFO"); equal(row.untracked, true)
    ns.Tracker:SetAuto("2H", "MH:IMBUE")
    equal(ns.Tracker:GetDesire("2H", "MH:IMBUE").key, "spell:Rockbiter Weapon", "auto adopts what is on the weapon")
end)

scenario("timer bar spans the buff's real duration, whatever it is", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    local BAR_WIDTH = 150
    local function barWidth()
        ns.PlayerFrame:Refresh()
        return ns.PlayerFrame.rowFrames[1].bar:GetWidth()
    end

    imbue(state, WF_SPELL, 0, 283, "Windfury 1", 3600) -- a 60 minute buff
    equal(rowByKey(ns, "MH:IMBUE").fullDuration, 3600)
    near(barWidth(), BAR_WIDTH, 0.5, "full when applied")
    Mock.advance(1799.5)
    near(barWidth(), BAR_WIDTH / 2, 0.5, "half way through 60 minutes")
    Mock.advance(1500)
    near(barWidth(), BAR_WIDTH * 300 / 3600, 0.5, "5 minutes left of 60 is a sliver, not a full bar")

    imbue(state, RB_SPELL, 0, 29, "Rockbiter 1", 300) -- a 5 minute buff gets a 5 minute scale
    equal(rowByKey(ns, "MH:IMBUE").fullDuration, 300)
    Mock.advance(149.5)
    near(barWidth(), BAR_WIDTH / 2, 0.5, "half way through 5 minutes")

    -- weapon swapped out and back with 100s left: the scale must not shrink to 100s
    Mock.setEnchants(0, {})
    Mock.advance(1)
    Mock.setEnchants(0, { enchant(IMBUE, 29, 100) })
    Mock.advance(1)
    equal(rowByKey(ns, "MH:IMBUE").fullDuration, 300)
    near(barWidth(), BAR_WIDTH * 99 / 300, 1, "a third left")
end)

scenario("a buff first met mid-way starts as a full bar until its real length is seen", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = MACE_2H
        s.enchants[0] = { enchant(IMBUE, 283, 700) } -- already running at login, length unknown
    end)
    near(rowByKey(ns, "MH:IMBUE").fullDuration, 700, 1)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1", 1800)
    equal(rowByKey(ns, "MH:IMBUE").fullDuration, 1800)
    equal(ns.db.durations[283], 1800)
end)

scenario("with nothing to track the frame stays out of the way until a weapon buff appears", function()
    local ns, state = start({ class = "ROGUE" }, function(s)
        s.equipment[16] = DAGGER_1H
        s.bags = { OIL_ITEM }
    end)
    local backdrop = ns.PlayerFrame:GetBackdropFrame()
    equal(AKForeverWeaponBuffsFrame:IsShown(), false, "level 1 rogue, nothing applied: no frame")
    equal(backdrop:IsShown(), false)

    Mock.fire("BAG_UPDATE_DELAYED")
    Mock.cast(OIL_SPELL)
    state.tooltips[16] = { "Dagger", "Brilliant Mana Oil (30 min)" }
    Mock.setEnchants(0, { enchant(TEMP, 2629, 1800) })
    Mock.advance(0.5)
    equal(AKForeverWeaponBuffsFrame:IsShown(), true, "appears with the first buff")
    equal(backdrop:IsShown(), true)

    Mock.setEnchants(0, {})
    Mock.advance(1)
    equal(AKForeverWeaponBuffsFrame:IsShown(), true, "stays once something is tracked: that is the reminder")

    SlashCmdList.AKFOREVERWEAPONBUFFS("forget")
    ns.cdb.desired = {}
    Mock.advance(1)
    equal(AKForeverWeaponBuffsFrame:IsShown(), false, "and leaves again when nothing is tracked")
    SlashCmdList.AKFOREVERWEAPONBUFFS("empty")
    Mock.advance(1)
    equal(AKForeverWeaponBuffsFrame:IsShown(), true, "'/wb empty' keeps it up for positioning")
end)

scenario("a buff landing mid-combat shows the timer rows at once; the secure button waits for combat to end", function()
    local ns, state = start({ class = "ROGUE" }, function(s) s.equipment[16] = DAGGER_1H end)
    local backdrop = ns.PlayerFrame:GetBackdropFrame()
    Mock.setCombat(true)
    state.tooltips[16] = { "Dagger", "Windfury Totem 3 (10 sec)" }
    Mock.setEnchants(0, { enchant(TEMP, 564, 10) })
    Mock.advance(0.6)
    equal(backdrop:IsShown(), true, "rows visible during the fight")
    equal(AKForeverWeaponBuffsFrame:IsShown(), false, "protected part untouched in combat")
    Mock.setCombat(false)
    Mock.advance(0.6)
    equal(AKForeverWeaponBuffsFrame:IsShown(), true)

    Mock.setCombat(true)
    Mock.setEnchants(0, {})
    Mock.advance(1)
    equal(backdrop:IsShown(), false, "totem gone: rows leave at once")
    equal(AKForeverWeaponBuffsFrame:IsShown(), true, "button waits")
    Mock.setCombat(false)
    Mock.advance(0.6)
    equal(AKForeverWeaponBuffsFrame:IsShown(), false)
end)

scenario("two timed buffs on one weapon get one row each", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    Mock.setEnchants(0, { enchant(IMBUE, 283, 1800), enchant(TEMP, 2629, 900), enchant(1, 1900, 0) })
    Mock.advance(0.5)
    local rows = ns.Tracker:BuildRows()
    equal(#rows, 2, "rows (permanent enchant must be ignored)")
    equal(rows[1].rowKey, "MH:IMBUE"); equal(rows[2].rowKey, "MH:TEMPORARY")
end)

scenario("fishing lures and unarmed never become a preference", function()
    local ns, state = start({ class = "MAGE" }, function(s)
        s.equipment[16] = POLE
        s.bags = { OIL_ITEM }
    end)
    equal(ns.Enchants:GetSetup(), "FISHING")
    Mock.fire("BAG_UPDATE_DELAYED")
    Mock.cast(OIL_SPELL)
    state.tooltips[16] = { "Fishing Pole", "Brilliant Mana Oil (30 min)" }
    Mock.setEnchants(0, { enchant(TEMP, 2629, 1800) })
    Mock.advance(0.5)
    equal(next(ns.cdb.desired), nil, "no desire while fishing")
end)

scenario("off-hand rows need an off-hand weapon (shield hides them)", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = AXE_1H; s.equipment[17] = DAGGER_1H end)
    equal(ns.Enchants:GetSetup(), "DW")
    imbue(state, FT_SPELL, 1, 5, "Flametongue 1")
    check(rowByKey(ns, "OH:IMBUE"), "off-hand row while dual wielding")
    state.equipment[17] = SHIELD
    Mock.setEnchants(1, {})
    Mock.fire("PLAYER_EQUIPMENT_CHANGED", 17, false)
    Mock.advance(0.5)
    equal(ns.Enchants:GetSetup(), "1H")
    equal(rowByKey(ns, "OH:IMBUE"), nil, "no off-hand nagging with a shield")
end)

scenario("dual wield: an imbue landing on the wrong hand keeps that hand's preference; items still follow", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = AXE_1H
        s.equipment[17] = DAGGER_1H
        s.items[20750] = { name = "Brilliant Wizard Oil", icon = 134726, spellID = 25122, count = 2 }
        s.spells[25122] = { name = "Brilliant Wizard Oil", icon = 134726, known = false }
        s.bags = { OIL_ITEM, 20750 }
    end)
    Mock.fire("BAG_UPDATE_DELAYED")
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    imbue(state, FT_SPELL, 1, 5, "Flametongue 1")

    -- Flametongue recast for the off hand overwrites the main hand instead
    imbue(state, FT_SPELL, 0, 5, "Flametongue 1")
    equal(ns.Tracker:GetDesire("DW", "MH:IMBUE").key, "spell:Windfury Weapon", "preference survives the collateral overwrite")
    equal(rowByKey(ns, "MH:IMBUE").status, "WRONG")

    -- items are aimed by hand, so switching oils is deliberate and is followed
    local function oil(spellID, enchantID, name)
        Mock.cast(spellID)
        state.tooltips[16] = { "Axe", "Flametongue 1 (30 min)", name .. " (30 min)" }
        Mock.setEnchants(0, { enchant(IMBUE, 5, 1800), enchant(TEMP, enchantID, 1800) })
        Mock.advance(0.5)
    end
    oil(OIL_SPELL, 2629, "Brilliant Mana Oil")
    equal(ns.Tracker:GetDesire("DW", "MH:TEMPORARY").key, "item:" .. OIL_ITEM)
    oil(25122, 2628, "Brilliant Wizard Oil")
    equal(ns.Tracker:GetDesire("DW", "MH:TEMPORARY").key, "item:20750", "item preference follows the last applied")
end)

-- Secret values / combat ---------------------------------------------------
scenario("secret enchant data keeps the last known state instead of erroring", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    state.enchants[0] = { { hasEnchant = true, enchantType = IMBUE, timeLeft = Mock.SECRET, enchantID = 283 } }
    Mock.advance(2)
    equal(ns.Enchants.locked, "secret")
    check(ns.Enchants.rows["MH:IMBUE"], "last known row kept")
    equal(rowByKey(ns, "MH:IMBUE").status, "OK")
    state.enchants[0] = { enchant(IMBUE, 283, 1700) }
    Mock.advance(2)
    equal(ns.Enchants.locked, nil)
end)

scenario("combat: nothing protected is touched; the new action is wired afterwards", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    imbue(state, RB_SPELL, 0, 29, "Rockbiter 1")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Rockbiter Weapon")

    Mock.setCombat(true)
    ns.Tracker:Pin("2H", "MH:IMBUE", "spell:Windfury Weapon") -- action changes mid-fight
    Mock.setEnchants(0, {})                                    -- and rows change size
    Mock.advance(3)
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Rockbiter Weapon", "attributes frozen in combat")
    check(ns.PlayerFrame.actionPending, "change should be queued")
    SlashCmdList.AKFOREVERWEAPONBUFFS("hide")
    Mock.advance(1)

    Mock.setCombat(false)
    Mock.advance(1)
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Windfury Weapon", "wired after combat")
    equal(AKForeverWeaponBuffsFrame:IsShown(), false, "hide applied after combat")
end)

-- Shaman extras -------------------------------------------------------------
scenario("skinning-knife strategy follows the SoD decision tree", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = AXE_1H; s.equipment[17] = DAGGER_1H end)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    imbue(state, FT_SPELL, 1, 5, "Flametongue 1")
    local function fix()
        local rows, setup = ns.Tracker:BuildRows()
        return ns.Tracker:ChooseFix(rows, setup)
    end

    -- both right: offer the one that expires first
    state.enchants[0] = { enchant(IMBUE, 283, 600) }
    state.enchants[1] = { enchant(IMBUE, 5, 300) }
    Mock.advance(2)
    local action = fix()
    equal(action.kind, "apply"); equal(action.source.key, "spell:Flametongue Weapon")

    -- off hand empty: just cast it
    Mock.setEnchants(1, {})
    Mock.advance(1)
    equal(fix().source.key, "spell:Flametongue Weapon")

    -- off hand carries the wrong imbue, main hand is good, no knife: recast anyway
    Mock.setEnchants(1, { enchant(IMBUE, 283, 900) })
    Mock.advance(1)
    equal(fix().kind, "apply")

    -- ...with a knife in the bags: park it in the main hand first
    state.items[KNIFE].count = 1
    action = fix()
    equal(action.kind, "macro"); equal(action.macrotext, "/equipslot 16 item:" .. KNIFE)

    -- knife parked in the main hand, off hand still wrong: rebuff the off hand
    state.equipment[16] = KNIFE
    Mock.setEnchants(0, {})
    Mock.advance(1)
    equal(fix().source.key, "spell:Flametongue Weapon")
    equal(rowByKey(ns, "MH:IMBUE").status, "KNIFE"); equal(rowByKey(ns, "MH:IMBUE").knifeText, "Rebuff other")

    -- off hand fixed: swap the real weapon back
    Mock.setEnchants(1, { enchant(IMBUE, 5, 1800) })
    Mock.advance(1)
    action = fix()
    equal(action.kind, "macro"); equal(action.macrotext, "/equipslot 16 item:" .. AXE_1H)
    equal(rowByKey(ns, "MH:IMBUE").knifeText, "Equip weapon")
end)

-- Party sharing -----------------------------------------------------------------
scenario("party: broadcast on change, hold during lockdown, flush after, answer requests", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = MACE_2H
        s.party.party1 = { name = "Bob", class = "WARRIOR" }
    end)
    Mock.fire("GROUP_ROSTER_UPDATE")
    Mock.advance(3)
    local baseline = #Mock.sent
    check(baseline >= 1, "should announce itself on joining")
    equal(Mock.sent[1].channel, "PARTY")

    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    Mock.advance(3)
    check(#Mock.sent > baseline, "enchant change should be broadcast")
    local last = Mock.sent[#Mock.sent]
    local decoded = ns.Comms.Decode(last.text, Mock.now)
    equal(decoded[1].name, "Windfury Weapon"); equal(decoded[1].selfApplied, true)

    state.chatLockdown = true
    local before = #Mock.sent
    Mock.setEnchants(0, {})
    Mock.advance(10)
    equal(#Mock.sent, before, "nothing leaves during messaging lockdown")
    check(ns.Comms.stats.lockedOut > 0)
    state.chatLockdown = false
    Mock.advance(4)
    check(#Mock.sent > before, "queued update flushed after lockdown")
    equal(#ns.Comms.Decode(Mock.sent[#Mock.sent].text, Mock.now), 0, "and it says: no buffs")

    before = #Mock.sent
    Mock.fire("CHAT_MSG_ADDON", "WeaponBuffs", "R1", "PARTY", "Bob-TestRealm")
    Mock.advance(5)
    check(#Mock.sent > before, "request answered")
end)

scenario("party: incoming updates fill the roster, leavers are pruned, panel renders", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = MACE_2H
        s.party.party1 = { name = "Bob", class = "WARRIOR" }
        s.party.party2 = { name = "Carl", class = "MAGE" } -- never sends anything: does not run the addon
    end)
    ns.PartyPanel:Refresh()
    equal(AKForeverWeaponBuffsPartyPanel:IsShown(), false, "in a party, but nobody has sent data: nothing to show, no panel")
    Mock.fire("CHAT_MSG_ADDON", "WeaponBuffs", "U1^M,T,564,8,136018,2,Windfury Totem 3;O,T,1643,1500,135250,1,Dense Sharpening Stone", "PARTY", "Bob-TestRealm")
    local bob = ns.Comms.roster.Bob
    check(bob, "roster entry")
    equal(#bob.entries, 2); equal(bob.entries[1].pulsed, true); equal(bob.entries[2].selfApplied, true)
    Mock.fire("CHAT_MSG_ADDON", "SomeOtherAddon", "U1^M,T,1,1,1,1,x", "PARTY", "Bob-TestRealm")
    Mock.fire("CHAT_MSG_ADDON", "WeaponBuffs", Mock.SECRET, "PARTY", "Bob-TestRealm")
    equal(#ns.Comms.roster.Bob.entries, 2, "foreign prefix and secret payloads ignored")
    ns.PartyPanel:Refresh()
    equal(AKForeverWeaponBuffsPartyPanel:IsShown(), true)
    equal(ns.PartyPanel.rows[1].name:GetText(), "Bob")
    check(not ns.PartyPanel.rows[2] or not ns.PartyPanel.rows[2]:IsShown(), "Carl sent nothing: no row for him")

    Mock.fire("CHAT_MSG_ADDON", "WeaponBuffs", "U1^", "PARTY", "Bob-TestRealm") -- Bob's buffs ran out
    ns.PartyPanel:Refresh()
    equal(ns.PartyPanel.rows[1].note:GetText(), "no weapon buffs", "he runs the addon and has nothing on: that is worth showing")

    -- which way the panel grows from your own frame
    Mock.fire("CHAT_MSG_ADDON", "WeaponBuffs", "U1^M,T,7,1500,135250,1,Wizard Oil", "PARTY", "Carl-TestRealm")
    ns.PartyPanel:Refresh()
    local point, _, relativePoint = AKForeverWeaponBuffsPartyPanel:GetPoint(1)
    equal(point, "TOPLEFT"); equal(relativePoint, "BOTTOMLEFT", "default: hangs under your own frame")
    equal((ns.PartyPanel.rows[2]:GetPoint(1)), "TOPLEFT", "rows listed downwards")
    SlashCmdList.AKFOREVERWEAPONBUFFS("party up")
    point, _, relativePoint = AKForeverWeaponBuffsPartyPanel:GetPoint(1)
    equal(point, "BOTTOMLEFT"); equal(relativePoint, "TOPLEFT", "sits on top of your own frame, bottom edge fixed")
    local rowPoint, _, _, _, firstY = ns.PartyPanel.rows[1]:GetPoint(1)
    local _, _, _, _, secondY = ns.PartyPanel.rows[2]:GetPoint(1)
    equal(rowPoint, "BOTTOMLEFT")
    check(secondY > firstY, "the first member is nearest to you, the next one appears above")
    equal(ns.PartyPanel.rows[1].name:GetText(), "Bob")
    equal(AKForeverWeaponBuffsPartyPanel:IsShown(), true)
    SlashCmdList.AKFOREVERWEAPONBUFFS("party down")
    equal((AKForeverWeaponBuffsPartyPanel:GetPoint(1)), "TOPLEFT")

    state.party = {}
    Mock.fire("GROUP_ROSTER_UPDATE")
    equal(ns.Comms.roster.Bob, nil, "pruned after leaving")
    equal(AKForeverWeaponBuffsPartyPanel:IsShown(), false)

    SlashCmdList.AKFOREVERWEAPONBUFFS("comms test")
    check(ns.Comms.roster.Purrdee and ns.Comms.roster.Purrdee.loopback, "loopback row for solo testing")
    ns.PartyPanel:Refresh()
    equal(AKForeverWeaponBuffsPartyPanel:IsShown(), true)
end)

-- Everything else -----------------------------------------------------------------
scenario("picker, slash commands and diagnostics run; the report is SavedVariables-safe", function()
    local ns, state = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    imbue(state, WF_SPELL, 0, 283, "Windfury 1")
    local rows, setup = ns.Tracker:BuildRows()
    ns.Picker:Toggle(rows[1], setup, AKForeverWeaponBuffsFixButton)
    equal(AKForeverWeaponBuffsPicker:IsShown(), true)
    ns.Picker:Toggle(rows[1], setup, AKForeverWeaponBuffsFixButton)
    equal(AKForeverWeaponBuffsPicker:IsShown(), false)

    for _, command in ipairs({ "", "debug", "debug", "party", "party", "comms", "show", "reset", "diag" }) do
        SlashCmdList.AKFOREVERWEAPONBUFFS(command)
    end
    Mock.fire("PLAYER_LOGOUT")

    local function assertPlain(value, path)
        local kind = type(value)
        if kind == "table" then
            for k, v in pairs(value) do
                check(type(k) == "string" or type(k) == "number", path .. ": bad key type " .. type(k))
                assertPlain(v, path .. "." .. tostring(k))
            end
        else
            check(kind == "string" or kind == "number" or kind == "boolean", path .. ": " .. kind .. " cannot be saved")
        end
    end
    assertPlain(AKForeverWeaponBuffsDB, "AKForeverWeaponBuffsDB")
    check(AKForeverWeaponBuffsDB.chars["Purrdee - TestRealm"].desired["2H"], "per-character data lives inside the account-wide table")
    equal(AKForeverWeaponBuffsDB.diag.api["C_Item.GetWeaponEnchantInfo"], "function")
    equal(AKForeverWeaponBuffsDB.diag.state.sources[283].key, "spell:Windfury Weapon")

    SlashCmdList.AKFOREVERWEAPONBUFFS("forget")
    equal(next(ns.db.sources), nil)
end)

scenario("survives a client that dropped an event and has no saved variables", function()
    local ns = start({ class = "SHAMAN", unknownEvents = { WEAPON_SLOT_CHANGED = true } }, function(s) s.equipment[16] = MACE_2H end)
    check(ns.unknownEvents.WEAPON_SLOT_CHANGED, "unknown event should be recorded, not fatal")
    equal(ns.db.loads, 1)
end)

local function savedSession()
    local character = {
        desired = { ["2H"] = { ["MH:IMBUE"] = { key = "spell:Windfury Weapon", pinned = true } } },
        position = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 10, y = -10 },
    }
    local db = {
        sources = { [283] = { kind = "spell", spellID = WF_SPELL, name = "Windfury Weapon", typeKey = "IMBUE", key = "spell:Windfury Weapon" } },
        loads = 4,
    }
    return db, character
end

local function assertRestored(ns)
    equal(ns.db.loads, 5)
    equal(rowByKey(ns, "MH:IMBUE").status, "MISSING", "nags about the pinned buff right after login")
    equal(AKForeverWeaponBuffsFixButton:GetAttribute("spell"), "Windfury Weapon")
    equal((AKForeverWeaponBuffsFrame:GetPoint(1)), "TOPLEFT")
end

scenario("saved state from a previous session is honoured (position, tracked buff, learned sources)", function()
    local db, character = savedSession()
    db.chars = { ["Purrdee - TestRealm"] = character }
    local ns = start({ class = "SHAMAN", db = db }, function(s) s.equipment[16] = MACE_2H end)
    assertRestored(ns)
    equal(ns.savedStateSource, "client")
end)

scenario("saved state loaded by the beta bridge addon is recognised as such", function()
    local db, character = savedSession()
    db.chars = { ["Purrdee - TestRealm"] = character }
    local ns = start({ class = "SHAMAN", db = db, bridge = { version = 1, table = db } }, function(s) s.equipment[16] = MACE_2H end)
    assertRestored(ns)
    equal(ns.savedStateSource, "bridge addon")
end)

scenario("2.0.0 per-character data is adopted once, by the first character only", function()
    local db, character = savedSession()
    local ns = start({ class = "SHAMAN", db = db, cdb = character }, function(s) s.equipment[16] = MACE_2H end)
    assertRestored(ns)
    equal(ns.db.chars["Purrdee - TestRealm"], character)
    check(ns.db.legacyAdopted)

    -- an alt logging in later must not inherit the shaman's tracking
    local altDb = { chars = { ["Purrdee - TestRealm"] = character }, legacyAdopted = true, loads = 5 }
    local altNs = start({ class = "ROGUE", db = altDb, cdb = character }, function(s)
        s.playerName = "Stabby"
        s.equipment[16] = DAGGER_1H
    end)
    check(altNs.cdb ~= character, "alt gets its own table")
    equal(next(altNs.cdb.desired), nil)
end)

scenario("the character profile is the same on a fresh login and after a /reload", function()
    local fresh = start({ class = "SHAMAN" }, function(s) s.freshLogin = true; s.equipment[16] = MACE_2H end)
    local reloaded = start({ class = "SHAMAN" }, function(s) s.freshLogin = false; s.equipment[16] = MACE_2H end)
    equal(fresh.characterKey, "Purrdee - TestRealm")
    equal(reloaded.characterKey, fresh.characterKey)
end)

scenario("profiles split by the 2.0.1 realm-name bug are merged; the canonical one wins", function()
    local db = { chars = {
        ["Purrdee - TestRealm"] = { position = { point = "LEFT", relativePoint = "LEFT", x = 59, y = -172 },
            desired = { ["1H"] = { ["MH:IMBUE"] = { key = "spell:Rockbiter Weapon", pinned = false } } } },
        ["Purrdee - Test Realm"] = { position = { point = "BOTTOMLEFT", relativePoint = "BOTTOMLEFT", x = 30, y = 277 },
            desired = {}, options = { partyPanel = false } },
    } }
    local ns = start({ class = "SHAMAN", db = db }, function(s) s.freshLogin = true; s.equipment[16] = AXE_1H end)
    equal(ns.db.chars["Purrdee - Test Realm"], nil, "split profile removed")
    equal(ns.cdb.position.x, 59, "canonical profile wins on conflicts")
    equal(ns.cdb.desired["1H"]["MH:IMBUE"].key, "spell:Rockbiter Weapon")
    equal(ns.cdb.options.partyPanel, false, "gaps are filled from the other profile")
end)

scenario("characters keep separate tracking inside the one saved table", function()
    local ns = start({ class = "SHAMAN" }, function(s) s.equipment[16] = MACE_2H end)
    equal(ns.characterKey, "Purrdee - TestRealm")
    equal(ns.cdb, AKForeverWeaponBuffsDB.chars["Purrdee - TestRealm"])
    equal(ns.savedStateSource, "none (first run, or the client did not load it)")
end)

scenario("the version: the packager's stamp, a working copy, a release tag", function()
    local function versionOf(tocVersion)
        return start({ class = "SHAMAN", version = tocVersion }, function(s) s.equipment[16] = MACE_2H end).version
    end
    equal(versionOf(nil), "2.0.0-test", "the version the packager stamped into the TOC")
    equal(versionOf("@project-version@"), "dev", "a working copy: the TOC still holds the packager's token")
    equal(versionOf("v2.1.0"), "2.1.0", "a release tag: printed as v2.1.0, not vv2.1.0")
end)

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
os.exit(#failures == 0 and 0 or 1)
