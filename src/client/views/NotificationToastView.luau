--!strict
-- NotificationToastView.luau
-- Toasts "NotifyClient" empilés en haut d'écran au style organique « Micro Wild » (glissement +
-- rebond Back, 4 max, fusion des doublons en "×N" avec pulsation) + pilule de retour
-- "AbilityFeedback" au-dessus du hotbar. Tout passe par TweenService : aucun travail par frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local NotificationToastView = {}

local mounted = false

local Colors = UiTheme.Colors

local MAX_TOASTS = 4
local TOAST_LIFETIME = 3.5
local TOAST_WIDTH = 368

local KIND_COLORS: { [string]: Color3 } = {
	info = Colors.Accent,
	warning = Colors.Warning,
	danger = Colors.Danger,
}
local KIND_ICONS: { [string]: string } = {
	info = "🌿",
	warning = "!",
	danger = "!",
}

local CARD_OFFSCREEN = UDim2.fromOffset(48, 0)
local CARD_SHOWN = UDim2.fromOffset(0, 0)
local SLOT_COLLAPSED = UDim2.fromScale(1, 0)
-- Filet de durée de vie sous le texte (déborde dans le padding gauche pour courir sous l'icône).
local LIFE_FULL = UDim2.new(1, 30, 0, 2)
local LIFE_EMPTY = UDim2.new(0, 0, 0, 2)
local LIFE_INFO = TweenInfo.new(TOAST_LIFETIME, Enum.EasingStyle.Linear)
local FEEDBACK_REST = UDim2.new(0.5, 0, 1, -146)
local FEEDBACK_START = UDim2.new(0.5, 0, 1, -132)

type Toast = {
	Slot: Frame,
	Card: Frame,
	Stroke: UIStroke,
	Accent: Frame,
	Icon: TextLabel,
	Label: TextLabel,
	Life: Frame,
	Message: string,
	Kind: string,
	Count: number,
	Token: number,
	Closing: boolean,
}

function NotificationToastView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "NotificationToastView"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 20
	screenGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	screenGui.Parent = playerGui

	local toastsFolder = Instance.new("Frame")
	toastsFolder.Name = "ToastsFolder"
	toastsFolder.AnchorPoint = Vector2.new(0.5, 0)
	toastsFolder.Position = UDim2.new(0.5, 0, 0, 14)
	toastsFolder.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
	toastsFolder.AutomaticSize = Enum.AutomaticSize.Y
	toastsFolder.BackgroundTransparency = 1
	toastsFolder.Parent = screenGui
	local toastScale = UiTheme.BindScale(toastsFolder, TOAST_WIDTH + 40, 420, 0.6, 1.15)

	local toastList = Instance.new("UIListLayout")
	toastList.SortOrder = Enum.SortOrder.LayoutOrder
	toastList.Padding = UDim.new(0, 6)
	toastList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastList.Parent = toastsFolder

	local toasts: { Toast } = {}
	local nextOrder = 0

	local function removeToast(toast: Toast)
		local index = table.find(toasts, toast)
		if index then
			table.remove(toasts, index)
		end
		toast.Slot:Destroy()
	end

	local function closeToast(toast: Toast)
		if toast.Closing then
			return
		end
		toast.Closing = true
		UiTheme.Tween(toast.Stroke, 0.25, { Transparency = 1 })
		UiTheme.Tween(toast.Accent, 0.25, { BackgroundTransparency = 1 })
		UiTheme.Tween(toast.Icon, 0.25, { TextTransparency = 1 })
		UiTheme.Tween(toast.Label, 0.25, { TextTransparency = 1 })
		UiTheme.Tween(toast.Life, 0.25, { BackgroundTransparency = 1 })
		local fadeOut = UiTheme.Tween(toast.Card, 0.25, { BackgroundTransparency = 1, Position = CARD_OFFSCREEN }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		fadeOut.Completed:Once(function()
			local slot = toast.Slot
			if not slot.Parent then
				return
			end
			slot.AutomaticSize = Enum.AutomaticSize.None
			slot.ClipsDescendants = true
			slot.Size = UDim2.new(1, 0, 0, slot.AbsoluteSize.Y / math.max(toastScale.Scale, 0.01))
			UiTheme.Tween(slot, 0.18, { Size = SLOT_COLLAPSED }).Completed:Once(function()
				removeToast(toast)
			end)
		end)
	end

	local function armLifetime(toast: Toast)
		toast.Life.Size = LIFE_FULL
		TweenService:Create(toast.Life, LIFE_INFO, { Size = LIFE_EMPTY }):Play()
		toast.Token += 1
		local myToken = toast.Token
		task.delay(TOAST_LIFETIME, function()
			if toast.Token == myToken then
				closeToast(toast)
			end
		end)
	end

	local function spawnToast(message: string, kind: string)
		local newest = toasts[#toasts]
		if newest and not newest.Closing and newest.Message == message and newest.Kind == kind then
			newest.Count += 1
			newest.Label.Text = string.format("%s  ×%d", message, newest.Count)
			newest.Stroke.Transparency = 0
			UiTheme.Pop(newest.Card, 0.94, 0.24)
			UiTheme.Tween(newest.Stroke, 0.4, { Transparency = 0.3 })
			armLifetime(newest)
			return
		end

		local live = 0
		local oldestLive: Toast? = nil
		for _, existing in ipairs(toasts) do
			if not existing.Closing then
				live += 1
				oldestLive = oldestLive or existing
			end
		end
		if live >= MAX_TOASTS and oldestLive then
			closeToast(oldestLive)
		end
		while #toasts >= MAX_TOASTS + 2 do
			removeToast(toasts[1])
		end

		local color = KIND_COLORS[kind] or Colors.Accent
		nextOrder += 1

		local slot = Instance.new("Frame")
		slot.Name = "Toast"
		slot.Size = UDim2.new(1, 0, 0, 0)
		slot.AutomaticSize = Enum.AutomaticSize.Y
		slot.BackgroundTransparency = 1
		slot.LayoutOrder = nextOrder
		slot.Parent = toastsFolder

		local card = Instance.new("Frame")
		card.Name = "Card"
		card.Position = CARD_OFFSCREEN
		card.Size = UDim2.new(1, 0, 0, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.BackgroundColor3 = Color3.new(1, 1, 1)
		card.BackgroundTransparency = 1
		card.BorderSizePixel = 0
		card.Parent = slot
		UiTheme.Corner(card, 10)
		UiTheme.Gradient(card, Colors.CardTop, Colors.PanelDeep, 95)
		local stroke = UiTheme.Stroke(card, color, 1.5, 1)

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 9)
		padding.PaddingBottom = UDim.new(0, 9)
		padding.PaddingLeft = UDim.new(0, 42)
		padding.PaddingRight = UDim.new(0, 12)
		padding.Parent = card

		local accent = Instance.new("Frame")
		accent.Name = "Accent"
		accent.AnchorPoint = Vector2.new(0, 0.5)
		accent.Position = UDim2.new(0, -31, 0.5, 0)
		accent.Size = UDim2.fromOffset(22, 22)
		accent.BackgroundColor3 = color
		accent.BackgroundTransparency = 1
		accent.BorderSizePixel = 0
		accent.Parent = card
		UiTheme.Corner(accent, 7)

		local icon = UiTheme.Label(accent, Enum.Font.GothamBlack, 13, Colors.PanelDeep)
		icon.Size = UDim2.fromScale(1, 1)
		icon.TextXAlignment = Enum.TextXAlignment.Center
		icon.TextTransparency = 1
		icon.Text = KIND_ICONS[kind] or "🌿"

		local label = UiTheme.Label(card, Enum.Font.GothamMedium, 14, Colors.Text)
		label.Name = "Message"
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextTransparency = 1
		label.Text = message

		local life = Instance.new("Frame")
		life.Name = "Life"
		life.AnchorPoint = Vector2.new(0, 1)
		life.Position = UDim2.new(0, -30, 1, 6)
		life.Size = LIFE_FULL
		life.BackgroundColor3 = color
		life.BackgroundTransparency = 1
		life.BorderSizePixel = 0
		life.Parent = card

		local toast: Toast = {
			Slot = slot,
			Card = card,
			Stroke = stroke,
			Accent = accent,
			Icon = icon,
			Label = label,
			Life = life,
			Message = message,
			Kind = kind,
			Count = 1,
			Token = 0,
			Closing = false,
		}
		table.insert(toasts, toast)

		UiTheme.Tween(card, 0.32, { BackgroundTransparency = 0.06, Position = CARD_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		UiTheme.Tween(stroke, 0.32, { Transparency = 0.3 })
		UiTheme.Tween(accent, 0.32, { BackgroundTransparency = 0 })
		UiTheme.Tween(icon, 0.32, { TextTransparency = 0 })
		UiTheme.Tween(label, 0.32, { TextTransparency = 0 })
		UiTheme.Tween(life, 0.32, { BackgroundTransparency = 0.45 })
		armLifetime(toast)
	end

	-- Flash de retour d'habileté, bas-centre au-dessus du hotbar.
	local feedbackLabel = UiTheme.Label(screenGui, Enum.Font.GothamBold, 15, Colors.Accent)
	feedbackLabel.Name = "AbilityFeedbackLabel"
	feedbackLabel.AnchorPoint = Vector2.new(0.5, 1)
	feedbackLabel.Position = FEEDBACK_REST
	feedbackLabel.Size = UDim2.new(0, 320, 0, 26)
	feedbackLabel.TextXAlignment = Enum.TextXAlignment.Center
	feedbackLabel.TextTransparency = 1
	feedbackLabel.TextStrokeTransparency = 1

	local feedbackSequence = 0
	local function showAbilityFeedback(success: boolean, reason: string?)
		feedbackSequence += 1
		local mySequence = feedbackSequence

		feedbackLabel.TextColor3 = if success then Colors.AccentBright else Colors.Danger
		local prefix = if success then "✓" else "✗"
		feedbackLabel.Text = if reason then string.format("%s %s", prefix, reason) else prefix
		feedbackLabel.Position = FEEDBACK_START
		feedbackLabel.TextTransparency = 0
		feedbackLabel.TextStrokeTransparency = 0.5
		UiTheme.Pop(feedbackLabel, 0.88, 0.24)
		UiTheme.Tween(feedbackLabel, 0.22, { Position = FEEDBACK_REST }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

		task.delay(1.3, function()
			if feedbackSequence == mySequence then
				UiTheme.Tween(feedbackLabel, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
			end
		end)
	end

	task.spawn(function()
		local ok, notifyRemote = pcall(Remotes.Get, "NotifyClient")
		if not ok then
			warn("[NotificationToastView] NotifyClient indisponible : " .. tostring(notifyRemote))
			return
		end
		local remote = notifyRemote :: RemoteEvent
		remote.OnClientEvent:Connect(function(message: unknown, kind: unknown)
			spawnToast(tostring(message), tostring(kind))
		end)
	end)

	task.spawn(function()
		local ok, feedbackRemote = pcall(Remotes.Get, "AbilityFeedback")
		if not ok then
			warn("[NotificationToastView] AbilityFeedback indisponible : " .. tostring(feedbackRemote))
			return
		end
		local remote = feedbackRemote :: RemoteEvent
		remote.OnClientEvent:Connect(function(success: unknown, reason: unknown)
			showAbilityFeedback(success == true, if typeof(reason) == "string" then reason else nil)
		end)
	end)
end

return NotificationToastView
