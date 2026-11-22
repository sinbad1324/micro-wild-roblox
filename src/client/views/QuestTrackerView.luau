--!strict
-- QuestTrackerView.luau
-- Panneau "Défis" (QuestService) sous la carte de stats : 3 défis avec barre de progression,
-- compteur de défis réussis (coffre tous les 5) et série quotidienne. Clignote à chaque défi
-- réussi ; masqué en mode construction (le panneau de construction prend la place).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local UiTheme = require(script.Parent.UiTheme)
local SfxController = require(script.Parent.Parent.controllers.SfxController)

local QuestTrackerView = {}

local player = Players.LocalPlayer
local Colors = UiTheme.Colors
local CHEST_EVERY = 5 -- QuestService.CHEST_EVERY

type Row = { Box: Frame, Label: TextLabel, Fill: Frame }

function QuestTrackerView.Mount()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "QuestTrackerGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Quests"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -12, 0, 116)
	panel.Size = UDim2.fromOffset(258, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = screenGui
	local stroke = UiTheme.StylePanel(panel, 12, Colors.Border, 0.5)
	UiTheme.Padding(panel, 12, 8)
	UiTheme.BindScale(panel, 760, 560, 0.6, 1.1)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	local header = UiTheme.Label(panel, Enum.Font.GothamBlack, 14, Colors.Gold)
	header.Size = UDim2.new(1, 0, 0, 18)
	header.LayoutOrder = 0

	local rows: { Row } = {}
	local function row(index: number): Row
		local existing = rows[index]
		if existing then
			return existing
		end
		local box = Instance.new("Frame")
		box.Size = UDim2.new(1, 0, 0, 30)
		box.BackgroundTransparency = 1
		box.LayoutOrder = index
		box.Parent = panel
		local label = UiTheme.Label(box, Enum.Font.GothamBold, 12, Colors.Text)
		label.Size = UDim2.new(1, 0, 0, 16)
		label.TextTruncate = Enum.TextTruncate.AtEnd
		local track = Instance.new("Frame")
		track.Position = UDim2.fromOffset(0, 19)
		track.Size = UDim2.new(1, 0, 0, 7)
		track.BackgroundColor3 = Colors.Track
		track.BorderSizePixel = 0
		track.Parent = box
		UiTheme.Corner(track, 4)
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = Colors.Accent
		fill.BorderSizePixel = 0
		fill.Parent = track
		UiTheme.Corner(fill, 4)
		local created = { Box = box, Label = label, Fill = fill }
		rows[index] = created
		return created
	end

	local function refreshHeader()
		local done = player:GetAttribute("QuestsDone")
		local count = if type(done) == "number" then done else 0
		local streak = player:GetAttribute("DailyStreak")
		header.Text = string.format(
			"🎯 Défis  ·  🎁 %d/%d%s",
			count % CHEST_EVERY,
			CHEST_EVERY,
			if type(streak) == "number" and streak > 0 then string.format("  ·  🔥 %dj", streak) else ""
		)
	end

	local function refresh()
		local raw = player:GetAttribute("Quests")
		local ok, list = pcall(function()
			return if type(raw) == "string" then HttpService:JSONDecode(raw) else nil
		end)
		if not ok or type(list) ~= "table" then
			panel.Visible = false
			return
		end
		panel.Visible = #list > 0 and player:GetAttribute("BuildMode") ~= true
		for i, quest in ipairs(list :: { any }) do
			local r = row(i)
			r.Label.Text = string.format("%s  (%d/%d)", tostring(quest.T), quest.P or 0, quest.G or 1)
			local ratio = math.clamp((quest.P or 0) / math.max(quest.G or 1, 1), 0, 1)
			UiTheme.Tween(r.Fill, 0.35, { Size = UDim2.fromScale(ratio, 1) })
			r.Fill.BackgroundColor3 = if ratio >= 0.75 then Colors.Gold else Colors.Accent
			r.Box.Visible = true
		end
		for i = #list + 1, #rows do
			rows[i].Box.Visible = false
		end
		refreshHeader()
	end

	-- Défi réussi : éclair doré sur le panneau.
	local lastDone = player:GetAttribute("QuestsDone")
	player:GetAttributeChangedSignal("QuestsDone"):Connect(function()
		local done = player:GetAttribute("QuestsDone")
		if type(done) == "number" and (type(lastDone) ~= "number" or done > lastDone) then
			SfxController.Play(if done % CHEST_EVERY == 0 then "Chest" else "Quest")
			stroke.Color = Colors.Gold
			stroke.Transparency = 0
			UiTheme.Pop(header, 1.35, 0.35) -- pas le panneau : son UIScale sert à BindScale
			UiTheme.Tween(stroke, 1.2, { Transparency = 0.5 })
			task.delay(1.2, function()
				stroke.Color = Colors.Border
			end)
		end
		lastDone = done
		refreshHeader()
	end)
	for _, attribute in ipairs({ "Quests", "BuildMode" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refresh)
	end
	player:GetAttributeChangedSignal("DailyStreak"):Connect(refreshHeader)
	refresh()
end

return QuestTrackerView
