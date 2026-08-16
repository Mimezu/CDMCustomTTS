local addonName = ...

local addon = CreateFrame("Frame")
local db
local installed = false

local SOUND_ALERT = Enum.CooldownViewerAlertType.Sound
local TTS_PAYLOAD = Enum.CooldownViewerSound.TextToSpeech
local DEFAULT_VOICE_TEXT = DEFAULT or "Default"

-- Match the shared Resonance / PriorityFader visual language, but keep the
-- palette local so this addon has no dependency on either project.
local COLORS = {
	panel = { 0.035, 0.04, 0.065, 0.98 },
	cardAlt = { 0.055, 0.06, 0.09, 0.96 },
	border = { 0.30, 0.22, 0.48, 0.85 },
	accent = { 0.61, 0.46, 1.0, 1 },
	muted = { 0.62, 0.64, 0.72, 1 },
}

local function ApplyBackdrop(frame, color, border)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(unpack(color or COLORS.panel))
	frame:SetBackdropBorderColor(unpack(border or COLORS.border))
end

local function StyleAddonButton(button)
	ApplyBackdrop(button, COLORS.cardAlt, COLORS.border)
	if not button:GetFontString() then
		local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		label:SetPoint("CENTER")
		button:SetFontString(label)
	end
	button:SetNormalFontObject(GameFontNormalSmall)
	button:SetHighlightFontObject(GameFontNormalSmall)
	button:SetDisabledFontObject(GameFontDisableSmall)
	button:GetFontString():SetTextColor(unpack(COLORS.accent))
	button:SetScript("OnEnter", function(self)
		self:SetBackdropColor(0.12, 0.12, 0.18, 1)
	end)
	button:SetScript("OnLeave", function(self)
		self:SetBackdropColor(unpack(COLORS.cardAlt))
	end)
end

local function StripDropdownArtwork(dropdown)
	-- WowStyle1 provides the menu behavior we want, so retain the template and
	-- remove only its Blizzard artwork before placing it over our own backdrop.
	if dropdown.NineSlice then
		dropdown.NineSlice:SetAlpha(0)
	end
	if dropdown.Arrow then
		dropdown.Arrow:SetAlpha(0)
	end
	for _, region in ipairs({ dropdown:GetRegions() }) do
		if region:IsObjectType("Texture") then
			region:SetAlpha(0)
		end
	end
end

local function Trim(text)
	return strtrim(text or "")
end

local function RuleKey(cooldownID, eventType)
	return tostring(cooldownID) .. ":" .. tostring(eventType)
end

local function GetRule(cooldownID, eventType)
	return db and db.rules[RuleKey(cooldownID, eventType)]
end

local function IsTextToSpeechAlert(alert)
	return alert
		and CooldownViewerAlert_GetType(alert) == SOUND_ALERT
		and CooldownViewerAlert_GetPayload(alert) == TTS_PAYLOAD
end

local function Speak(rule)
	if not (rule and rule.text and C_VoiceChat and C_VoiceChat.SpeakText) then
		return false
	end

	local volume = 100
	if C_TTSSettings and C_TTSSettings.GetSpeechVolume then
		volume = C_TTSSettings.GetSpeechVolume()
	end

	-- Retail 12.x: voiceID, text, rate, volume, allowOverlappedSpeech.
	pcall(C_VoiceChat.SpeakText, rule.voiceID or 0, rule.text, 0, volume, true)
	return true
end

local function GetVoiceOptions()
	local voices = { { voiceID = 0, name = DEFAULT_VOICE_TEXT } }
	if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then
		return voices
	end

	local ok, installedVoices = pcall(C_VoiceChat.GetTtsVoices)
	if ok and installedVoices then
		for _, voice in ipairs(installedVoices) do
			if voice.voiceID and voice.voiceID ~= 0 and voice.name then
				voices[#voices + 1] = voice
			end
		end
	end
	return voices
end

local function VoiceName(voiceID)
	for _, voice in ipairs(GetVoiceOptions()) do
		if voice.voiceID == voiceID then
			return voice.name
		end
	end
	return DEFAULT_VOICE_TEXT
end

local function GetEditorRule(editor)
	local alert = editor.workingCopyOfAlert
	if not (editor:GetCooldownID() and IsTextToSpeechAlert(alert)) then
		return nil
	end
	return GetRule(editor:GetCooldownID(), CooldownViewerAlert_GetEvent(alert))
end

local function EditorAlertState(editor)
	local alert = editor.workingCopyOfAlert
	if not alert then
		return ""
	end
	return table.concat({
		tostring(editor:GetCooldownID() or ""),
		tostring(CooldownViewerAlert_GetType(alert) or ""),
		tostring(CooldownViewerAlert_GetEvent(alert) or ""),
		tostring(CooldownViewerAlert_GetPayload(alert) or ""),
	}, ":")
end

local function RefreshEditor(editor)
	local pane = editor.CustomTTSPane
	if not pane then
		return
	end

	local show = IsTextToSpeechAlert(editor.workingCopyOfAlert)
	pane:SetShown(show)
	editor:SetHeight(show and 495 or 385)
	if not show then
		editor._cdmCustomTTSAlertState = EditorAlertState(editor)
		return
	end

	local rule = GetEditorRule(editor)
	pane.text:SetText(rule and rule.text or "")
	pane.voiceID = rule and rule.voiceID or 0
	pane.voiceDropdown:UpdateText()
	editor._cdmCustomTTSAlertState = EditorAlertState(editor)
end

local function CreateEditorExtension(editor)
	if editor.CustomTTSPane then
		return
	end

	local pane = CreateFrame("Frame", nil, editor)
	pane:SetSize(268, 94)
	pane:SetPoint("TOPLEFT", editor.PayloadDropdown, "BOTTOMLEFT", 0, -24)
	pane:Hide()
	editor.CustomTTSPane = pane

	local textLabel = pane:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	textLabel:SetPoint("TOPLEFT", 0, 0)
	textLabel:SetText("Custom spoken text")
	textLabel:SetTextColor(unpack(COLORS.accent))

	local text = CreateFrame("EditBox", nil, pane, "BackdropTemplate")
	text:SetSize(268, 20)
	text:SetPoint("TOPLEFT", textLabel, "BOTTOMLEFT", 0, -5)
	text:SetAutoFocus(false)
	text:SetMaxLetters(120)
	text:SetFontObject("GameFontHighlight")
	text:SetTextInsets(7, 7, 0, 0)
	ApplyBackdrop(text, COLORS.panel, COLORS.border)
	text:SetScript("OnEscapePressed", text.ClearFocus)
	pane.text = text

	local voiceLabel = pane:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	voiceLabel:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
	voiceLabel:SetText("Voice")
	voiceLabel:SetTextColor(unpack(COLORS.accent))

	local voiceSkin = CreateFrame("Frame", nil, pane, "BackdropTemplate")
	voiceSkin:SetSize(184, 25)
	voiceSkin:SetPoint("TOPLEFT", voiceLabel, "BOTTOMLEFT", 0, -4)
	ApplyBackdrop(voiceSkin, COLORS.cardAlt, COLORS.border)

	local voiceDropdown = CreateFrame("DropdownButton", nil, pane, "WowStyle1DropdownTemplate")
	voiceDropdown:SetSize(184, 25)
	voiceDropdown:SetPoint("TOPLEFT", voiceSkin)
	StripDropdownArtwork(voiceDropdown)
	voiceDropdown:SetSelectionText(function()
		return VoiceName(pane.voiceID or 0)
	end)
	voiceDropdown:SetupMenu(function(_, rootDescription)
		for _, voice in ipairs(GetVoiceOptions()) do
			rootDescription:CreateRadio(voice.name, function(voiceID)
				return (pane.voiceID or 0) == voiceID
			end, function(voiceID)
				pane.voiceID = voiceID
				voiceDropdown:UpdateText()
			end, voice.voiceID)
		end
	end)
	local voiceArrow = voiceDropdown:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	voiceArrow:SetPoint("RIGHT", -8, 0)
	voiceArrow:SetText("v")
	voiceArrow:SetTextColor(unpack(COLORS.accent))
	pane.voiceDropdown = voiceDropdown

	local preview = CreateFrame("Button", nil, pane, "BackdropTemplate")
	preview:SetSize(76, 22)
	preview:SetPoint("LEFT", voiceDropdown, "RIGHT", 8, 0)
	StyleAddonButton(preview)
	preview:SetText("Preview")
	preview:SetScript("OnClick", function()
		Speak({ text = Trim(text:GetText()) ~= "" and Trim(text:GetText()) or "Text to speech preview", voiceID = pane.voiceID or 0 })
	end)
end

local function SaveEditorRule(editor)
	local alert = editor.workingCopyOfAlert
	if not editor:GetCooldownID() then
		return
	end

	local key = RuleKey(editor:GetCooldownID(), CooldownViewerAlert_GetEvent(alert))
	if IsTextToSpeechAlert(alert) then
		local text = Trim(editor.CustomTTSPane.text:GetText())
		if text ~= "" then
			db.rules[key] = { text = text, voiceID = editor.CustomTTSPane.voiceID or 0 }
			return
		end
	end
	db.rules[key] = nil
end

local function HookSaveButton(editor)
	if editor._cdmCustomTTSSaveHooked then
		return
	end
	editor._cdmCustomTTSSaveHooked = true

	-- Save before Blizzard applies the working alert and refreshes its item pool.
	-- HookScript runs after that refresh on some client builds, which is too late.
	local blizzardOnClick = editor:GetAddButton():GetScript("OnClick")
	editor:GetAddButton():SetScript("OnClick", function(button, ...)
		SaveEditorRule(editor)
		return blizzardOnClick(button, ...)
	end)
end

local function Install()
	if installed or not (CooldownViewerSettingsEditAlertMixin and CooldownViewerAlert_PlayAlert) then
		return
	end
	installed = true

	-- Never replace a Blizzard Cooldown Viewer function. Its combat update path
	-- touches secret values, and an addon replacement taints that path. A secure
	-- post-hook lets Blizzard finish its state transition first; we then replace
	-- only the audible phrase for configured TTS alerts.
	hooksecurefunc("CooldownViewerAlert_PlayAlert", function(cooldownItem, _, alert)
		if not IsTextToSpeechAlert(alert) then
			return
		end

		local rule = GetRule(cooldownItem:GetCooldownID(), CooldownViewerAlert_GetEvent(alert))
		if rule and rule.text and C_VoiceChat and C_VoiceChat.StopSpeakingText then
			C_VoiceChat.StopSpeakingText()
		end
		Speak(rule)
	end)

	hooksecurefunc(CooldownViewerSettingsEditAlertMixin, "DisplayForAlert", function(editor)
		CreateEditorExtension(editor)
		HookSaveButton(editor)
		RefreshEditor(editor)
	end)
	hooksecurefunc(CooldownViewerSettingsEditAlertMixin, "SetupDropdowns", function(editor)
		CreateEditorExtension(editor)
		RefreshEditor(editor)
	end)

	-- The editor is a Blizzard frame created from XML.  These two frame hooks are
	-- a fallback for client builds that update the working alert without calling
	-- the global setter helpers used above.
	if CooldownViewerSettingsEditAlert then
		CooldownViewerSettingsEditAlert:HookScript("OnShow", function(editor)
			CreateEditorExtension(editor)
			HookSaveButton(editor)
			RefreshEditor(editor)
		end)
		CooldownViewerSettingsEditAlert:HookScript("OnUpdate", function(editor)
			local state = EditorAlertState(editor)
			if state ~= editor._cdmCustomTTSAlertState then
				CreateEditorExtension(editor)
				RefreshEditor(editor)
			end
		end)
	end

	-- Update the extension immediately when the native event or sound type changes.
	hooksecurefunc("CooldownViewerAlert_SetEvent", function(alert)
		local editor = CooldownViewerSettingsEditAlert
		if editor and editor:IsShown() and editor.workingCopyOfAlert == alert then
			RefreshEditor(editor)
		end
	end)
	hooksecurefunc("CooldownViewerAlert_SetPayload", function(alert)
		local editor = CooldownViewerSettingsEditAlert
		if editor and editor:IsShown() and editor.workingCopyOfAlert == alert then
			RefreshEditor(editor)
		end
	end)
end

addon:RegisterEvent("ADDON_LOADED")
addon:SetScript("OnEvent", function(_, _, loadedName)
	if loadedName == addonName then
		CDMCustomTTSDB = CDMCustomTTSDB or {}
		CDMCustomTTSDB.rules = CDMCustomTTSDB.rules or {}
		db = CDMCustomTTSDB
		if C_AddOns.IsAddOnLoaded("Blizzard_CooldownViewer") then
			Install()
		end
	elseif loadedName == "Blizzard_CooldownViewer" then
		Install()
	end
end)
