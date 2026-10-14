-- RarityBorders for WoW 3.3.5a
-- 1) Quality-colored glow around item buttons (bags, bank, character frame).
-- 2) Red tint on the icon of items the player cannot use (weapon skill not learned,
--    wrong armor type, class/skill/level requirement not met), like retail.
--
-- 0.9rc/1.0: bank bag-slot buttons are skipped (BankFrameItemButton_Update also fires for them and
--      their ID was being read as a slot of the main bank)
-- 0.8: /rb level removed (level-gated items are always tinted); /rb alpha folded into /rb border
-- 0.7: sparkle start angle is now random over the full 360 degrees
-- 0.6: glint layer removed; sparkles twinkle slower and linger a bit longer before fading
-- 0.5: sparkles rotate while they twinkle (random start angle)
-- 0.4: border / sparkle / trail are now independent on-off switches; slower comet
-- 0.3: experimental comet trail (/rb trail on)
-- 0.2: combat flicker fixes
--   * the stock UI resets icon colour in places that bypass ContainerFrame_Update
--     (lock changes call SetItemButtonDesaturated) -> tint is now re-applied there too
--   * a failed/empty tooltip scan never flips an item to "usable"; the last known state is kept
--   * usability cache is not cleared during combat (skill-up events fire constantly in a fight);
--     it is cleared once combat ends
--   * refreshes triggered by events are debounced

local ADDON = "RarityBorders"

local defaults = {
    minQuality = 2,      -- 0 poor, 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary, 6 artifact
    alpha = 0.9,
    tintUnusable = true,
    border = true,       -- quality-colored glow around the item
    sparkle = false,     -- EXPERIMENTAL: twinkling sparkles
    sparkles = 2,        -- sparkles per item (1-4)
    trail = false,       -- EXPERIMENTAL: comet trail running around the item edge
    trailSpeed = 1,      -- 0.25 .. 3, multiplier for the comet speed
}

local function DB()
    RarityBordersDB = RarityBordersDB or {}
    local d = RarityBordersDB
    if d.style ~= nil then            -- migrate the old single "style" setting (1.4/1.5)
        if d.border == nil then d.border = (d.style == "border" or d.style == "both") end
        if d.sparkle == nil then d.sparkle = (d.style == "sparkle" or d.style == "both") end
        d.style = nil
    end
    d.glint = nil                     -- removed in 1.8
    d.tintLevel = nil                 -- removed in 2.0
    for k, v in pairs(defaults) do
        if d[k] == nil then d[k] = v end
    end
    return d
end

----------------------------------------------------------------
-- Rarity border
----------------------------------------------------------------
local function GetBorder(button)
    if button.rbBorder then return button.rbBorder end
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetPoint("CENTER", button, "CENTER", 0, 0)
    local w, h = button:GetWidth(), button:GetHeight()
    if not w or w < 1 then w, h = 37, 37 end
    border:SetWidth(w * 1.75)
    border:SetHeight(h * 1.75)
    border:Hide()
    button.rbBorder = border
    return border
end

----------------------------------------------------------------
-- EXPERIMENTAL: twinkling sparkles (style "sparkle" or "both")
-- Each item gets a few small stars that fade in and out at random spots, each on its own
-- random timer, tinted with the item's quality colour (lightened towards white).
----------------------------------------------------------------
local SPARK_TEXTURE = "Interface\\Cooldown\\star4"
local activeSparks = {}      -- button -> true while the button should sparkle

-- 3.3.5a textures have no SetRotation, so rotate the texture coordinates instead.
-- The sampled area is enlarged by sqrt(2) so the star tips are not clipped while turning;
-- callers compensate by drawing the texture SIZE_COMP times bigger.
local SIZE_COMP = 1.41421356
local HALF_DIAG = 0.70710678
local function SetTexRotation(tex, angle)
    local c, s = math.cos(angle) * HALF_DIAG, math.sin(angle) * HALF_DIAG
    tex:SetTexCoord(
        0.5 - c + s, 0.5 - s - c,    -- upper left
        0.5 - c - s, 0.5 - s + c,    -- lower left
        0.5 + c + s, 0.5 + s - c,    -- upper right
        0.5 + c - s, 0.5 + s + c)    -- lower right
end

local function ResetSpark(s, button, initial)
    local w = button:GetWidth()
    if not w or w < 1 then w = 37 end
    s.wait = initial and (random() * 3) or (0.3 + random() * 2.2)   -- pause before next twinkle
    s.dur = 1.2 + random() * 0.9                                    -- length of one twinkle
    s.t = 0
    s.size = w * (0.45 + random() * 0.35)
    s.tex:ClearAllPoints()
    s.tex:SetPoint("CENTER", button, "CENTER", (random() - 0.5) * w * 0.7, (random() - 0.5) * w * 0.7)
    s.tex:SetAlpha(0)
    s.tex:Hide()
    s.angle0 = random() * (2 * math.pi)                              -- random start angle, full 360 degrees
    s.spin = ((random() < 0.5) and 1 or -1) * (math.pi / 12 + random() * (math.pi / 6))   -- 15-45 degrees over one twinkle
end

local function EnsureSparks(button, count)
    local sparks = button.rbSparks
    if not sparks then
        sparks = {}
        button.rbSparks = sparks
    end
    for i = #sparks + 1, count do
        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(SPARK_TEXTURE)
        tex:SetBlendMode("ADD")
        local s = { tex = tex }
        ResetSpark(s, button, true)
        sparks[i] = s
    end
    return sparks
end

local function StartSparkles(button, quality)
    local db = DB()
    local count = db.sparkles or 2
    local sparks = EnsureSparks(button, count)
    local r, g, b = GetItemQualityColor(quality)
    r, g, b = r + (1 - r) * 0.4, g + (1 - g) * 0.4, b + (1 - b) * 0.4
    for i = 1, #sparks do
        local s = sparks[i]
        s.enabled = (i <= count)
        s.tex:SetVertexColor(r, g, b)
        if not s.enabled then s.tex:Hide() end
    end
    activeSparks[button] = true
end

local function StopSparkles(button)
    if not button.rbSparks then return end
    activeSparks[button] = nil
    for i = 1, #button.rbSparks do
        local s = button.rbSparks[i]
        s.enabled = false
        s.tex:Hide()
    end
end

local sparkDriver = CreateFrame("Frame")
sparkDriver:SetScript("OnUpdate", function(self, elapsed)
    local on = DB().sparkle
    for button in pairs(activeSparks) do
        if not on then
            StopSparkles(button)
        elseif button:IsVisible() then
            local sparks = button.rbSparks
            for i = 1, #sparks do
                local s = sparks[i]
                if s.enabled then
                    if s.wait > 0 then
                        s.wait = s.wait - elapsed
                    else
                        s.t = s.t + elapsed
                        local p = s.t / s.dur
                        if p >= 1 then
                            ResetSpark(s, button)
                        else
                            local a = math.sin(p * math.pi)
                            a = a ^ 1.4                            -- softer peak: lingers before fading
                            local size = s.size * (0.5 + 0.5 * a)
                            SetTexRotation(s.tex, s.angle0 + s.spin * p)      -- turns while it twinkles
                            s.tex:SetWidth(size * SIZE_COMP)
                            s.tex:SetHeight(size * SIZE_COMP)
                            s.tex:SetAlpha(a)
                            s.tex:Show()
                        end
                    end
                end
            end
        end
    end
end)

----------------------------------------------------------------
-- EXPERIMENTAL: comet trail (/rb trail on)
-- A short bright line with a fading tail runs around the item's edge. Start point, direction,
-- speed, run length and pause are random per item, so no two items look alike.
----------------------------------------------------------------
local TRAIL_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local TRAIL_SEGMENTS = 9
local activeTrails = {}     -- button -> true while the button should run a trail
local trailAcc = 0

-- Point on a square outline of half-size `half`, d = distance travelled along it (clockwise).
local function PerimeterPoint(d, half)
    local side = half * 2
    d = d % (side * 4)
    if d < side then
        return -half + d, half
    elseif d < side * 2 then
        return half, half - (d - side)
    elseif d < side * 3 then
        return half - (d - side * 2), -half
    else
        return -half, -half + (d - side * 3)
    end
end

local function ResetTrail(t, button, initial)
    local w = button:GetWidth()
    if not w or w < 1 then w = 37 end
    t.w = w
    t.half = w / 2 - 1
    t.running = false
    t.wait = initial and (random() * 4) or (0.8 + random() * 3.5)   -- pause before the next run
    t.life = 1.6 + random() * 1.2                                   -- length of one run
    t.age = 0
    t.pos = random() * (w * 4)                                      -- random start point on the edge
    local speed = w * (1.3 + random() * 0.9) * (DB().trailSpeed or 1)   -- pixels per second
    t.speed = (random() < 0.5) and speed or -speed                  -- random direction
    for i = 1, #t.segs do t.segs[i]:Hide() end
end

local function EnsureTrail(button)
    local t = button.rbTrail
    if t then return t end
    t = { segs = {} }
    for i = 1, TRAIL_SEGMENTS do
        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(TRAIL_TEXTURE)
        tex:SetBlendMode("ADD")
        tex:Hide()
        t.segs[i] = tex
    end
    button.rbTrail = t
    ResetTrail(t, button, true)
    return t
end

local function StartTrail(button, quality)
    local t = EnsureTrail(button)
    local r, g, b = GetItemQualityColor(quality)
    r, g, b = r + (1 - r) * 0.25, g + (1 - g) * 0.25, b + (1 - b) * 0.25
    for i = 1, #t.segs do t.segs[i]:SetVertexColor(r, g, b) end
    activeTrails[button] = true
end

local function StopTrail(button)
    local t = button.rbTrail
    activeTrails[button] = nil
    if not t then return end
    t.running = false
    for i = 1, #t.segs do t.segs[i]:Hide() end
end

local function StepTrail(button, t, dt)
    if not t.running then
        t.wait = t.wait - dt
        if t.wait > 0 then return end
        t.running = true
        t.age = 0
        local size = max(2, t.w * 0.075)
        for i = 1, #t.segs do
            local s = size * (1 - 0.5 * (i - 1) / #t.segs)           -- tail tapers
            t.segs[i]:SetWidth(s)
            t.segs[i]:SetHeight(s)
        end
    end

    t.age = t.age + dt
    local p = t.age / t.life
    if p >= 1 then
        ResetTrail(t, button)
        return
    end

    t.pos = t.pos + t.speed * dt
    local dir = (t.speed >= 0) and 1 or -1
    local gap = max(1.5, t.w * 0.06)
    local env = math.sin(p * math.pi)                                -- fade in / out over the run
    for i = 1, #t.segs do
        local x, y = PerimeterPoint(t.pos - dir * (i - 1) * gap, t.half)
        local seg = t.segs[i]
        seg:SetPoint("CENTER", button, "CENTER", x, y)
        local fade = 1 - (i - 1) / #t.segs
        seg:SetAlpha(env * fade * fade)
        seg:Show()
    end
end

local trailDriver = CreateFrame("Frame")
trailDriver:SetScript("OnUpdate", function(self, elapsed)
    trailAcc = trailAcc + elapsed
    if trailAcc < 0.03 then return end                               -- ~30 updates/s
    local dt = trailAcc
    trailAcc = 0
    local on = DB().trail
    for button in pairs(activeTrails) do
        if not on then
            StopTrail(button)
        elseif button:IsVisible() then
            StepTrail(button, button.rbTrail, dt)
        end
    end
end)

local function SetBorder(button, quality)
    local border = GetBorder(button)
    local db = DB()
    local show = quality and quality >= db.minQuality

    if show and db.border then
        local r, g, b = GetItemQualityColor(quality)
        border:SetVertexColor(r, g, b, db.alpha)
        border:Show()
    else
        border:Hide()
    end

    if show and db.sparkle then
        StartSparkles(button, quality)
    else
        StopSparkles(button)
    end

    if show and db.trail then
        StartTrail(button, quality)
    else
        StopTrail(button)
    end
end

local function QualityFromLink(link)
    if not link then return nil end
    local _, _, quality = GetItemInfo(link)
    return quality
end

----------------------------------------------------------------
-- Usability check via hidden tooltip (red text = cannot use)
----------------------------------------------------------------
local scanTip = CreateFrame("GameTooltip", "RarityBordersScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

local KNOWN_TEXT = ITEM_SPELL_KNOWN or "Already known"

local function IsRed(fs)
    if not fs or not fs:GetText() then return false end
    local r, g, b = fs:GetTextColor()
    return r > 0.9 and g < 0.25 and b < 0.25
end

-- Returns nil if the tooltip could not be read (caller must keep the old state),
-- otherwise true when the item has no red requirement line (usable) or false when it has one.
local function ScanTooltip(bag, slot)
    scanTip:ClearLines()
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetBagItem(bag, slot)

    local lines = scanTip:NumLines()
    if not lines or lines < 1 then return nil end

    local redCount = 0
    for i = 2, lines do
        for _, side in ipairs({ "Left", "Right" }) do
            local fs = _G["RarityBordersScanTipText" .. side .. i]
            if IsRed(fs) then
                local text = fs:GetText()
                if text ~= KNOWN_TEXT then
                    redCount = redCount + 1
                end
            end
        end
    end
    return redCount == 0
end

-- Cache by item link. Only cleared when something that affects usability changes.
local cache = {}
local function ClearCache() wipe(cache) end

-- Returns true/false, or nil when the state could not be determined right now.
local function IsUnusable(bag, slot, link)
    local key = strmatch(link, "item:[%-%d:]+") or link
    local usable = cache[key]
    if usable == nil then
        usable = ScanTooltip(bag, slot)
        if usable == nil then return nil end
        cache[key] = usable
    end
    return not usable
end

----------------------------------------------------------------
-- Tint (state lives on the button so it can be re-applied after the stock UI resets it)
----------------------------------------------------------------
local function GetIcon(button)
    if button.icon then return button.icon end
    local name = button:GetName()
    return name and _G[name .. "IconTexture"]
end

local function ApplyTint(button)
    local icon = GetIcon(button)
    if not icon then return end
    if button.rbUnusable and DB().tintUnusable then
        if button.rbLocked then
            icon:SetVertexColor(0.5, 0.05, 0.05)
        else
            icon:SetVertexColor(1, 0.1, 0.1)
        end
        button.rbTinted = true
    elseif button.rbTinted then
        -- we changed the colour earlier and the item is no longer unusable: undo our change
        if button.rbLocked then icon:SetVertexColor(0.5, 0.5, 0.5) else icon:SetVertexColor(1, 1, 1) end
        button.rbTinted = nil
    end
end

-- The stock UI resets the icon colour in places that bypass ContainerFrame_Update:
--   * SetItemButtonDesaturated        (item lock changes)
--   * SetItemButtonTextureVertexColor (cooldown updates: BAG_UPDATE_COOLDOWN fires after every
--                                      cast / global cooldown and sets the icon back to white)
-- Put our tint back right after either one runs. ApplyTint uses icon:SetVertexColor directly,
-- so there is no recursion.
if SetItemButtonDesaturated then
    hooksecurefunc("SetItemButtonDesaturated", function(button, desaturated)
        if button and (button.rbUnusable or button.rbTinted) then
            button.rbLocked = desaturated and true or nil
            ApplyTint(button)
        end
    end)
end

if SetItemButtonTextureVertexColor then
    hooksecurefunc("SetItemButtonTextureVertexColor", function(button)
        if button and (button.rbUnusable or button.rbTinted) then
            ApplyTint(button)
        end
    end)
end

-- Belt and braces: re-tint a whole container after the stock cooldown pass.
local function RetintContainer(frame)
    if not frame or not frame.GetName then return end
    local name = frame:GetName()
    local size = frame.size or (frame.GetID and GetContainerNumSlots(frame:GetID())) or 0
    for i = 1, size do
        local button = _G[name .. "Item" .. i]
        if button and (button.rbUnusable or button.rbTinted) then ApplyTint(button) end
    end
end
if ContainerFrame_UpdateCooldowns then
    hooksecurefunc("ContainerFrame_UpdateCooldowns", RetintContainer)
end

----------------------------------------------------------------
-- Bags and bank
----------------------------------------------------------------
local function UpdateItemButton(button, bag)
    local slot = button:GetID()
    local link = GetContainerItemLink(bag, slot)
    if not link then
        button.rbQuality, button.rbUnusable, button.rbLocked = nil, nil, nil
        SetBorder(button, nil)
        ApplyTint(button)
        return
    end

    local _, _, locked, quality = GetContainerItemInfo(bag, slot)
    if not quality or quality < 0 then quality = QualityFromLink(link) end
    if not quality then quality = button.rbQuality end   -- item data not available this frame: keep what we had
    button.rbQuality = quality
    SetBorder(button, quality)

    local unusable = IsUnusable(bag, slot, link)
    if unusable ~= nil then button.rbUnusable = unusable end   -- nil = scan failed, keep previous state
    button.rbLocked = locked and true or nil
    ApplyTint(button)
end

local function UpdateContainerFrame(frame)
    local name = frame:GetName()
    local bag = frame:GetID()
    local size = frame.size or GetContainerNumSlots(bag)
    for i = 1, size do
        local button = _G[name .. "Item" .. i]
        if button then UpdateItemButton(button, bag) end
    end
end
hooksecurefunc("ContainerFrame_Update", UpdateContainerFrame)

-- BankFrameItemButton_Update is also called for the purchasable bag-slot buttons at the bottom
-- of the bank frame (BankFrameBag1..7). Their ID is the bag slot number, not an item slot of the
-- main bank, so they must not be treated as item buttons.
local function IsBankBagButton(button)
    if button.isBag then return true end
    local name = button:GetName()
    return name and strmatch(name, "^BankFrameBag%d") and true or false
end

if BankFrameItemButton_Update then
    hooksecurefunc("BankFrameItemButton_Update", function(button)
        if not button then return end
        if IsBankBagButton(button) then
            -- make sure nothing of ours is left on a bag-slot button
            button.rbQuality, button.rbUnusable, button.rbLocked = nil, nil, nil
            SetBorder(button, nil)
            ApplyTint(button)
        else
            UpdateItemButton(button, BANK_CONTAINER)
        end
    end)
end

----------------------------------------------------------------
-- Character frame (border only; equipped items are always usable)
----------------------------------------------------------------
local function UpdateSlotButton(button)
    if not button then return end
    local slot = button:GetID()
    local link = GetInventoryItemLink("player", slot)
    if not link then
        button.rbQuality = nil
        SetBorder(button, nil)
        return
    end
    local quality = GetInventoryItemQuality and GetInventoryItemQuality("player", slot)
    if not quality or quality < 0 then quality = QualityFromLink(link) end
    if not quality then quality = button.rbQuality end
    button.rbQuality = quality
    SetBorder(button, quality)
end

if PaperDollItemSlotButton_Update then
    hooksecurefunc("PaperDollItemSlotButton_Update", UpdateSlotButton)
end

----------------------------------------------------------------
-- Refresh visible frames
----------------------------------------------------------------
local slotNames = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist",
    "Hands", "Waist", "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1",
    "MainHand", "SecondaryHand", "Ranged", "Ammo",
}

local function RefreshAll()
    for i = 1, NUM_CONTAINER_FRAMES or 13 do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsShown() then UpdateContainerFrame(frame) end
    end
    if BankFrame and BankFrame:IsShown() then
        for i = 1, NUM_BANKGENERIC_SLOTS or 28 do
            local button = _G["BankFrameItem" .. i]
            if button then UpdateItemButton(button, BANK_CONTAINER) end
        end
    end
    if CharacterFrame and CharacterFrame:IsShown() then
        for _, n in ipairs(slotNames) do UpdateSlotButton(_G["Character" .. n .. "Slot"]) end
    end
end

-- Debounced refresh so bursts of events cause one pass
local refresher = CreateFrame("Frame")
refresher:Hide()
refresher:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) - elapsed
    if self.t <= 0 then
        self:Hide()
        RefreshAll()
    end
end)
local function RequestRefresh()
    refresher.t = 0.3
    refresher:Show()
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local pendingClear = false

local function Invalidate()
    if UnitAffectingCombat("player") then
        pendingClear = true        -- keep using cached results during the fight
    else
        ClearCache()
        RequestRefresh()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("SKILL_LINES_CHANGED")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("LEARNED_SPELL_IN_TAB")
f:RegisterEvent("PLAYER_TALENT_UPDATE")
f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then DB() end
    elseif event == "PLAYER_LOGIN" then
        RefreshAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingClear then
            pendingClear = false
            ClearCache()
            RequestRefresh()
        end
    else
        Invalidate()
    end
end)

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------
local function OnOff(arg) return arg == "on" or arg == "1" or arg == "true" end

SLASH_RARITYBORDERS1 = "/rb"
SLASH_RARITYBORDERS2 = "/rarityborders"
SlashCmdList["RARITYBORDERS"] = function(msg)
    local db = DB()
    local cmd, arg = strmatch(msg or "", "^(%S*)%s*(.-)%s*$")
    cmd = strlower(cmd or "")
    arg = strlower(arg or "")
    local p = "|cff33ff99RarityBorders|r: "

    if cmd == "min" and tonumber(arg) then
        db.minQuality = max(0, min(6, floor(tonumber(arg))))
        print(p .. "effects for quality " .. db.minQuality .. " and up.")
    elseif cmd == "unusable" and arg ~= "" then
        db.tintUnusable = OnOff(arg)
        print(p .. "red tint on unusable items " .. (db.tintUnusable and "ON" or "OFF") .. ".")
    elseif cmd == "border" then
        local a = strmatch(arg, "^alpha%s+(%S+)$") or arg      -- "/rb border 0.5" or "/rb border alpha 0.5"
        if a == "on" or a == "off" then
            db.border = (a == "on")
            print(p .. "border " .. (db.border and "ON" or "OFF") .. ".")
        elseif tonumber(a) then
            db.alpha = max(0.1, min(1, tonumber(a)))
            print(p .. "border opacity " .. db.alpha .. ".")
        else
            print(p .. "border " .. (db.border and "ON" or "OFF") .. ", opacity " .. db.alpha
                .. "  (usage: /rb border on|off|<0.1-1>)")
            return
        end
    elseif cmd == "sparkle" and arg ~= "" then
        db.sparkle = OnOff(arg)
        print(p .. "sparkles " .. (db.sparkle and "ON (experimental)" or "OFF") .. ".")
    elseif cmd == "style" and (arg == "border" or arg == "sparkle" or arg == "both") then
        -- legacy shortcut from 1.4/1.5
        db.border = (arg == "border" or arg == "both")
        db.sparkle = (arg == "sparkle" or arg == "both")
        print(p .. "border " .. (db.border and "ON" or "OFF") .. ", sparkles " .. (db.sparkle and "ON" or "OFF") .. ".")
    elseif cmd == "trailspeed" and tonumber(arg) then
        db.trailSpeed = max(0.25, min(3, tonumber(arg)))
        print(p .. "comet speed x" .. db.trailSpeed .. " (applies from the next run).")
    elseif cmd == "sparkles" and tonumber(arg) then
        db.sparkles = max(1, min(4, floor(tonumber(arg))))
        print(p .. "sparkles per item: " .. db.sparkles .. ".")
    elseif cmd == "trail" and arg ~= "" then
        db.trail = OnOff(arg)
        print(p .. "comet trail " .. (db.trail and "ON (experimental)" or "OFF") .. ".")
    elseif cmd == "rescan" then
        pendingClear = false
        print(p .. "rescanning items.")
    else
        local function st(v) return v and "|cff00ff00ON|r" or "|cffff4040OFF|r" end
        print(p .. "border " .. st(db.border) .. "  sparkle " .. st(db.sparkle) .. "  trail " .. st(db.trail)
            .. "  unusable tint " .. st(db.tintUnusable))
        print(p .. "commands")
        print("  /rb min <0-6>        lowest quality that gets an effect (0 gray, 1 white, 2 green, 3 blue, 4 epic)")
        print("  /rb unusable on|off  red tint on items you cannot use")
        print("  /rb border on|off|<0.1-1>   quality-colored border; a number sets its opacity")
        print("  /rb sparkle on|off   EXPERIMENTAL: twinkling, rotating sparkles")
        print("  /rb sparkles <1-4>   sparkles per item (sparkle styles)")
        print("  /rb trail on|off     EXPERIMENTAL: fading comet line running around the item edge")
        print("  /rb trailspeed <0.25-3>   comet speed multiplier (1 = default)")
        print("  /rb rescan           clear the usability cache and refresh")
        return
    end
    ClearCache()
    RefreshAll()
end
