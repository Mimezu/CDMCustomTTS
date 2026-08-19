local addonName = ...

local addon = CreateFrame("Frame")
local db
local installed = false
local lastSpokenAt = {}
local pendingSpeech = {}
local pendingSpeechKeys = {}
local speechFlushScheduled = false
local suppressionGeneration = 0
local suppressionActive = false
local delayedSpeechTimers = {}

local SOUND_ALERT = Enum.CooldownViewerAlertType.Sound
local TTS_PAYLOAD = Enum.CooldownViewerSound.TextToSpeech
local AURA_APPLIED_EVENT = Enum.CooldownViewerAlertEventType.OnAuraApplied
local AURA_REMOVED_EVENT = Enum.CooldownViewerAlertEventType.OnAuraRemoved
local DEFAULT_VOICE_TEXT = DEFAULT or "Default"
local REPEAT_GUARD_SECONDS = 0.75
local TTS_STOP_SETTLE_SECONDS = 0.075
local MAX_DELAY_SECONDS = 300

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

local function IsAuraEvent(eventType)
	return eventType == AURA_APPLIED_EVENT or eventType == AURA_REMOVED_EVENT
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

local function FlushPendingSpeech()
	speechFlushScheduled = false
	if suppressionActive then
		return
	end

	local speech = pendingSpeech
	pendingSpeech = {}
	pendingSpeechKeys = {}

	for _, rule in ipairs(speech) do
		Speak(rule)
	end
end

local function ScheduleSpeechFlush()
	if suppressionActive or speechFlushScheduled then
		return
	end
	speechFlushScheduled = true
	C_Timer.After(0, FlushPendingSpeech)
end

local function QueueCustomSpeech(key, rule)
	if pendingSpeechKeys[key] then
		return
	end

	pendingSpeechKeys[key] = true
	pendingSpeech[#pendingSpeech + 1] = {
		text = rule.text,
		voiceID = rule.voiceID or 0,
	}
	ScheduleSpeechFlush()
end

local function StopNativeSpeech()
	if C_VoiceChat and C_VoiceChat.StopSpeakingText then
		C_VoiceChat.StopSpeakingText()
	end
end

local function BeginNativeSpeechSuppression()
	-- StopSpeakingText and SpeakText are handled asynchronously by the Windows
	-- speech engine. Speaking the replacement in the same callback can race the
	-- stop request, allowing the native full-name utterance through. Two bounded
	-- stop passes create a stable handoff before any queued custom line is spoken.
	suppressionGeneration = suppressionGeneration + 1
	local generation = suppressionGeneration
	suppressionActive = true

	C_Timer.After(0, function()
		if generation ~= suppressionGeneration then
			return
		end
		StopNativeSpeech()
		C_Timer.After(TTS_STOP_SETTLE_SECONDS, function()
			if generation ~= suppressionGeneration then
				return
			end
			StopNativeSpeech()
			C_Timer.After(TTS_STOP_SETTLE_SECONDS, function()
				if generation ~= suppressionGeneration then
					return
				end
				suppressionActive = false
				FlushPendingSpeech()
			end)
		end)
	end)
end

local function CancelDelayedSpeech(key)
	local timer = delayedSpeechTimers[key]
	if timer then
		timer:Cancel()
		delayedSpeechTimers[key] = nil
	end
end

local function CancelAllDelayedSpeech()
	for _, timer in pairs(delayedSpeechTimers) do
		timer:Cancel()
	end
	delayedSpeechTimers = {}
end

local function ResetSpeechState()
	CancelAllDelayedSpeech()
	suppressionGeneration = suppressionGeneration + 1
	suppressionActive = false
	pendingSpeech = {}
	pendingSpeechKeys = {}
	speechFlushScheduled = false
	lastSpokenAt = {}
end

local function QueueSpeechReplacement(key, rule)
	local now = GetTime()
	local previous = lastSpokenAt[key]
	lastSpokenAt[key] = now

	-- Always suppress the native full-name utterance. A duplicate native event
	-- should not replace or restart an already scheduled custom warning.
	BeginNativeSpeechSuppression()
	if previous and now - previous < REPEAT_GUARD_SECONDS then
		return
	end

	CancelDelayedSpeech(key)
	local speech = {
		text = rule.text,
		voiceID = rule.voiceID or 0,
	}
	local delaySeconds = math.min(math.max(tonumber(rule.delaySeconds) or 0, 0), MAX_DELAY_SECONDS)
	if delaySeconds > 0 then
		delayedSpeechTimers[key] = C_Timer.NewTimer(delaySeconds, function()
			delayedSpeechTimers[key] = nil
			QueueCustomSpeech(key, speech)
		end)
	else
		QueueCustomSpeech(key, speech)
	end
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

	local alert = editor.workingCopyOfAlert
	local show = IsTextToSpeechAlert(alert)
	local auraEvent = show and IsAuraEvent(CooldownViewerAlert_GetEvent(alert))
	pane:SetShown(show)
	editor:SetHeight(show and (auraEvent and 535 or 495) or 385)
	if not show then
		editor._cdmCustomTTSAlertState = EditorAlertState(editor)
		return
	end

	local rule = GetEditorRule(editor)
	pane.text:SetText(rule and rule.text or "")
	pane.voiceID = rule and rule.voiceID or 0
	pane.voiceDropdown:UpdateText()
	pane.delayLabel:SetShown(auraEvent)
	pane.delay:SetShown(auraEvent)
	pane.delaySuffix:SetShown(auraEvent)
	pane.delay:SetText(auraEvent and tostring(rule and rule.delaySeconds or 0) or "0")
	editor._cdmCustomTTSAlertState = EditorAlertState(editor)
end

local function CreateEditorExtension(editor)
	if editor.CustomTTSPane then
		return
	end

	local pane = CreateFrame("Frame", nil, editor)
	pane:SetSize(268, 134)
	pane:SetPoint("TOPLEFT", editor.PayloadDropdown, "BOTTOMLEFT", 0, -24)
	pane:Hide()
	editor.CustomTTSPane = pane

	local textLabel = pane:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	textLabel:SetPoint("TOPLEFT", 0, 0)
	textLabel:SetText("Custom spoken text")
	textLabel:SetTextColor(unpack(COLORS.accent))

	local creator = pane:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	creator:SetPoint("TOPRIGHT", 0, -2)
	creator:SetText("by Mimezu")
	creator:SetTextColor(unpack(COLORS.muted))

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

	local delayLabel = pane:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	delayLabel:SetPoint("TOPLEFT", voiceDropdown, "BOTTOMLEFT", 0, -14)
	delayLabel:SetText("Delay TTS")
	delayLabel:SetTextColor(unpack(COLORS.accent))
	pane.delayLabel = delayLabel

	local delay = CreateFrame("EditBox", nil, pane, "BackdropTemplate")
	delay:SetSize(42, 20)
	delay:SetPoint("LEFT", delayLabel, "RIGHT", 8, 0)
	delay:SetAutoFocus(false)
	delay:SetNumeric(true)
	delay:SetMaxLetters(3)
	delay:SetFontObject("GameFontHighlight")
	delay:SetJustifyH("CENTER")
	delay:SetTextInsets(4, 4, 0, 0)
	delay:SetText("0")
	ApplyBackdrop(delay, COLORS.panel, COLORS.border)
	delay:SetScript("OnEnterPressed", delay.ClearFocus)
	delay:SetScript("OnEscapePressed", delay.ClearFocus)
	pane.delay = delay

	local delaySuffix = pane:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	delaySuffix:SetPoint("LEFT", delay, "RIGHT", 7, 0)
	delaySuffix:SetText("seconds after aura event")
	delaySuffix:SetTextColor(unpack(COLORS.muted))
	pane.delaySuffix = delaySuffix
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
			local delaySeconds
			if IsAuraEvent(CooldownViewerAlert_GetEvent(alert)) then
				delaySeconds = math.min(tonumber(editor.CustomTTSPane.delay:GetText()) or 0, MAX_DELAY_SECONDS)
				if delaySeconds <= 0 then
					delaySeconds = nil
				end
			end
			db.rules[key] = {
				text = text,
				voiceID = editor.CustomTTSPane.voiceID or 0,
				delaySeconds = delaySeconds,
			}
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

	-- Do not replace Blizzard's handler or call AddCurrentAlert from addon code.
	-- That would taint the native layout and cooldown item tables before combat.
	-- A script hook runs only after Blizzard has applied and refreshed the alert;
	-- the working copy is still available, so only our SavedVariables are touched.
	editor:GetAddButton():HookScript("OnClick", function()
		SaveEditorRule(editor)
	end)
end

local function Install()
	if installed or not (CooldownViewerSettingsEditAlertMixin and CooldownViewerAlert_PlayAlert) then
		return
	end
	installed = true

	-- Never replace a Blizzard Cooldown Viewer function. Its combat update path
	-- touches secret values, and an addon replacement taints that path. The secure
	-- post-hook only captures non-secret alert identity; voice work is deferred
	-- until the native combat update stack has unwound.
	hooksecurefunc("CooldownViewerAlert_PlayAlert", function(cooldownItem, _, alert)
		if not IsTextToSpeechAlert(alert) then
			return
		end

		local cooldownID = cooldownItem:GetCooldownID()
		local eventType = CooldownViewerAlert_GetEvent(alert)
		if eventType == AURA_REMOVED_EVENT then
			CancelDelayedSpeech(RuleKey(cooldownID, AURA_APPLIED_EVENT))
		end

		local key = RuleKey(cooldownID, eventType)
		local rule = db and db.rules[key]
		if not (rule and rule.text) then
			return
		end

		QueueSpeechReplacement(key, rule)
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
addon:RegisterEvent("PLAYER_DEAD")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:SetScript("OnEvent", function(_, event, loadedName)
	if event == "PLAYER_DEAD" or event == "PLAYER_ENTERING_WORLD" then
		ResetSpeechState()
	elseif event == "ADDON_LOADED" and loadedName == addonName then
		CDMCustomTTSDB = CDMCustomTTSDB or {}
		CDMCustomTTSDB.rules = CDMCustomTTSDB.rules or {}
		db = CDMCustomTTSDB
		if C_AddOns.IsAddOnLoaded("Blizzard_CooldownViewer") then
			Install()
		end
	elseif event == "ADDON_LOADED" and loadedName == "Blizzard_CooldownViewer" then
		Install()
	end
end)
