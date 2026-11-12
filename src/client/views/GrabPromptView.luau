--!strict
-- GrabPromptView.luau
-- Prompt centre-écran "AGRIPPÉ PAR ..." + barre de progression locale pour le mash ESPACE.
-- La logique de QTE (comptage des appuis, réussite de l'évasion) est côté serveur : cette vue ne
-- fait qu'informer et envoyer l'intention RequestGrabEscape à chaque appui.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local GrabPromptView = {}

local mounted = false

local BAR_BUMP_PER_PRESS = 0.15
local BAR_DECAY_PER_SECOND = 0.08

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

	local promptFrame = Instance.new("Frame")
	promptFrame.Name = "PromptFrame"
	promptFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	promptFrame.Position = UDim2.new(0.5, 0, 0.4, 0)
	promptFrame.Size = UDim2.new(0, 420, 0, 90)
	promptFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	promptFrame.BackgroundTransparency = 0.2
	promptFrame.Visible = false
	promptFrame.Parent = screenGui

	local promptCorner = Instance.new("UICorner")
	promptCorner.CornerRadius = UDim.new(0, 10)
	promptCorner.Parent = promptFrame

	local promptPadding = Instance.new("UIPadding")
	promptPadding.PaddingTop = UDim.new(0, 10)
	promptPadding.PaddingLeft = UDim.new(0, 14)
	promptPadding.PaddingRight = UDim.new(0, 14)
	promptPadding.Parent = promptFrame

	local promptLabel = Instance.new("TextLabel")
	promptLabel.Name = "PromptLabel"
	promptLabel.Size = UDim2.new(1, 0, 0, 44)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Font = Enum.Font.GothamBold
	promptLabel.TextSize = 18
	promptLabel.TextWrapped = true
	promptLabel.TextColor3 = Color3.fromRGB(255, 70, 70)
	promptLabel.Text = ""
	promptLabel.Parent = promptFrame

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 0, 0, 52)
	track.Size = UDim2.new(1, 0, 0, 18)
	track.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	track.BorderSizePixel = 0
	track.Parent = promptFrame

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 5)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Color3.fromRGB(95, 215, 120)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 5)
	fillCorner.Parent = fill

	local isGrabbed = false
	local escapeProgress = 0
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
		fill.Size = UDim2.new(escapeProgress, 0, 1, 0)
	end

	local function showPrompt(grabberName: string?)
		isGrabbed = true
		setEscapeProgress(0)
		promptLabel.Text = string.format(
			"AGRIPPÉ PAR %s — Appuie sur ESPACE pour te libérer !",
			grabberName or "un prédateur"
		)
		promptFrame.Visible = true
	end

	local function hidePrompt()
		isGrabbed = false
		promptFrame.Visible = false
		setEscapeProgress(0)
	end

	task.spawn(function()
		local ok, grabRemote = pcall(Remotes.Get, "GrabStateChanged")
		if not ok then
			warn("[GrabPromptView] GrabStateChanged indisponible : " .. tostring(grabRemote))
			return
		end
		(grabRemote :: RemoteEvent).OnClientEvent:Connect(function(grabbed: boolean, grabberName: string?)
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

	UserInputService.InputBegan:Connect(function(input: InputObject)
		if not isGrabbed then
			return
		end
		if input.KeyCode ~= Enum.KeyCode.Space then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		setEscapeProgress(escapeProgress + BAR_BUMP_PER_PRESS)
		if requestGrabEscapeRemote then
			requestGrabEscapeRemote:FireServer()
		end
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		if not isGrabbed or escapeProgress <= 0 then
			return
		end
		setEscapeProgress(escapeProgress - BAR_DECAY_PER_SECOND * deltaTime)
	end)
end

return GrabPromptView
