--!strict
-- GrabPromptView.luau
-- Prompt centre-écran "AGRIPPÉ PAR ..." au style organique « Micro Wild » + barre de progression
-- avec rebond visuel à chaque appui sur ESPACE / bouton tactile « Libérer ».

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local GrabPromptView = {}

local mounted = false

local ESCAPE_ACTION = "MW_GrabEscape"
local DEFAULT_PRESSES_NEEDED = 12
local PROMPT_SIZE = UDim2.fromOffset(430, 96)
local PROMPT_POP_START = UDim2.fromOffset(375, 84)

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
	promptFrame.BackgroundTransparency = 0.06
	promptFrame.Visible = false
	promptFrame.Parent = screenGui
	local promptStroke = UiTheme.StylePanel(promptFrame, 14, Colors.Danger, 0.5)
	promptStroke.Thickness = 2
	UiTheme.Padding(promptFrame, 16, 12)
	UiTheme.BindScale(promptFrame, 480, 360, 0.6, 1.2)

	local promptLabel = UiTheme.Label(promptFrame, Enum.Font.GothamBlack, 17, Colors.Danger)
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
	UiTheme.Corner(track, 7)
	UiTheme.Stroke(track, Colors.Border, 1, 0.65)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Colors.Accent
	fill.Parent = track
	UiTheme.Corner(fill, 7)

	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.new(1, 0, 0.45, 0)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.8
	shine.BorderSizePixel = 0
	shine.Parent = fill
	UiTheme.Corner(shine, 7)

	local strokePulse = TweenService:Create(
		promptStroke,
		TweenInfo.new(0.38, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
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
		UiTheme.Tween(fill, 0.12, {
			Size = UDim2.new(escapeProgress, 0, 1, 0),
			BackgroundColor3 = Colors.Warning:Lerp(Colors.Accent, escapeProgress),
		})
	end

	local function onEscapeAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if inputState ~= Enum.UserInputState.Begin or not isGrabbed then
			return Enum.ContextActionResult.Pass
		end
		setEscapeProgress(escapeProgress + 1 / pressesNeeded)
		-- Petit rebond nerveux du cadre à chaque appui pour renforcer le ressenti du QTE.
		promptFrame.Size = UDim2.fromOffset(442, 100)
		UiTheme.Tween(promptFrame, 0.14, { Size = PROMPT_SIZE }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		if requestGrabEscapeRemote then
			requestGrabEscapeRemote:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end

	local hideToken = 0

	local function showPrompt(grabberName: string?)
		isGrabbed = true
		hideToken += 1
		setEscapeProgress(0)
		promptLabel.TextColor3 = Colors.Danger
		promptStroke.Color = Colors.Danger
		ContextActionService:BindActionAtPriority(ESCAPE_ACTION, onEscapeAction, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
		ContextActionService:SetTitle(ESCAPE_ACTION, "Libérer")
		ContextActionService:SetPosition(ESCAPE_ACTION, UDim2.new(0.5, -40, 0.6, 0))
		promptLabel.Text = string.format(
			"⚠ AGRIPPÉ PAR %s — %s pour te libérer !",
			grabberName or "un prédateur",
			if UiTheme.IsTouchOnly() then "Touche « Libérer »" else "Martèle [ESPACE]"
		)
		promptFrame.Size = PROMPT_POP_START
		promptFrame.Visible = true
		UiTheme.Tween(promptFrame, 0.26, { Size = PROMPT_SIZE }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		strokePulse:Play()
	end

	local function hidePrompt()
		local wasGrabbed = isGrabbed
		isGrabbed = false
		ContextActionService:UnbindAction(ESCAPE_ACTION)
		strokePulse:Cancel()
		promptStroke.Transparency = 0.5
		if not wasGrabbed or not promptFrame.Visible then
			promptFrame.Visible = false
			setEscapeProgress(0)
			return
		end
		hideToken += 1
		local myToken = hideToken
		-- Libération réussie (encore en vie) : bref flash vert avant de replier le cadre.
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local alive = humanoid ~= nil and humanoid.Health > 0
		local holdSeconds = 0
		if alive then
			promptLabel.Text = "🌿 Libéré !"
			promptLabel.TextColor3 = Colors.AccentBright
			promptStroke.Color = Colors.Accent
			setEscapeProgress(1)
			holdSeconds = 0.45
		end
		task.delay(holdSeconds, function()
			if hideToken ~= myToken then
				return
			end
			UiTheme.Tween(promptFrame, 0.18, { Size = PROMPT_POP_START }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Once(function()
				if hideToken == myToken then
					promptFrame.Visible = false
					promptFrame.Size = PROMPT_SIZE
					setEscapeProgress(0)
				end
			end)
		end)
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

	player:GetAttributeChangedSignal("IsGrabbed"):Connect(function()
		if isGrabbed and player:GetAttribute("IsGrabbed") == false then
			hidePrompt()
		end
	end)
end

return GrabPromptView
