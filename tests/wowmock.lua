-- Minimal, deliberately strict stand-in for the WoW client so the addon's logic
-- can run under a plain Lua interpreter.
--
--  * Widgets only answer to real widget API method names: a typo surfaces as
--    "attempt to call a nil value".
--  * Protected frames are modelled: touching a secure button (or anything it is
--    anchored to / parented by) while in combat raises an error, like the game.
--  * Time and timers are manual: Mock.advance(seconds).
--
-- Not loaded by the game (not in the .toc).
local Mock = {}

local REAL_PRINT = print

local WIDGET_METHODS = {
    -- region / frame
    "SetSize", "SetWidth", "SetHeight", "GetWidth", "GetHeight", "SetPoint", "ClearAllPoints", "SetAllPoints",
    "GetPoint", "Show", "Hide", "IsShown", "IsVisible", "SetShown", "SetAlpha", "GetAlpha", "SetParent", "GetParent",
    "SetMovable", "SetClampedToScreen", "SetClampRectInsets", "EnableMouse", "RegisterForDrag", "StartMoving",
    "StopMovingOrSizing", "SetUserPlaced", "SetFrameLevel", "GetFrameLevel", "SetFrameStrata", "SetScript",
    "GetScript", "HookScript", "RegisterEvent", "RegisterUnitEvent", "UnregisterEvent", "SetBackdrop",
    "SetBackdropColor", "SetBackdropBorderColor", "CreateTexture", "CreateFontString", "SetAttribute",
    "GetAttribute", "RegisterForClicks", "SetHighlightTexture", "SetNormalTexture", "SetID", "GetID",
    -- texture
    "SetTexture", "SetTexCoord", "SetColorTexture", "SetDesaturated", "SetBlendMode", "SetVertexColor",
    "CreateAnimationGroup",
    -- font string
    "SetText", "GetText", "SetTextColor", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFont", "GetFont",
    -- animation
    "SetLooping", "CreateAnimation", "Play", "Stop", "IsPlaying", "SetFromAlpha", "SetToAlpha", "SetDuration",
    -- tooltip
    "SetOwner", "AddLine", "SetItemByID", "SetSpellByID", "SetInventoryItem",
}

-- Methods the game blocks on protected frames during combat.
local PROTECTED_METHODS = {
    SetSize = true, SetWidth = true, SetHeight = true, SetPoint = true, ClearAllPoints = true, SetAllPoints = true,
    Show = true, Hide = true, SetShown = true, SetParent = true, SetAttribute = true, SetFrameLevel = true,
    SetFrameStrata = true, EnableMouse = true, StartMoving = true, SetMovable = true, SetClampRectInsets = true,
    SetUserPlaced = true, RegisterForClicks = true,
}

local SECURE_TEMPLATES = { SecureActionButtonTemplate = true }

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
local function isProtected(widget)
    return widget.__protected or widget.__implicitlyProtected
end

local implementations = {}

function implementations.SetScript(self, name, fn) self.__scripts[name] = fn end
function implementations.GetScript(self, name) return self.__scripts[name] end
function implementations.RegisterEvent(self, event)
    if Mock.unknownEvents[event] then
        error("Attempt to register unknown event \"" .. event .. "\"")
    end
    -- Like the Forever client: some events are reserved for Blizzard's UI. The
    -- call does not error (pcall sees nothing) - it is refused, and the client
    -- raises ADDON_ACTION_FORBIDDEN plus a dialog blaming the addon.
    if Mock.forbiddenEvents[event] then
        Mock.forbiddenCalls[#Mock.forbiddenCalls + 1] = "RegisterEvent(" .. event .. ")"
        Mock.fire("ADDON_ACTION_FORBIDDEN", "AKForeverWeaponBuffs", "Frame:RegisterEvent()")
        return
    end
    self.__events[event] = true
end
function implementations.RegisterUnitEvent(self, event, unit) self.__unitEvents[event] = unit end
function implementations.UnregisterEvent(self, event) self.__events[event] = nil; self.__unitEvents[event] = nil end
function implementations.SetAttribute(self, key, value) self.__attributes[key] = value end
function implementations.GetAttribute(self, key) return self.__attributes[key] end
function implementations.Show(self) self.__shown = true end
function implementations.Hide(self) self.__shown = false end
function implementations.SetShown(self, shown) self.__shown = shown and true or false end
function implementations.IsShown(self) return self.__shown end
function implementations.IsVisible(self) return self.__shown end
function implementations.GetParent(self) return self.__parent end
function implementations.SetText(self, text) self.__text = text end
function implementations.GetText(self) return self.__text end
function implementations.SetTexture(self, texture) self.__texture = texture end
function implementations.SetSize(self, width, height) self.__width, self.__height = width, height end
function implementations.SetWidth(self, width) self.__width = width end
function implementations.SetHeight(self, height) self.__height = height end
function implementations.GetWidth(self) return self.__width or 0 end
function implementations.GetHeight(self) return self.__height or 0 end
function implementations.SetFrameLevel(self, level) self.__level = level end
function implementations.GetFrameLevel(self) return self.__level end
function implementations.GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function implementations.Play(self) self.__playing = true end
function implementations.Stop(self) self.__playing = false end
function implementations.IsPlaying(self) return self.__playing or false end
function implementations.ClearAllPoints(self) self.__points = {} end
function implementations.GetPoint(self, index)
    local point = self.__points[index or 1]
    if not point then
        return "CENTER", nil, "CENTER", 0, 0
    end
    return point[1], point[2], point[3], point[4], point[5]
end

local function anchorTo(self, target)
    if type(target) == "table" and isProtected(self) then
        target.__implicitlyProtected = true
    end
end

function implementations.SetPoint(self, point, relativeTo, relativePoint, x, y)
    if type(relativeTo) ~= "table" then -- SetPoint("CENTER") / SetPoint("CENTER", x, y)
        relativeTo, relativePoint, x, y = nil, point, relativeTo, relativePoint
    end
    anchorTo(self, relativeTo)
    self.__points[#self.__points + 1] = { point, relativeTo, relativePoint, x or 0, y or 0 }
end

function implementations.SetAllPoints(self, target)
    anchorTo(self, target or self.__parent)
end

local newWidget

function implementations.CreateTexture(self) return newWidget("Texture", nil, self) end
function implementations.CreateFontString(self) return newWidget("FontString", nil, self) end
function implementations.CreateAnimationGroup(self) return newWidget("AnimationGroup", nil, self) end
function implementations.CreateAnimation(self) return newWidget("Animation", nil, self) end

local function noop() end

local methodTable = {}
for _, name in ipairs(WIDGET_METHODS) do
    local implementation = implementations[name] or noop
    if PROTECTED_METHODS[name] then
        methodTable[name] = function(self, ...)
            if Mock.state.inCombat and isProtected(self) then
                error("ADDON_ACTION_BLOCKED: " .. name .. "() on protected frame " .. tostring(self.__name or self.__kind) .. " in combat", 2)
            end
            return implementation(self, ...)
        end
    else
        methodTable[name] = implementation
    end
end

local widgetMeta = { __index = methodTable }

function newWidget(kind, name, parent, template)
    local widget = setmetatable({
        __kind = kind, __name = name, __parent = parent, __scripts = {}, __events = {}, __unitEvents = {},
        __attributes = {}, __points = {}, __shown = true, __level = (parent and parent.__level or 0) + 1,
    }, widgetMeta)
    if template and SECURE_TEMPLATES[template] then
        widget.__protected = true
        if parent then
            parent.__implicitlyProtected = true
        end
    end
    return widget
end

------------------------------------------------------------------------
-- Time
------------------------------------------------------------------------
function Mock.advance(seconds)
    local target = Mock.now + seconds
    while true do
        local nextIndex, nextTimer
        for index, timer in ipairs(Mock.timers) do
            if timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
                nextIndex, nextTimer = index, timer
            end
        end
        if not nextTimer then
            break
        end
        Mock.now = math.max(Mock.now, nextTimer.at)
        if nextTimer.every then
            nextTimer.at = nextTimer.at + nextTimer.every
        else
            table.remove(Mock.timers, nextIndex)
        end
        nextTimer.fn()
    end
    Mock.now = target
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
function Mock.fire(event, ...)
    -- copy: handlers may create frames while we iterate
    local frames = {}
    for i, frame in ipairs(Mock.frames) do
        frames[i] = frame
    end
    for _, frame in ipairs(frames) do
        local unit = frame.__unitEvents[event]
        if frame.__events[event] or (unit and unit == (...)) then
            local handler = frame.__scripts.OnEvent
            if handler then
                handler(frame, event, ...)
            end
        end
    end
end

function Mock.setCombat(inCombat)
    Mock.state.inCombat = inCombat
    Mock.fire(inCombat and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

------------------------------------------------------------------------
-- Install globals + load the addon in .toc order
------------------------------------------------------------------------
local function readToc(root)
    local files = {}
    for line in io.lines(root .. "/AKForeverWeaponBuffs.toc") do
        line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

function Mock.install(options)
    options = options or {}
    Mock.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
    Mock.now = 1000
    Mock.timers = {}
    Mock.frames = {}
    Mock.errors = {}
    Mock.printed = {}
    Mock.sent = {}
    Mock.unknownEvents = options.unknownEvents or {}
    Mock.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }
    Mock.forbiddenCalls = {}
    Mock.state = {
        inCombat = false,
        chatLockdown = false,
        playerName = "Purrdee",
        playerClass = options.class or "SHAMAN",
        equipment = {},  -- [invSlot] = itemID
        items = {},      -- [itemID] = { name, equipLoc, classID, subclassID, icon, spellID, count }
        spells = {},     -- [spellID] = { name, icon, known }
        enchants = { [0] = {}, [1] = {}, [2] = {} },
        tooltips = {},   -- [invSlot] = { "line", ... }
        bags = {},       -- itemIDs in the backpack
        party = {},      -- [unit] = { name, class }
        aurasBlocked = false,
    }
    local state = Mock.state

    local G = _G
    G.unpack = table.unpack
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        Mock.printed[#Mock.printed + 1] = table.concat(parts, " ")
    end
    G.issecretvalue = function(value) return value == Mock.SECRET end
    G.geterrorhandler = function()
        return function(err)
            Mock.errors[#Mock.errors + 1] = tostring(err)
        end
    end
    G.GetTime = function() return Mock.now end
    G.InCombatLockdown = function() return state.inCombat end
    G.date = os.date
    G.GetBuildInfo = function() return "1.60.1", "69893", "Sep 17 2026", 16001 end
    G.GetLocale = function() return "enUS" end
    G.UnitLevel = function() return 60 end
    G.WOW_PROJECT_ID, G.WOW_PROJECT_MAINLINE, G.WOW_PROJECT_CLASSIC = 1, 1, 2
    G.NUM_BAG_SLOTS = 4
    G.LE_PARTY_CATEGORY_INSTANCE = 2
    G.INVTYPE_WEAPONMAINHAND, G.INVTYPE_WEAPONOFFHAND, G.INVTYPE_RANGED = "Main Hand", "Off Hand", "Ranged"
    G.ITEM_SPELL_TRIGGER_ONUSE, G.ITEM_SPELL_TRIGGER_ONEQUIP, G.ITEM_SPELL_TRIGGER_ONPROC = "Use:", "Equip:", "Chance on hit:"
    G.RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, SHAMAN = { r = 0, g = 0.44, b = 0.87 } }
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.AKForeverWeaponBuffsDB, G.WeaponBuffsCharDB = options.db, options.cdb
    G.AKForeverWeaponBuffs_SavedStateBridge = options.bridge

    G.Enum = {
        WeaponSlot = { MainHand = 0, OffHand = 1, Ranged = 2 },
        ItemEnchantType = { None = 0, Permanent = 1, Temporary = 2, Imbue = 3 },
        SendAddonMessageResult = { Success = 0, AddOnMessageLockdown = 11 },
    }

    G.CreateFrame = function(kind, name, parent, template)
        local widget = newWidget(kind, name, parent, template)
        Mock.frames[#Mock.frames + 1] = widget
        if name then
            G[name] = widget
        end
        return widget
    end
    G.UIParent = newWidget("Frame", "UIParent")
    G.GameTooltip = newWidget("GameTooltip", "GameTooltip")

    G.C_Timer = {
        After = function(delay, fn)
            Mock.timers[#Mock.timers + 1] = { at = Mock.now + delay, fn = fn }
        end,
        NewTicker = function(interval, fn)
            local ticker = { at = Mock.now + interval, fn = fn, every = interval }
            Mock.timers[#Mock.timers + 1] = ticker
            return ticker
        end,
    }
    G.C_AddOns = { GetAddOnMetadata = function() return options.version or "2.0.0-test" end }

    G.C_Item = {
        -- Timers count down for real: timeLeft is what was set, minus the time since.
        GetWeaponEnchantInfo = function(weaponSlot)
            if state.enchantsError then
                error(state.enchantsError)
            end
            local list = {}
            for _, info in ipairs(state.enchants[weaponSlot] or {}) do
                if type(info.timeLeft) ~= "number" then
                    list[#list + 1] = info -- e.g. a secret value: hand it over untouched
                else
                    info.__appliedAt = info.__appliedAt or Mock.now
                    local left = info.timeLeft - (Mock.now - info.__appliedAt) * 1000
                    if left > 0 or info.timeLeft == 0 then
                        local copy = {}
                        for key, value in pairs(info) do
                            if key:sub(1, 2) ~= "__" then
                                copy[key] = value
                            end
                        end
                        copy.timeLeft = math.max(0, left)
                        list[#list + 1] = copy
                    end
                end
            end
            return list
        end,
        GetItemInfoInstant = function(itemID)
            local item = state.items[itemID] or {}
            return itemID, "Weapon", "Sub", item.equipLoc, item.icon, item.classID, item.subclassID
        end,
        GetItemSpell = function(itemID)
            local item = state.items[itemID]
            if item and item.spellID then
                return (state.spells[item.spellID] or {}).name or item.name, item.spellID
            end
        end,
        GetItemCount = function(itemID) return (state.items[itemID] or {}).count or 0 end,
        GetItemNameByID = function(itemID) return (state.items[itemID] or {}).name end,
        GetItemIconByID = function(itemID) return (state.items[itemID] or {}).icon end,
        IsItemDataCachedByID = function() return true end,
        RequestLoadItemDataByID = noop,
    }
    G.C_Spell = {
        GetSpellName = function(spellID) return (state.spells[spellID] or {}).name end,
        GetSpellTexture = function(spellID) return (state.spells[spellID] or {}).icon end,
    }
    G.C_SpellBook = {
        IsSpellKnownOrInSpellBook = function(spellID) return (state.spells[spellID] or {}).known or false end,
    }
    G.C_Container = {
        GetContainerNumSlots = function(bag) return bag == 0 and #state.bags or 0 end,
        GetContainerItemID = function(bag, slot) return bag == 0 and state.bags[slot] or nil end,
    }
    G.C_TooltipInfo = {
        GetInventoryItem = function(_, invSlot)
            local lines = {}
            for index, text in ipairs(state.tooltips[invSlot] or {}) do
                lines[index] = { leftText = text, type = 0 }
            end
            return { lines = lines }
        end,
    }
    G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return 0 end,
        InChatMessagingLockdown = function() return state.chatLockdown end,
        SendAddonMessage = function(prefix, text, channel, target)
            if state.chatLockdown then
                return 11
            end
            Mock.sent[#Mock.sent + 1] = { prefix = prefix, text = text, channel = channel, target = target }
            if channel == "WHISPER" then
                Mock.fire("CHAT_MSG_ADDON", prefix, text, channel, target .. "-TestRealm")
            end
            return 0
        end,
    }
    G.GetInventoryItemID = function(_, invSlot) return state.equipment[invSlot] end
    G.UnitClass = function(unit)
        if unit == "player" then
            return "Player Class", state.playerClass
        end
        local member = state.party[unit]
        return member and member.class, member and member.class
    end
    G.UnitName = function(unit)
        if unit == "player" then
            return state.playerName
        end
        return state.party[unit] and state.party[unit].name
    end
    G.GetUnitName = function(unit) return G.UnitName(unit) end
    -- Like the real client: on a fresh login UnitFullName has no realm yet (only
    -- GetRealmName works, and it returns the spaced display name); after a /reload
    -- UnitFullName returns the normalized realm. Tests flip state.freshLogin.
    G.UnitFullName = function(unit)
        if state.freshLogin then
            return G.UnitName(unit), nil
        end
        return G.UnitName(unit), "TestRealm"
    end
    G.GetRealmName = function() return "Test Realm" end
    G.UnitExists = function(unit) return unit == "player" or state.party[unit] ~= nil end
    G.IsInGroup = function(category)
        if category == G.LE_PARTY_CATEGORY_INSTANCE then
            return false
        end
        return next(state.party) ~= nil
    end
    G.Ambiguate = function(name) return (name:gsub("%-TestRealm$", "")) end

    -- Load the addon exactly as the client would.
    local root = options.root or "."
    local ns = {}
    for _, file in ipairs(readToc(root)) do
        local chunk, err = loadfile(root .. "/" .. file)
        if not chunk then
            error("cannot load " .. file .. ": " .. tostring(err))
        end
        chunk("AKForeverWeaponBuffs", ns)
    end
    Mock.ns = ns

    if options.login ~= false then
        Mock.fire("ADDON_LOADED", "AKForeverWeaponBuffs")
        Mock.fire("PLAYER_LOGIN")
        Mock.fire("PLAYER_ENTERING_WORLD", true, false)
    end
    return ns, state
end

-- Convenience used by the scenarios ------------------------------------
function Mock.setEnchants(weaponSlot, list)
    Mock.state.enchants[weaponSlot] = list
    Mock.fire("WEAPON_ENCHANT_CHANGED")
end

function Mock.cast(spellID)
    Mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-0-0-0-" .. spellID, spellID)
end

function Mock.realPrint(...)
    REAL_PRINT(...)
end

return Mock
