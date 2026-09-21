-- PARKED 2026-09-19 (AKForeverWeaponBuffs v2.0.3): the shaman shield charge counter, taken out of Shaman.lua
-- on request. Kept here, not loaded by the game (not in the .toc), for a possible bigger rebuild.
--
-- What it did: a strip at the bottom of your weapon buff frame with one row of dashes per shield
-- (Lightning / Water / Earth Shield), one dash per charge, read with AuraUtil.FindAuraByName on
-- UNIT_AURA; when the client would not say (aura data is secret to addons in combat on the
-- Forever client) the last value stayed up, dimmed.
--
-- If it comes back: charges are an aura's "applications" - secret in combat unless Blizzard flags
-- the spell never-secret. ForeverSwingTimers / AKForeverCombatTimers' buff experiment (/fst diag ->
-- buffs.samples) already watches Lightning Shield and records what the client reveals; a display-only
-- route exists (C_UnitAuras.GetAuraApplicationDisplayCount -> FontString:SetText). It hooked in with:
--     Shaman:GetExtraHeight()            -> UI/PlayerFrame.lua added it to the frame's height
--     ns:Listen("PLAYER_FRAME_READY")    -> created the strip on the frame's background
-- and needs `local _, ns = ...`, `isShaman()` and a `Shaman` table like Shaman.lua has.

------------------------------------------------------------------------
-- 1. Shield charge counter
------------------------------------------------------------------------
local STRIP_HEIGHT = 14

-- Spell IDs are only used to get a localized name; English is the fallback.
local SHIELDS = {
    { spellID = 324, fallback = "Lightning Shield", color = { 0, 0.45, 0.85 }, offsetY = 5 },
    { spellID = 24398, fallback = "Water Shield", color = { 0.43, 0.79, 0.94 }, offsetY = 5 },
    { spellID = 974, fallback = "Earth Shield", color = { 0, 0.85, 0.45 }, offsetY = -3 },
}

local strip

function Shaman:GetExtraHeight()
    return (strip and isShaman()) and STRIP_HEIGHT or 0
end

-- charges, or nil + reason when the client will not tell us (auras are locked
-- to addons in combat on the Midnight-era API)
local function readCharges(auraName)
    if AuraUtil and AuraUtil.FindAuraByName then
        local ok, name, _, count = pcall(AuraUtil.FindAuraByName, auraName, "player", "HELPFUL")
        if not ok then
            return nil, "blocked"
        end
        if name == nil then
            return 0
        end
        if ns.AnySecret(name, count) then
            return nil, "secret"
        end
        return count or 0
    end
    if UnitBuff then
        for i = 1, 40 do
            local name, _, count = UnitBuff("player", i)
            if not name then
                break
            end
            if name == auraName then
                return count or 0
            end
        end
        return 0
    end
    return nil, "no aura API"
end

local function updateShields()
    if not strip then
        return
    end
    for _, shield in ipairs(SHIELDS) do
        local charges, reason = readCharges(shield.name)
        if charges then
            shield.text:SetText(string.rep("-", charges))
            shield.text:SetAlpha(1)
        else
            shield.text:SetAlpha(0.35) -- stale: keep the last known value, dimmed
            if shield.blockedReason ~= reason then
                shield.blockedReason = reason
                ns:Log("shield_read_blocked", { shield = shield.fallback, reason = reason })
            end
        end
    end
end

ns:Listen("PLAYER_FRAME_READY", function(_, anchor)
    if not isShaman() then
        return
    end
    strip = CreateFrame("Frame", nil, anchor)
    strip:SetHeight(STRIP_HEIGHT)
    strip:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 8, 6)
    strip:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -8, 6)

    for _, shield in ipairs(SHIELDS) do
        shield.name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(shield.spellID)) or shield.fallback
        shield.text = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        shield.text:SetPoint("LEFT", strip, "LEFT", 0, shield.offsetY)
        local font, _, flags = shield.text:GetFont()
        if font then
            shield.text:SetFont(font, 40, flags)
        end
        shield.text:SetTextColor(shield.color[1], shield.color[2], shield.color[3])
    end

    ns:OnPlayerUnit("UNIT_AURA", updateShields)
    ns:Listen("COMBAT_END", updateShields)
    updateShields()
    ns.PlayerFrame:RequestRefresh() -- make room for the strip
end)
