local ADDON_NAME = ...
local api = {}
_G.Aware = api

local defaults = {
    enabled = true,
    showFriendly = true,
    showHostile = true,
    showNPCPets = true,
    showChannels = true,
    showIcon = true,
    barWidth = 97,
    barHeight = 18,
    verticalOffset = 0,
    opacity = 1,
    scale = 1,
    showMinimap = true,
    minimapAngle = 220,
    rawCombatLog = true,
}

local function ensureSettings()
    if type(AwareSettings) ~= "table" then
        AwareSettings = {}
    end
    for key, value in pairs(defaults) do
        if AwareSettings[key] == nil then
            AwareSettings[key] = value
        end
    end
end

local aware = CreateFrame("Frame")
local plates = {}
local visibleBars = {}
local activeCasts = {}
local activeByGUID = {}
local activeByName = {}
local knownChildren = 0
local scanElapsed = 0
local unitScanElapsed = 0
local summaryElapsed = 0
local sessionStarted = false
local sessionID
local rawLoggingWasEnabled = false

local MAX_LOG_ENTRIES = 20000
local LOG_TRIM_COUNT = 1000
local LOG_FORMAT_VERSION = 4
local SUMMARY_INTERVAL = 15

local stats = {
    starts = 0,
    immediate = 0,
    unmatched = 0,
    late = 0,
    stops = 0,
    channels = 0,
    replacements = 0,
    skipped = 0,
}

local totals = {
    starts = 0,
    immediate = 0,
    unmatched = 0,
    late = 0,
    stops = 0,
    channels = 0,
    replacements = 0,
    skipped = 0,
}

local unitTokens = { "target", "focus", "mouseover" }
for index = 1, 4 do
    table.insert(unitTokens, "party" .. index)
end
for index = 1, 40 do
    table.insert(unitTokens, "raid" .. index)
end
for index = 1, 5 do
    table.insert(unitTokens, "arena" .. index)
end

local function chat(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffaware:|r " .. tostring(message))
end

local function clearLog()
    AwareDebugLog = {
        formatVersion = LOG_FORMAT_VERSION,
        sessionCounter = 0,
    }
end

local function ensureLog()
    if type(AwareDebugLog) ~= "table"
        or AwareDebugLog.formatVersion ~= LOG_FORMAT_VERSION then
        clearLog()
    end
end

local function log(message)
    ensureLog()

    local entry = date("%H:%M:%S") .. " " .. tostring(message)
    table.insert(AwareDebugLog, entry)

    if #AwareDebugLog > MAX_LOG_ENTRIES then
        local retained = #AwareDebugLog - LOG_TRIM_COUNT
        for index = 1, retained do
            AwareDebugLog[index] = AwareDebugLog[index + LOG_TRIM_COUNT]
        end
        for index = retained + 1, #AwareDebugLog do
            AwareDebugLog[index] = nil
        end
    end
end

local function bump(key, amount)
    amount = amount or 1
    stats[key] = stats[key] + amount
    totals[key] = totals[key] + amount
end

local function flushSummary(reason)
    local activity = stats.starts + stats.stops + stats.skipped
    if activity == 0 then
        return
    end

    log(
        "SUMMARY reason=" .. tostring(reason)
        .. " starts=" .. stats.starts
        .. " immediate=" .. stats.immediate
        .. " unmatched=" .. stats.unmatched
        .. " late=" .. stats.late
        .. " stops=" .. stats.stops
        .. " channels=" .. stats.channels
        .. " replaced=" .. stats.replacements
        .. " skipped=" .. stats.skipped
    )

    for key in pairs(stats) do
        stats[key] = 0
    end
end

local function normalizeName(name)
    if not name then
        return nil
    end
    return string.lower((name:gsub("%-.+$", "")))
end

local function shortName(name)
    if not name then
        return nil
    end
    return name:gsub("%-.+$", "")
end

local function plateName(plate)
    local nameRegion = select(7, plate:GetRegions())
    if nameRegion and nameRegion.GetText then
        return nameRegion:GetText() or "unknown"
    end
    return "unknown"
end

local function isNameplate(frame)
    if not frame or frame:GetName() then
        return false
    end

    local border = select(2, frame:GetRegions())
    return border
        and border:GetObjectType() == "Texture"
        and border:GetTexture() == "Interface\\Tooltips\\Nameplate-Border"
end

local function hideOverlay(plate, reason)
    local data = plates[plate]
    if not data then
        return
    end

    if data.overlay:IsShown() then
        log(
            "BAR_HIDE name=" .. plateName(plate)
            .. " mode=" .. tostring(data.mode)
            .. " reason=" .. tostring(reason)
        )
    end

    data.overlay:Hide()
    visibleBars[plate] = nil
    data.mode = nil
    data.cast = nil
end

local function setIcon(data, texture)
    data.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
end

local function removeCast(cast)
    if not cast then
        return
    end

    activeCasts[cast] = nil
    if cast.guid and activeByGUID[cast.guid] == cast then
        activeByGUID[cast.guid] = nil
    end
    if cast.normalizedName and activeByName[cast.normalizedName] == cast then
        activeByName[cast.normalizedName] = nil
    end
end

local function findCastForPlate(plate)
    local data = plates[plate]
    local cast

    if data and data.guid then
        cast = activeByGUID[data.guid]
    end
    if not cast then
        cast = activeByName[normalizeName(plateName(plate))]
    end

    if cast and GetTime() < cast.endTime then
        return cast
    end
    return nil
end

local function showNativeCast(plate)
    local data = plates[plate]
    if not data then
        return
    end
    ensureSettings()
    if not AwareSettings.enabled then
        hideOverlay(plate, "disabled")
        return
    end

    local minimum, maximum = data.sourceBar:GetMinMaxValues()
    setIcon(data, data.sourceIcon and data.sourceIcon:GetTexture())
    data.bar:SetMinMaxValues(minimum, maximum)
    data.bar:SetValue(data.sourceBar:GetValue())
    data.mode = "native"
    data.cast = nil
    data.overlay:Show()
    visibleBars[plate] = true

    log(
        "BAR_SHOW name=" .. plateName(plate)
        .. " mode=native min=" .. tostring(minimum)
        .. " max=" .. tostring(maximum)
    )
end

local function showTrackedCast(plate, cast, late)
    local data = plates[plate]
    if not data or not plate:IsShown() then
        return false
    end

    if data.sourceBar:IsShown() then
        showNativeCast(plate)
        return true
    end

    local now = GetTime()
    if now >= cast.endTime then
        return false
    end

    setIcon(data, cast.icon)
    data.bar:SetMinMaxValues(0, cast.duration)
    data.bar:SetValue(now - cast.startTime)
    data.mode = cast.kind
    data.cast = cast
    data.overlay:Show()
    visibleBars[plate] = true

    log(
        "BAR_SHOW name=" .. plateName(plate)
        .. " mode=" .. tostring(cast.kind)
        .. " spell=" .. tostring(cast.spellName)
        .. " id=" .. tostring(cast.spellID)
        .. " duration=" .. string.format("%.3f", cast.duration)
        .. " elapsed=" .. string.format("%.3f", now - cast.startTime)
        .. " late=" .. tostring(late and true or false)
    )

    if late then
        bump("late")
    end
    return true
end

local function nativeCastEnded(plate)
    local cast = findCastForPlate(plate)
    if cast and showTrackedCast(plate, cast, false) then
        log("NATIVE_ENDED_FALLBACK name=" .. plateName(plate))
    else
        hideOverlay(plate, "native_end")
    end
end

local function applyPlateVisualSettings(plate, data)
    local iconSpace = AwareSettings.showIcon and AwareSettings.barHeight + 1 or 0

    data.overlay:SetWidth(AwareSettings.barWidth + iconSpace)
    data.overlay:SetHeight(AwareSettings.barHeight)
    data.overlay:SetScale(AwareSettings.scale)
    data.overlay:SetAlpha(AwareSettings.opacity)
    data.overlay:ClearAllPoints()
    data.overlay:SetPoint("BOTTOM", plate, "TOP", 0, AwareSettings.verticalOffset)

    data.iconBorder:SetWidth(AwareSettings.barHeight)
    data.iconBorder:SetHeight(AwareSettings.barHeight)
    if AwareSettings.showIcon then
        data.iconBorder:Show()
        data.icon:Show()
        data.background:ClearAllPoints()
        data.background:SetPoint("TOPLEFT", data.iconBorder, "TOPRIGHT", 1, 0)
        data.background:SetPoint("BOTTOMRIGHT", data.overlay, "BOTTOMRIGHT", 0, 0)
    else
        data.iconBorder:Hide()
        data.icon:Hide()
        data.background:ClearAllPoints()
        data.background:SetPoint("TOPLEFT", data.overlay, "TOPLEFT", 0, 0)
        data.background:SetPoint("BOTTOMRIGHT", data.overlay, "BOTTOMRIGHT", 0, 0)
    end
end

local function attachPlate(plate)
    if plates[plate] then
        return
    end

    local _, sourceBar = plate:GetChildren()
    local sourceIcon = select(5, plate:GetRegions())
    if not sourceBar then
        log("PLATE_SKIP name=" .. plateName(plate) .. " reason=no_castbar")
        return
    end

    local overlay = CreateFrame("Frame", nil, plate)
    overlay:SetWidth(116)
    overlay:SetHeight(18)
    overlay:SetPoint("BOTTOM", plate, "TOP", 0, 0)
    overlay:SetFrameStrata("HIGH")
    overlay:SetFrameLevel(20)
    overlay:Hide()

    local iconBorder = overlay:CreateTexture(nil, "BACKGROUND")
    iconBorder:SetTexture(0, 0, 0, 1)
    iconBorder:SetWidth(18)
    iconBorder:SetHeight(18)
    iconBorder:SetPoint("LEFT", overlay, "LEFT", 0, 0)

    local icon = overlay:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", iconBorder, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", iconBorder, "BOTTOMRIGHT", -1, 1)

    local background = overlay:CreateTexture(nil, "BACKGROUND")
    background:SetTexture(0, 0, 0, 1)
    background:SetPoint("TOPLEFT", iconBorder, "TOPRIGHT", 1, 0)
    background:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)

    local bar = CreateFrame("StatusBar", nil, overlay)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(1.0, 0.7, 0.0)
    bar:SetPoint("TOPLEFT", background, "TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT", -1, 1)

    local data = {
        sourceBar = sourceBar,
        sourceIcon = sourceIcon,
        overlay = overlay,
        icon = icon,
        iconBorder = iconBorder,
        background = background,
        bar = bar,
    }
    plates[plate] = data
    applyPlateVisualSettings(plate, data)

    sourceBar:HookScript("OnShow", function()
        showNativeCast(plate)
    end)
    sourceBar:HookScript("OnHide", function()
        nativeCastEnded(plate)
    end)
    plate:HookScript("OnHide", function()
        hideOverlay(plate, "plate_hide")
        plates[plate].guid = nil
    end)

    if sourceBar:IsShown() then
        showNativeCast(plate)
    else
        local cast = findCastForPlate(plate)
        if cast then
            showTrackedCast(plate, cast, true)
        end
    end

    log("PLATE_ATTACH name=" .. plateName(plate))
end

local function applyVisualSettings()
    ensureSettings()
    for plate, data in pairs(plates) do
        applyPlateVisualSettings(plate, data)
    end
end

local function scanNameplates()
    local childCount = select("#", WorldFrame:GetChildren())
    if childCount == knownChildren then
        return
    end

    knownChildren = childCount
    for index = 1, childCount do
        local frame = select(index, WorldFrame:GetChildren())
        if isNameplate(frame) then
            attachPlate(frame)
        end
    end
end

local function getBaseCastDuration(spellID)
    local _, _, icon, _, _, _, castTimeMilliseconds = GetSpellInfo(spellID)
    local raw = castTimeMilliseconds and castTimeMilliseconds / 1000 or 0
    if raw <= 0 then
        return 0, icon
    end

    local rawHalf = math.floor(raw * 2 + 0.5) / 2
    if math.abs(raw - rawHalf) < 0.02 then
        return raw, icon
    end

    local haste = 0
    if UnitSpellHaste then
        haste = UnitSpellHaste("player") or 0
    elseif GetCombatRatingBonus and CR_HASTE_SPELL then
        haste = GetCombatRatingBonus(CR_HASTE_SPELL) or 0
    end

    local corrected = raw * (1 + haste / 100)
    local correctedHalf = math.floor(corrected * 2 + 0.5) / 2
    if math.abs(corrected - correctedHalf) <= 0.20 then
        corrected = correctedHalf
    end

    return corrected, icon
end


local function findKuiPlate(guid, name)
    local kui = _G.KuiNameplates
    if not kui or not kui.GetNameplate then
        return nil
    end

    local frame = kui:GetNameplate(guid, shortName(name))
    if frame and frame.oldCastbar then
        return frame.oldCastbar:GetParent()
    end
    return nil
end

local function associateUnit(unit)
    if not unit or not UnitExists(unit) then
        return
    end

    local guid = UnitGUID(unit)
    local name = UnitName(unit)
    if not guid or not name then
        return
    end

    local plate = findKuiPlate(guid, name)
    if plate and plates[plate] then
        plates[plate].guid = guid
        return
    end

    local normalized = normalizeName(name)
    local candidate
    for visiblePlate in pairs(plates) do
        if visiblePlate:IsShown()
            and normalizeName(plateName(visiblePlate)) == normalized then
            if candidate then
                return
            end
            candidate = visiblePlate
        end
    end

    if candidate then
        plates[candidate].guid = guid
    end
end

local function associateKnownUnits()
    for _, unit in ipairs(unitTokens) do
        associateUnit(unit)
    end
end

local function matchingPlates(cast)
    local matches = {}

    if cast.guid then
        for plate, data in pairs(plates) do
            if plate:IsShown() and data.guid == cast.guid then
                table.insert(matches, plate)
            end
        end
    end

    if #matches == 0 then
        for plate in pairs(plates) do
            if plate:IsShown()
                and normalizeName(plateName(plate)) == cast.normalizedName then
                table.insert(matches, plate)
            end
        end
    end

    return matches
end

local function stopCast(cast, reason)
    if not cast then
        return
    end

    removeCast(cast)
    for plate, data in pairs(plates) do
        if data.cast == cast then
            hideOverlay(plate, reason)
        end
    end

    bump("stops")
    if reason ~= "SPELL_CAST_SUCCESS" and reason ~= "UNIT_SPELLCAST_STOP" then
        log(
            "CAST_STOP source=" .. tostring(cast.sourceName)
            .. " spell=" .. tostring(cast.spellName)
            .. " id=" .. tostring(cast.spellID)
            .. " reason=" .. tostring(reason)
        )
    end
end

local function stopCastByIdentity(guid, name, spellID, reason)
    local cast = guid and activeByGUID[guid]
    if not cast then
        cast = activeByName[normalizeName(name)]
    end
    if not cast then
        return
    end
    if spellID and cast.spellID and spellID ~= cast.spellID then
        return
    end
    if reason == "SPELL_CAST_SUCCESS" and cast.kind == "channel" then
        return
    end

    stopCast(cast, reason)
end

local function beginCast(guid, name, spellID, spellName, icon, duration, startTime, kind)
    ensureSettings()
    if not AwareSettings.enabled then
        return
    end
    local normalized = normalizeName(name)
    if not normalized or not duration or duration <= 0 then
        bump("skipped")
        log(
            "CAST_SKIP source=" .. tostring(name)
            .. " spell=" .. tostring(spellName)
            .. " id=" .. tostring(spellID)
            .. " reason=no_duration"
        )
        return
    end

    local previous = (guid and activeByGUID[guid]) or activeByName[normalized]
    if previous then
        local sameSpell = (spellID and previous.spellID == spellID)
            or (spellName and previous.spellName == spellName)
        local sameStart = math.abs(previous.startTime - startTime) < 0.75

        if sameSpell and sameStart and kind == "combatlog"
            and previous.kind ~= "combatlog" then
            return previous
        elseif sameSpell and sameStart and kind ~= "combatlog"
            and previous.kind == "combatlog" then
            stopCast(previous, "timing_upgrade")
        else
            bump("replacements")
            stopCast(previous, "replaced_by_new_cast")
        end
    end

    local cast = {
        guid = guid,
        sourceName = name,
        normalizedName = normalized,
        spellID = spellID,
        spellName = spellName,
        icon = icon,
        duration = duration,
        startTime = startTime,
        endTime = startTime + duration,
        kind = kind,
    }

    activeCasts[cast] = true
    if guid then
        activeByGUID[guid] = cast
    end
    activeByName[normalized] = cast
    bump("starts")
    if kind == "channel" then
        bump("channels")
    end

    local matched = 0
    for _, plate in ipairs(matchingPlates(cast)) do
        if showTrackedCast(plate, cast, false) then
            matched = matched + 1
        end
    end

    if matched > 0 then
        bump("immediate", matched)
    else
        bump("unmatched")
    end
end

local function sourceAllowed(flags)
    ensureSettings()
    if flags and bit and bit.band
        and COMBATLOG_OBJECT_REACTION_FRIENDLY
        and COMBATLOG_OBJECT_TYPE_PLAYER then
        local friendly = bit.band(flags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0
        local player = bit.band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0
        if friendly and not AwareSettings.showFriendly then
            return false
        elseif not friendly and not AwareSettings.showHostile then
            return false
        end
        if not player and not AwareSettings.showNPCPets then
            return false
        end
    end
    return true
end

local function startCombatCast(guid, name, flags, spellID, spellName)
    if not sourceAllowed(flags) then
        return
    end
    local duration, icon = getBaseCastDuration(spellID)
    beginCast(guid, name, spellID, spellName, icon, duration, GetTime(), "combatlog")
end

local function startUnitCast(unit, channel)
    if not unit or not UnitExists(unit) then
        return
    end

    ensureSettings()
    if channel and not AwareSettings.showChannels then
        return
    end
    if UnitIsFriend("player", unit) and not AwareSettings.showFriendly then
        return
    elseif not UnitIsFriend("player", unit) and not AwareSettings.showHostile then
        return
    end
    if not UnitIsPlayer(unit) and not AwareSettings.showNPCPets then
        return
    end

    associateUnit(unit)

    local spellName, _, _, icon, startMilliseconds, endMilliseconds, _, _, possibleSpellID
    if channel then
        spellName, _, _, icon, startMilliseconds, endMilliseconds, _, _, possibleSpellID = UnitChannelInfo(unit)
    else
        spellName, _, _, icon, startMilliseconds, endMilliseconds, _, _, possibleSpellID = UnitCastingInfo(unit)
    end
    if not spellName or not startMilliseconds or not endMilliseconds then
        return
    end

    local spellID = type(possibleSpellID) == "number" and possibleSpellID or nil
    local existing = activeByGUID[UnitGUID(unit)]
    if not spellID and existing and existing.spellName == spellName then
        spellID = existing.spellID
    end
    local startTime = startMilliseconds / 1000
    local duration = (endMilliseconds - startMilliseconds) / 1000
    beginCast(
        UnitGUID(unit),
        UnitName(unit),
        spellID,
        spellName,
        icon,
        duration,
        startTime,
        channel and "channel" or "unit"
    )
end

local function updateUnitChannel(unit)
    if not unit or not UnitExists(unit) then
        return
    end

    local guid = UnitGUID(unit)
    local cast = guid and activeByGUID[guid]
    if not cast or cast.kind ~= "channel" then
        return
    end

    local _, _, _, _, startMilliseconds, endMilliseconds = UnitChannelInfo(unit)
    if startMilliseconds and endMilliseconds then
        cast.startTime = startMilliseconds / 1000
        cast.duration = (endMilliseconds - startMilliseconds) / 1000
        cast.endTime = endMilliseconds / 1000
    end
end

local function clearActiveCasts(reason)
    for cast in pairs(activeCasts) do
        stopCast(cast, reason)
    end
end

local function enableRawCombatLog()
    ensureSettings()
    if not LoggingCombat then
        log("RAW_COMBAT_LOG unavailable")
        return
    end

    rawLoggingWasEnabled = LoggingCombat() and true or false
    if AwareSettings.rawCombatLog then
        LoggingCombat(1)
    end
    log(
        "RAW_COMBAT_LOG enabled=" .. tostring(AwareSettings.rawCombatLog)
        .. " wasEnabled=" .. tostring(rawLoggingWasEnabled)
    )
end

local function beginSession()
    if sessionStarted then
        return
    end

    ensureLog()
    AwareDebugLog.sessionCounter = (AwareDebugLog.sessionCounter or 0) + 1
    sessionID = date("%Y%m%d-%H%M%S") .. "-" .. AwareDebugLog.sessionCounter
    sessionStarted = true

    local instanceName, instanceType = GetInstanceInfo()
    log(
        "SESSION_START id=" .. sessionID
        .. " version=" .. tostring(GetAddOnMetadata(ADDON_NAME, "Version"))
        .. " character=" .. tostring(UnitName("player"))
        .. " realm=" .. tostring(GetRealmName())
        .. " zone=" .. tostring(GetRealZoneText())
        .. " instance=" .. tostring(instanceName)
        .. " type=" .. tostring(instanceType)
    )
end

local function printHealth()
    ensureLog()
    local plateCount = 0
    local activeCount = 0
    for _ in pairs(plates) do
        plateCount = plateCount + 1
    end
    for _ in pairs(activeCasts) do
        activeCount = activeCount + 1
    end

    UpdateAddOnMemoryUsage()
    local memory = GetAddOnMemoryUsage(ADDON_NAME) or 0
    local rawEnabled = LoggingCombat and LoggingCombat() and true or false

    chat(
        "health: plates=" .. plateCount
        .. ", active=" .. activeCount
        .. ", log=" .. #AwareDebugLog .. "/" .. MAX_LOG_ENTRIES
        .. ", memory=" .. string.format("%.1f KB", memory)
        .. ", rawLog=" .. tostring(rawEnabled)
    )
    chat(
        "totals: starts=" .. totals.starts
        .. ", shown=" .. totals.immediate
        .. ", late=" .. totals.late
        .. ", stops=" .. totals.stops
        .. ", channels=" .. totals.channels
        .. ", skipped=" .. totals.skipped
    )
end

local function applySettings()
    ensureSettings()
    SetCVar("nameplateShowEnemies", AwareSettings.showHostile and 1 or 0)
    SetCVar("nameplateShowFriends", AwareSettings.showFriendly and 1 or 0)
    applyVisualSettings()

    if not AwareSettings.enabled then
        clearActiveCasts("disabled")
    end

    if LoggingCombat then
        if AwareSettings.rawCombatLog then
            LoggingCombat(1)
        elseif not rawLoggingWasEnabled then
            LoggingCombat(0)
        end
    end
end

api.GetSettings = function()
    ensureSettings()
    return AwareSettings
end

api.GetDefaults = function()
    return defaults
end

api.ApplySettings = applySettings
api.Health = printHealth
api.ClearTrackedCasts = function()
    clearActiveCasts("settings_change")
end
api.ClearLog = function()
    clearLog()
    log("LOG_CLEARED session=" .. tostring(sessionID))
end

aware:SetScript("OnUpdate", function(_, elapsed)
    scanElapsed = scanElapsed + elapsed
    unitScanElapsed = unitScanElapsed + elapsed
    summaryElapsed = summaryElapsed + elapsed

    local now = GetTime()
    for plate in pairs(visibleBars) do
        local data = plates[plate]
        if not data or not plate:IsShown() then
            hideOverlay(plate, "not_visible")
        elseif data.sourceBar:IsShown() then
            local minimum, maximum = data.sourceBar:GetMinMaxValues()
            data.bar:SetMinMaxValues(minimum, maximum)
            data.bar:SetValue(data.sourceBar:GetValue())

            local texture = data.sourceIcon and data.sourceIcon:GetTexture()
            if texture and texture ~= data.icon:GetTexture() then
                data.icon:SetTexture(texture)
            end
        elseif data.cast and activeCasts[data.cast] and now < data.cast.endTime then
            data.bar:SetValue(now - data.cast.startTime)
        else
            hideOverlay(plate, "inactive")
        end
    end

    if scanElapsed < 0.10 then
        return
    end
    scanElapsed = 0

    scanNameplates()

    if unitScanElapsed >= 1 then
        unitScanElapsed = 0
        associateKnownUnits()
    end

    for cast in pairs(activeCasts) do
        if now >= cast.endTime then
            stopCast(cast, "expired")
        end
    end

    for plate, data in pairs(plates) do
        if plate:IsShown() and not data.mode then
            local cast = findCastForPlate(plate)
            if cast then
                showTrackedCast(plate, cast, true)
            end
        end
    end

    if summaryElapsed >= SUMMARY_INTERVAL then
        summaryElapsed = 0
        flushSummary("periodic")
    end
end)

aware:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= ADDON_NAME then
            return
        end

        ensureLog()
        ensureSettings()
        SetCVar("showVKeyCastbar", 1)
        enableRawCombatLog()
        applySettings()
        log("ADDON_LOADED version=" .. tostring(GetAddOnMetadata(ADDON_NAME, "Version")))
        chat("loaded; visible nameplate cast bars are active")
        scanNameplates()
    elseif event == "PLAYER_ENTERING_WORLD" then
        clearActiveCasts("enter_world")
        associateKnownUnits()
        beginSession()
        local instanceName, instanceType = GetInstanceInfo()
        log(
            "WORLD_ENTER zone=" .. tostring(GetRealZoneText())
            .. " instance=" .. tostring(instanceName)
            .. " type=" .. tostring(instanceType)
        )
    elseif event == "PLAYER_LOGOUT" then
        flushSummary("logout")
        log("SESSION_END id=" .. tostring(sessionID) .. " reason=logout")
    elseif event == "PLAYER_TARGET_CHANGED"
        or event == "PLAYER_FOCUS_CHANGED"
        or event == "UPDATE_MOUSEOVER_UNIT"
        or event == "PARTY_MEMBERS_CHANGED"
        or event == "RAID_ROSTER_UPDATE"
        or event == "ARENA_OPPONENT_UPDATE" then
        associateKnownUnits()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, _, spellID, spellName, _, extraSpellID = ...

        if subevent == "SPELL_CAST_START" then
            startCombatCast(sourceGUID, sourceName, sourceFlags, spellID, spellName)
        elseif subevent == "SPELL_CAST_SUCCESS"
            or subevent == "SPELL_CAST_FAILED" then
            stopCastByIdentity(sourceGUID, sourceName, spellID, subevent)
        elseif subevent == "SPELL_INTERRUPT" then
            stopCastByIdentity(destGUID, destName, extraSpellID, subevent)
        end
    elseif event == "UNIT_SPELLCAST_START" then
        startUnitCast((...), false)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        startUnitCast((...), true)
    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        updateUnitChannel((...))
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit = ...
        if unit then
            stopCastByIdentity(UnitGUID(unit), UnitName(unit), nil, event)
        end
    end
end)

aware:RegisterEvent("ADDON_LOADED")
aware:RegisterEvent("PLAYER_ENTERING_WORLD")
aware:RegisterEvent("PLAYER_LOGOUT")
aware:RegisterEvent("PLAYER_TARGET_CHANGED")
aware:RegisterEvent("PLAYER_FOCUS_CHANGED")
aware:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
aware:RegisterEvent("PARTY_MEMBERS_CHANGED")
aware:RegisterEvent("RAID_ROSTER_UPDATE")
aware:RegisterEvent("ARENA_OPPONENT_UPDATE")
aware:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
aware:RegisterEvent("UNIT_SPELLCAST_START")
aware:RegisterEvent("UNIT_SPELLCAST_STOP")
aware:RegisterEvent("UNIT_SPELLCAST_FAILED")
aware:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
aware:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
aware:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
aware:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

SLASH_AWARE1 = "/aware"
SlashCmdList.AWARE = function(message)
    message = string.lower(message or "")
    ensureLog()

    if message == "clear" then
        api.ClearLog()
        chat("debug log cleared")
        return
    end

    if message == "health" or message == "status" then
        printHealth()
        return
    end

    if message == "log" then
        local first = math.max(1, #AwareDebugLog - 19)
        chat("showing the last " .. tostring(#AwareDebugLog - first + 1) .. " log entries")
        for index = first, #AwareDebugLog do
            chat(AwareDebugLog[index])
        end
        return
    end

    if message == "" or message == "config" or message == "options" then
        if api.ToggleOptions then
            api.ToggleOptions()
        else
            chat("options are not available")
        end
        return
    end

    chat("commands: /aware, /aware health, /aware log, /aware clear")
end
