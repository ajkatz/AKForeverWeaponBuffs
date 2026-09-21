-- The scenario that covered it (tests/run.lua, v2.0.2).
scenario("shield counter reads charges and degrades when auras are locked", function()
    local ns, state = start({ class = "SHAMAN" }, function(s)
        s.equipment[16] = MACE_2H
        s.auras["Lightning Shield"] = 3
    end)
    Mock.fire("UNIT_AURA", "player")
    state.aurasBlocked = true
    Mock.fire("UNIT_AURA", "player")
    local blocked = false
    for _, entry in ipairs(ns.sessionLog) do
        if entry.k == "shield_read_blocked" then
            blocked = true
        end
    end
    check(blocked, "blocked aura read should be logged, not raised")
end)
