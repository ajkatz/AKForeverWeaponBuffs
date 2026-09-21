-- Picker: choose what a weapon row should track. Self-built popup on purpose -
-- Blizzard's dropdown/menu systems have been replaced twice already, and this
-- addon is meant to keep working.
local _, ns = ...

local Sources, Tracker = ns.Sources, ns.Tracker

local Picker = {}
ns.Picker = Picker

local WIDTH, ENTRY_HEIGHT, PAD = 230, 20, 8

local frame, catcher, title, footer
local entryButtons = {}

local function close()
    if frame then
        frame:Hide()
    end
end

local function createEntry(index)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(WIDTH - PAD * 2, ENTRY_HEIGHT)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 16 + (index - 1) * ENTRY_HEIGHT))
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    button.check = button:CreateTexture(nil, "ARTWORK")
    button.check:SetSize(14, 14)
    button.check:SetPoint("LEFT", button, "LEFT", 0, 0)
    button.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(16, 16)
    button.icon:SetPoint("LEFT", button, "LEFT", 16, 0)
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.text:SetPoint("LEFT", button, "LEFT", 36, 0)
    button.text:SetPoint("RIGHT", button, "RIGHT", -2, 0)
    button.text:SetJustifyH("LEFT")
    button.text:SetWordWrap(false)

    button:SetScript("OnClick", function(self, mouseButton)
        local option = self.option
        if not option then
            return
        end
        if mouseButton == "RightButton" then
            if option.sourceKey then
                Sources:Forget(option.sourceKey)
                close()
            end
            return
        end
        option.select()
        close()
    end)
    return button
end

local function create()
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", close)
    catcher:Hide()

    frame = CreateFrame("Frame", "AKForeverWeaponBuffsPicker", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(catcher:GetFrameLevel() + 10)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)
    frame:Hide()
    frame:SetScript("OnShow", function()
        catcher:Show()
    end)
    frame:SetScript("OnHide", function()
        catcher:Hide()
    end)
    table.insert(UISpecialFrames, "AKForeverWeaponBuffsPicker") -- Escape closes it

    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)

    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    footer:SetText("Right-click a buff to forget it")
end

local function buildOptions(row, setup)
    local desire = row.desire
    local options = {}

    options[#options + 1] = {
        text = "Auto: track whatever I apply",
        checked = not row.untracked and not (desire and desire.pinned),
        select = function()
            Tracker:SetAuto(setup, row.rowKey)
        end,
    }

    for _, source in ipairs(Sources:ListForType(row.typeKey)) do
        local name, icon = Sources:GetDisplay(source)
        local available, count = Sources:GetAvailability(source)
        if count then
            name = name .. " |cffaaaaaa(" .. count .. ")|r"
        end
        local sourceKey = source.key
        options[#options + 1] = {
            text = name,
            icon = icon,
            dimmed = not available,
            sourceKey = sourceKey,
            checked = desire and desire.pinned and desire.key == sourceKey or false,
            select = function()
                Tracker:Pin(setup, row.rowKey, sourceKey)
            end,
        }
    end

    options[#options + 1] = {
        text = "Don't track this",
        checked = row.untracked and true or false,
        select = function()
            Tracker:SetNone(setup, row.rowKey)
        end,
    }
    return options
end

function Picker:Toggle(row, setup, anchor)
    if not frame then
        create()
    end
    if frame:IsShown() and self.rowKey == row.rowKey then
        close()
        return
    end
    self.rowKey = row.rowKey

    local typeLabel = ns.Enchants.TYPE_LABELS[row.typeKey] or row.typeKey
    title:SetText(row.slot.name .. " - " .. typeLabel)

    local options = buildOptions(row, setup)
    for index, option in ipairs(options) do
        local button = entryButtons[index] or createEntry(index)
        entryButtons[index] = button
        button.option = option
        button.text:SetText(option.text)
        button.text:SetAlpha(option.dimmed and 0.5 or 1)
        button.icon:SetTexture(option.icon)
        button.icon:SetShown(option.icon ~= nil)
        button.icon:SetDesaturated(option.dimmed and true or false)
        button.check:SetShown(option.checked and true or false)
        button:Show()
    end
    for index = #options + 1, #entryButtons do
        entryButtons[index].option = nil
        entryButtons[index]:Hide()
    end

    frame:SetSize(WIDTH, PAD + 16 + #options * ENTRY_HEIGHT + 6 + 12 + PAD)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    frame:Show()
end

function Picker:Close()
    close()
end
