--!strict
-- NotificationToastView.luau
-- Toasts "NotifyClient" en haut d'écran + flash de retour "AbilityFeedback" près du hotbar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local NotificationToastView = {}

local mounted = false

local MAX_TOASTS = 4
local TOAST_LIFETIME = 3.5

local KIND_COLORS: { [string]: Color3 } = {
	info = Color3.fromRGB(60, 120, 220),
	warning = Color3.fromRGB(220, 165, 40),
	danger = Color3.fromRGB(200, 55, 55),
}

-- Fait apparaître puis disparaître un toast, et le détruit à la fin de son cycle de vie.
local function spawnToast(toastList: UIListLayout, message: string, kind: string)
	local toastsFolder = toastList.Parent :: Frame
	local existingCount = #toastsFolder:GetChildren() - 1 -- -1 pour exclure le UIListLayout lui-même
	if existingCount >= MAX_TOASTS then
		local oldest = toastsFolder:FindFirstChildOfClass("Frame")
		if oldest then
			oldest:Destroy()
		end
	end

	local toast = Instance.new("Frame")
	toast.Name = "Toast"
	toast.Size = UDim2.new(0, 360, 0, 40)
	toast.BackgroundColor3 = KIND_COLORS[kind] or KIND_COLORS.info
	toast.BackgroundTransparency = 1
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.Parent = toastsFolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = toast

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = toast

	local label = Instance.new("TextLabel")
	label.Name = "Message"
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextWrapped = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextTransparency = 1
	label.Text = message
	label.Parent = toast

	TweenService:Create(toast, TweenInfo.new(0.2), { BackgroundTransparency = 0.1 }):Play()
	TweenService:Create(label, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()

	task.delay(TOAST_LIFETIME, function()
		if not toast.Parent then
			return
		end
		local fadeOut = TweenService:Create(toast, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
		TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		fadeOut:Play()
		fadeOut.Completed:Wait()
		toast:Destroy()
	end)
end

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
	toastsFolder.Position = UDim2.new(0.5, 0, 0, 16)
	toastsFolder.Size = UDim2.new(0, 360, 0, 0)
	toastsFolder.AutomaticSize = Enum.AutomaticSize.Y
	toastsFolder.BackgroundTransparency = 1
	toastsFolder.Parent = screenGui

	local toastList = Instance.new("UIListLayout")
	toastList.SortOrder = Enum.SortOrder.LayoutOrder
	toastList.Padding = UDim.new(0, 6)
	toastList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toastList.Parent = toastsFolder

	-- Flash de retour d'habileté, bas-centre près du hotbar.
	local feedbackLabel = Instance.new("TextLabel")
	feedbackLabel.Name = "AbilityFeedbackLabel"
	feedbackLabel.AnchorPoint = Vector2.new(0.5, 1)
	feedbackLabel.Position = UDim2.new(0.5, 0, 1, -140)
	feedbackLabel.Size = UDim2.new(0, 320, 0, 26)
	feedbackLabel.BackgroundTransparency = 1
	feedbackLabel.Font = Enum.Font.GothamBold
	feedbackLabel.TextSize = 16
	feedbackLabel.TextTransparency = 1
	feedbackLabel.Text = ""
	feedbackLabel.Parent = screenGui

	local feedbackSequence = 0
	local function showAbilityFeedback(success: boolean, reason: string?)
		feedbackSequence += 1
		local mySequence = feedbackSequence

		feedbackLabel.TextColor3 = success and Color3.fromRGB(95, 215, 120) or Color3.fromRGB(230, 80, 70)
		local prefix = success and "✓" or "✗"
		feedbackLabel.Text = reason and string.format("%s %s", prefix, reason) or prefix
		feedbackLabel.TextTransparency = 0

		task.delay(1.5, function()
			if feedbackSequence == mySequence then
				feedbackLabel.TextTransparency = 1
			end
		end)
	end

	task.spawn(function()
		local ok, notifyRemote = pcall(Remotes.Get, "NotifyClient")
		if not ok then
			warn("[NotificationToastView] NotifyClient indisponible : " .. tostring(notifyRemote))
			return
		end
		(notifyRemote :: RemoteEvent).OnClientEvent:Connect(function(message: string, kind: string)
			spawnToast(toastList, tostring(message), tostring(kind))
		end)
	end)

	task.spawn(function()
		local ok, feedbackRemote = pcall(Remotes.Get, "AbilityFeedback")
		if not ok then
			warn("[NotificationToastView] AbilityFeedback indisponible : " .. tostring(feedbackRemote))
			return
		end
		(feedbackRemote :: RemoteEvent).OnClientEvent:Connect(function(success: boolean, reason: string?)
			showAbilityFeedback(success, reason)
		end)
	end)
end

return NotificationToastView
