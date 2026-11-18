--!strict
-- GrabPromptView.luau
-- Prompt centre-écran "AGRIPPÉ PAR ..." + barre de progression locale pour le mash ESPACE.
-- La logique de QTE (comptage des appuis, réussite de l'évasion) est côté serveur : cette vue ne
-- fait qu'informer et envoyer l'intention RequestGrabEscape à chaque appui.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local GrabPromptView = {}

local mounted = false

local ESCAPE_ACTION = "MW_GrabEscape"
-- Repli si le serveur n'envoie pas le nombre d'appuis requis.
local DEFAULT_PRESSES_NEEDED = 12
-- Tailles pré-allouées : l'entrée "pop" part d'un cadre un peu plus petit.
local PROMPT_SIZE = UDim2.fromOffset(420, 90)
local PROMPT_POP_START = UDim2.fromOffset(370, 80)

function GrabPromptView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GrabPromptView"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 30
	screenGui.Parent = playerGui

	local Colors = UiTheme.Colors

	local promptFrame = Instance.new("Frame")
	promptFrame.Name = "PromptFrame"
	promptFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	promptFrame.Position = UDim2.new(0.5, 0, 0.4, 0)
	promptFrame.Size = PROMPT_SIZE
	promptFrame.BackgroundColor3 = Colors.Panel
	promptFrame.BackgroundTransparency = 0.1
	promptFrame.BorderSizePixel = 0
	promptFrame.Visible = false
	promptFrame.Parent = screenGui
	UiTheme.Corner(promptFrame, 12)
	local promptStroke = UiTheme.Stroke(promptFrame, Colors.Danger, 2, 0.6)
	UiTheme.Padding(promptFrame, 14, 10)
	UiTheme.BindScale(promptFrame, 480, 360, 0.6, 1.2)

	local promptLabel = UiTheme.Label(promptFrame, Enum.Font.GothamBold, 18, Colors.Danger)
	promptLabel.Name = "PromptLabel"
	promptLabel.Size = UDim2.new(1, 0, 0, 44)
	promptLabel.TextWrapped = true
	promptLabel.TextXAlignment = Enum.TextXAlignment.Center

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 0, 0, 52)
	track.Size = UDim2.new(1, 0, 0, 18)
	track.BackgroundColor3 = Colors.Track
	track.BorderSizePixel = 0
	track.Parent = promptFrame
	UiTheme.Corner(track, 6)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Colors.Accent
	fill.Parent = track
	UiTheme.Corner(fill, 6)

	-- Alerte : contour pulsant, un seul tween en boucle joué seulement pendant l'agrippement.
	local strokePulse = TweenService:Create(
		promptStroke,
		TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0 }
	)

	local isGrabbed = false
	local escapeProgress = 0
	local pressesNeeded = DEFAULT_PRESSES_NEEDED
	local requestGrabEscapeRemote: RemoteEvent? = nil

	task.spawn(function()
		local ok, escapeRemote = pcall(Remotes.Get, "RequestGrabEscape")
		if ok then
			requestGrabEscapeRemote = escapeRemote :: RemoteEvent
		else
			warn("[GrabPromptView] RequestGrabEscape indisponible : " .. tostring(escapeRemote))
		end
	end)

	local function setEscapeProgress(value: number)
		escapeProgress = math.clamp(value, 0, 1)
		-- Remplissage tweené (une allocation par appui, jamais par frame) : ambre -> vert à mesure
		-- qu'on approche de la libération.
		UiTheme.Tween(fill, 0.12, {
			Size = UDim2.new(escapeProgress, 0, 1, 0),
			BackgroundColor3 = Colors.Warning:Lerp(Colors.Accent, escapeProgress),
		})
	end

	local function onEscapeAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if inputState ~= Enum.UserInputState.Begin or not isGrabbed then
			return Enum.ContextActionResult.Pass
		end
		-- Une barre fidèle au compteur serveur : 1/N par appui, sans décroissance.
		setEscapeProgress(escapeProgress + 1 / pressesNeeded)
		if requestGrabEscapeRemote then
			requestGrabEscapeRemote:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end

	local function showPrompt(grabberName: string?)
		isGrabbed = true
		setEscapeProgress(0)
		-- Espace / bouton A / bouton tactile "Libérer" : le QTE marche sur tous les appareils.
		ContextActionService:BindActionAtPriority(ESCAPE_ACTION, onEscapeAction, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
		ContextActionService:SetTitle(ESCAPE_ACTION, "Libérer")
		ContextActionService:SetPosition(ESCAPE_ACTION, UDim2.new(0.5, -40, 0.6, 0))
		promptLabel.Text = string.format(
			"AGRIPPÉ PAR %s — %s pour te libérer !",
			grabberName or "un prédateur",
			if UiTheme.IsTouchOnly() then "Touche « Libérer »" else "Appuie sur ESPACE"
		)
		-- Entrée : petit "pop" + contour rouge pulsant.
		promptFrame.Size = PROMPT_POP_START
		promptFrame.Visible = true
		UiTheme.Tween(promptFrame, 0.25, { Size = PROMPT_SIZE }, Enum.EasingStyle.Back)
		strokePulse:Play()
	end

	local function hidePrompt()
		isGrabbed = false
		ContextActionService:UnbindAction(ESCAPE_ACTION)
		promptFrame.Visible = false
		strokePulse:Cancel()
		promptStroke.Transparency = 0.6
		setEscapeProgress(0)
	end

	task.spawn(function()
		local ok, grabRemote = pcall(Remotes.Get, "GrabStateChanged")
		if not ok then
			warn("[GrabPromptView] GrabStateChanged indisponible : " .. tostring(grabRemote))
			return
		end
		(grabRemote :: RemoteEvent).OnClientEvent:Connect(function(grabbed: boolean, grabberName: string?, needed: unknown)
			pressesNeeded = if typeof(needed) == "number" and needed > 0 then needed :: number else DEFAULT_PRESSES_NEEDED
			if grabbed then
				showPrompt(grabberName)
			else
				hidePrompt()
			end
		end)
	end)

	-- Filet de sécurité : si l'attribut serveur retombe à false (ex: mort du joueur) sans que
	-- GrabStateChanged(false) soit émis, on masque quand même le prompt.
	player:GetAttributeChangedSignal("IsGrabbed"):Connect(function()
		if isGrabbed and player:GetAttribute("IsGrabbed") == false then
			hidePrompt()
		end
	end)
end

return GrabPromptView
