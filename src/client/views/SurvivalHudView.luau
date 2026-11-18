--!strict
-- SurvivalHudView.luau
-- HUD de survie : Faim, Soif, Température (zone idéale de l'espèce), Oxygène (affiché seulement
-- quand il baisse), Croissance/Stade avec indice du prochain stade, Saison + Horloge, et bannière
-- de changement de saison. Tout est piloté par les signaux d'attributs + TweenService : aucun
-- travail par frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local UiTheme = require(script.Parent.UiTheme)
local ClientState = require(script.Parent.Parent.state.ClientState)

local SurvivalHudView = {}

local mounted = false

local Colors = UiTheme.Colors

-- Doit rester aligné sur GameConstants.STAGE_THRESHOLDS (serveur, non répliqué).
local STAGE_LARVE = 10
local STAGE_COCON = 50
local STAGE_ADULTE = 75
-- Doit rester aligné sur GrowthAndNestService : la croissance se fige sous 20 de Faim/Soif.
local GROWTH_PAUSE_THRESHOLD = 20
-- Seuil d'alerte visuelle (pulsation rouge) des jauges Faim / Soif / Oxygène.
local LOW_STAT_THRESHOLD = 25

local STAGE_NAMES: { [string]: string } = {
	Oeuf = "Œuf",
	Larve = "Larve",
	Mue = "Mue",
	Cocon = "Cocon",
	Adulte = "Adulte",
}

local BANNER_HIDDEN = UDim2.new(0.5, 0, 0.15, 0)
local BANNER_SHOWN = UDim2.new(0.5, 0, 0.2, 0)
local BANNER_SECONDS = 5

type Bar = {
	Container: Frame,
	Value: TextLabel,
	Track: Frame,
	Fill: Frame,
	Stroke: UIStroke,
	Pulse: Tween,
	Ratio: number,
	Color: Color3,
	Warn: boolean,
}

-- Construit une jauge (titre à gauche, valeur à droite, piste + remplissage).
local function createBar(parent: Instance, order: number, title: string): Bar
	local container = Instance.new("Frame")
	container.Name = title .. "Bar"
	container.Size = UDim2.new(1, 0, 0, 28)
	container.BackgroundTransparency = 1
	container.LayoutOrder = order
	container.Parent = parent

	local label = UiTheme.Label(container, Enum.Font.GothamBold, 12, Colors.Text)
	label.Name = "Label"
	label.Size = UDim2.new(0.5, 0, 0, 14)
	label.Text = title

	local value = UiTheme.Label(container, Enum.Font.GothamMedium, 12, Colors.Muted)
	value.Name = "Value"
	value.Position = UDim2.new(0.4, 0, 0, 0)
	value.Size = UDim2.new(0.6, 0, 0, 14)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 0, 0, 17)
	track.Size = UDim2.new(1, 0, 0, 9)
	track.BackgroundColor3 = Colors.Track
	track.BorderSizePixel = 0
	track.Parent = container
	UiTheme.Corner(track, 5)
	local stroke = UiTheme.Stroke(track, Colors.Danger, 1.5, 1)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Colors.Accent
	fill.Parent = track
	UiTheme.Corner(fill, 5)

	-- Pulsation d'alerte : un seul tween en boucle, créé une fois, joué/annulé à la demande.
	local pulse = TweenService:Create(
		stroke,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0 }
	)

	return {
		Container = container,
		Value = value,
		Track = track,
		Fill = fill,
		Stroke = stroke,
		Pulse = pulse,
		Ratio = 1,
		Color = Colors.Accent,
		Warn = false,
	}
end

-- Met à jour une jauge : ne tweene (et n'alloue) que ce qui a réellement changé.
local function setBar(bar: Bar, ratio: number, color: Color3, valueText: string, warn: boolean)
	bar.Value.Text = valueText
	if math.abs(ratio - bar.Ratio) > 0.001 then
		bar.Ratio = ratio
		UiTheme.Tween(bar.Fill, 0.35, { Size = UDim2.new(ratio, 0, 1, 0) })
	end
	if color ~= bar.Color then
		bar.Color = color
		UiTheme.Tween(bar.Fill, 0.35, { BackgroundColor3 = color })
	end
	if warn ~= bar.Warn then
		bar.Warn = warn
		bar.Value.TextColor3 = if warn then Colors.Danger else Colors.Muted
		if warn then
			bar.Pulse:Play()
		else
			bar.Pulse:Cancel()
			bar.Stroke.Transparency = 1
		end
	end
end

-- Petit repère vertical posé sur une piste (paliers de croissance, bornes de température idéale).
local function createTick(track: Frame): Frame
	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.AnchorPoint = Vector2.new(0.5, 0)
	tick.Size = UDim2.new(0, 2, 1, 0)
	tick.BackgroundColor3 = Color3.new(1, 1, 1)
	tick.BackgroundTransparency = 0.35
	tick.BorderSizePixel = 0
	tick.ZIndex = 3
	tick.Parent = track
	return tick
end

-- Échelle d'affichage fixe de la température (-20°C à 50°C).
local function tempRatio(temperature: number): number
	return math.clamp((temperature + 20) / 70, 0, 1)
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

	-- Tactile sans clavier : le stick virtuel occupe le bas-gauche, le HUD passe en haut-gauche
	-- (sous la barre Roblox). Sinon : bas-gauche comme sur PC.
	local touchOnly = UiTheme.IsTouchOnly()

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	if touchOnly then
		panel.AnchorPoint = Vector2.new(0, 0)
		panel.Position = UDim2.new(0, 12, 0, 64)
	else
		panel.AnchorPoint = Vector2.new(0, 1)
		panel.Position = UDim2.new(0, 16, 1, -16)
	end
	panel.Size = UDim2.new(0, 236, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Colors.Panel
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Parent = screenGui
	UiTheme.Corner(panel, 10)
	UiTheme.Stroke(panel, Color3.new(1, 1, 1), 1, 0.88)
	UiTheme.Padding(panel, 10, 8)

	local panelScale = Instance.new("UIScale")
	panelScale.Parent = panel
	UiTheme.OnViewportChanged(function(size: Vector2)
		if touchOnly then
			panelScale.Scale = math.clamp(size.Y / 560, 0.55, 1)
		else
			panelScale.Scale = math.clamp(size.Y / 760, 0.75, 1.2)
		end
	end)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = panel

	local speciesLabel = UiTheme.Label(panel, Enum.Font.GothamBlack, 14, Colors.Text)
	speciesLabel.Name = "SpeciesLabel"
	speciesLabel.Size = UDim2.new(1, 0, 0, 18)
	speciesLabel.LayoutOrder = 0
	speciesLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local hungerBar = createBar(panel, 1, "Faim")
	local thirstBar = createBar(panel, 2, "Soif")
	local tempBar = createBar(panel, 3, "Température")
	local oxygenBar = createBar(panel, 4, "Oxygène")
	local growthBar = createBar(panel, 5, "Croissance")

	local idealMinTick = createTick(tempBar.Track)
	local idealMaxTick = createTick(tempBar.Track)

	local larveTick = createTick(growthBar.Track)
	larveTick.Position = UDim2.new(STAGE_LARVE / 100, 0, 0, 0)
	local coconTick = createTick(growthBar.Track)
	coconTick.Position = UDim2.new(STAGE_COCON / 100, 0, 0, 0)
	local adulteTick = createTick(growthBar.Track)
	adulteTick.Position = UDim2.new(STAGE_ADULTE / 100, 0, 0, 0)

	local hintLabel = UiTheme.Label(panel, Enum.Font.Gotham, 11, Colors.Muted)
	hintLabel.Name = "GrowthHint"
	hintLabel.Size = UDim2.new(1, 0, 0, 14)
	hintLabel.LayoutOrder = 6
	hintLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.Size = UDim2.new(1, 0, 0, 16)
	footer.BackgroundTransparency = 1
	footer.LayoutOrder = 7
	footer.Parent = panel

	local seasonLabel = UiTheme.Label(footer, Enum.Font.GothamMedium, 12, Colors.Text)
	seasonLabel.Name = "SeasonLabel"
	seasonLabel.Size = UDim2.new(0.7, 0, 1, 0)

	local clockLabel = UiTheme.Label(footer, Enum.Font.GothamMedium, 12, Colors.Muted)
	clockLabel.Name = "ClockLabel"
	clockLabel.Position = UDim2.new(0.7, 0, 0, 0)
	clockLabel.Size = UDim2.new(0.3, 0, 1, 0)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- ---------- Bannière de changement de saison (haut-centre) ----------
	local banner = Instance.new("CanvasGroup")
	banner.Name = "SeasonBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = BANNER_HIDDEN
	banner.Size = UDim2.fromOffset(440, 88)
	banner.BackgroundColor3 = Colors.Panel
	banner.BackgroundTransparency = 0.1
	banner.BorderSizePixel = 0
	banner.GroupTransparency = 1
	banner.Visible = false
	banner.Parent = screenGui
	UiTheme.Corner(banner, 12)
	UiTheme.BindScale(banner, 480, 320, 0.6, 1.2)

	local bannerTitle = UiTheme.Label(banner, Enum.Font.GothamBlack, 24, Colors.Text)
	bannerTitle.Position = UDim2.fromOffset(12, 8)
	bannerTitle.Size = UDim2.new(1, -24, 0, 32)
	bannerTitle.TextXAlignment = Enum.TextXAlignment.Center

	local bannerBody = UiTheme.Label(banner, Enum.Font.Gotham, 13, Colors.Muted)
	bannerBody.Position = UDim2.fromOffset(14, 42)
	bannerBody.Size = UDim2.new(1, -28, 0, 38)
	bannerBody.TextXAlignment = Enum.TextXAlignment.Center
	bannerBody.TextYAlignment = Enum.TextYAlignment.Top
	bannerBody.TextWrapped = true

	local bannerSequence = 0
	local function showSeasonBanner(title: string, body: string)
		bannerSequence += 1
		local mySequence = bannerSequence
		bannerTitle.Text = title
		bannerBody.Text = body
		banner.Position = BANNER_HIDDEN
		banner.Visible = true
		UiTheme.Tween(banner, 0.45, { GroupTransparency = 0, Position = BANNER_SHOWN }, Enum.EasingStyle.Back)
		task.delay(BANNER_SECONDS, function()
			if bannerSequence ~= mySequence then
				return
			end
			local fadeOut = UiTheme.Tween(banner, 0.5, { GroupTransparency = 1, Position = BANNER_HIDDEN })
			fadeOut.Completed:Wait()
			if bannerSequence == mySequence then
				banner.Visible = false
			end
		end)
	end

	-- ---------- Rafraîchissements ----------
	local function speciesInfo(): InsectData.InsectInfo?
		local speciesId = player:GetAttribute("Species")
		return if typeof(speciesId) == "string" then InsectData[speciesId] else nil
	end

	local function numberAttribute(name: string, fallback: number): number
		local value = player:GetAttribute(name)
		return if typeof(value) == "number" then value else fallback
	end

	-- Faim / Soif / Oxygène : 0..100, vert -> ambre (< 50) -> rouge pulsant (< 25).
	local function updatePercentBar(bar: Bar, value: number): number
		local clamped = math.clamp(value, 0, 100)
		local color = if clamped >= 50 then Colors.Accent elseif clamped >= LOW_STAT_THRESHOLD then Colors.Warning else Colors.Danger
		setBar(bar, clamped / 100, color, tostring(math.floor(clamped)), clamped < LOW_STAT_THRESHOLD)
		return clamped
	end

	local function refreshGrowth()
		local growth = math.clamp(numberAttribute("Growth", 0), 0, 100)
		local stage = player:GetAttribute("Stage")
		local stageName = (typeof(stage) == "string" and STAGE_NAMES[stage]) or "Œuf"
		if player:GetAttribute("IsMolting") == true then
			stageName = "Mue"
		end
		setBar(growthBar, growth / 100, Colors.Accent, string.format("%s · %d%%", stageName, math.floor(growth)), false)

		local info = speciesInfo()
		local metamorphosis = info == nil or info.GrowthType == "Metamorphose"
		local starving = numberAttribute("Hunger", 100) < GROWTH_PAUSE_THRESHOLD
			or numberAttribute("Thirst", 100) < GROWTH_PAUSE_THRESHOLD

		local hint: string
		local hintColor = Colors.Muted
		if stage == "Oeuf" and growth == 0 and player:GetAttribute("HasConfirmedSpawn") ~= true then
			hint = "Choisissez une espèce ou un nid pour éclore"
		elseif starving and stage ~= "Cocon" and growth < 100 then
			hint = "Croissance en pause : mangez et buvez !"
			hintColor = Colors.Warning
		elseif growth < STAGE_LARVE then
			hint = string.format("Prochain stade : Larve à %d%%", STAGE_LARVE)
		elseif growth < STAGE_COCON and metamorphosis then
			hint = string.format("Prochain stade : Cocon à %d%%", STAGE_COCON)
		elseif growth < STAGE_ADULTE then
			if stage == "Cocon" then
				hint = string.format("Métamorphose… Adulte à %d%%", STAGE_ADULTE)
			elseif metamorphosis then
				hint = string.format("Prochain stade : Adulte à %d%%", STAGE_ADULTE)
			else
				hint = string.format("Mues successives… Adulte à %d%%", STAGE_ADULTE)
			end
		elseif growth < 100 then
			hint = "Adulte : colonie possible à 100%"
		elseif player:GetAttribute("IsMother") == true then
			hint = "Maman : votre nid accueille les œufs"
		else
			hint = "Croissance max : fondez une colonie !"
			hintColor = Colors.Accent
		end
		hintLabel.Text = hint
		hintLabel.TextColor3 = hintColor
	end

	local function refreshHunger()
		updatePercentBar(hungerBar, numberAttribute("Hunger", 0))
		refreshGrowth() -- l'indice "croissance en pause" dépend de la faim
	end
	local function refreshThirst()
		updatePercentBar(thirstBar, numberAttribute("Thirst", 0))
		refreshGrowth()
	end
	local function refreshOxygen()
		local oxygen = updatePercentBar(oxygenBar, numberAttribute("Oxygen", 100))
		-- Jauge masquée tant qu'on respire normalement : le panneau reste compact.
		oxygenBar.Container.Visible = oxygen < 99.5
	end

	-- Température : bleu -> vert -> rouge selon la zone idéale de l'espèce active.
	local function refreshTemperature()
		local bodyTemp = numberAttribute("BodyTemperature", 22)
		local info = speciesInfo()
		local idealMin = if info then info.IdealTempMin else 10
		local idealMax = if info then info.IdealTempMax else 30

		local color = Colors.Accent
		local state = "idéal"
		if bodyTemp < idealMin then
			color = Colors.Accent:Lerp(Colors.Cold, math.clamp((idealMin - bodyTemp) / 15, 0, 1))
			state = "trop froid"
		elseif bodyTemp > idealMax then
			color = Colors.Accent:Lerp(Colors.Danger, math.clamp((bodyTemp - idealMax) / 15, 0, 1))
			state = "trop chaud"
		end
		setBar(
			tempBar,
			tempRatio(bodyTemp),
			color,
			string.format("%d°C · %s", math.floor(bodyTemp), state),
			state ~= "idéal"
		)
	end

	local function refreshSpecies()
		local info = speciesInfo()
		speciesLabel.Text = if info then info.Name else "Micro Wild"
		idealMinTick.Position = UDim2.new(tempRatio(if info then info.IdealTempMin else 10), 0, 0, 0)
		idealMaxTick.Position = UDim2.new(tempRatio(if info then info.IdealTempMax else 30), 0, 0, 0)
		coconTick.Visible = info == nil or info.GrowthType == "Metamorphose"
		refreshTemperature()
		refreshGrowth()
	end

	-- Flash blanc de la jauge de croissance à chaque changement de stade (hors retour à l'œuf).
	local lastStage = player:GetAttribute("Stage")
	local function onStageChanged()
		local stage = player:GetAttribute("Stage")
		if stage ~= lastStage and stage ~= "Oeuf" then
			growthBar.Fill.BackgroundColor3 = Color3.new(1, 1, 1)
			UiTheme.Tween(growthBar.Fill, 0.9, { BackgroundColor3 = Colors.Accent })
		end
		lastStage = stage
		refreshGrowth()
	end

	local lastSeasonId = workspace:GetAttribute("CurrentSeason")
	local function refreshSeason()
		local seasonId = workspace:GetAttribute("CurrentSeason")
		local seasonInfo = if typeof(seasonId) == "string" then SeasonConfig.Seasons[seasonId] else nil
		local displayName = workspace:GetAttribute("SeasonDisplayName")
		if typeof(displayName) ~= "string" then
			displayName = if seasonInfo then seasonInfo.DisplayName else tostring(seasonId or "?")
		end
		seasonLabel.Text = displayName :: string

		if typeof(seasonId) == "string" then
			ClientState.CurrentSeason = seasonId
			-- Bannière uniquement sur un vrai changement (pas à la première réplication).
			if lastSeasonId ~= nil and seasonId ~= lastSeasonId and seasonInfo then
				showSeasonBanner(seasonInfo.DisplayName, seasonInfo.Description)
				-- Fondu d'apparition du nouveau nom de saison dans le pied du panneau.
				seasonLabel.TextTransparency = 1
				UiTheme.Tween(seasonLabel, 0.8, { TextTransparency = 0 })
			end
			lastSeasonId = seasonId
		end
	end

	refreshHunger()
	refreshThirst()
	refreshOxygen()
	refreshSpecies()
	refreshSeason()

	player:GetAttributeChangedSignal("Hunger"):Connect(refreshHunger)
	player:GetAttributeChangedSignal("Thirst"):Connect(refreshThirst)
	player:GetAttributeChangedSignal("Oxygen"):Connect(refreshOxygen)
	player:GetAttributeChangedSignal("BodyTemperature"):Connect(refreshTemperature)
	player:GetAttributeChangedSignal("Species"):Connect(refreshSpecies)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("Stage"):Connect(onStageChanged)
	player:GetAttributeChangedSignal("IsMolting"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("IsMother"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("HasConfirmedSpawn"):Connect(refreshGrowth)
	workspace:GetAttributeChangedSignal("CurrentSeason"):Connect(refreshSeason)
	workspace:GetAttributeChangedSignal("SeasonDisplayName"):Connect(refreshSeason)

	-- Horloge : une vérification par seconde, et le texte n'est reformaté que si la minute change.
	task.spawn(function()
		local lastMinuteOfDay = -1
		while true do
			local minuteOfDay = math.floor(Lighting.ClockTime * 60)
			if minuteOfDay ~= lastMinuteOfDay then
				lastMinuteOfDay = minuteOfDay
				clockLabel.Text = string.format("%02d:%02d", minuteOfDay // 60, minuteOfDay % 60)
			end
			task.wait(1)
		end
	end)
end

return SurvivalHudView
