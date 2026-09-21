-- Party panel: what is on everyone else's weapons, as told by their AKForeverWeaponBuffs.
-- Pulsed entries (totem buffs such as Windfury Totem) get a green frame so a
-- shaman can see at a glance who is actually receiving the totem.
local _, ns = ...

local Comms = ns.Comms

local PartyPanel = {}
ns.PartyPanel = PartyPanel

local PAD, ROW_HEIGHT, NAME_WIDTH, ICON, ICON_GAP, MAX_ICONS = 8, 24, 84, 20, 4, 4
local MAX_ROWS = 5 -- four party members + an optional loopback row for solo testing
local TIMER_MIN_SECONDS = 60 -- shorter buffs are pulsed; their countdown would only mislead
local SLOT_LETTERS = { MH = "M", OH = "O", RG = "R" }

local frame, title
local rowFrames = {}
PartyPanel.rows = rowFrames -- read by the tests

local function classColor(unit)
    local _, classFile = UnitClass(unit)
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

local function showIconTooltip(self)
    local entry = self.entry
    if not entry then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(entry.name or ("Weapon buff #" .. entry.enchantID))
    local slot = ns.Enchants.SLOT_BY_KEY[entry.slotKey]
    GameTooltip:AddLine((slot and slot.name or entry.slotKey) .. " - " .. (ns.Enchants.TYPE_LABELS[entry.typeKey] or entry.typeKey), 1, 1, 1)
    if entry.pulsed then
        GameTooltip:AddLine("Pulsed buff from a totem or another player", 0.4, 1, 0.4, true)
    elseif entry.selfApplied then
        GameTooltip:AddLine("Applied by this player", 0.8, 0.8, 0.8)
    end
    local remaining = entry.expiresAt - GetTime()
    if not entry.pulsed and remaining > 0 then
        GameTooltip:AddLine(ns.PlayerFrame.FormatTime(remaining) .. " left", 1, 0.82, 0)
    end
    GameTooltip:Show()
end

-- Growing DOWN (default): the panel hangs under your own weapon buff frame, rows listed downwards.
-- Growing UP (option partyGrowUp, '/wb party up'): it sits on top of that frame with its bottom edge
-- fixed; the first member is the row nearest to you and new rows appear above - nobody's row moves.
local function placeRow(row, index, growUp)
    row:ClearAllPoints()
    if growUp then
        row:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD + (index - 1) * ROW_HEIGHT)
    else
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 14 + (index - 1) * ROW_HEIGHT))
    end
end

local function createRow()
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(NAME_WIDTH + MAX_ICONS * (ICON + ICON_GAP), ROW_HEIGHT)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.name:SetWidth(NAME_WIDTH - 4)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.note:SetPoint("LEFT", row, "LEFT", NAME_WIDTH, 0)

    row.icons = {}
    for i = 1, MAX_ICONS do
        local icon = CreateFrame("Frame", nil, row)
        icon:SetSize(ICON, ICON)
        icon:SetPoint("LEFT", row, "LEFT", NAME_WIDTH + (i - 1) * (ICON + ICON_GAP), 0)
        icon:EnableMouse(true)

        icon.glow = icon:CreateTexture(nil, "BACKGROUND")
        icon.glow:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
        icon.glow:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
        icon.glow:SetColorTexture(0.2, 1, 0.2, 0.9)

        icon.texture = icon:CreateTexture(nil, "ARTWORK")
        icon.texture:SetAllPoints(icon)
        icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        icon.slot = icon:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        icon.slot:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
        local font, _, flags = icon.slot:GetFont()
        if font then
            icon.slot:SetFont(font, 8, "OUTLINE")
        end

        icon.time = icon:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        icon.time:SetPoint("BOTTOM", icon, "BOTTOM", 0, -1)
        if font then
            icon.time:SetFont(font, 8, "OUTLINE")
        end

        icon:SetScript("OnEnter", showIconTooltip)
        icon:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        row.icons[i] = icon
    end
    return row
end

local function shortTime(seconds)
    if seconds >= 60 then
        return math.floor(seconds / 60 + 0.5) .. "m"
    end
    return math.floor(seconds) .. "s"
end

local function renderRow(row, member, now)
    row.name:SetText(member.displayName)
    row.name:SetTextColor(member.r, member.g, member.b)

    local entries = member.state.entries or {}
    -- They run the addon and have nothing on their weapons: that IS information (the rogue without poison).
    row.note:SetText(#entries == 0 and "no weapon buffs" or "")

    for i = 1, MAX_ICONS do
        local icon, entry = row.icons[i], entries[i]
        icon.entry = entry
        if entry then
            icon.texture:SetTexture(entry.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon.glow:SetShown(entry.pulsed)
            icon.slot:SetText(SLOT_LETTERS[entry.slotKey] or "")
            local remaining = entry.expiresAt - now
            if entry.pulsed or entry.secondsLeft < TIMER_MIN_SECONDS then
                icon.time:SetText("")
                icon.texture:SetDesaturated(false)
            elseif remaining > 0 then
                icon.time:SetText(shortTime(remaining))
                icon.texture:SetDesaturated(false)
            else
                icon.time:SetText("?") -- should have expired; waiting for their next update
                icon.texture:SetDesaturated(true)
            end
            icon:Show()
        else
            icon:Hide()
        end
    end
    row:Show()
end

local function collectMembers()
    local members = {}
    if IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local fullName = GetUnitName(unit, true)
                -- No data from them (they do not run the addon, or nothing has arrived yet): no row. A
                -- panel full of "no addon data" says nothing - and with nobody to show, there is no panel.
                local state = Comms.roster[fullName]
                if state then
                    local r, g, b = classColor(unit)
                    members[#members + 1] = { displayName = UnitName(unit) or fullName, r = r, g = g, b = b, state = state }
                end
            end
        end
    end
    -- '/wb comms test' whispers our own state back to us: show it, so the panel
    -- can be checked without a second player.
    for name, state in pairs(Comms.roster) do
        if state.loopback and #members < MAX_ROWS then
            members[#members + 1] = { displayName = name .. " (test)", r = 0.7, g = 0.7, b = 0.7, state = state }
        end
    end
    return members
end

function PartyPanel:Refresh()
    if not frame then
        return
    end
    local members = ns:GetOption("partyPanel") and collectMembers() or {}
    if #members == 0 then
        frame:Hide()
        return
    end
    local now = GetTime()
    local growUp = ns:GetOption("partyGrowUp") and true or false
    for index, member in ipairs(members) do
        rowFrames[index] = rowFrames[index] or createRow()
        placeRow(rowFrames[index], index, growUp)
        renderRow(rowFrames[index], member, now)
    end
    for index = #members + 1, #rowFrames do
        rowFrames[index]:Hide()
    end
    frame:SetSize(PAD * 2 + NAME_WIDTH + MAX_ICONS * (ICON + ICON_GAP), PAD + 14 + #members * ROW_HEIGHT + PAD)
    frame:Show()
end

local playerFrame -- your own weapon buff frame: the panel hangs under it, or sits on top of it

local function applyDirection()
    if not (frame and playerFrame) then
        return
    end
    frame:ClearAllPoints()
    if ns:GetOption("partyGrowUp") then
        frame:SetPoint("BOTTOMLEFT", playerFrame, "TOPLEFT", 0, 4) -- that corner never moves: the frame grows downwards
    else
        frame:SetPoint("TOPLEFT", playerFrame, "BOTTOMLEFT", 0, -4)
    end
end

ns:Listen("PLAYER_FRAME_READY", function(_, anchor)
    playerFrame = anchor
    frame = CreateFrame("Frame", "AKForeverWeaponBuffsPartyPanel", UIParent, "BackdropTemplate")
    applyDirection()
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:Hide()

    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    title:SetText("Party weapon buffs")

    PartyPanel:Refresh()
    C_Timer.NewTicker(1, function()
        ns.SafeCall(PartyPanel.Refresh, PartyPanel)
    end)
end)

ns:Listen("ROSTER_CHANGED", function()
    PartyPanel:Refresh()
end)

ns:On("GROUP_ROSTER_UPDATE", function()
    PartyPanel:Refresh()
end)

ns:Listen("OPTION_CHANGED", function(_, key)
    if key == "partyPanel" then
        PartyPanel:Refresh()
    elseif key == "partyGrowUp" then
        applyDirection()
        PartyPanel:Refresh()
    end
end)

ns:RegisterCommand("party", "toggle the party panel; 'up' / 'down': which way it grows from your own frame", function(rest)
    local mode = string.lower(rest or "")
    if mode == "up" or mode == "down" then
        ns:SetOption("partyGrowUp", mode == "up")
        ns:Print("party panel grows", mode .. (mode == "up" and " (it sits on top of your own frame now)." or "."))
        return
    end
    local enabled = not ns:GetOption("partyPanel")
    ns:SetOption("partyPanel", enabled)
    ns:Print("party panel", enabled and "on" or "off", "- grows", ns:GetOption("partyGrowUp") and "up" or "down",
        "(|cffffd100/wb party up|r / |cffffd100down|r)")
end)
