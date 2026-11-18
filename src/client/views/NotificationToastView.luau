--!strict
-- NotificationToastView.luau
-- Toasts "NotifyClient" empilés en haut d'écran (glissement + fondu, 4 max, les doublons
-- consécutifs sont fusionnés en "×N") + flash de retour "AbilityFeedback" au-dessus du hotbar.
-- Tout passe par TweenService : aucun travail par frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local NotificationToastView = {}

local mounted = false

local Colors = UiTheme.Colors

local MAX_TOASTS = 4
local TOAST_LIFETIME = 3.5
local TOAST_WIDTH = 360

local KIND_COLORS: { [string]: Color3 } = {
	info = Colors.Info,
	warning = Colors.Warning,
	danger = Colors.Danger,
}
local KIND_ICONS: { [string]: string } = {
	info = "i",
	warning = "!",
	danger = "!",
}

-- Positions pré-allouées de la carte dans son emplacement (glissement horizontal uniquement :
-- la hauteur automatique de l'emplacement ne bouge donc pas pendant l'animation).
local CARD_OFFSCREEN = UDim2.fromOffset(48, 0)
local CARD_SHOWN = UDim2.fromOffset(0, 0)
local SLOT_COLLAPSED = UDim2.fromScale(1, 0)
local FEEDBACK_REST = UDim2.new(0.5, 0, 1, -140)
local FEEDBACK_START = UDim2.new(0.5, 0, 1, -128)

type Toast = {
	Slot: Frame,
	Card: Frame,
	Stroke: UIStroke,
	Accent: Frame,
	Icon: TextLabel,
	Label: TextLabel,
	Message: string,
	Kind: string,
	Count: number,
	Token: number, -- incrémenté à chaque prolongation : seul le dernier minuteur ferme le toast
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
	screenGui.Parent = playerGui

	-- Pile de toasts en haut-centre.
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

	local toasts: { Toast } = {} -- du plus ancien au plus récent
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
		local fadeOut = UiTheme.Tween(toast.Card, 0.25, { BackgroundTransparency = 1, Position = CARD_OFFSCREEN }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		fadeOut.Completed:Once(function()
			-- Repli de l'emplacement : les toasts suivants remontent en douceur au lieu de sauter.
			-- AbsoluteSize inclut le UIScale de la pile, on le retire pour retrouver la taille "design".
			local slot = toast.Slot
			if not slot.Parent then
				return -- déjà évincé
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
		toast.Token += 1
		local myToken = toast.Token
		task.delay(TOAST_LIFETIME, function()
			if toast.Token == myToken then
				closeToast(toast)
			end
		end)
	end

	local function spawnToast(message: string, kind: string)
		-- Même message que le toast le plus récent : on le prolonge au lieu d'empiler un doublon.
		local newest = toasts[#toasts]
		if newest and not newest.Closing and newest.Message == message and newest.Kind == kind then
			newest.Count += 1
			newest.Label.Text = string.format("%s  ×%d", message, newest.Count)
			-- Petit éclat du contour pour signaler la répétition.
			newest.Stroke.Transparency = 0
			UiTheme.Tween(newest.Stroke, 0.4, { Transparency = 0.35 })
			armLifetime(newest)
			return
		end

		-- Pile pleine : le plus ancien toast encore affiché sort en glissant (pas de disparition sèche).
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
		-- Garde-fou anti-spam : jamais plus de MAX_TOASTS + 2 cartes, même en cours de sortie.
		while #toasts >= MAX_TOASTS + 2 do
			removeToast(toasts[1])
		end

		local color = KIND_COLORS[kind] or Colors.Info
		nextOrder += 1

		-- Emplacement dans la pile (géré par le UIListLayout) ; la carte glisse à l'intérieur.
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
		card.BackgroundColor3 = Colors.Panel
		card.BackgroundTransparency = 1
		card.BorderSizePixel = 0
		card.Parent = slot
		UiTheme.Corner(card, 8)
		local stroke = UiTheme.Stroke(card, color, 1, 1)

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 9)
		padding.PaddingBottom = UDim.new(0, 9)
		padding.PaddingLeft = UDim.new(0, 40)
		padding.PaddingRight = UDim.new(0, 12)
		padding.Parent = card

		-- Pastille colorée du type de message (à gauche, dans la marge).
		local accent = Instance.new("Frame")
		accent.Name = "Accent"
		accent.AnchorPoint = Vector2.new(0, 0.5)
		accent.Position = UDim2.new(0, -30, 0.5, 0)
		accent.Size = UDim2.fromOffset(20, 20)
		accent.BackgroundColor3 = color
		accent.BackgroundTransparency = 1
		accent.BorderSizePixel = 0
		accent.Parent = card
		UiTheme.Corner(accent, 10)

		local icon = UiTheme.Label(accent, Enum.Font.GothamBlack, 13, Colors.Panel)
		icon.Size = UDim2.fromScale(1, 1)
		icon.TextXAlignment = Enum.TextXAlignment.Center
		icon.TextTransparency = 1
		icon.Text = KIND_ICONS[kind] or "i"

		local label = UiTheme.Label(card, Enum.Font.GothamMedium, 14, Colors.Text)
		label.Name = "Message"
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextTransparency = 1
		label.Text = message

		local toast: Toast = {
			Slot = slot,
			Card = card,
			Stroke = stroke,
			Accent = accent,
			Icon = icon,
			Label = label,
			Message = message,
			Kind = kind,
			Count = 1,
			Token = 0,
			Closing = false,
		}
		table.insert(toasts, toast)

		UiTheme.Tween(card, 0.3, { BackgroundTransparency = 0.08, Position = CARD_SHOWN }, Enum.EasingStyle.Back)
		UiTheme.Tween(stroke, 0.3, { Transparency = 0.35 })
		UiTheme.Tween(accent, 0.3, { BackgroundTransparency = 0 })
		UiTheme.Tween(icon, 0.3, { TextTransparency = 0 })
		UiTheme.Tween(label, 0.3, { TextTransparency = 0 })
		armLifetime(toast)
	end

	-- Flash de retour d'habileté, bas-centre au-dessus du hotbar.
	local feedbackLabel = UiTheme.Label(screenGui, Enum.Font.GothamBold, 16, Colors.Accent)
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

		feedbackLabel.TextColor3 = if success then Colors.Accent else Colors.Danger
		local prefix = if success then "✓" else "✗"
		feedbackLabel.Text = if reason then string.format("%s %s", prefix, reason) else prefix
		feedbackLabel.Position = FEEDBACK_START
		feedbackLabel.TextTransparency = 0
		feedbackLabel.TextStrokeTransparency = 0.6
		UiTheme.Tween(feedbackLabel, 0.2, { Position = FEEDBACK_REST })

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
