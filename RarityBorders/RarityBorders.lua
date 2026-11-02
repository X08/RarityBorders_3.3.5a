-- RarityBorders for WoW 3.3.5a
-- 1) Quality-colored glow around item buttons (bags, bank, character frame).
-- 2) Red tint on the icon of items the player cannot use (weapon skill not learned,
--    wrong armor type, class/skill/level requirement not met), like retail.
--
-- Version numbers are x.y.z: x = release, y = an addition or major change, z = a minor addition or fix.
--
-- 1.8.2  Performance: animations run at a fixed, lower update rate (animations are time-based, so
--        speed is unchanged), only a limited number of sparkles / comets / shimmers run at the same
--        moment, closed bags cost nothing, no garbage is created per frame any more, and the
--        shimmer does about half the work per step. /rb perf low|normal|high picks the trade-off.
-- 1.8.1  Shimmer redrawn: no separate bands visible any more (10 thin rows instead of 4, bell-shaped
--        brightness profile). Added white-hot core with prism-style colour dispersion, a lens flare
--        that rides the band across the middle of the item (or sits under the cursor with tilt on)
--        and a border flash. The textures now come from a fixed pool of 10 frames.
-- 1.8.0  EXPERIMENTAL holographic shimmer (/rb holo on|off): an iridescent band sweeps across the
--        item, its colours fanning out around the rarity colour. Optional cursor tilt: while the
--        mouse is over an item, the band follows the cursor and the hues shift with it.
--        /rb holo tilt on|off, /rb holo speed <0.25-3>.
-- 1.7.0  Compatibility with Bagnon (bags, bank, keyring, cached bags, guild bank), ElvUI (bags, bank,
--        keyring) and, best effort, other bag addons that call ContainerFrame_UpdateCooldown for
--        their item buttons. Their own quality borders are hidden while ours are active
--        (/rb overwrite off keeps both); their settings are never touched. /rb foreign, /rb compat.
-- 1.6.1  Bank bag-slot buttons are skipped (BankFrameItemButton_Update also fires for them and their
--        ID was being read as a slot of the main bank: the third bag slot glowed green).
-- 1.6.0  /rb level removed (level-gated items are always tinted); /rb alpha folded into /rb border.
-- 1.5.2  Sparkle start angle is random over the full 360 degrees.
-- 1.5.1  Glint layer removed; sparkles twinkle slower and linger a bit longer before fading.
-- 1.5.0  Sparkles rotate while they twinkle (a glint layer was tried alongside, see 1.5.1).
-- 1.4.0  Border, sparkle and trail are independent on/off switches; slower comet.
-- 1.3.0  EXPERIMENTAL comet trail: a short fading line runs around the item edge (/rb trail on).
-- 1.2.0  EXPERIMENTAL twinkling sparkles in the quality colour (/rb sparkle on).
-- 1.1.2  Red tint no longer disappears after casting a spell: BAG_UPDATE_COOLDOWN makes the stock UI
--        reset the icon colour (SetItemButtonTextureVertexColor), so the tint is re-applied there.
-- 1.1.1  Combat flicker fixes:
--          * the stock UI resets icon colour in places that bypass ContainerFrame_Update (lock
--            changes call SetItemButtonDesaturated) -> tint is re-applied there too
--          * a failed/empty tooltip scan never flips an item to "usable"; the last known state is kept
--          * the usability cache is not cleared during combat (skill-up events fire constantly in a
--            fight); it is cleared once combat ends
--          * refreshes triggered by events are debounced
-- 1.1.0  First release: quality-colored glow around item buttons (bags, bank, character frame) and a
--        red tint on the icon of items you cannot use (weapon skill not learned, wrong armor type,
--        class/skill/level requirement not met), which OGlow does not show.

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
    holo = false,        -- EXPERIMENTAL: holographic shimmer
    holoTilt = true,     -- the shimmer follows the cursor while it hovers an item
    holoSpeed = 1,       -- 0.25 .. 3, multiplier for the sweep rate
    perf = "normal",      -- "low" / "normal" / "high": animation update rate and how many run at once
    overwrite = true,    -- hide Bagnon / ElvUI quality borders while our effects are active
    foreign = true,      -- also decorate buttons of unknown bag addons (best effort)
}

local dbReady            -- the saved-variables table that already went through the migration below
local fxVersion = 0      -- bumped whenever a setting changes, so cached per-button effect state is redone

local function DB()
    local d = RarityBordersDB
    if d and d == dbReady then return d end      -- hot path: the drivers ask for the settings every frame
    RarityBordersDB = RarityBordersDB or {}
    d = RarityBordersDB
    dbReady = d
    if d.style ~= nil then            -- migrate the old single "style" setting (before 1.4.0)
        if d.border == nil then d.border = (d.style == "border" or d.style == "both") end
        if d.sparkle == nil then d.sparkle = (d.style == "sparkle" or d.style == "both") end
        d.style = nil
    end
    d.glint = nil                     -- removed in 1.5.1
    d.tintLevel = nil                 -- removed in 1.6.0
    for k, v in pairs(defaults) do
        if d[k] == nil then d[k] = v end
    end
    return d
end

----------------------------------------------------------------
-- Performance presets (/rb perf low|normal|high)
-- Hz = how often an animation is redrawn (all animations are time-based, so this changes smoothness,
-- never speed); the caps are how many sparkles / comets / shimmers may run at the same moment.
----------------------------------------------------------------
local PERF = {
    low    = { sparkHz = 12, trailHz = 15, holoHz = 15, sparkCap = 20,  trailCap = 8,  holoCap = 3 },
    normal = { sparkHz = 20, trailHz = 24, holoHz = 24, sparkCap = 60,  trailCap = 24, holoCap = 6 },
    high   = { sparkHz = 30, trailHz = 30, holoHz = 40, sparkCap = 999, trailCap = 999, holoCap = 10 },
}
local function Perf() return PERF[DB().perf] or PERF.normal end

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
local sparkRunning = 0       -- sparkles twinkling right now (limited by the perf preset)
local sparkDriver
local sparkAcc = 0

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
    if s.running then
        s.running = false
        sparkRunning = sparkRunning - 1
    end
    s.shown, s.lastSize = false, nil
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
    sparkDriver:Show()
end

local function StopSparkles(button)
    activeSparks[button] = nil
    button.rbFxKey = nil
    if not button.rbSparks then return end
    for i = 1, #button.rbSparks do
        local s = button.rbSparks[i]
        s.enabled = false
        if s.running then
            s.running = false
            sparkRunning = sparkRunning - 1
        end
        s.shown = false
        s.tex:Hide()
    end
end

sparkDriver = CreateFrame("Frame")
sparkDriver:SetScript("OnUpdate", function(self, elapsed)
    sparkAcc = sparkAcc + elapsed
    local perf = Perf()
    if sparkAcc < 1 / perf.sparkHz then return end
    local dt = sparkAcc
    sparkAcc = 0
    local on = DB().sparkle
    local any = false
    for button in pairs(activeSparks) do
        if not on then
            StopSparkles(button)
        elseif not button:IsVisible() then
            StopSparkles(button)                    -- closed bag / hidden frame: costs nothing until it is shown again
        else
            any = true
            local sparks = button.rbSparks
            for i = 1, #sparks do
                local s = sparks[i]
                if s.enabled then
                    if s.wait > 0 then
                        s.wait = s.wait - dt
                    elseif not s.running and sparkRunning >= perf.sparkCap then
                        s.wait = 0.2 + random() * 0.5          -- too many twinkling already: try again shortly
                    else
                        if not s.running then
                            s.running = true
                            sparkRunning = sparkRunning + 1
                        end
                        s.t = s.t + dt
                        local p = s.t / s.dur
                        if p >= 1 then
                            ResetSpark(s, button)
                        else
                            local a = math.sin(p * math.pi)
                            a = a ^ 1.4                            -- softer peak: lingers before fading
                            local size = s.size * (0.5 + 0.5 * a)
                            SetTexRotation(s.tex, s.angle0 + s.spin * p)      -- turns while it twinkles
                            if not s.lastSize or math.abs(size - s.lastSize) > 0.25 then
                                s.lastSize = size
                                s.tex:SetWidth(size * SIZE_COMP)
                                s.tex:SetHeight(size * SIZE_COMP)
                            end
                            s.tex:SetAlpha(a)
                            if not s.shown then
                                s.shown = true
                                s.tex:Show()
                            end
                        end
                    end
                end
            end
        end
    end
    if not any and not next(activeSparks) then self:Hide() end
end)
sparkDriver:Hide()

----------------------------------------------------------------
-- EXPERIMENTAL: comet trail (/rb trail on)
-- A short bright line with a fading tail runs around the item's edge. Start point, direction,
-- speed, run length and pause are random per item, so no two items look alike.
----------------------------------------------------------------
local TRAIL_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local TRAIL_SEGMENTS = 9
local activeTrails = {}     -- button -> true while the button should run a trail
local trailAcc = 0
local trailRunning = 0     -- comets running right now (limited by the perf preset)
local trailDriver

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
    if t.counted then
        t.counted = false
        trailRunning = trailRunning - 1
    end
    t.shown = false
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
    trailDriver:Show()
end

local function StopTrail(button)
    local t = button.rbTrail
    activeTrails[button] = nil
    button.rbFxKey = nil
    if not t then return end
    if t.counted then
        t.counted = false
        trailRunning = trailRunning - 1
    end
    t.running = false
    t.shown = false
    for i = 1, #t.segs do t.segs[i]:Hide() end
end

local function StepTrail(button, t, dt)
    if not t.running then
        t.wait = t.wait - dt
        if t.wait > 0 then return end
        if trailRunning >= Perf().trailCap then
            t.wait = 0.2 + random() * 0.5                        -- too many comets already: try again shortly
            return
        end
        t.counted = true
        trailRunning = trailRunning + 1
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
        if not t.shown then seg:Show() end
    end
    t.shown = true
end

trailDriver = CreateFrame("Frame")
trailDriver:SetScript("OnUpdate", function(self, elapsed)
    trailAcc = trailAcc + elapsed
    if trailAcc < 1 / Perf().trailHz then return end
    local dt = trailAcc
    trailAcc = 0
    local on = DB().trail
    for button in pairs(activeTrails) do
        if not on then
            StopTrail(button)
        elseif button:IsVisible() then
            StepTrail(button, button.rbTrail, dt)
        else
            StopTrail(button)                       -- closed bag / hidden frame: costs nothing until it is shown again
        end
    end
    if not next(activeTrails) then self:Hide() end
end)
trailDriver:Hide()

----------------------------------------------------------------
-- EXPERIMENTAL: holographic shimmer (/rb holo on)
-- A soft band of light sweeps over the item every few seconds, on its own random timer per item.
--   * the band is a bell-shaped brightness profile (not a hard stripe) with a white-hot core and
--     coloured fringes whose hues are fanned out around the item's rarity colour (dispersion, like
--     light through a prism); the hue also drifts a little from the bottom of the item to the top
--   * it is slanted; the slant is drawn as HOLO_ROWS thin rows, thin enough that no steps show
--   * a small lens flare rides the band as it crosses the middle of the item and the border glow
--     flashes whiter at that moment
--   * with tilt on, the band, flare, slant and hues follow the mouse cursor while it is over the item
-- The textures live in a small pool of overlay frames that are lent to whichever items are shimmering
-- right now, so the cost stays fixed however many items are on screen.
-- 3.3.5a cannot clip textures, so the band is cut to the icon area by hand (position + width).
----------------------------------------------------------------
local HOLO_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local HOLO_ROWS = 10
local HOLO_POOL = 10                                  -- most items shimmering at the same moment
local HOLO_INSET = 2
local HOLO_POS   = { -1, -0.5, 0, 0.5, 1 }            -- across the band, in half-widths
local HOLO_ALPHA = { 0, 0.35, 1, 0.35, 0 }            -- bell-shaped brightness
local HOLO_SAT   = { 1, 0.9, 0.25, 0.9, 1 }           -- white-hot core, saturated fringes
local HOLO_DISP  = { -1, -0.5, 0, 0.5, 1 }            -- hue dispersion (x HOLO_DISPERSE)
local HOLO_DISPERSE = 0.07
local activeHolo = {}          -- button -> true while the button should shimmer
local holoAcc, holoClock = 0, 0
local holoPool, holoFree = {}, {}
local holoBusy = 0            -- band frames lent out right now (limited by the perf preset)
local holoDriver
local holoCols = {}           -- scratch colours, reused every step (no garbage)
for k = 1, 5 do holoCols[k] = { 0, 0, 0 } end

local function RGBToHSV(r, g, b)
    local mx, mn = max(r, g, b), min(r, g, b)
    local d = mx - mn
    if d < 0.0001 then return 0, 0, mx end
    local h
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    return h / 6, d / mx, mx
end

local function HSVToRGB(h, s, v)
    h = (h % 1) * 6
    local i = floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    i = i % 6
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    else return v, p, q end
end

local function Clamp(v, lo, hi) return max(lo, min(hi, v)) end

-- Colour at hue offset `off` from the item's rarity colour; satScale 1 = full, small = near white.
local function HoloRGB(hl, off, satScale)
    if hl.rainbow then
        return HSVToRGB(holoClock * 0.1 + off * 3, 0.8 * satScale, 1)
    end
    return HSVToRGB(hl.hue + off, max(0.45, hl.sat * 0.8) * satScale, 1)
end

local function NewBandFrame()
    local f = CreateFrame("Frame", nil, UIParent)
    f.quads = {}
    for j = 1, HOLO_ROWS do
        f.quads[j] = {}
        for k = 1, #HOLO_POS - 1 do
            local tex = f:CreateTexture(nil, "OVERLAY")
            tex:SetTexture(HOLO_TEXTURE)
            tex:SetBlendMode("ADD")
            tex:Hide()
            f.quads[j][k] = tex
        end
    end
    f.flare = f:CreateTexture(nil, "OVERLAY")
    f.flare:SetTexture(SPARK_TEXTURE)
    f.flare:SetBlendMode("ADD")
    f.flare:Hide()
    return f
end

local function AcquireBand(button)
    if holoBusy >= min(HOLO_POOL, Perf().holoCap) then return nil end
    local f = table.remove(holoFree)
    if not f then
        f = NewBandFrame()
        holoPool[#holoPool + 1] = f
    end
    holoBusy = holoBusy + 1
    f:SetParent(button)
    f:ClearAllPoints()
    f:SetAllPoints(button)
    f:SetFrameLevel((button:GetFrameLevel() or 1) + 2)
    f:Show()
    return f
end

local function ReleaseBand(hl)
    local f = hl.band
    if not f then return end
    hl.band = nil
    for j = 1, HOLO_ROWS do
        for k = 1, #f.quads[j] do
            f.quads[j][k]:Hide()
            f.quads[j][k].rbOn = false
        end
    end
    f.flare:Hide()
    f:Hide()
    f:SetParent(UIParent)
    holoFree[#holoFree + 1] = f
    holoBusy = holoBusy - 1
end

local function EnsureHolo(button)
    local hl = button.rbHolo
    if hl then return hl end
    hl = { wait = random() * 6, t = 0, dur = 1.3, hover = 0, flash = 0, phase = random() * 6.2832 }
    button.rbHolo = hl
    return hl
end

local function StartHolo(button, quality)
    local hl = EnsureHolo(button)
    local r, g, b = GetItemQualityColor(quality)
    hl.hue, hl.sat, hl.val = RGBToHSV(r, g, b)
    hl.rainbow = hl.sat < 0.2          -- grey / white: no colour to fan out from, use the full rainbow
    activeHolo[button] = true
    holoDriver:Show()
end

local function StopHolo(button, restoreBorder)
    local hl = button.rbHolo
    activeHolo[button] = nil
    button.rbFxKey = nil
    if not hl then return end
    hl.sweeping = false
    hl.hover = 0
    hl.flash = 0
    ReleaseBand(hl)
    if restoreBorder then                -- the driver bent the border colour: put the quality colour back
        local bd = button.rbBorder
        if bd and bd:IsShown() and button.rbQuality then
            local r, g, b = GetItemQualityColor(button.rbQuality)
            bd:SetVertexColor(r, g, b, DB().alpha)
        end
    end
end

-- One piece of a band row: alpha and colour ramp from x0 to x1, cut to the icon area.
local function SetHoloQuad(tex, band, x0, x1, a0, a1, c0, c1, w, y, rowH)
    local l, r = max(x0, HOLO_INSET), min(x1, w - HOLO_INSET)
    if r - l < 0.5 or (a0 < 0.01 and a1 < 0.01) then
        if tex.rbOn then
            tex:Hide()
            tex.rbOn = false
        end
        return
    end
    local span = x1 - x0
    local t0, t1 = (l - x0) / span, (r - x0) / span
    tex:SetPoint("BOTTOMLEFT", band, "BOTTOMLEFT", l, y)     -- same anchor point: replaces the old one
    if not tex.rbW or math.abs(tex.rbW - (r - l)) > 0.05 then tex.rbW = r - l; tex:SetWidth(r - l) end
    if tex.rbH ~= rowH then tex.rbH = rowH; tex:SetHeight(rowH) end
    tex:SetGradientAlpha("HORIZONTAL",
        c0[1] + (c1[1] - c0[1]) * t0, c0[2] + (c1[2] - c0[2]) * t0, c0[3] + (c1[3] - c0[3]) * t0, a0 + (a1 - a0) * t0,
        c0[1] + (c1[1] - c0[1]) * t1, c0[2] + (c1[2] - c0[2]) * t1, c0[3] + (c1[3] - c0[3]) * t1, a0 + (a1 - a0) * t1)
    if not tex.rbOn then
        tex.rbOn = true
        tex:Show()
    end
end

local function LayoutHoloBand(hl, w, h, center, slant, strength, hueShift, fx, fy, flare)
    local band = hl.band
    local rowH = (h - HOLO_INSET * 2) / HOLO_ROWS
    local bw = w * 0.28
    for j = 1, HOLO_ROWS do
        local cx = center + slant * ((j - 1) / (HOLO_ROWS - 1) - 0.5)
        local rowOff = (j - (HOLO_ROWS + 1) / 2) * 0.012 + hueShift
        local y = HOLO_INSET + (j - 1) * rowH
        local cols = holoCols
        for k = 1, #HOLO_POS do
            local c = cols[k]
            c[1], c[2], c[3] = HoloRGB(hl, rowOff + HOLO_DISP[k] * HOLO_DISPERSE, HOLO_SAT[k])
        end
        for k = 1, #HOLO_POS - 1 do
            SetHoloQuad(band.quads[j][k], band, cx + HOLO_POS[k] * bw, cx + HOLO_POS[k + 1] * bw,
                HOLO_ALPHA[k] * strength, HOLO_ALPHA[k + 1] * strength, cols[k], cols[k + 1], w, y, rowH)
        end
    end

    local fl = band.flare
    if flare > 0.02 then
        local size = w * (0.35 + 0.2 * flare)
        local r, g, b = HoloRGB(hl, hueShift, 0.3)
        SetTexRotation(fl, (fx / w) * 1.5708)
        fl:ClearAllPoints()
        fl:SetPoint("CENTER", band, "BOTTOMLEFT", fx, fy)
        fl:SetWidth(size * SIZE_COMP)
        fl:SetHeight(size * SIZE_COMP)
        fl:SetVertexColor(r, g, b)
        fl:SetAlpha(min(1, flare * 0.9))
        fl:Show()
    else
        fl:Hide()
    end
end

local function StepHolo(button, hl, dt, db)
    local w, h = button:GetWidth(), button:GetHeight()
    if not w or w < 1 then w = 37 end
    if not h or h < 1 then h = w end
    local speed = db.holoSpeed or 1

    local hovering = db.holoTilt and MouseIsOver(button)
    if hovering then
        hl.hover = min(1, hl.hover + dt * 6)
        local cx, cy = GetCursorPosition()
        local sc, l, bt = button:GetEffectiveScale(), button:GetLeft(), button:GetBottom()
        if cx and cy and sc and sc > 0 and l and bt then
            hl.nx = Clamp((cx / sc - l) / w, 0, 1)
            hl.ny = Clamp((cy / sc - bt) / h, 0, 1)
        end
    else
        hl.hover = max(0, hl.hover - dt * 5)
    end

    if db.holoTilt and hl.hover > 0 then
        if not hl.band then hl.band = AcquireBand(button) end
        if hl.band then
            hl.sweeping = false
            local nx, ny = hl.nx or 0.5, hl.ny or 0.5
            hl.flash = 0.5 * hl.hover
            LayoutHoloBand(hl, w, h, nx * w, w * (0.15 + 0.5 * ny), 0.55 * hl.hover,
                (nx - 0.5) * 0.2 + (ny - 0.5) * 0.1,
                Clamp(nx * w, w * 0.25, w * 0.75), Clamp(ny * h, h * 0.25, h * 0.75), 0.8 * hl.hover)
        end
        return
    end

    if not hl.sweeping then
        hl.flash = 0
        ReleaseBand(hl)
        hl.wait = hl.wait - dt
        if hl.wait > 0 then return end
        hl.band = AcquireBand(button)
        if not hl.band then hl.wait = 0.2 + random() * 0.6; return end   -- every band frame is busy: retry at a random moment (fair)
        hl.sweeping = true
        hl.t = 0
        hl.dur = (1.1 + random() * 0.5) / speed
        hl.slant = w * (0.25 + random() * 0.2)
    end

    hl.t = hl.t + dt
    local p = hl.t / hl.dur
    if p >= 1 then
        ReleaseBand(hl)
        hl.sweeping = false
        hl.flash = 0
        hl.wait = (2 + random() * 5) / speed
        return
    end
    local bw = w * 0.28
    local from, to = -(bw + hl.slant / 2), w + bw + hl.slant / 2
    local center = from + (to - from) * p
    local env = min(1, math.sin(p * math.pi) * 3)
    local prox = max(0, 1 - math.abs(center - w / 2) / (w * 0.45))     -- the flare peaks mid-item
    hl.flash = env * prox
    LayoutHoloBand(hl, w, h, center, hl.slant, 0.55 * env,
        (p - 0.5) * 0.16 + (hl.phase / 6.2832 - 0.5) * 0.06,
        Clamp(center, w * 0.25, w * 0.75), h / 2, env * prox * 0.9)
end

holoDriver = CreateFrame("Frame")
holoDriver:SetScript("OnUpdate", function(self, elapsed)
    holoAcc = holoAcc + elapsed
    if holoAcc < 1 / Perf().holoHz then return end
    local dt = holoAcc
    holoAcc = 0
    holoClock = holoClock + dt
    local db = DB()
    for button in pairs(activeHolo) do
        if not db.holo then
            StopHolo(button, true)
        elseif button:IsVisible() then
            local hl = button.rbHolo
            StepHolo(button, hl, dt, db)
            -- the border glow breathes through nearby hues and flashes whiter when the band crosses
            local bd = button.rbBorder
            if bd and bd:IsShown() and not hl.rainbow then
                local fl = hl.flash or 0
                local r, g, b = HSVToRGB(hl.hue + 0.05 * math.sin(holoClock * (db.holoSpeed or 1) * 1.3 + hl.phase),
                    hl.sat * (1 - 0.6 * fl), hl.val)
                bd:SetVertexColor(r, g, b, min(1, db.alpha + 0.3 * fl))
            end
        else
            StopHolo(button)                         -- closed bag / hidden frame: give the band frame back, cost nothing
        end
    end
    if not next(activeHolo) then self:Hide() end
end)
holoDriver:Hide()

local function SetBorder(button, quality)
    local db = DB()
    local show = quality and quality >= db.minQuality and not button.rbFaded
    -- Bag updates call this for every slot; skip the work when nothing changed for this button.
    local key = show and quality or -1
    if button.rbFxKey == key and button.rbFxVer == fxVersion then return end
    button.rbFxKey, button.rbFxVer = key, fxVersion
    local border = GetBorder(button)

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

    if show and db.holo then
        StartHolo(button, quality)
    elseif activeHolo[button] then
        StopHolo(button)
    end
    button.rbFxKey = key          -- the Stop* helpers above clear it; the state is consistent again here
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
local function ScanTooltip(bag, slot, link)
    scanTip:ClearLines()
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    if bag and slot then
        scanTip:SetBagItem(bag, slot)
        if (scanTip:NumLines() or 0) < 1 and bag == BANK_CONTAINER and BankButtonIDToInvSlotID then
            scanTip:SetInventoryItem("player", BankButtonIDToInvSlotID(slot))
        end
    elseif link then
        scanTip:SetHyperlink(link)       -- cached / guild bank items: no bag slot to read
    else
        return nil
    end

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
        usable = ScanTooltip(bag, slot, link)
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
-- Shared by the stock UI and every adapter. bag/slot may be nil (cached or guild bank items):
-- the usability scan then reads the item link instead.
local function ApplyItemData(button, link, quality, locked, bag, slot)
    if not link then
        button.rbQuality, button.rbUnusable, button.rbLocked = nil, nil, nil
        SetBorder(button, nil)
        ApplyTint(button)
        return
    end

    if not quality or quality < 0 then quality = QualityFromLink(link) end
    if not quality then quality = button.rbQuality end   -- item data not available this frame: keep what we had
    button.rbQuality = quality
    SetBorder(button, quality)

    local unusable = IsUnusable(bag, slot, link)
    if unusable ~= nil then button.rbUnusable = unusable end   -- nil = scan failed, keep previous state
    button.rbLocked = locked and true or nil
    ApplyTint(button)
end

local function UpdateItemButton(button, bag)
    if button.rbAdapter then return end      -- owned by a bag addon, see "Compatibility"
    local slot = button:GetID()
    local link = GetContainerItemLink(bag, slot)
    local locked, quality
    if link then
        local _
        _, _, locked, quality = GetContainerItemInfo(bag, slot)
    end
    ApplyItemData(button, link, quality, locked, bag, slot)
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
        if not button or button.rbAdapter then return end
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
-- Compatibility with bag addons (Bagnon, ElvUI, others)
-- Their item buttons are decorated from hooks on their own update functions; nothing is
-- replaced. Every adapter runs under pcall, so an unexpected change in the other addon can never
-- break its bags. A button owned by an adapter has .rbAdapter set, which makes the stock
-- handlers above leave it alone.
----------------------------------------------------------------
local adopted = setmetatable({}, { __mode = "k" })   -- button -> "bagnon" | "elvui" | "slot"
local hooked = {}
local lastError

local function Overwriting()
    local db = DB()
    return db.overwrite and (db.border or db.sparkle or db.trail or db.holo)
end

local function Guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then lastError = tostring(err) end
    end
end

local function Adopt(button, kind)
    button.rbAdapter = kind
    adopted[button] = kind
end

-- Bagnon: ItemSlot (bags, bank, keyring, cached views) and GuildItemSlot --------------------
local function BagnonApply(self, quality)
    Adopt(self, "bagnon")
    local link = self.GetItem and self:GetItem()
    if self.GetBag then
        local bag, slot = self:GetBag(), self:GetID()
        if self.IsCached and self:IsCached() then
            ApplyItemData(self, link, quality, nil, nil, nil)
        else
            local locked
            if link then locked = select(3, GetContainerItemInfo(bag, slot)) end
            ApplyItemData(self, link, quality, locked, bag, slot)
        end
    else
        ApplyItemData(self, link, quality, nil, nil, nil)       -- guild bank
    end
    if Overwriting() and self.border then self.border:Hide() end
end

local function BagnonSearch(self)
    -- Bagnon fades non-matching items by alpha; our effects follow suit
    local faded = (self:GetAlpha() or 1) < 0.99
    self.rbFaded = faded or nil
    SetBorder(self, self.rbQuality)
    if Overwriting() and self.border then self.border:Hide() end
end

local function HookBagnonClass(class)
    if not class then return false end
    if type(class.SetBorderQuality) ~= "function" then return false end
    hooksecurefunc(class, "SetBorderQuality", Guard(BagnonApply))
    if type(class.UpdateSearch) == "function" then
        hooksecurefunc(class, "UpdateSearch", Guard(BagnonSearch))
    end
    return true
end

local function BagnonQuality(button)
    if button.GetBag then
        return (select(4, button:GetItemSlotInfo()))
    end
    return QualityFromLink(button:GetItem())
end

-- ElvUI bags ---------------------------------------------------------------------------------
local elvE, elvB

local function ApplySlot(button, bag, slot)
    button.rbBag, button.rbSlot = bag, slot
    local link = GetContainerItemLink(bag, slot)
    local locked, quality
    if link then
        local _
        _, _, locked, quality = GetContainerItemInfo(bag, slot)
    end
    ApplyItemData(button, link, quality, locked, bag, slot)
    return link
end

-- True when ElvUI coloured this slot's border by item quality (not quest / profession bag colours)
local function ElvQualityBorder(slot, bag, slotID)
    if not (elvB.db and elvB.db.qualityColors and slot.rarity and slot.rarity > 1) then return false end
    if elvB.db.questItemColors and GetContainerItemQuestInfo then
        local isQuest, questId = GetContainerItemQuestInfo(bag, slotID)
        if questId or isQuest then return false end
    end
    return true
end

local function ElvNeutralise(slot, bag, slotID, link)
    if link and Overwriting() and slot.SetBackdropBorderColor and ElvQualityBorder(slot, bag, slotID) then
        local c = elvE.media and elvE.media.bordercolor
        if c then
            slot:SetBackdropBorderColor(c[1], c[2], c[3], c[4])
            slot.ignoreBorderColors = nil
        end
    end
end

local function ElvSlot(self, frame, bagID, slotID)
    local bags = frame and frame.Bags
    local bagFrame = bags and bags[bagID]
    local slot = bagFrame and bagFrame[slotID]
    if not slot or bagFrame.numSlots ~= GetContainerNumSlots(bagID) then return end
    Adopt(slot, "elvui")
    ElvNeutralise(slot, bagID, slotID, ApplySlot(slot, bagID, slotID))
end

local function ElvKeySlot(self, slotID)
    local slot = _G["ElvUIKeyFrameItem" .. tostring(slotID)]
    if not slot then return end
    Adopt(slot, "elvui")
    ElvNeutralise(slot, KEYRING_CONTAINER, slotID, ApplySlot(slot, KEYRING_CONTAINER, slotID))
end

-- Unknown bag addons (best effort): most of them call the stock ContainerFrame_UpdateCooldown
-- (bag, button) for every item button they update. Stock buttons and adapter buttons are skipped.
local function IsStockName(name)
    return name and (strmatch(name, "^ContainerFrame%d+Item%d+$") or strmatch(name, "^BankFrameItem%d+$"))
end

local function GenericAdopt(bag, button)
    if not DB().foreign then return end
    if type(bag) ~= "number" or type(button) ~= "table" or not button.GetID then return end
    if button.rbAdapter and button.rbAdapter ~= "slot" then return end
    if IsStockName(button.GetName and button:GetName()) and not button.rbAdapter then return end
    local slot = button:GetID()
    if not slot or slot < 1 then return end
    Adopt(button, "slot")
    ApplySlot(button, bag, slot)
end

local function TryAdapters()
    if not hooked.bagnon then
        local ace = LibStub and LibStub("AceAddon-3.0", true)
        local B = ace and ace:GetAddon("Bagnon", true)
        if B and B.ItemSlot then
            hooked.bagnon = HookBagnonClass(B.ItemSlot) or nil
        end
        hooked.bagnonRef = B or hooked.bagnonRef
    end
    if not hooked.guild and hooked.bagnonRef and hooked.bagnonRef.GuildItemSlot then
        hooked.guild = HookBagnonClass(hooked.bagnonRef.GuildItemSlot) or nil
    end
    if not hooked.elvui and _G.ElvUI and type(_G.ElvUI) == "table" then
        local E = _G.ElvUI[1]
        local B = E and E.GetModule and E:GetModule("Bags", true)
        if B and type(B.UpdateSlot) == "function" then
            elvE, elvB = E, B
            hooksecurefunc(B, "UpdateSlot", Guard(ElvSlot))
            if type(B.UpdateKeySlot) == "function" then
                hooksecurefunc(B, "UpdateKeySlot", Guard(ElvKeySlot))
            end
            hooked.elvui = true
        end
    end
    if not hooked.generic and ContainerFrame_UpdateCooldown then
        hooksecurefunc("ContainerFrame_UpdateCooldown", Guard(GenericAdopt))
        hooked.generic = true
    end
end

-- Re-run the other addon's own update so its borders come back (overwrite off) or go (overwrite on)
local function RestoreForeign()
    for button, kind in pairs(adopted) do
        if kind == "bagnon" and button:IsVisible() and button.UpdateBorder then
            Guard(button.UpdateBorder)(button)
        end
    end
    if hooked.elvui and elvB.UpdateAllBagSlots then
        Guard(elvB.UpdateAllBagSlots)(elvB)
    end
end

local function RefreshForeign()
    local foreignOn = DB().foreign
    for button, kind in pairs(adopted) do
        if button:IsVisible() and (kind ~= "slot" or foreignOn) then
            if kind == "bagnon" then
                Guard(function() BagnonApply(button, BagnonQuality(button)) end)()
            elseif button.rbBag and button.rbSlot then
                Guard(ApplySlot)(button, button.rbBag, button.rbSlot)
            end
        end
    end
end

local function ReleaseGeneric()
    for button, kind in pairs(adopted) do
        if kind == "slot" then
            button.rbQuality, button.rbUnusable, button.rbLocked = nil, nil, nil
            SetBorder(button, nil)
            ApplyTint(button)
        end
    end
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
    RefreshForeign()
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
        if arg1 == ADDON then DB(); fxVersion = fxVersion + 1 end
        TryAdapters()                -- Bagnon_GuildBank is load-on-demand, so retry on every addon load
    elseif event == "PLAYER_LOGIN" then
        TryAdapters()
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
        -- legacy shortcut from before 1.4.0
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
    elseif cmd == "holo" then
        local sub, val = strmatch(arg, "^(%S*)%s*(.-)$")
        if sub == "on" or sub == "off" then
            db.holo = (sub == "on")
            print(p .. "holographic shimmer " .. (db.holo and "ON (experimental)" or "OFF") .. ".")
        elseif sub == "tilt" and val ~= "" then
            db.holoTilt = OnOff(val)
            print(p .. "shimmer follows the cursor: " .. (db.holoTilt and "ON" or "OFF") .. ".")
        elseif sub == "speed" and tonumber(val) then
            db.holoSpeed = max(0.25, min(3, tonumber(val)))
            print(p .. "shimmer speed x" .. db.holoSpeed .. ".")
        else
            print(p .. "shimmer " .. (db.holo and "ON" or "OFF") .. ", cursor tilt " .. (db.holoTilt and "ON" or "OFF")
                .. ", speed x" .. db.holoSpeed .. "  (usage: /rb holo on|off, /rb holo tilt on|off, /rb holo speed <0.25-3>)")
            return
        end
    elseif cmd == "perf" then
        if PERF[arg] then
            db.perf = arg
            local c = PERF[arg]
            print(p .. "performance preset " .. arg .. ": animations redrawn " .. c.sparkHz .. "/" .. c.trailHz .. "/" .. c.holoHz
                .. " times per second (sparkle/comet/shimmer), at most " .. (c.sparkCap < 999 and c.sparkCap or "unlimited") .. " sparkles, "
                .. (c.trailCap < 999 and c.trailCap or "unlimited") .. " comets and " .. c.holoCap .. " shimmers at once.")
        else
            print(p .. "performance preset: " .. (db.perf or "normal") .. "  (usage: /rb perf low|normal|high)")
            return
        end
    elseif cmd == "overwrite" and arg ~= "" then
        db.overwrite = OnOff(arg)
        print(p .. "hiding Bagnon / ElvUI quality borders while ours are on: " .. (db.overwrite and "ON" or "OFF") .. ".")
    elseif cmd == "foreign" and arg ~= "" then
        db.foreign = OnOff(arg)
        if not db.foreign then ReleaseGeneric() end
        print(p .. "other bag addons (best effort) " .. (db.foreign and "ON" or "OFF") .. ".")
    elseif cmd == "compat" then
        local function yn(v) return v and "|cff00ff00hooked|r" or "|cff888888not found|r" end
        print(p .. "Bagnon " .. yn(hooked.bagnon) .. ", Bagnon guild bank " .. yn(hooked.guild)
            .. ", ElvUI bags " .. yn(hooked.elvui) .. ", other addons " .. (db.foreign and "on" or "off"))
        local n = 0
        for _ in pairs(adopted) do n = n + 1 end
        print(p .. n .. " buttons from other addons seen" .. (lastError and ("; last error: " .. lastError) or "."))
        return
    elseif cmd == "rescan" then
        pendingClear = false
        print(p .. "rescanning items.")
    else
        local function st(v) return v and "|cff00ff00ON|r" or "|cffff4040OFF|r" end
        print(p .. "border " .. st(db.border) .. "  sparkle " .. st(db.sparkle) .. "  trail " .. st(db.trail) .. "  holo " .. st(db.holo)
            .. "  unusable tint " .. st(db.tintUnusable))
        print(p .. "commands")
        print("  /rb min <0-6>        lowest quality that gets an effect (0 gray, 1 white, 2 green, 3 blue, 4 epic)")
        print("  /rb unusable on|off  red tint on items you cannot use")
        print("  /rb border on|off|<0.1-1>   quality-colored border; a number sets its opacity")
        print("  /rb sparkle on|off   EXPERIMENTAL: twinkling, rotating sparkles")
        print("  /rb sparkles <1-4>   sparkles per item (sparkle styles)")
        print("  /rb trail on|off     EXPERIMENTAL: fading comet line running around the item edge")
        print("  /rb trailspeed <0.25-3>   comet speed multiplier (1 = default)")
        print("  /rb holo on|off      EXPERIMENTAL: iridescent shimmer sweeping over the item")
        print("  /rb holo tilt on|off the shimmer follows the mouse cursor while it hovers an item")
        print("  /rb holo speed <0.25-3>   shimmer rate (1 = default)")
        print("  /rb perf low|normal|high   animation update rate and how many run at once (lower = faster game)")
        print("  /rb overwrite on|off   hide Bagnon / ElvUI quality borders while ours are on (their settings stay untouched)")
        print("  /rb foreign on|off   decorate buttons of other bag addons too (best effort)")
        print("  /rb compat           show which bag addons were detected")
        print("  /rb rescan           clear the usability cache and refresh")
        return
    end
    ClearCache()
    fxVersion = fxVersion + 1      -- settings changed: every button redoes its effects on the next refresh
    RestoreForeign()
    RefreshAll()
end
