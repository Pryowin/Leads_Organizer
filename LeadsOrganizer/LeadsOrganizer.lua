--[[
    Leads Organizer — filter, sort, and search scrying leads.
    Dedicated panel: /leadsorg or keybind (Controls → Keybindings → General).
]]

LeadsOrganizer = LeadsOrganizer or {}
local LO = LeadsOrganizer

LO.name = "LeadsOrganizer"
LO.version = "1.1.0"
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
}

local NO_EXPIRY_SORT_VALUE = 999999999
local SEARCH_DEBOUNCE_MS = 250
local MAX_RESULT_LINES = 45
local searchDebounceGeneration = 0

local function StripGenderSuffix(text)
    if not text or text == "" then
        return text
    end
    return text:gsub("%^[a-zA-Z]+$", "")
end

local function GetSettings()
    return LO.settings
end

function LO.IsGreenAlwaysAvailable(antiquityData)
    return not antiquityData:RequiresLead()
end

function LO.HasCompletedBefore(antiquityData)
    return antiquityData:GetNumRecovered() > 0 or antiquityData:HasAchievedAllGoals()
end

function LO.AntiquityPassesFilters(antiquityData)
    local settings = GetSettings()
    if settings.hideAboveScryingSkill and not antiquityData:MeetsScryingSkillRequirements() then
        return false
    end
    if not settings.showGreenAlwaysAvailable and LO.IsGreenAlwaysAvailable(antiquityData) then
        return false
    end
    if not settings.showCompletedBefore and LO.HasCompletedBefore(antiquityData) then
        return false
    end
    return true
end

function LO.FilterAllActiveLeads(antiquityData)
    return LO.AntiquityPassesFilters(antiquityData)
end

local function GetLeadSortTime(antiquityData)
    if not antiquityData:HasLead() then
        return NO_EXPIRY_SORT_VALUE
    end
    local leadTime = antiquityData:GetLeadTimeRemainingS()
    if leadTime == 0 then
        return NO_EXPIRY_SORT_VALUE
    end
    return leadTime
end

function LO.SortByZone(leftAntiquityData, rightAntiquityData)
    local leftZone = GetZoneNameById(leftAntiquityData:GetZoneId()) or ""
    local rightZone = GetZoneNameById(rightAntiquityData:GetZoneId()) or ""
    if leftZone ~= rightZone then
        return leftZone < rightZone
    end
    return leftAntiquityData:CompareNameTo(rightAntiquityData)
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
    return leftAntiquityData:CompareNameTo(rightAntiquityData)
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
        ZO_SCRYABLE_ANTIQUITY_ALL_LEADS_SUBCATEGORY_DATA:SetAntiquityFilterFunction(LO.FilterAllActiveLeads)
    end
end

function LO.RefreshAntiquityLists()
    LO.ApplySubcategoryFilter()
    LO.SortActiveLeadSections()
    if ADM then
        ADM:RefreshAll()
    end
end

function LO.InstallHooks()
    if not LO.SortActiveLeadSections() then
        zo_callLater(LO.InstallHooks, 1000)
        return
    end
    LO.ApplySubcategoryFilter()
    LO.RefreshAntiquityLists()
end

local function FormatAntiquityStatus(antiquityData)
    local parts = {}
    local zoneName = GetZoneNameById(antiquityData:GetZoneId())
    if zoneName and zoneName ~= "" then
        table.insert(parts, zoneName)
    end

    if antiquityData:HasLead() then
        local _, timeRemaining = antiquityData:GetLeadExpirationStatus()
        if timeRemaining and timeRemaining ~= "" then
            table.insert(parts, "Expires: " .. timeRemaining)
        else
            table.insert(parts, "Lead active")
        end
    elseif LO.IsGreenAlwaysAvailable(antiquityData) then
        table.insert(parts, "Always available (green)")
    else
        table.insert(parts, "No lead owned")
    end

    if not antiquityData:MeetsScryingSkillRequirements() then
        table.insert(parts, "Scrying skill too low")
    end

    if LO.HasCompletedBefore(antiquityData) then
        table.insert(parts, "Completed before")
    end

    if antiquityData:IsInProgress() then
        table.insert(parts, "In progress")
    end

    return table.concat(parts, " · ")
end

function LO.UpdateSearchStatusLabel()
    local statusLabel = LO.searchStatusLabel
    if not statusLabel then
        return
    end

    local searchText = ADM:GetSearch() or ""
    if zo_strlen(searchText) < 2 then
        statusLabel:SetHidden(true)
        return
    end

    local results = ADM:GetSearchResults()
    local unownedCount = 0
    for _, antiquityId in ipairs(results) do
        local antiquityData = ADM:GetAntiquityData(antiquityId)
        if antiquityData and not antiquityData:HasLead() then
            unownedCount = unownedCount + 1
        end
    end

    statusLabel:SetText(string.format(
        "Search: %d result(s) — %d without lead on this character",
        #results,
        unownedCount
    ))
    statusLabel:SetHidden(false)
end

function LO.RefreshResultsBody()
    local body = LO.resultsBodyLabel
    if not body then
        return
    end

    local searchText = ADM:GetSearch() or ""
    if zo_strlen(searchText) < 2 then
        body:SetText("Type at least 2 characters to search. Results list antiquities you do not currently have a lead for.")
        LO.UpdateSearchStatusLabel()
        return
    end

    local results = ADM:GetSearchResults()
    local lines = {}
    local count = 0
    local totalNoLead = 0

    for _, antiquityId in ipairs(results) do
        local antiquityData = ADM:GetAntiquityData(antiquityId)
        if antiquityData and not antiquityData:HasLead() then
            totalNoLead = totalNoLead + 1
            if count < MAX_RESULT_LINES then
                local qualityColor = GetAntiquityQualityColor(antiquityData:GetQuality())
                local plainName = StripGenderSuffix(antiquityData:GetName())
                local name = qualityColor:Colorize(plainName)
                table.insert(lines, string.format("• %s — %s", name, FormatAntiquityStatus(antiquityData)))
                count = count + 1
            end
        end
    end

    if totalNoLead == 0 then
        body:SetText("No matching antiquities without a lead, or search still loading.")
    else
        local text = table.concat(lines, "\n")
        if totalNoLead > MAX_RESULT_LINES then
            text = text .. string.format("\n… and %d more without a lead (truncated)", totalNoLead - MAX_RESULT_LINES)
        end
        body:SetText(text)
    end

    LO.UpdateSearchStatusLabel()
end

function LO.OnSearchResultsUpdated()
    LO.lastAnnouncedSearch = nil
    LO.RefreshResultsBody()
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
end

function LO.CommitSearchFromEdit()
    if not LO.searchEditBox or not ADM then
        return
    end
    local text = LO.searchEditBox:GetText() or ""
    ADM:SetSearch(text)
    LO.lastAnnouncedSearch = nil
    LO.RefreshResultsBody()
end

function LO.OnSearchEditTextChanged()
    searchDebounceGeneration = searchDebounceGeneration + 1
    local generation = searchDebounceGeneration
    zo_callLater(function()
        if generation ~= searchDebounceGeneration then
            return
        end
        LO.CommitSearchFromEdit()
    end, SEARCH_DEBOUNCE_MS)
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
            text = "Open the panel with |c00FFFF/leadsorg|r or assign a key in Controls → Keybindings → General.",
        },
        {
            type = "dropdown",
            name = "Sort active leads by",
            tooltip = "Applies to Active Leads lists in the Scryable antiquities journal.",
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

    LO.hideScryingToggle = LO.window:GetNamedChild("HideScryingToggle")
    LO.showGreenToggle = LO.window:GetNamedChild("ShowGreenToggle")
    LO.showDoneToggle = LO.window:GetNamedChild("ShowDoneToggle")

    LO.SetCheckButtonState(LO.hideScryingToggle, GetSettings().hideAboveScryingSkill)
    LO.SetCheckButtonState(LO.showGreenToggle, GetSettings().showGreenAlwaysAvailable)
    LO.SetCheckButtonState(LO.showDoneToggle, GetSettings().showCompletedBefore)

    if LO.hideScryingToggle then
        LO.hideScryingToggle:SetHandler("OnClicked", LO.OnHideScryingToggled)
    end
    if LO.showGreenToggle then
        LO.showGreenToggle:SetHandler("OnClicked", LO.OnShowGreenToggled)
    end
    if LO.showDoneToggle then
        LO.showDoneToggle:SetHandler("OnClicked", LO.OnShowDoneToggled)
    end

    local searchBackdrop = LO.window:GetNamedChild("SearchBackdrop")
    LO.searchEditBox = searchBackdrop and searchBackdrop:GetNamedChild("Box")
    if LO.searchEditBox then
        LO.searchEditBox:SetHandler("OnTextChanged", function()
            LO.OnSearchEditTextChanged()
        end)
    end

    LO.searchStatusLabel = LO.window:GetNamedChild("SearchStatus")
    local resultsBackdrop = LO.window:GetNamedChild("ResultsBackdrop")
    LO.resultsBodyLabel = resultsBackdrop and resultsBackdrop:GetNamedChild("Body")

    local fragment = ZO_FadeSceneFragment:New(LO.window)
    LO.scene = ZO_Scene:New(LO.SCENE_NAME, SCENE_MANAGER)
    LO.scene:AddFragment(fragment)
    SCENE_MANAGER:AddScene(LO.scene)

    LO.scene:RegisterCallback("StateChange", function(oldState, newState)
        if newState == SCENE_SHOWN then
            LO.SyncWindowControlsFromSettings()
            if LO.searchEditBox then
                LO.searchEditBox:SetText(ADM:GetSearch() or "")
            end
            LO.RefreshAntiquityLists()
            LO.RefreshResultsBody()
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

    ADM:RegisterCallback("UpdateSearchResults", LO.OnSearchResultsUpdated)

    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_UPDATED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_LEAD_ACQUIRED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_SKILL_RANK_UPDATE, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
        if SCENE_MANAGER:IsShowing(LO.SCENE_NAME) then
            zo_callLater(LO.RefreshResultsBody, 100)
        end
    end)

    SLASH_COMMANDS["/leadsorg"] = function()
        LO.ToggleWindow()
    end

    SLASH_COMMANDS["/leadsorganizer"] = function(arg)
        if arg == "refresh" then
            LO.RefreshAntiquityLists()
            if SCENE_MANAGER:IsShowing(LO.SCENE_NAME) then
                LO.RefreshResultsBody()
            end
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
