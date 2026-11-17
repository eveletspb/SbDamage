-- Run with a Lua interpreter from the addon directory, after loading
-- Core.lua, Nameplates.lua and Renderer.lua. No WoW client is required.
local addon = SbDamage
local passed, failed = 0, 0
local function test(name, run)
    local ok, err = pcall(run)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function near(actual, expected)
    assert(math.abs(actual - expected) < 0.00001,
        tostring(actual) .. " ~= " .. tostring(expected))
end

local clock, selectedGUID, selectedName = 0, nil, nil
local plates = {}
GetTime = function() return clock end
UnitGUID = function(unit) if unit == "target" then return selectedGUID end end
UnitName = function(unit) if unit == "target" then return selectedName end end
UIParent = {
    GetCenter = function() return 600, 400 end,
    GetWidth = function() return 1200 end,
    GetHeight = function() return 800 end,
    GetEffectiveScale = function() return 0.8 end,
}
WorldFrame = { GetChildren = function() return (unpack or table.unpack)(plates) end }
local function plate(name, alpha, x, y)
    return {
        done = true, name = name, alpha = alpha or 0.5,
        x = x or 0, y = y or 0, visible = true,
        GetRegions = function() end,
        IsVisible = function(self) return self.visible end,
        GetAlpha = function(self) return self.alpha end,
        GetCenter = function(self) return 600 + self.x, 400 + self.y end,
        GetEffectiveScale = function() return 0.8 end,
    }
end
local function reset()
    clock = clock + 10
    selectedGUID, selectedName = nil, nil
    plates = {}
    addon.db = addon:SanitizeSettings({})
    addon.db.layout.aoeMode = "exact"
    addon.activeMessages, addon.freeMessages = {}, {}
    addon.nextNameplateScan, addon.nextDamageTargetRefresh = nil, nil
    addon.destinationNameplates = nil
    addon.anchor = plate("fallback", 1, -100, -80)
    addon.rendererFrame = { SetScript = function() end }
end
local function message(damage)
    local m = {
        damage = damage, elapsed = 0, duration = 1,
        critical = damage.critical, visualScale = 1,
        streamType = "direct", layoutWidth = 60, layoutHeight = 30,
        anchor = UIParent, baseX = 200, baseY = 100,
        text = { SetText = function() end },
        icon = { SetTexture = function() end, Hide = function() end,
            SetVertexColor = function() end },
        ClearAllPoints = function() end,
        SetPoint = function(self, _, _, _, x, y) self.pointX, self.pointY = x, y end,
        SetScale = function(self, value) self.scale = value end,
        SetAlpha = function(self, value) self.alpha = value end,
        Hide = function() end,
    }
    m.targetFrame, m.streamTarget = addon:GetDamagePlacement(damage, clock)
    addon.activeMessages[#addon.activeMessages + 1] = m
    local x, y = addon:GetDamageOrigin(m.targetFrame)
    addon:LayoutDamageCluster(m.streamTarget, x, y)
    return m
end

test("ambiguous duplicate names use fallback", function()
    reset()
    plates = { plate("Mob"), plate("Mob") }
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == nil)
end)
test("selecting another identical mob resolves its current plate", function()
    reset()
    local a, b = plate("Mob", 1), plate("Mob", 0.5)
    plates = { a, b }
    selectedGUID, selectedName = "A", "Mob"
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == a)
    a.alpha, b.alpha = 0.5, 1
    clock = clock + 1
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == b)
end)
test("nonselected same-name target cannot steal selected plate", function()
    reset()
    plates = { plate("Mob", 1) }
    selectedGUID, selectedName = "A", "Mob"
    assert(addon:FindNameplate({ destinationGUID = "B", destinationName = "Mob" }, clock) == nil)
end)
test("unmatched selected name does not use an unrelated plate", function()
    reset()
    plates = { plate("Other", 1) }
    selectedGUID, selectedName = "A", "Mob"
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == nil)
end)
test("offscreen selected target cannot steal a same-name unselected plate", function()
    reset()
    plates = { plate("Mob", 0.5) }
    selectedGUID, selectedName = "A", "Mob"
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == nil)
end)
test("unique name still resolves", function()
    reset()
    plates = { plate("Mob") }
    assert(addon:FindNameplate({ destinationGUID = "A", destinationName = "Mob" }, clock) == plates[1])
end)
test("hidden plate is rejected before next scan", function()
    reset()
    plates = { plate("Mob", 1) }
    local damage = { destinationGUID = "A", destinationName = "Mob" }
    assert(addon:FindNameplate(damage, clock) == plates[1])
    plates[1].visible = false
    assert(addon:FindNameplate(damage, clock + 0.01) == nil)
end)
test("many unique GUIDs leave no identity cache", function()
    reset()
    plates = { plate("Mob") }
    for i = 1, 1000 do
        addon:FindNameplate({ destinationGUID = tostring(i), destinationName = "Mob" }, clock)
    end
    assert(not addon.destinationNameplates or next(addon.destinationNameplates) == nil)
end)
test("moving plate updates active hit without another hit", function()
    reset()
    plates = { plate("Mob", 1, 200, 40) }
    local m = message({ destinationGUID = "A", destinationName = "Mob" })
    local x, y = m.baseX, m.baseY
    plates[1].x, plates[1].y = 260, 70
    addon:OnRendererUpdate(0.01)
    near(m.baseX, x + 60)
    near(m.baseY, y + 30)
    near(m.elapsed, 0.01)
end)
test("hidden plate moves active hit to fallback immediately", function()
    reset()
    plates = { plate("Mob", 1, 200, 40) }
    local m = message({ destinationGUID = "A", destinationName = "Mob" })
    plates[1].visible = false
    addon:OnRendererUpdate(0.01)
    assert(m.targetFrame == nil and m.streamTarget == addon.anchor)
    near(m.baseX, -100)
    near(m.baseY, -80)
end)
test("fallback hit reacquires a newly visible plate", function()
    reset()
    local m = message({ destinationGUID = "A", destinationName = "Mob" })
    plates = { plate("Mob", 1, 200, 40) }
    clock = clock + 0.11
    addon:OnRendererUpdate(0.01)
    assert(m.targetFrame == plates[1])
    near(m.baseX, 200)
end)
test("fallback follows the configured anchor", function()
    reset()
    local m = message({})
    addon.anchor.x, addon.anchor.y = -140, -120
    addon:OnRendererUpdate(0.01)
    near(m.baseX, -140)
    near(m.baseY, -120)
end)
test("focus mode follows a changed selected target", function()
    reset()
    addon.db.layout.aoeMode = "focus"
    plates = { plate("First", 1, 100, 20), plate("Second", 0.5, -200, 60) }
    selectedGUID, selectedName = "A", "First"
    local m = message({ destinationGUID = "A", destinationName = "First" })
    selectedGUID, selectedName = "B", "Second"
    plates[1].alpha, plates[2].alpha = 0.5, 1
    clock = clock + 0.11
    addon:OnRendererUpdate(0.01)
    assert(m.targetFrame == plates[2])
    near(m.baseX, -200)
end)
test("merging hidden target streams preserves the configured limit", function()
    reset()
    addon.db.layout.maxPerColumn = 3
    plates = { plate("First", 1, 100, 20), plate("Second", 0.5, -200, 60) }
    for i = 1, 3 do
        message({ destinationGUID = "A", destinationName = "First" })
        message({ destinationGUID = "B", destinationName = "Second" })
    end
    plates[1].visible, plates[2].visible = false, false
    addon:OnRendererUpdate(0.01)
    assert(#addon.activeMessages == 3)
    for _, m in ipairs(addon.activeMessages) do assert(m.streamTarget == addon.anchor) end
end)
test("screen clamping does not relayout an unchanged cluster every frame", function()
    reset()
    plates = { plate("Mob", 1, 2000, 40) }
    message({ destinationGUID = "A", destinationName = "Mob" })
    local original = addon.LayoutDamageCluster
    local calls = 0
    addon.LayoutDamageCluster = function(self, ...)
        calls = calls + 1
        return original(self, ...)
    end
    addon:OnRendererUpdate(0.01)
    addon:OnRendererUpdate(0.01)
    addon.LayoutDamageCluster = original
    assert(calls == 0, "unnecessary relayouts: " .. calls)
end)
test("critical pulse and pet scales preserve screen-space center", function()
    reset()
    local m = message({ critical = true })
    m.baseX, m.baseY = 300, -200
    for _, mode in ipairs({ "none", "shake", "scale", "combined" }) do
        addon.db.critAnimation = mode
        for _, scale in ipairs({ 0.5, 0.85, 1, 2 }) do
            for _, progress in ipairs({ 0, 0.05, 0.175, 0.35, 0.8 }) do
                m.visualScale, m.elapsed = scale, progress
                addon:UpdateDamageMessage(m, 0)
                -- WoW offsets are in the scaled frame's coordinate system.
                near(m.pointX * m.scale, m.currentX)
                near(m.pointY * m.scale, m.currentY)
                if mode == "none" or mode == "scale" then near(m.currentX, 300) end
                near(m.currentY, -200 + 42 * progress)
            end
        end
    end
end)
test("expired messages are released after tracking", function()
    reset()
    message({})
    addon:OnRendererUpdate(1.1)
    assert(#addon.activeMessages == 0 and #addon.freeMessages == 1)
end)
print("Results: " .. passed .. " passed, " .. failed .. " failed")
assert(failed == 0, "regression tests failed")
