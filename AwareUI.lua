local api = _G.Aware
if not api then
    return
end

local controls = {}
local refreshing = false
local window
local minimapButton
local zoneStatus
local appearanceSelection = 1
local appearanceOptions = {
    { label = "Bar width", key = "barWidth", minimum = 70, maximum = 180, step = 1, format = function(v) return string.format("%d", v) end },
    { label = "Bar height", key = "barHeight", minimum = 12, maximum = 28, step = 1, format = function(v) return string.format("%d", v) end },
    { label = "Vertical offset", key = "verticalOffset", minimum = -20, maximum = 40, step = 1, format = function(v) return string.format("%d", v) end },
    { label = "Opacity", key = "opacity", minimum = 0.4, maximum = 1, step = 0.05, format = function(v) return string.format("%d%%", v * 100) end },
    { label = "Scale", key = "scale", minimum = 0.75, maximum = 1.5, step = 0.05, format = function(v) return string.format("%d%%", v * 100) end },
}
local atan2 = math.atan2 or function(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 then
        return math.atan(y / x) - math.pi
    elseif y > 0 then
        return math.pi / 2
    elseif y < 0 then
        return -math.pi / 2
    end
    return 0
end

local function settings()
    return api.GetSettings()
end

local function apply(clearTracked)
    if clearTracked and api.ClearTrackedCasts then
        api.ClearTrackedCasts()
    end
    api.ApplySettings()
end

local function title(parent, text, x, y, size, color)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetFont("Fonts\\FRIZQT__.TTF", size)
    label:SetText(text)
    if color then
        label:SetTextColor(color[1], color[2], color[3])
    end
    return label
end

local function section(parent, text, y)
    local label = title(parent, string.upper(text), 24, y, 11, { 0.40, 0.82, 1.0 })
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(0.18, 0.48, 0.62, 0.65)
    line:SetHeight(1)
    line:SetPoint("LEFT", label, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
end

local function checkbox(parent, label, key, x, y, clearTracked, afterApply)
    local button = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetWidth(24)
    button:SetHeight(24)

    local text = button:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", button, "RIGHT", 3, 0)
    text:SetText(label)

    button:SetScript("OnClick", function(self)
        settings()[key] = self:GetChecked() and true or false
        apply(clearTracked)
        if afterApply then
            afterApply()
        end
    end)
    button.Refresh = function(self)
        self:SetChecked(settings()[key] and 1 or nil)
    end
    table.insert(controls, button)
    return button
end

local function appearanceSlider(parent, x, y)
    local selector = CreateFrame("Frame", "AwareAppearanceSelector", parent, "UIDropDownMenuTemplate")
    selector:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 16, y + 8)
    UIDropDownMenu_SetWidth(selector, 142)

    local control = CreateFrame("Slider", "AwareAppearanceSlider", parent, "OptionsSliderTemplate")
    control:SetPoint("LEFT", selector, "RIGHT", 4, 1)
    control:SetWidth(205)
    control:SetHeight(16)
    if _G.AwareAppearanceSliderText then
        _G.AwareAppearanceSliderText:Hide()
        _G.AwareAppearanceSliderLow:Hide()
        _G.AwareAppearanceSliderHigh:Hide()
    end

    local caption = control:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    caption:SetPoint("BOTTOMLEFT", control, "TOPLEFT", 0, 4)

    local low = control:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", control, "BOTTOMLEFT", 0, -2)

    local high = control:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", control, "BOTTOMRIGHT", 0, -2)

    local function configure()
        local option = appearanceOptions[appearanceSelection]
        refreshing = true
        control:SetMinMaxValues(option.minimum, option.maximum)
        control:SetValueStep(option.step)
        control:SetValue(settings()[option.key])
        caption:SetText(option.label .. ": |cff66ccff" .. option.format(settings()[option.key]) .. "|r")
        low:SetText(option.format(option.minimum))
        high:SetText(option.format(option.maximum))
        UIDropDownMenu_SetSelectedValue(selector, appearanceSelection)
        UIDropDownMenu_SetText(selector, option.label)
        refreshing = false
    end

    control:SetScript("OnValueChanged", function(self, value)
        local option = appearanceOptions[appearanceSelection]
        local rounded = math.floor(value / option.step + 0.5) * option.step
        caption:SetText(option.label .. ": |cff66ccff" .. option.format(rounded) .. "|r")
        if refreshing then
            return
        end
        settings()[option.key] = rounded
        apply(false)
    end)

    UIDropDownMenu_Initialize(selector, function()
        for index, option in ipairs(appearanceOptions) do
            local selectedIndex = index
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.label
            info.value = selectedIndex
            info.checked = selectedIndex == appearanceSelection
            info.func = function()
                appearanceSelection = selectedIndex
                configure()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    control.Refresh = function(self)
        configure()
    end
    table.insert(controls, control)
    return control
end

local function updateZoneStatus()
    if not zoneStatus or not api.GetZoneContext then
        return
    end
    local context = api.GetZoneContext()
    local enabled = settings()[context.setting] ~= false
    zoneStatus:SetText(
        "Current: " .. context.label .. " — "
        .. (enabled and "|cff66ff99enabled|r" or "|cffff7777disabled|r")
    )
end

local function refresh()
    refreshing = true
    for _, control in ipairs(controls) do
        control:Refresh()
    end
    refreshing = false
    updateZoneStatus()
end

local function positionMinimapButton()
    if not minimapButton then
        return
    end
    if not settings().showMinimap then
        minimapButton:Hide()
        return
    end

    minimapButton:Show()
    local angle = math.rad(settings().minimapAngle or 220)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function createWindow()
    local frame = CreateFrame("Frame", "AwareOptionsFrame", UIParent)
    frame:SetWidth(460)
    frame:SetHeight(635)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 24,
        edgeSize = 18,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.025, 0.040, 0.055, 1)
    frame:SetBackdropBorderColor(0.18, 0.48, 0.62, 0.95)
    frame:Hide()

    local solidBackground = frame:CreateTexture(nil, "BACKGROUND")
    solidBackground:SetTexture(0.012, 0.022, 0.034, 0.96)
    solidBackground:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -8)
    solidBackground:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -7, 7)

    local accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetTexture(0.18, 0.72, 0.95, 1)
    accent:SetHeight(3)
    accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -7)
    accent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -7, -7)

    title(frame, "aware", 24, -24, 22, { 0.86, 0.95, 1.0 })
    title(frame, "Nearby cast visibility", 24, -51, 11, { 0.55, 0.62, 0.68 })

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)

    section(frame, "General", -82)
    checkbox(frame, "Enable aware", "enabled", 22, -102, true)
    checkbox(frame, "Show minimap button", "showMinimap", 238, -102, false, positionMinimapButton)

    section(frame, "Tracking", -144)
    checkbox(frame, "Friendly casters", "showFriendly", 22, -164, true)
    checkbox(frame, "Hostile casters", "showHostile", 238, -164, true)
    checkbox(frame, "NPCs and pets", "showNPCPets", 22, -194, true)
    checkbox(frame, "Channeled spells", "showChannels", 238, -194, true)

    section(frame, "Zones", -236)
    checkbox(frame, "Dungeons", "zoneDungeon", 22, -256, true, updateZoneStatus)
    checkbox(frame, "Raids", "zoneRaid", 238, -256, true, updateZoneStatus)
    checkbox(frame, "Battlegrounds", "zoneBattleground", 22, -286, true, updateZoneStatus)
    checkbox(frame, "Arenas", "zoneArena", 238, -286, true, updateZoneStatus)
    checkbox(frame, "Sanctuary areas", "zoneSanctuary", 22, -316, true, updateZoneStatus)
    checkbox(frame, "Friendly territory / cities", "zoneFriendly", 238, -316, true, updateZoneStatus)
    checkbox(frame, "Hostile territory / cities", "zoneHostile", 22, -346, true, updateZoneStatus)
    checkbox(frame, "Contested / neutral", "zoneContested", 238, -346, true, updateZoneStatus)
    zoneStatus = title(frame, "Current zone", 24, -379, 10, { 0.70, 0.76, 0.82 })

    section(frame, "Appearance", -407)
    checkbox(frame, "Show spell icon", "showIcon", 22, -427, false)
    appearanceSlider(frame, 24, -481)

    section(frame, "Diagnostics", -536)
    checkbox(frame, "Protect continuous combat log", "rawCombatLog", 22, -556, false)

    local health = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    health:SetWidth(96)
    health:SetHeight(24)
    health:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 20)
    health:SetText("Health")
    health:SetScript("OnClick", api.Health)

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetWidth(96)
    clear:SetHeight(24)
    clear:SetPoint("LEFT", health, "RIGHT", 8, 0)
    clear:SetText("Clear log")
    clear:SetScript("OnClick", function()
        api.ClearLog()
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffaware:|r debug log cleared")
    end)

    local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reset:SetWidth(112)
    reset:SetHeight(24)
    reset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 20)
    reset:SetText("Reset defaults")
    reset:SetScript("OnClick", function()
        StaticPopup_Show("AWARE_RESET_CONFIRM")
    end)

    frame:SetScript("OnShow", refresh)
    return frame
end

StaticPopupDialogs.AWARE_RESET_CONFIRM = {
    text = "Reset all aware settings to their defaults?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        local current = settings()
        for key, value in pairs(api.GetDefaults()) do
            current[key] = value
        end
        apply(true)
        positionMinimapButton()
        refresh()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

window = createWindow()

api.ToggleOptions = function()
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

local function createMinimapButton()
    local button = CreateFrame("Button", "AwareMinimapButton", Minimap)
    button:SetWidth(32)
    button:SetHeight(32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\AddOns\\aware\\Media\\aware-icon")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(54)
    border:SetHeight(54)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            api.Health()
        else
            api.ToggleOptions()
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("aware", 0.40, 0.82, 1.0)
        GameTooltip:AddLine("Left-click: options", 1, 1, 1)
        GameTooltip:AddLine("Right-click: health", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local scale = UIParent:GetEffectiveScale()
            local cursorX, cursorY = GetCursorPosition()
            local centerX, centerY = Minimap:GetCenter()
            cursorX = cursorX / scale
            cursorY = cursorY / scale
            local angle = math.deg(atan2(cursorY - centerY, cursorX - centerX))
            settings().minimapAngle = angle
            positionMinimapButton()
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    minimapButton = button
    positionMinimapButton()
end

local category = CreateFrame("Frame")
category.name = "aware"
local categoryTitle = title(category, "aware", 16, -16, 20, { 0.40, 0.82, 1.0 })
local categoryText = category:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
categoryText:SetPoint("TOPLEFT", categoryTitle, "BOTTOMLEFT", 0, -14)
categoryText:SetWidth(560)
categoryText:SetJustifyH("LEFT")
categoryText:SetText("Nearby cast visibility. Changes apply immediately.")
local open = CreateFrame("Button", nil, category, "UIPanelButtonTemplate")
open:SetWidth(150)
open:SetHeight(24)
open:SetPoint("TOPLEFT", categoryText, "BOTTOMLEFT", 0, -18)
open:SetText("Open aware options")
open:SetScript("OnClick", function()
    api.ToggleOptions()
end)
InterfaceOptions_AddCategory(category)

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:RegisterEvent("ZONE_CHANGED")
loader:RegisterEvent("ZONE_CHANGED_INDOORS")
loader:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        createMinimapButton()
    elseif window:IsShown() then
        updateZoneStatus()
    end
end)
