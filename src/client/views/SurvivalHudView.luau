--!strict
-- SurvivalHudView.luau
-- HUD de survie bas-gauche : Faim, Soif, Température, Oxygène, Croissance/Stade, Saison, Horloge.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)

local SurvivalHudView = {}

local mounted = false

local COLOR_COLD = Color3.fromRGB(90, 170, 255)
local COLOR_IDEAL = Color3.fromRGB(95, 215, 120)
local COLOR_HOT = Color3.fromRGB(230, 80, 70)

-- Construit une barre labellisée (titre + fond + remplissage) et renvoie les pièces à mettre à jour.
local function createBar(parent: Instance, order: number, labelText: string)
	local container = Instance.new("Frame")
	container.Name = labelText .. "Bar"
	container.Size = UDim2.new(1, 0, 0, 34)
	container.BackgroundTransparency = 1
	container.LayoutOrder = order
	container.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 0, 14)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = labelText
	label.Parent = container

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 0, 0, 16)
	track.Size = UDim2.new(1, 0, 0, 14)
	track.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	track.BorderSizePixel = 0
	track.Parent = container

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = COLOR_IDEAL
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	return label, fill
end

function SurvivalHudView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SurvivalHudView"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 5
	screenGui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 1, -16)
	panel.Size = UDim2.new(0, 230, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	panel.BackgroundTransparency = 0.25
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 8)
	panelCorner.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = panel

	local hungerLabel, hungerFill = createBar(panel, 1, "Faim")
	local thirstLabel, thirstFill = createBar(panel, 2, "Soif")
	local tempLabel, tempFill = createBar(panel, 3, "Température")
	local oxygenLabel, oxygenFill = createBar(panel, 4, "Oxygène")
	local growthLabel, growthFill = createBar(panel, 5, "Croissance")

	local seasonLabel = Instance.new("TextLabel")
	seasonLabel.Name = "SeasonLabel"
	seasonLabel.Size = UDim2.new(1, 0, 0, 16)
	seasonLabel.BackgroundTransparency = 1
	seasonLabel.Font = Enum.Font.Gotham
	seasonLabel.TextSize = 12
	seasonLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	seasonLabel.TextXAlignment = Enum.TextXAlignment.Left
	seasonLabel.LayoutOrder = 6
	seasonLabel.Parent = panel

	local clockLabel = Instance.new("TextLabel")
	clockLabel.Name = "ClockLabel"
	clockLabel.Size = UDim2.new(1, 0, 0, 16)
	clockLabel.BackgroundTransparency = 1
	clockLabel.Font = Enum.Font.Gotham
	clockLabel.TextSize = 12
	clockLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Left
	clockLabel.LayoutOrder = 7
	clockLabel.Parent = panel

	-- Faim / Soif / Oxygène : simples barres 0..100, vertes et qui virent au rouge en dessous de 30.
	local function updatePercentBar(fill: Frame, label: TextLabel, prefix: string, value: number)
		local clamped = math.clamp(value, 0, 100)
		fill.Size = UDim2.new(clamped / 100, 0, 1, 0)
		fill.BackgroundColor3 = clamped < 30 and COLOR_HOT or COLOR_IDEAL
		label.Text = string.format("%s : %d", prefix, math.floor(clamped))
	end

	local function refreshHunger()
		updatePercentBar(hungerFill, hungerLabel, "Faim", tonumber(player:GetAttribute("Hunger")) or 0)
	end
	local function refreshThirst()
		updatePercentBar(thirstFill, thirstLabel, "Soif", tonumber(player:GetAttribute("Thirst")) or 0)
	end
	local function refreshOxygen()
		updatePercentBar(oxygenFill, oxygenLabel, "Oxygène", tonumber(player:GetAttribute("Oxygen")) or 0)
	end

	-- Température : couleur bleu -> vert -> rouge selon la zone idéale de l'espèce active.
	local function refreshTemperature()
		local bodyTemp = tonumber(player:GetAttribute("BodyTemperature")) or 22
		local speciesId = player:GetAttribute("Species")
		local info = typeof(speciesId) == "string" and InsectData[speciesId] or nil
		local idealMin = info and info.IdealTempMin or 10
		local idealMax = info and info.IdealTempMax or 30

		local color: Color3
		if bodyTemp < idealMin then
			local t = math.clamp((idealMin - bodyTemp) / 15, 0, 1)
			color = COLOR_IDEAL:Lerp(COLOR_COLD, t)
		elseif bodyTemp > idealMax then
			local t = math.clamp((bodyTemp - idealMax) / 15, 0, 1)
			color = COLOR_IDEAL:Lerp(COLOR_HOT, t)
		else
			color = COLOR_IDEAL
		end

		tempFill.BackgroundColor3 = color
		-- Échelle d'affichage fixe (-20°C à 50°C) : la couleur porte l'information d'idéal, pas la largeur.
		tempFill.Size = UDim2.new(math.clamp((bodyTemp + 20) / 70, 0, 1), 0, 1, 0)
		tempLabel.Text = string.format("Température : %d°C", math.floor(bodyTemp))
	end

	local function refreshGrowth()
		local growth = math.clamp(tonumber(player:GetAttribute("Growth")) or 0, 0, 100)
		local stage = player:GetAttribute("Stage")
		growthFill.Size = UDim2.new(growth / 100, 0, 1, 0)
		growthFill.BackgroundColor3 = COLOR_IDEAL
		growthLabel.Text = string.format("Croissance (%s) : %d%%", tostring(stage), math.floor(growth))
	end

	local function refreshSeason()
		local displayName = workspace:GetAttribute("SeasonDisplayName")
		if typeof(displayName) ~= "string" then
			local seasonId = workspace:GetAttribute("CurrentSeason")
			local seasonInfo = typeof(seasonId) == "string" and SeasonConfig.Seasons[seasonId] or nil
			displayName = (seasonInfo and seasonInfo.DisplayName) or tostring(seasonId or "?")
		end
		seasonLabel.Text = string.format("Saison : %s", displayName)
	end

	refreshHunger()
	refreshThirst()
	refreshOxygen()
	refreshTemperature()
	refreshGrowth()
	refreshSeason()

	player:GetAttributeChangedSignal("Hunger"):Connect(refreshHunger)
	player:GetAttributeChangedSignal("Thirst"):Connect(refreshThirst)
	player:GetAttributeChangedSignal("Oxygen"):Connect(refreshOxygen)
	player:GetAttributeChangedSignal("BodyTemperature"):Connect(refreshTemperature)
	player:GetAttributeChangedSignal("Species"):Connect(refreshTemperature)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("Stage"):Connect(refreshGrowth)
	workspace:GetAttributeChangedSignal("CurrentSeason"):Connect(refreshSeason)
	workspace:GetAttributeChangedSignal("SeasonDisplayName"):Connect(refreshSeason)

	-- Horloge : accumulateur à basse fréquence (~0.5s) plutôt qu'un Heartbeat brut à chaque frame.
	local clockAccumulator = 0.5 -- démarre plein pour afficher l'heure dès le premier Heartbeat
	RunService.Heartbeat:Connect(function(deltaTime: number)
		clockAccumulator += deltaTime
		if clockAccumulator < 0.5 then
			return
		end
		clockAccumulator = 0
		local clockTime = Lighting.ClockTime
		local hours = math.floor(clockTime)
		local minutes = math.floor((clockTime % 1) * 60)
		clockLabel.Text = string.format("Heure : %02d:%02d", hours, minutes)
	end)
end

return SurvivalHudView
