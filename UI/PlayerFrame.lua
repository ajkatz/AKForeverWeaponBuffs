-- Player frame: a secure "fix" button plus one timer row per tracked weapon buff.
--
-- Layout note: the fix button is a protected frame, and whatever it is anchored
-- to becomes protected with it. So `main` (the mover the button sits on) has a
-- fixed size and is never touched in combat, while the backdrop and rows are
-- ordinary frames hanging off it that are free to resize mid-fight.
local _, ns = ...

local Sources, Tracker = ns.Sources, ns.Tracker

local PlayerFrame = {}
ns.PlayerFrame = PlayerFrame

local PAD, BUTTON, GAP = 8, 44, 8
local ICON, ICON_GAP, BAR_WIDTH, ROW_HEIGHT, ROW_GAP = 18, 4, 150, 18, 3
local PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local STATUS_COLORS = {
    OK = { 0.30, 0.62, 0.32, 1 },
    LOW = { 0.85, 0.55, 0.15, 1 },
    MISSING = { 0.55, 0.14, 0.14, 0.9 },
    WRONG = { 0.55, 0.14, 0.14, 0.9 },
    INFO = { 0.30, 0.45, 0.65, 1 },
    KNIFE = { 0.45, 0.45, 0.45, 0.7 },
}
local BAR_BACKGROUND = { 0.15, 0.15, 0.15, 0.7 }

local main, bg, fix, hint
local rowFrames = {}
PlayerFrame.rowFrames = rowFrames -- read by the tests

local function formatTime(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
PlayerFrame.FormatTime = formatTime

------------------------------------------------------------------------
-- Position
------------------------------------------------------------------------
local function savePosition()
    local point, _, relativePoint, x, y = main:GetPoint(1)
    if point then
        ns.cdb.position = { point = point, relativePoint = relativePoint, x = x, y = y }
    end
end

local function restorePosition()
    main:ClearAllPoints()
    local position = ns.cdb.position
    if position and position.point then
        main:SetPoint(position.point, UIParent, position.relativePoint or position.point, position.x or 0, position.y or 0)
    else
        main:SetPoint("CENTER", UIParent, "CENTER", -160, -140)
    end
end

------------------------------------------------------------------------
-- Fix button
------------------------------------------------------------------------
local function showFixTooltip(self)
    local action = PlayerFrame.action
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not action then
        GameTooltip:SetText("AKForeverWeaponBuffs")
        GameTooltip:AddLine("Apply a weapon buff (imbue, oil, stone, poison...) and it is tracked from then on.", 1, 1, 1, true)
    elseif action.kind == "apply" then
        local source = action.source
        if source.kind == "item" and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(source.itemID)
        elseif source.kind == "spell" and GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(source.spellID)
        else
            GameTooltip:SetText((Sources:GetDisplay(source)))
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click: apply to " .. action.slot.name, 0.5, 1, 0.5)
    else
        GameTooltip:SetText(action.title or "AKForeverWeaponBuffs")
        if action.description then
            GameTooltip:AddLine(action.description, 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

local function actionSignature(action)
    if not action then
        return "none"
    end
    if action.kind == "apply" then
        return "apply|" .. action.source.key .. "|" .. action.slot.invSlot
    end
    return "macro|" .. (action.macrotext or "")
end

local function setAttribute(key, value)
    if fix:GetAttribute(key) ~= value then
        fix:SetAttribute(key, value)
    end
end

-- Secure attributes; only ever called out of combat.
local function wireAction(action)
    if not action then
        setAttribute("type", nil)
        setAttribute("spell", nil)
        setAttribute("item", nil)
        setAttribute("macrotext", nil)
        setAttribute("target-slot", nil)
    elseif action.kind == "apply" then
        local source = action.source
        if source.kind == "spell" then
            setAttribute("type", "spell")
            setAttribute("spell", (Sources:GetDisplay(source)))
            setAttribute("item", nil)
        else
            setAttribute("type", "item")
            setAttribute("item", "item:" .. source.itemID)
            setAttribute("spell", nil)
        end
        setAttribute("macrotext", nil)
        -- Blizzard's secure handler only uses this while a spell is waiting for
        -- an item target, i.e. "use the oil, then click this weapon slot".
        setAttribute("target-slot", action.slot.invSlot)
    else
        setAttribute("type", "macro")
        setAttribute("macrotext", action.macrotext)
        setAttribute("spell", nil)
        setAttribute("item", nil)
        setAttribute("target-slot", nil)
    end
end

local function renderFixButton()
    local action = PlayerFrame.action
    local icon, label, countText, usable = PLACEHOLDER_ICON, "", "", true
    if action and action.kind == "apply" then
        local _, sourceIcon = Sources:GetDisplay(action.source)
        icon = sourceIcon or icon
        local available, count = Sources:GetAvailability(action.source)
        usable = available
        if count then
            countText = tostring(count)
        end
    elseif action then
        icon = action.icon or icon
        label = action.label or ""
    end
    fix.icon:SetTexture(icon)
    fix.icon:SetDesaturated(not usable)
    fix.icon:SetAlpha(action and 1 or 0.35)
    fix.label:SetText(label)
    fix.count:SetText(countText)
end

function PlayerFrame:ApplyAction(action)
    local signature = actionSignature(action)
    if signature ~= self.wiredSignature then
        if InCombatLockdown() then
            self.actionPending = true -- picked up again on COMBAT_END
            return
        end
        wireAction(action)
        self.wiredSignature = signature
    end
    self.actionPending = nil
    self.action = action
end

------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------
local function showRowTooltip(pick)
    local data = pick:GetParent().data
    if not data then
        return
    end
    GameTooltip:SetOwner(pick, "ANCHOR_RIGHT")
    local typeLabel = ns.Enchants.TYPE_LABELS[data.typeKey] or data.typeKey
    GameTooltip:SetText(data.slot.name .. " - " .. typeLabel)
    if data.entry then
        local suffix = data.pulsed and " (from a totem or another player)" or ""
        GameTooltip:AddLine("Now: " .. (data.name or "weapon buff") .. suffix, 1, 1, 1, true)
    else
        GameTooltip:AddLine("Now: nothing", 1, 1, 1)
    end
    if data.desire then
        local mode = data.desire.pinned and "pinned" or "auto - follows what you apply"
        GameTooltip:AddLine("Tracking: " .. (data.desiredName or "?") .. " (" .. mode .. ")", 1, 0.82, 0, true)
    elseif data.untracked then
        GameTooltip:AddLine("Not tracked", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("Not tracked yet - buffs you apply yourself are picked up automatically.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine("Click to choose what to track", 0.5, 1, 0.5)
    GameTooltip:Show()
end

local function createRow(index)
    local row = CreateFrame("Frame", nil, bg)
    row:SetSize(ICON + ICON_GAP + BAR_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", bg, "TOPLEFT", PAD + BUTTON + GAP, -(PAD + (index - 1) * (ROW_HEIGHT + ROW_GAP)))

    local pick = CreateFrame("Button", nil, row)
    pick:SetSize(ICON, ICON)
    pick:SetPoint("LEFT", row, "LEFT", 0, 0)
    pick:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pick:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    pick.icon = pick:CreateTexture(nil, "ARTWORK")
    pick.icon:SetAllPoints(pick)
    pick.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    pick.pin = pick:CreateTexture(nil, "OVERLAY")
    pick.pin:SetSize(6, 6)
    pick.pin:SetPoint("TOPRIGHT", pick, "TOPRIGHT", 1, 1)
    pick.pin:SetColorTexture(1, 0.82, 0, 1)
    pick:SetScript("OnClick", function(self)
        if ns.Picker and row.data then
            ns.Picker:Toggle(row.data, PlayerFrame.setup, self)
        end
    end)
    pick:SetScript("OnEnter", showRowTooltip)
    pick:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.pick = pick

    row.barBackground = row:CreateTexture(nil, "BACKGROUND")
    row.barBackground:SetSize(BAR_WIDTH, ROW_HEIGHT)
    row.barBackground:SetPoint("LEFT", pick, "RIGHT", ICON_GAP, 0)
    row.barBackground:SetColorTexture(unpack(BAR_BACKGROUND))

    row.bar = row:CreateTexture(nil, "BORDER")
    row.bar:SetHeight(ROW_HEIGHT)
    row.bar:SetPoint("LEFT", row.barBackground, "LEFT", 0, 0)

    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.time:SetPoint("RIGHT", row.barBackground, "RIGHT", -4, 0)
    row.time:SetJustifyH("RIGHT")

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.barBackground, "LEFT", 4, 0)
    row.text:SetWidth(BAR_WIDTH - 46)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    return row
end

local function renderRow(row, data)
    row.data = data
    local color = STATUS_COLORS[data.status] or STATUS_COLORS.INFO
    local label = "|cffaaaaaa" .. data.slot.label .. "|r "
    local fraction, text, timeText, icon, desaturate

    if data.status == "MISSING" or data.status == "WRONG" then
        fraction = 1
        text = label .. "Rebuff " .. (data.desiredName or "?")
        timeText = ""
        icon = data.desiredIcon
        desaturate = true
    elseif data.status == "KNIFE" then
        fraction = 1
        text = label .. (data.knifeText or "Equip weapon")
        timeText = ""
        icon = data.icon or data.desiredIcon
        desaturate = true
    else
        fraction = math.min(1, data.remaining / data.fullDuration) -- full at application, empty at expiry
        text = label .. (data.name or "Weapon buff")
        timeText = formatTime(data.remaining)
        icon = data.icon or data.desiredIcon
        desaturate = false
    end

    row.bar:SetWidth(math.max(1, BAR_WIDTH * fraction))
    row.bar:SetColorTexture(color[1], color[2], color[3], color[4])
    row.text:SetText(text)
    row.time:SetText(timeText)
    row.pick.icon:SetTexture(icon or PLACEHOLDER_ICON)
    row.pick.icon:SetDesaturated(desaturate)
    row.pick.pin:SetShown(data.desire and data.desire.pinned and true or false)
    row:SetAlpha(data.untracked and 0.6 or 1)
    row:Show()
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------
function PlayerFrame:Refresh()
    if not main then
        return
    end
    local rows, setup = Tracker:BuildRows()
    self.rows, self.setup = rows, setup

    for index, data in ipairs(rows) do
        rowFrames[index] = rowFrames[index] or createRow(index)
        renderRow(rowFrames[index], data)
    end
    for index = #rows + 1, #rowFrames do
        rowFrames[index].data = nil
        rowFrames[index]:Hide()
    end
    hint:SetShown(#rows == 0)
    self.hasRows = #rows > 0
    self:UpdateVisibility()

    local rowsHeight = #rows * (ROW_HEIGHT + ROW_GAP) - ROW_GAP
    bg:SetSize(PAD + BUTTON + GAP + ICON + ICON_GAP + BAR_WIDTH + PAD, PAD + math.max(BUTTON, rowsHeight) + PAD)

    self:ApplyAction(Tracker:ChooseFix(rows, setup))
    renderFixButton()

    if Tracker:IsUrgent(rows) then
        if not fix.flash:IsPlaying() then
            fix.flash:Play()
        end
    elseif fix.flash:IsPlaying() then
        fix.flash:Stop()
    end
end

function PlayerFrame:RequestRefresh()
    if self.refreshQueued then
        return
    end
    self.refreshQueued = true
    C_Timer.After(0.05, function()
        self.refreshQueued = false
        ns.SafeCall(self.Refresh, self)
    end)
end

-- Nothing on the weapons and nothing tracked (a fresh character, a caster who
-- never buffs a weapon): stay out of the way until there is something to show.
--
-- The backdrop with its rows is an ordinary frame and follows immediately, even
-- mid-fight (a Windfury Totem pulse landing on you). `main` carries the secure
-- button, so IT can only be shown or hidden once combat is over.
function PlayerFrame:UpdateVisibility()
    if not main then
        return
    end
    local wanted = ns:GetOption("shown") and (self.hasRows or ns:GetOption("showWhenEmpty")) and true or false
    if bg:IsShown() ~= wanted then
        bg:SetShown(wanted)
    end
    if main:IsShown() == wanted then
        self.visibilityPending = nil
    elseif InCombatLockdown() then
        self.visibilityPending = true
    else
        self.visibilityPending = nil
        main:SetShown(wanted)
    end
end

function PlayerFrame:GetBackdropFrame()
    return bg
end

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------
local function create()
    main = CreateFrame("Frame", "AKForeverWeaponBuffsFrame", UIParent)
    main:SetSize(BUTTON, BUTTON)
    main:SetMovable(true)
    main:SetClampedToScreen(true)
    -- `main` is only the button; clamp as if it were the whole backdrop.
    main:SetClampRectInsets(-PAD, GAP + ICON + ICON_GAP + BAR_WIDTH + PAD, PAD, -PAD)
    restorePosition()

    -- Deliberately NOT a child of `main`: anchored to it (so it moves with it), but
    -- free to appear while `main` has to stay hidden until combat ends.
    bg = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    bg:SetPoint("TOPLEFT", main, "TOPLEFT", -PAD, PAD)
    bg:SetFrameLevel(main:GetFrameLevel())
    bg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    bg:SetBackdropColor(0, 0, 0, 0.9)
    bg:EnableMouse(true)
    bg:RegisterForDrag("LeftButton")
    bg:SetScript("OnDragStart", function()
        if not InCombatLockdown() then
            main:StartMoving()
        end
    end)
    bg:SetScript("OnDragStop", function()
        pcall(main.StopMovingOrSizing, main)
        pcall(main.SetUserPlaced, main, false) -- position lives in our own saved variables
        savePosition()
    end)

    hint = bg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", bg, "LEFT", PAD + BUTTON + GAP, 0)
    hint:SetWidth(ICON + ICON_GAP + BAR_WIDTH)
    hint:SetJustifyH("LEFT")
    hint:SetText("Apply a weapon buff\nto start tracking it.")

    fix = CreateFrame("Button", "AKForeverWeaponBuffsFixButton", main, "SecureActionButtonTemplate")
    fix:SetAllPoints(main)
    fix:SetFrameLevel(main:GetFrameLevel() + 3)
    fix:RegisterForClicks("AnyUp", "AnyDown") -- works with either ActionButtonUseKeyDown setting

    fix.icon = fix:CreateTexture(nil, "ARTWORK")
    fix.icon:SetAllPoints(fix)
    fix.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    fix.label = fix:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fix.label:SetPoint("CENTER", fix, "CENTER", 0, 0)

    fix.count = fix:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    fix.count:SetPoint("BOTTOMRIGHT", fix, "BOTTOMRIGHT", -2, 2)

    fix.border = fix:CreateTexture(nil, "OVERLAY")
    fix.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    fix.border:SetBlendMode("ADD")
    fix.border:SetSize(BUTTON * 1.7, BUTTON * 1.7)
    fix.border:SetPoint("CENTER", fix, "CENTER", 0, 0)
    fix.border:SetAlpha(0)

    fix.flash = fix.border:CreateAnimationGroup()
    fix.flash:SetLooping("BOUNCE")
    local fade = fix.flash:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.6)

    fix:SetScript("OnEnter", showFixTooltip)
    fix:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    PlayerFrame:UpdateVisibility()
    PlayerFrame:Refresh()
    ns:Fire("PLAYER_FRAME_READY", bg)

    C_Timer.NewTicker(0.5, function()
        PlayerFrame:RequestRefresh()
    end)
end

ns:Listen("LOGIN", create)

for _, message in ipairs({ "ENCHANTS_CHANGED", "ENCHANT_APPLIED", "SOURCES_CHANGED", "PREFS_CHANGED", "WEAPONS_CHANGED" }) do
    ns:Listen(message, function()
        PlayerFrame:RequestRefresh()
    end)
end

ns:Listen("COMBAT_END", function()
    if PlayerFrame.visibilityPending then
        PlayerFrame:UpdateVisibility()
    end
    PlayerFrame:RequestRefresh() -- wires any action that was waiting for combat to end
end)

ns:Listen("OPTION_CHANGED", function(_, key)
    if key == "shown" or key == "showWhenEmpty" then
        PlayerFrame:UpdateVisibility()
    end
    PlayerFrame:RequestRefresh()
end)

ns:RegisterCommand("empty", "toggle showing the frame while there is nothing to track (handy for placing it)", function()
    local enabled = not ns:GetOption("showWhenEmpty")
    ns:SetOption("showWhenEmpty", enabled)
    ns:Print(enabled and "the frame now stays visible with nothing to track." or "the frame hides again when there is nothing to track.")
end)

ns:RegisterCommand("show", "show the weapon buff frame", function()
    ns:SetOption("shown", true)
end)

ns:RegisterCommand("hide", "hide the weapon buff frame", function()
    ns:SetOption("shown", false)
end)

ns:RegisterCommand("reset", "move the frame back to the middle of the screen", function()
    if InCombatLockdown() then
        ns:Print("can't move the frame in combat.")
        return
    end
    ns.cdb.position = nil
    restorePosition()
end)
