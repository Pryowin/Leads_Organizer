--[[
    Leads Organizer — filter, sort, and search scrying leads.
]]

LeadsOrganizer = LeadsOrganizer or {}
local LO = LeadsOrganizer

LO.name = "LeadsOrganizer"
LO.version = "1.0.0"

local EM = EVENT_MANAGER
local WM = WINDOW_MANAGER
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
}

local NO_EXPIRY_SORT_VALUE = 999999999

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
    -- Zone starter leads that do not require discovering a lead first.
    return not antiquityData:RequiresLead()
end

function LO.HasCompletedBefore(antiquityData)
    return antiquityData:GetNumRecovered() > 0 or antiquityData:HasAchievedAllGoals()
end

function LO.AntiquityPassesFilters(antiquityData)
    local settings = GetSettings()
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

    if LO.HasCompletedBefore(antiquityData) then
        table.insert(parts, "Completed before")
    end

    if antiquityData:IsInProgress() then
        table.insert(parts, "In progress")
    end

    return table.concat(parts, " · ")
end

function LO.UpdateSearchStatus()
    if not LO.searchStatusLabel then
        return
    end

    local searchText = ADM:GetSearch() or ""
    if zo_strlen(searchText) < 2 then
        LO.searchStatusLabel:SetHidden(true)
        return
    end

    local results = ADM:GetSearchResults()
    local ownedCount = 0
    local unownedCount = 0
    for _, antiquityId in ipairs(results) do
        local antiquityData = ADM:GetAntiquityData(antiquityId)
        if antiquityData and antiquityData:HasLead() then
            ownedCount = ownedCount + 1
        else
            unownedCount = unownedCount + 1
        end
    end

    LO.searchStatusLabel:SetText(string.format(
        "Search: %d result(s) — %d without lead",
        #results,
        unownedCount
    ))
    LO.searchStatusLabel:SetHidden(false)
end

function LO.OnSearchResultsUpdated()
    LO.UpdateSearchStatus()

    local searchText = ADM:GetSearch() or ""
    if zo_strlen(searchText) < 2 then
        LO.lastAnnouncedSearch = nil
        return
    end

    if LO.lastAnnouncedSearch == searchText then
        return
    end
    LO.lastAnnouncedSearch = searchText

    local results = ADM:GetSearchResults()
    if #results == 0 then
        return
    end

    local announced = 0
    for _, antiquityId in ipairs(results) do
        local antiquityData = ADM:GetAntiquityData(antiquityId)
        if antiquityData and not antiquityData:HasLead() then
            local qualityColor = GetAntiquityQualityColor(antiquityData:GetQuality())
            local name = qualityColor:Colorize(StripGenderSuffix(antiquityData:GetName()))
            d(string.format("|cB8B8D8Leads Organizer|r — %s — %s", name, FormatAntiquityStatus(antiquityData)))
            announced = announced + 1
            if announced >= 12 then
                d("|cB8B8D8Leads Organizer|r — (additional matches omitted)")
                break
            end
        end
    end
end

function LO.OnSortSelected(_, _, entry)
    GetSettings().sortMode = entry.sortMode
    LO.RefreshAntiquityLists()
end

function LO.SetupSortDropdown(dropdown)
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

function LO.OnShowGreenToggled(control)
    GetSettings().showGreenAlwaysAvailable = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.OnShowDoneToggled(control)
    GetSettings().showCompletedBefore = ZO_CheckButton_IsChecked(control)
    LO.RefreshAntiquityLists()
end

function LO.SetCheckButtonState(button, checked)
    if checked then
        ZO_CheckButton_SetChecked(button)
    else
        ZO_CheckButton_SetUnchecked(button)
    end
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
            type = "dropdown",
            name = "Sort active leads by",
            tooltip = "Applies to Active Leads lists in the Scryable antiquities journal.",
            choices = { LO.SORT_LABELS[LO.SORT_ZONE], LO.SORT_LABELS[LO.SORT_EXPIRY], LO.SORT_LABELS[LO.SORT_NAME] },
            choicesValues = { LO.SORT_ZONE, LO.SORT_EXPIRY, LO.SORT_NAME },
            getFunc = function() return GetSettings().sortMode end,
            setFunc = function(value)
                GetSettings().sortMode = value
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.sortMode,
        },
        {
            type = "checkbox",
            name = "Show green always-available leads",
            tooltip = "Zone starter leads that do not require discovering a lead. Affects All Active Leads only.",
            getFunc = function() return GetSettings().showGreenAlwaysAvailable end,
            setFunc = function(value)
                GetSettings().showGreenAlwaysAvailable = value
                if LO.showGreenToggle then
                    LO.SetCheckButtonState(LO.showGreenToggle, value)
                end
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
                if LO.showDoneToggle then
                    LO.SetCheckButtonState(LO.showDoneToggle, value)
                end
                LO.RefreshAntiquityLists()
            end,
            default = DEFAULT_SETTINGS.showCompletedBefore,
        },
    }

    LibAddonMenu2:RegisterAddonPanel("LeadsOrganizerOptions", panelData)
    LibAddonMenu2:RegisterOptionControls("LeadsOrganizerOptions", options)
end

function LO.CreateJournalBar()
    if LO.barControl or not ZO_AntiquityJournal_Keyboard_TopLevelContents then
        return
    end

    local parent = ZO_AntiquityJournal_Keyboard_TopLevelContents
    local searchControl = parent:GetNamedChild("Search")
    if not searchControl then
        zo_callLater(LO.CreateJournalBar, 500)
        return
    end

    local bar = CreateControlFromVirtual("LeadsOrganizerBarInstance", parent, "LeadsOrganizerBar")
    bar:SetAnchor(BOTTOMLEFT, searchControl, TOPLEFT, 0, -8)
    bar:SetAnchor(BOTTOMRIGHT, searchControl, TOPRIGHT, 0, -8)
    LO.barControl = bar

    local sortLabel = bar:GetNamedChild("SortLabel")
    sortLabel:SetText("Sort:")

    local sortDropdown = ZO_ComboBox_ObjectFromContainer(bar:GetNamedChild("SortDropdown"))
    LO.sortDropdown = sortDropdown
    LO.SetupSortDropdown(sortDropdown)

    local showGreenToggle = bar:GetNamedChild("ShowGreenToggle")
    LO.showGreenToggle = showGreenToggle
    LO.SetCheckButtonState(showGreenToggle, GetSettings().showGreenAlwaysAvailable)
    showGreenToggle:SetHandler("OnClicked", LO.OnShowGreenToggled)
    local showGreenLabel = bar:GetNamedChild("ShowGreenLabel")
    showGreenLabel:SetText("Green leads")

    local showDoneToggle = bar:GetNamedChild("ShowDoneToggle")
    LO.showDoneToggle = showDoneToggle
    LO.SetCheckButtonState(showDoneToggle, GetSettings().showCompletedBefore)
    showDoneToggle:SetHandler("OnClicked", LO.OnShowDoneToggled)
    local showDoneLabel = bar:GetNamedChild("ShowDoneLabel")
    showDoneLabel:SetText("Done before")

    LO.searchStatusLabel = bar:GetNamedChild("SearchStatus")
end

function LO.HookJournalSearch()
  if not ANTIQUITY_JOURNAL_KEYBOARD or LO.searchHooked then
        return
    end

    local journal = ANTIQUITY_JOURNAL_KEYBOARD
    if journal.contentSearchEditBox then
        local originalHandler = journal.contentSearchEditBox:GetHandler("OnTextChanged")
        journal.contentSearchEditBox:SetHandler("OnTextChanged", function(control)
            if originalHandler then
                originalHandler(control)
            end
            zo_callLater(LO.UpdateSearchStatus, 50)
        end)
    end

    LO.searchHooked = true
end

function LO.OnAntiquityJournalShown()
    LO.CreateJournalBar()
    LO.UpdateSearchStatus()
end

function LO.RegisterJournalSceneCallback()
    local scene = SCENE_MANAGER:GetScene("antiquityJournalKeyboard")
    if not scene then
        zo_callLater(LO.RegisterJournalSceneCallback, 500)
        return
    end
    scene:RegisterCallback("StateChange", function(_, newState)
        if newState == SCENE_SHOWING then
            LO.OnAntiquityJournalShown()
        end
    end)
end

function LO.Initialize()
    LO.settings = ZO_SavedVars:NewAccountWide("LeadsOrganizer_SavedVariables", 1, nil, DEFAULT_SETTINGS)

    LO.BuildSettingsMenu()
    LO.InstallHooks()
    LO.RegisterJournalSceneCallback()

    ADM:RegisterCallback("UpdateSearchResults", LO.OnSearchResultsUpdated)

    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_UPDATED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)
    EM:RegisterForEvent(LO.name, EVENT_ANTIQUITY_LEAD_ACQUIRED, function()
        zo_callLater(LO.RefreshAntiquityLists, 50)
    end)

    zo_callLater(function()
        LO.CreateJournalBar()
        LO.HookJournalSearch()
    end, 1200)

    SLASH_COMMANDS["/leadsorganizer"] = function(arg)
        if arg == "refresh" then
            LO.RefreshAntiquityLists()
            d("Leads Organizer: lists refreshed.")
        else
            d("Leads Organizer — use the bar above Search in Antiquities, or Settings → Add-ons.")
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
