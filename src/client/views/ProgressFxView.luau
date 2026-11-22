--!strict
-- ProgressFxView.luau
-- Retour immédiat sur la progression (le "juice") :
--   * "+N XP" qui s'envole au-dessus de l'insecte à chaque gain d'XP (attribut "XP");
--   * bannière dorée "NIVEAU X" au centre de l'écran à chaque niveau gagné (attribut "Level").

local Players = game:GetService("Players")

local UiTheme = require(script.Parent.UiTheme)
local SfxController = require(script.Parent.Parent.controllers.SfxController)

local ProgressFxView = {}

local player = Players.LocalPlayer
local Colors = UiTheme.Colors

local function floatText(text: string, color: Color3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(160, 40)
	board.StudsOffsetWorldSpace = Vector3.new(math.random(-10, 10) / 10, 3, 0)
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.Adornee = root
	board.Parent = player:WaitForChild("PlayerGui")
	local label = UiTheme.Label(board, Enum.Font.GothamBlack, 22, color)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextStrokeTransparency = 0.4
	label.Text = text
	UiTheme.Tween(board, 1.1, { StudsOffsetWorldSpace = board.StudsOffsetWorldSpace + Vector3.new(0, 3, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	UiTheme.Tween(label, 1.1, { TextTransparency = 1, TextStrokeTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(1.2, function()
		board:Destroy()
	end)
end

function ProgressFxView.Mount()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ProgressFxGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 5
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local banner = UiTheme.Label(screenGui, Enum.Font.GothamBlack, 46, Colors.Gold)
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.3)
	banner.Size = UDim2.fromOffset(600, 60)
	banner.TextXAlignment = Enum.TextXAlignment.Center
	banner.TextStrokeTransparency = 0.2
	banner.TextTransparency = 1
	banner.TextStrokeTransparency = 1

	local lastXp = player:GetAttribute("XP")
	local lastLevel = player:GetAttribute("Level")
	local bannerToken = 0

	player:GetAttributeChangedSignal("Level"):Connect(function()
		local level = player:GetAttribute("Level")
		if type(level) == "number" and type(lastLevel) == "number" and level > lastLevel then
			bannerToken += 1
			local token = bannerToken
			banner.Text = string.format("⭐ NIVEAU %d ⭐", level)
			banner.TextTransparency = 0
			banner.TextStrokeTransparency = 0.2
			UiTheme.Pop(banner, 1.6, 0.4)
			floatText("NIVEAU " .. level .. " !", Colors.Gold)
			SfxController.Play("LevelUp")
			task.delay(1.8, function()
				if token == bannerToken then
					UiTheme.Tween(banner, 0.6, { TextTransparency = 1, TextStrokeTransparency = 1 })
				end
			end)
		end
		lastLevel = level
	end)

	-- Gain d'XP = nouvel XP - ancien (ou nouvel XP seul si le niveau vient de passer).
	player:GetAttributeChangedSignal("XP"):Connect(function()
		local xp = player:GetAttribute("XP")
		if type(xp) ~= "number" then
			return
		end
		local gained = if type(lastXp) == "number" and xp >= lastXp then xp - lastXp else xp
		lastXp = xp
		if gained >= 1 then
			floatText(string.format("+%d XP", gained), Colors.AccentBright)
			SfxController.Play("XpTick")
		end
	end)
end

return ProgressFxView
