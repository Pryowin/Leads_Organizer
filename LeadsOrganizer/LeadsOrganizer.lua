--[[
    Leads Organizer — filter and sort scrying leads.
    Panel: /leadsorg or keybind (Controls → Keybindings → General).
    Search uses the in-game Antiquities journal; this panel lists active leads only.
]]

LeadsOrganizer = LeadsOrganizer or {}
local LO = LeadsOrganizer

LO.name = "LeadsOrganizer"
LO.version = "1.3.3"
LO.SCENE_NAME = "LeadsOrganizerMainScene"

local EM = EVENT_MANAGER
local ADM = ANTIQUITY_DATA_MANAGER

LO.SORT_ZONE = 1
LO.SORT_EXPIRY = 2
LO.SORT_NAME = 3

LO.SORT_LABELS = {
    [LO.SORT_ZONE] = "Zone",
    [LO.SORT_EXPIRY] = "Expiry (soonest)",
    [LO.SORT_NAME] = "Name",
}

local DEFAULT_SETTINGS = {
    sortMode = LO.SORT_EXPIRY,
    showGreenAlwaysAvailable = true,
    showCompletedBefore = true,
    hideAboveScryingSkill = false,
    currentZoneOnly = false,
}

local NO_EXPIRY_SORT_VALUE = 999999999
local LEAD_ROW_DATA_TYPE = 1

--- Journal scryable tile: primary = Scry, tertiary = View in Codex (see zo_antiquityjournal_keyboard).
local KEYBIND_SCRY = "UI_SHORTCUT_PRIMARY"
local KEYBIND_CODEX = "UI_SHORTCUT_TERTIARY"

local function SafeCall(method, obj, ...)
    if not obj or not method then
        return nil
    end
    local fn = obj[method]
    if not fn then
        return nil
    end
    local ok, r1, r2 = pcall(fn, obj, ...)
    if ok then
        return r1, r2
    end
    return nil
end

local function SetRowLabelTextColor(label, textColor)
    if not label or not textColor then
        return
    end
    local r, g, b = GetInterfaceColor(INTERFACE_COLOR_TYPE_TEXT_COLORS, textColor)
    label:SetColor(r, g, b, 1)
end

local function UpdateLeadKeybindStrip()
    if not KEYBIND_STRIP or not LO.leadKeybindStripDescriptor or not LO.leadKeybindStripActive then
        return
    end
    if KEYBIND_STRIP.RefreshKeybindButtonGroup then
        KEYBIND_STRIP:RefreshKeybindButtonGroup(LO.leadKeybindStripDescriptor)
    elseif KEYBIND_STRIP.UpdateKeybindButtonGroup then
        KEYBIND_STRIP:UpdateKeybindButtonGroup(LO.leadKeybindStripDescriptor)
    end
end

local function FormatSecondsRough(secs)
    if not secs or secs <= 0 or secs >= NO_EXPIRY_SORT_VALUE then
        return nil
    end
    local d = zo_floor(secs / 86400)
    local h = zo_floor((secs % 86400) / 3600)
    local m = zo_floor((secs % 3600) / 60)
    if d > 0 then
        return string.format("%dd %dh", d, h)
    end
    if h > 0 then
        return string.format("%dh %dm", h, m)
    end
    if m > 0 then
        return string.format("%dm", m)
    end
    return "<1m"
end

local function SafeGetLeadExpiryDisplayText(antiquityData)
    if antiquityData.GetLeadExpirationStatus then
        local ok, _, timeRemaining = pcall(function()
            return antiquityData:GetLeadExpirationStatus()
        end)
        if ok and timeRemaining and timeRemaining ~= "" then
            return timeRemaining
        end
    end
    if antiquityData.GetLeadTimeRemainingS then
        local ok, secs = pcall(function()
            return antiquityData:GetLeadTimeRemainingS()
        end)
        if ok and secs then
            local rough = FormatSecondsRough(secs)
            if rough then
                return rough .. " left"
            end
        end
    end
    local id = antiquityData.GetId and antiquityData:GetId() or antiquityData.antiquityId
    if id and GetAntiquityLeadTimeRemainingSeconds then
        local secs = GetAntiquityLeadTimeRemainingSeconds(id)
        local rough = FormatSecondsRough(secs)
        if rough then
            return rough .. " left"
        end
    end
    return nil
end

local function StripGenderSuffix(text)
    if not text or text == "" then
        return text
    end
    return text:gsub("%^[a-zA-Z]+$", "")
end

local function GetSettings()
    return LO.settings
end

--- Player zone id (stable); prefer ZOS helper over raw unit index when available.
local function GetPlayerCurrentZoneId()
    if ZO_ExplorationUtils_GetPlayerCurrentZoneId then
        local z = ZO_ExplorationUtils_GetPlayerCurrentZoneId()
        if z and z ~= 0 then
            return z
        end
    end
    local zoneIndex = GetUnitZoneIndex("player")
    if not zoneIndex then
        return nil
    end
    return GetZoneId(zoneIndex)
end

--- Zone for an antiquity/lead row (object or light table). Uses global GetAntiquityZoneId(number id) when needed — do not name this GetAntiquityZoneId (global name clash).
local function GetLeadObjectZoneId(antiquityData)
    if antiquityData.GetZoneId then
        local ok, z = pcall(function()
            return antiquityData:GetZoneId()
        end)
        if ok and z then
            return z
        end
    end
    if antiquityData.zoneId then
        return antiquityData.zoneId
    end
    local id = antiquityData.GetId and antiquityData:GetId() or antiquityData.antiquityId
    if id and GetAntiquityZoneId then
        local ok, z = pcall(function()
            return GetAntiquityZoneId(id)
        end)
        if ok and z then
            return z
        end
    end
    return nil
end

--- "Current zone only" is strict: antiquities with zone 0 / unknown (anywhere) are hidden when the filter is on.
local function LeadObjectMatchesCurrentZoneFilter(antiquityData)
    if antiquityData.IsInCurrentPlayerZone then
        local ok, matches = pcall(function()
            return antiquityData:IsInCurrentPlayerZone()
        end)
        if ok and not matches then
            return false
        end
    end
    local pZone = GetPlayerCurrentZoneId()
    if not pZone then
        return false
    end
    local aZone = GetLeadObjectZoneId(antiquityData)
    if not aZone or aZone == 0 then
        return false
    end
    return aZone == pZone
end

function LO.IsGreenAlwaysAvailable(antiquityData)
    if antiquityData.RequiresLead then
        return not antiquityData:RequiresLead()
    end
    return antiquityData.requiresLead == false
end

function LO.HasCompletedBefore(antiquityData)
    if antiquityData.GetNumRecovered and (antiquityData:GetNumRecovered() or 0) > 0 then
        return true
    end
    if (antiquityData.numRecovered or 0) > 0 then
        return true
    end
    if antiquityData.HasAchievedAllGoals and antiquityData:HasAchievedAllGoals() then
        return true
    end
    return false
end

function LO.AntiquityPassesFilters(antiquityData)
    if not antiquityData then
        return false
    end
    local settings = GetSettings()
    if not settings then
        return true
    end
    if settings.hideAboveScryingSkill then
        local meets = SafeCall("MeetsScryingSkillRequirements", antiquityData)
        if meets == false then
            return false
        end
    end
    if not settings.showGreenAlwaysAvailable and LO.IsGreenAlwaysAvailable(antiquityData) then
        return false
    end
    if not settings.showCompletedBefore and LO.HasCompletedBefore(antiquityData) then
        return false
    end
    if settings.currentZoneOnly and not LeadObjectMatchesCurrentZoneFilter(antiquityData) then
        return false
    end
    return true
end

function LO.FilterAllActiveLeads(antiquityData)
    local ok, passes = pcall(LO.AntiquityPassesFilters, antiquityData)
    return ok and passes == true
end

local function GetLeadSortTime(antiquityData)
    if not (antiquityData.HasLead and antiquityData:HasLead()) then
        return NO_EXPIRY_SORT_VALUE
    end
    local leadTime
    if antiquityData.GetLeadTimeRemainingS then
        leadTime = antiquityData:GetLeadTimeRemainingS()
    end
    if (not leadTime or leadTime == 0) and antiquityData.GetId and GetAntiquityLeadTimeRemainingSeconds then
        leadTime = GetAntiquityLeadTimeRemainingSeconds(antiquityData:GetId())
    end
    if not leadTime or leadTime == 0 then
        return NO_EXPIRY_SORT_VALUE
    end
    return leadTime
end

local function CompareAntiquityNames(left, right)
    if left.CompareNameTo and right.CompareNameTo then
        return left:CompareNameTo(right)
    end
    local ln = (left.GetName and left:GetName()) or ""
    local rn = (right.GetName and right:GetName()) or ""
    return ln < rn
end

function LO.SortByZone(leftAntiquityData, rightAntiquityData)
    local lz = GetLeadObjectZoneId(leftAntiquityData)
    local rz = GetLeadObjectZoneId(rightAntiquityData)
    local leftZone = (lz and GetZoneNameById(lz)) or ""
    local rightZone = (rz and GetZoneNameById(rz)) or ""
    if leftZone ~= rightZone then
        return leftZone < rightZone
    end
    return CompareAntiquityNames(leftAntiquityData, rightAntiquityData)
end

function LO.SortByExpiry(leftAntiquityData, rightAntiquityData)
    local leftTime = GetLeadSortTime(leftAntiquityData)
    local rightTime = GetLeadSortTime(rightAntiquityData)
    if leftTime ~= rightTime then
        return leftTime < rightTime
    end
    return LO.SortByZone(leftAntiquityData, rightAntiquityData)
end

function LO.SortByName(leftAntiquityData, rightAntiquityData)
    return CompareAntiquityNames(leftAntiquityData, rightAntiquityData)
end

function LO.GetActiveSortFunction()
    local settings = GetSettings()
    if settings.sortMode == LO.SORT_ZONE then
        return LO.SortByZone
    elseif settings.sortMode == LO.SORT_NAME then
        return LO.SortByName
    end
    return LO.SortByExpiry
end

function LO.SortActiveLeadSections()
    if not ANTIQUITY_MANAGER or not ANTIQUITY_MANAGER.antiquitySectionData then
        return false
    end

    local sortFunction = LO.GetActiveSortFunction()
    for _, section in pairs(ANTIQUITY_MANAGER.antiquitySectionData) do
        if section.sectionType == ZO_ANTIQUITY_SECTION_TYPE.ACTIVE_LEAD and section.list then
            section.sortFunction = sortFunction
            if #section.list > 1 then
                table.sort(section.list, sortFunction)
            end
        end
    end
    return true
end

function LO.ApplySubcategoryFilter()
    if ZO_SCRYABLE_ANTIQUITY_ALL_LEADS_SUBCATEGORY_DATA then
        pcall(function()
            ZO_SCRYABLE_ANTIQUITY_ALL_LEADS_SUBCATEGORY_DATA:SetAntiquityFilterFunction(LO.FilterAllActiveLeads)
        end)
    end
end

--- Same notion as “All Active Leads”: in progress, has a lead, or always-available (no lead required).
local function IsActiveLeadCandidate(antiquityData)
    if antiquityData.HasAchievedAllGoals and antiquityData:HasAchievedAllGoals() then
        return false
    end
    local inProgress = antiquityData.IsInProgress and antiquityData:IsInProgress()
    local hasLead = antiquityData.HasLead and antiquityData:HasLead()
    if inProgress or hasLead then
        return true
    end
    if antiquityData.RequiresLead then
        if not antiquityData:RequiresLead() then
            return true
        end
    elseif antiquityData.requiresLead == false then
        return true
    end
    return false
end

function LO.CollectFilteredActiveLeads()
    local seen = {}
    local list = {}

    if ADM and ADM.antiquities then
        for _, antiquityData in pairs(ADM.antiquities) do
            if antiquityData and IsActiveLeadCandidate(antiquityData) and LO.AntiquityPassesFilters(antiquityData) then
                local id = (antiquityData.GetId and antiquityData:GetId()) or antiquityData.antiquityId
                if id and not seen[id] then
                    seen[id] = true
                    table.insert(list, antiquityData)
                end
            end
        end
    end

    local sortFn = LO.GetActiveSortFunction()
    table.sort(list, sortFn)

    return list
end

local function GetRowPayload(data)
    if type(data) == "table" and data.data ~= nil then
        return data.data
    end
    return data
end

function LO.ApplyLeadRowSelection(control, antiquityId)
    if not control or not antiquityId then
        return
    end
    LO.SetLeadRowSelected(control, antiquityId)
end

function LO.OnLeadRowMouseUp(control, button, upInside, scrollList)
    if not upInside or button ~= MOUSE_BUTTON_INDEX_LEFT then
        return
    end
    scrollList = scrollList or LO.resultsScroll
    if scrollList and ZO_ScrollList_MouseClick then
        ZO_ScrollList_MouseClick(scrollList, control)
    end
    if control.loAntiquityId then
        LO.ApplyLeadRowSelection(control, control.loAntiquityId)
    end
end

function LO.OnLeadRowHighlighted(control, data)
    local antiquityId = control and control.loAntiquityId
    if not antiquityId and data then
        local payload = GetRowPayload(data)
        if type(payload) == "table" then
            antiquityId = payload.antiquityId
        end
    end
    if control and antiquityId then
        LO.ApplyLeadRowSelection(control, antiquityId)
    end
end

function LO.SetupLeadScrollRow(control, data, scrollList)
    scrollList = scrollList or LO.resultsScroll
    local payload = GetRowPayload(data)
    local text = ""
    control.loAntiquityId = nil
    if type(payload) == "table" then
        text = payload.text or ""
        control.loAntiquityId = payload.antiquityId
    elseif type(payload) == "string" then
        text = payload
    end

    control:SetMouseEnabled(true)
    if control.SetFont then
        control:SetFont("ZoFontGameSmall")
    end
    if control.SetMaxLineCount then
        control:SetMaxLineCount(2)
    end
    if control.SetWrapMode and TEXT_WRAP_MODE_WRAP_TEXT then
        control:SetWrapMode(TEXT_WRAP_MODE_WRAP_TEXT)
    end
    control:SetText(text)

    if LO.selectedAntiquityId and control.loAntiquityId == LO.selectedAntiquityId then
        LO.selectedRowControl = control
        SetRowLabelTextColor(control, INTERFACE_TEXT_COLOR_SELECTED)
    else
        SetRowLabelTextColor(control, INTERFACE_TEXT_COLOR_DEFAULT)
    end

    control:SetHandler("OnMouseUp", nil)
    control:SetHandler("OnMouseUp", function(rowControl, mouseButton, isUpInside)
        LO.OnLeadRowMouseUp(rowControl, mouseButton, isUpInside, scrollList)
    end)
end

function LO.ClearLeadSelection()
    LO.selectedRowControl = nil
    LO.selectedAntiquityId = nil
    UpdateLeadKeybindStrip()
end

function LO.SetLeadRowSelected(control, antiquityId)
    if LO.selectedRowControl and LO.selectedRowControl ~= control then
        SetRowLabelTextColor(LO.selectedRowControl, INTERFACE_TEXT_COLOR_DEFAULT)
    end
    LO.selectedRowControl = control
    LO.selectedAntiquityId = antiquityId
    SetRowLabelTextColor(control, INTERFACE_TEXT_COLOR_SELECTED)
    UpdateLeadKeybindStrip()
end

function LO.AntiquityCanScry(antiquityId)
    if not antiquityId or not ADM then
        return false
    end
    local data = ADM:GetAntiquityData(antiquityId)
    if not data or not data.CanScry then
        return false
    end
    local ok, canScry, _msg = pcall(function()
        return data:CanScry()
    end)
    return ok and canScry == true
end

function LO.IsPanelActive()
    return LO.scene and SCENE_MANAGER:IsShowing(LO.SCENE_NAME)
end

function LO.PerformSelectedScry()
    local id = LO.selectedAntiquityId
    if not id or not ScryForAntiquity then
        return
    end
    pcall(function()
        ScryForAntiquity(id)
    end)
end

function LO.PerformSelectedCodex()
    local id = LO.selectedAntiquityId
    if not id or not ADM or not ANTIQUITY_JOURNAL_KEYBOARD then
        return
    end
    local data = ADM:GetAntiquityData(id)
    if not data or not data.GetAntiquityCategoryData then
        return
    end
    local okCat, categoryData = pcall(function()
        return data:GetAntiquityCategoryData()
    end)
    if not okCat or not categoryData or not categoryData.GetId then
        return
    end
    local catId = categoryData:GetId()
    local formattedName = ""
    if data.GetFormattedName then
        local okN, n = pcall(function()
            return data:GetFormattedName()
        end)
        if okN and n then
            formattedName = n
        end
    end
    pcall(function()
        if SCENE_MANAGER and not SCENE_MANAGER:IsShowing("antiquityJournalKeyboard") then
            SCENE_MANAGER:Show("antiquityJournalKeyboard")
        end
        ANTIQUITY_JOURNAL_KEYBOARD:ShowCategory(catId, formattedName)
    end)
end

function LO.BuildLeadKeybindStripDescriptor()
    if LO.leadKeybindStripDescriptor then
        return
    end
    -- Visible strip at bottom of screen (same shortcuts as Antiquities journal scryable tiles).
    LO.leadKeybindStripDescriptor = {
        {
            alignment = KEYBIND_STRIP_ALIGN_CENTER,
            name = function()
                return GetString(SI_ANTIQUITY_SCRY)
            end,
            keybind = KEYBIND_SCRY,
            callback = function()
                LO.PerformSelectedScry()
            end,
            visible = function()
                return LO.IsPanelActive() and LO.selectedAntiquityId ~= nil
            end,
            enabled = function()
                return LO.selectedAntiquityId ~= nil and LO.AntiquityCanScry(LO.selectedAntiquityId)
            end,
        },
        {
            alignment = KEYBIND_STRIP_ALIGN_CENTER,
            name = function()
                return GetString(SI_ANTIQUITY_VIEW_IN_CODEX)
            end,
            keybind = KEYBIND_CODEX,
            callback = function()
                LO.PerformSelectedCodex()
            end,
            visible = function()
                return LO.IsPanelActive() and LO.selectedAntiquityId ~= nil
            end,
            enabled = function()
                return LO.selectedAntiquityId ~= nil
            end,
        },
        {
            alignment = KEYBIND_STRIP_ALIGN_CENTER,
            name = function()
                return GetString(SI_DIALOG_CLOSE)
            end,
            keybind = "UI_SHORTCUT_NEGATIVE",
            callback = function()
                LO.ToggleWindow()
            end,
            visible = function()
                return LO.IsPanelActive()
            end,
        },
    }
end

function LO.InstallLeadKeybindStrip()
    LO.BuildLeadKeybindStripDescriptor()
    if LO.leadKeybindStripActive or not KEYBIND_STRIP or not LO.leadKeybindStripDescriptor then
        return
    end
    if KEYBIND_STRIP.PushKeybindGroupState then
        LO.leadKeybindStripState = KEYBIND_STRIP:PushKeybindGroupState()
    end
    local ok = pcall(function()
        if LO.leadKeybindStripState then
            KEYBIND_STRIP:AddKeybindButtonGroup(LO.leadKeybindStripDescriptor, LO.leadKeybindStripState)
        else
            KEYBIND_STRIP:AddKeybindButtonGroup(LO.leadKeybindStripDescriptor)
        end
    end)
    LO.leadKeybindStripActive = ok
    UpdateLeadKeybindStrip()
end

function LO.RemoveLeadKeybindStrip()
    if not LO.leadKeybindStripActive or not KEYBIND_STRIP or not LO.leadKeybindStripDescriptor then
        return
    end
    pcall(function()
        if LO.leadKeybindStripState then
            KEYBIND_STRIP:RemoveKeybindButtonGroup(LO.leadKeybindStripDescriptor, LO.leadKeybindStripState)
        else
            KEYBIND_STRIP:RemoveKeybindButtonGroup(LO.leadKeybindStripDescriptor)
        end
    end)
    if LO.leadKeybindStripState and KEYBIND_STRIP.PopKeybindGroupState then
        pcall(function()
            KEYBIND_STRIP:PopKeybindGroupState(LO.leadKeybindStripState)
        end)
    end
    LO.leadKeybindStripActive = false
    LO.leadKeybindStripState = nil
end

function LO.SetupResultsScrollList()
    if LO.leadScrollInitialized then
        return
    end
    local backdrop = LO.window and LO.window:GetNamedChild("ResultsBackdrop")
    LO.resultsScroll = backdrop and backdrop:GetNamedChild("ScrollList")
    if not LO.resultsScroll or not ZO_ScrollList_AddDataType then
        return
    end
    -- Built-in ZO_SelectableLabel rows receive mouse clicks; custom Control wrappers often do not.
    ZO_ScrollList_AddDataType(LO.resultsScroll, LEAD_ROW_DATA_TYPE, "ZO_SelectableLabel", 44, LO.SetupLeadScrollRow, nil)
    if ZO_ScrollList_EnableHighlight then
        ZO_ScrollList_EnableHighlight(LO.resultsScroll, "ZO_ThinListHighlight", LO.OnLeadRowHighlighted)
    end
    LO.leadScrollInitialized = true
end

function LO.RefreshPanelLeadList()
    LO.SetupResultsScrollList()
    local scroll = LO.resultsScroll
    if not scroll then
        return
    end

    LO.ClearLeadSelection()

    local scrollData = ZO_ScrollList_GetDataList(scroll)
    ZO_ClearNumericallyIndexedTable(scrollData)

    local list = LO.CollectFilteredActiveLeads()
    if #list == 0 then
        table.insert(scrollData, ZO_ScrollList_CreateDataEntry(LEAD_ROW_DATA_TYPE, {
            text = "No active leads match the current filters. Open Journal → Antiquities → Scryable once if this stays empty.",
        }))
    else
        for i = 1, #list do
            local antiquityData = list[i]
            local quality = (antiquityData.GetQuality and antiquityData:GetQuality()) or 0
            local rawName = (antiquityData.GetName and antiquityData:GetName()) or "?"
            local qualityColor = GetAntiquityQualityColor(quality)
            local name = qualityColor:Colorize(StripGenderSuffix(rawName))
            local line = string.format("• %s — %s", name, LO.FormatLeadLineDetail(antiquityData))
            local id = (antiquityData.GetId and antiquityData:GetId()) or antiquityData.antiquityId
            table.insert(scrollData, ZO_ScrollList_CreateDataEntry(LEAD_ROW_DATA_TYPE, { text = line, antiquityId = id }))
        end
    end

    ZO_ScrollList_Commit(scroll)
    if ZO_ScrollList_ResetToTop then
        ZO_ScrollList_ResetToTop(scroll)
    end
    UpdateLeadKeybindStrip()
end

function LO.FormatLeadLineDetail(antiquityData)
    local parts = {}
    local zoneId = GetLeadObjectZoneId(antiquityData)
    local zoneName = (zoneId and zoneId ~= 0) and GetZoneNameById(zoneId) or nil
    if zoneName and zoneName ~= "" then
        table.insert(parts, zoneName)
    end

    if antiquityData.HasLead and antiquityData:HasLead() then
        local timeRemaining = SafeGetLeadExpiryDisplayText(antiquityData)
        if timeRemaining and timeRemaining ~= "" then
            table.insert(parts, "Expires: " .. timeRemaining)
        else
            table.insert(parts, "Lead active")
        end
    elseif LO.IsGreenAlwaysAvailable(antiquityData) then
        table.insert(parts, "Always available")
    end

    if antiquityData.MeetsScryingSkillRequirements and not antiquityData:MeetsScryingSkillRequirements() then
        table.insert(parts, "Scrying skill too low")
    end

    if antiquityData.IsInProgress and antiquityData:IsInProgress() then
        table.insert(parts, "In progress")
    end

    return table.concat(parts, " · ")
end

function LO.RefreshAntiquityLists()
    LO.ApplySubcategoryFilter()
    LO.SortActiveLeadSections()
    if ADM then
        ADM:RefreshAll()
    end
    zo_callLater(function()
        if SCENE_MANAGER:IsShowing(LO.SCENE_NAME) then
            LO.RefreshPanelLeadList()
        end
    end, 100)
end

function LO.InstallHooks()
    if not LO.SortActiveLeadSections() then
        zo_callLater(LO.InstallHooks, 1000)
        return
    end
    LO.ApplySubcategoryFilter()
    LO.RefreshAntiquityLists()
end

function LO.OnSortSelected(_, _, entry)
    GetSettings().sortMode = entry.sortMode
    LO.RefreshAntiquityLists()
end

function LO.SetupSortDropdown(dropdown)
    if not dropdown then
        return
    end

    dropdown:ClearItems()
    dropdown:SetSortsItems(false)

    local defaultEntry
    for sortMode = LO.SORT_ZONE, LO.SORT_NAME do
        local entry = ZO_ComboBox:CreateItemEntry(LO.SORT_LABELS[sortMode], LO.OnSortSelected)
        entry.sortMode = sortMode
        dropdown:AddItem(entry, ZO_COMBOBOX_SUPPRESS_UPDATE)
        if GetSettings().sortMode == sortMode then
            defaultEntry = entry
        end
    end

    dropdown:UpdateItems()
    if defaultEntry then
        dropdown:SelectItem(defaultEntry)
    end
end

function LO.OnHideScryingToggled(control, button, upInside)
    ZO_CheckButton_OnClicked(control)
    GetSettings().hideAboveScryingSkill = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.OnShowGreenToggled(control, button, upInside)
    ZO_CheckButton_OnClicked(control)
    GetSettings().showGreenAlwaysAvailable = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.OnShowDoneToggled(control, button, upInside)
    ZO_CheckButton_OnClicked(control)
    GetSettings().showCompletedBefore = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.OnCurrentZoneOnlyToggled(control, button, upInside)
    ZO_CheckButton_OnClicked(control)
    GetSettings().currentZoneOnly = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.SetCheckButtonState(button, checked)
    if not button then
        return
    end
    if checked then
        ZO_CheckButton_SetChecked(button)
    else
        ZO_CheckButton_SetUnchecked(button)
    end
end

function LO.SyncWindowControlsFromSettings()
    LO.SetupSortDropdown(LO.sortDropdown)
    LO.SetCheckButtonState(LO.hideScryingToggle, GetSettings().hideAboveScryingSkill)
    LO.SetCheckButtonState(LO.showGreenToggle, GetSettings().showGreenAlwaysAvailable)
    LO.SetCheckButtonState(LO.showDoneToggle, GetSettings().showCompletedBefore)
    LO.SetCheckButtonState(LO.currentZoneOnlyToggle, GetSettings().currentZoneOnly)
end

function LO.BuildSettingsMenu()
    if not LibAddonMenu2 then
        return
    end

    local panelData = {
        type = "panel",
        name = "Leads Organizer",
        displayName = "Leads Organizer",
        author = "ESO Community",
        version = LO.version,
        registerForRefresh = true,
        registerForDefaults = true,
    }

    local options = {
        {
            type = "description",
            text = "Open the panel with |c00FFFF/leadsorg|r or assign a key in Controls → Keybindings → General. Use the Antiquities journal search when you need text search.",
        },
        {
            type = "dropdown",
            name = "Sort active leads by",
            tooltip = "Applies to Active Leads lists in the Scryable antiquities journal and to this panel.",
            choices = { LO.SORT_LABELS[LO.SORT_ZONE], LO.SORT_LABELS[LO.SORT_EXPIRY], LO.SORT_LABELS[LO.SORT_NAME] },
            choicesValues = { LO.SORT_ZONE, LO.SORT_EXPIRY, LO.SORT_NAME },
            getFunc = function() return GetSettings().sortMode end,
            setFunc = function(value)
                GetSettings().sortMode = value
                LO.SyncWindowControlsFromSettings()
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.sortMode,
        },
        {
            type = "checkbox",
            name = "Hide leads this character cannot scry (skill)",
            tooltip = "Hides antiquities that require a higher Scrying skill than this character currently has.",
            getFunc = function() return GetSettings().hideAboveScryingSkill end,
            setFunc = function(value)
                GetSettings().hideAboveScryingSkill = value
                LO.SyncWindowControlsFromSettings()
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.hideAboveScryingSkill,
        },
        {
            type = "checkbox",
            name = "Show green always-available leads",
            tooltip = "Zone starter leads that do not require discovering a lead. Affects All Active Leads only.",
            getFunc = function() return GetSettings().showGreenAlwaysAvailable end,
            setFunc = function(value)
                GetSettings().showGreenAlwaysAvailable = value
                LO.SyncWindowControlsFromSettings()
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.showGreenAlwaysAvailable,
        },
        {
            type = "checkbox",
            name = "Show leads completed before",
            tooltip = "Antiquities you have already recovered at least once.",
            getFunc = function() return GetSettings().showCompletedBefore end,
            setFunc = function(value)
                GetSettings().showCompletedBefore = value
                LO.SyncWindowControlsFromSettings()
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.showCompletedBefore,
        },
        {
            type = "checkbox",
            name = "Show leads in current zone only",
            tooltip = "When enabled, only antiquities tied to a specific zone that matches where you are now are listed. Uses the same player zone as the game UI. Entries with no fixed zone (zone 0) are hidden while this is on. Also updates All Active Leads in the journal.",
            getFunc = function() return GetSettings().currentZoneOnly end,
            setFunc = function(value)
                GetSettings().currentZoneOnly = value
                LO.SyncWindowControlsFromSettings()
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.currentZoneOnly,
        },
    }

    LibAddonMenu2:RegisterAddonPanel("LeadsOrganizerOptions", panelData)
    LibAddonMenu2:RegisterOptionControls("LeadsOrganizerOptions", options)
end

function LO.InitializeWindow()
    LO.window = LeadsOrganizerWindowTopLevel
    if not LO.window then
        return
    end

    local closeBtn = LO.window:GetNamedChild("Close")
    if closeBtn then
        closeBtn:SetHandler("OnClicked", function()
            LO.ToggleWindow()
        end)
    end

    local sortDropdownControl = LO.window:GetNamedChild("SortDropdown")
    LO.sortDropdown = sortDropdownControl and ZO_ComboBox_ObjectFromContainer(sortDropdownControl)
    LO.SetupSortDropdown(LO.sortDropdown)

    local function filterRowToggle(rowName, toggleName)
        local row = LO.window:GetNamedChild(rowName)
        return row and row:GetNamedChild(toggleName)
    end
    LO.hideScryingToggle = filterRowToggle("FilterRowHideScrying", "HideScryingToggle")
    LO.showGreenToggle = filterRowToggle("FilterRowShowGreen", "ShowGreenToggle")
    LO.showDoneToggle = filterRowToggle("FilterRowShowDone", "ShowDoneToggle")
    LO.currentZoneOnlyToggle = filterRowToggle("FilterRowCurrentZone", "CurrentZoneOnlyToggle")

    LO.SetCheckButtonState(LO.hideScryingToggle, GetSettings().hideAboveScryingSkill)
    LO.SetCheckButtonState(LO.showGreenToggle, GetSettings().showGreenAlwaysAvailable)
    LO.SetCheckButtonState(LO.showDoneToggle, GetSettings().showCompletedBefore)
    LO.SetCheckButtonState(LO.currentZoneOnlyToggle, GetSettings().currentZoneOnly)

    if LO.hideScryingToggle then
        LO.hideScryingToggle:SetHandler("OnClicked", LO.OnHideScryingToggled)
    end
    if LO.showGreenToggle then
        LO.showGreenToggle:SetHandler("OnClicked", LO.OnShowGreenToggled)
    end
    if LO.showDoneToggle then
        LO.showDoneToggle:SetHandler("OnClicked", LO.OnShowDoneToggled)
    end
    if LO.currentZoneOnlyToggle then
        LO.currentZoneOnlyToggle:SetHandler("OnClicked", LO.OnCurrentZoneOnlyToggled)
    end

    LO.SetupResultsScrollList()

    local fragment = ZO_FadeSceneFragment:New(LO.window)
    LO.scene = ZO_Scene:New(LO.SCENE_NAME, SCENE_MANAGER)
    LO.scene:AddFragment(fragment)
    if FRAGMENT_GROUP and FRAGMENT_GROUP.MOUSE_DRIVEN_UI_WINDOW then
        LO.scene:AddFragmentGroup(FRAGMENT_GROUP.MOUSE_DRIVEN_UI_WINDOW)
    end
    SCENE_MANAGER:Add(LO.scene)

    LO.scene:RegisterCallback("StateChange", function(oldState, newState)
        if newState == SCENE_SHOWING then
            LO.InstallLeadKeybindStrip()
        elseif newState == SCENE_SHOWN then
            LO.SyncWindowControlsFromSettings()
            LO.RefreshAntiquityLists()
            UpdateLeadKeybindStrip()
        elseif newState == SCENE_HIDING or newState == SCENE_HIDDEN then
            LO.RemoveLeadKeybindStrip()
            LO.ClearLeadSelection()
        end
    end)
end

function LO.ToggleWindow()
    if not LO.scene then
        return
    end
    if SCENE_MANAGER:IsShowing(LO.SCENE_NAME) then
        SCENE_MANAGER:Hide(LO.SCENE_NAME)
    else
        SCENE_MANAGER:Show(LO.SCENE_NAME)
    end
end

LeadsOrganizer.ToggleWindow = LO.ToggleWindow

function LO.Initialize()
    ZO_CreateStringId("SI_BINDING_NAME_LEADS_ORGANIZER_TOGGLE", "Toggle Leads Organizer")

    LO.settings = ZO_SavedVars:NewAccountWide("LeadsOrganizer_SavedVariables", 2, nil, DEFAULT_SETTINGS)

    LO.BuildSettingsMenu()
    LO.InstallHooks()
    LO.InitializeWindow()

    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_UPDATED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_LEAD_ACQUIRED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_SKILL_RANK_UPDATE, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_PLAYER_ACTIVATED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)

    SLASH_COMMANDS["/leadsorg"] = function()
        LO.ToggleWindow()
    end

    SLASH_COMMANDS["/leadsorganizer"] = function(arg)
        if arg == "refresh" then
            LO.RefreshAntiquityLists()
            d("Leads Organizer: refreshed.")
        else
            LO.ToggleWindow()
        end
    end
end

local function OnAddOnLoaded(_, addOnName)
    if addOnName ~= LO.name then
        return
    end
    EM:UnregisterForEvent(LO.name, EVENT_ADD_ON_LOADED)
    LO.Initialize()
end

EM:RegisterForEvent(LO.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)

function LeadsOrganizer_Keybind_Toggle()
    if LeadsOrganizer and LeadsOrganizer.ToggleWindow then
        LeadsOrganizer.ToggleWindow()
    end
end
