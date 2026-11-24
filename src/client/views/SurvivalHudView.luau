--!strict
-- SurvivalHudView.luau
-- HUD de survie au style organique « Micro Wild » :
--   * Portrait 3D en temps réel de l'insecte du joueur (espèce, stade actuel Œuf/Larve/Mue/Cocon/Adulte et mutation)
--     qui pivote avec un rebond fluide à chaque évolution ou changement d'espèce
--   * Jauges animées (Faim, Soif, Température avec bande de zone idéale, Oxygène dynamique, Croissance)
--   * Pied de panneau teinté selon la saison active + horloge jour/nuit
--   * Bannière cinématique de changement de saison
-- Aucun travail par frame hors des brèves transitions tweenées.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local UiTheme = require(script.Parent.UiTheme)
local CreatureViewport = require(script.Parent.CreatureViewport)
local ClientState = require(script.Parent.Parent.state.ClientState)

local SurvivalHudView = {}

local mounted = false

local Colors = UiTheme.Colors

-- Doit rester aligné sur GameConstants.STAGE_THRESHOLDS (serveur, non répliqué).
local STAGE_LARVE = 10
local STAGE_COCON = 50
local STAGE_ADULTE = 75
local GROWTH_PAUSE_THRESHOLD = 20
local LOW_STAT_THRESHOLD = 25
local CRITICAL_THRESHOLD = 15

local STAGE_NAMES: { [string]: string } = {
	Oeuf = "🥚 Œuf",
	Larve = "🐛 Larve",
	Mue = "🦎 Mue",
	Cocon = "🐚 Cocon",
	Adulte = "🪲 Adulte",
}

local BANNER_HIDDEN = UDim2.new(0.5, 0, 0.13, 0)
local BANNER_SHOWN = UDim2.new(0.5, 0, 0.19, 0)
local BANNER_SECONDS = 5

-- Traîne pâle qui rattrape la jauge après une perte (lecture immédiate des dégâts/consommation).
local GHOST_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.35)
local PULSE_INFO = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

type Bar = {
	Container: Frame,
	Value: TextLabel,
	Track: Frame,
	Fill: Frame,
	Ghost: Frame,
	Stroke: UIStroke,
	Pulse: Tween,
	Ratio: number,
	Color: Color3,
	Warn: boolean,
}

local function createBar(parent: Instance, order: number, title: string): Bar
	local container = Instance.new("Frame")
	container.Name = title .. "Bar"
	container.Size = UDim2.new(1, 0, 0, 28)
	container.BackgroundTransparency = 1
	container.LayoutOrder = order
	container.Parent = parent

	local label = UiTheme.Label(container, Enum.Font.GothamBold, 12, Colors.Text)
	label.Name = "Label"
	label.Size = UDim2.new(0.52, 0, 0, 14)
	label.Text = title

	local value = UiTheme.Label(container, Enum.Font.GothamBold, 11, Colors.Muted)
	value.Name = "Value"
	value.Position = UDim2.new(0.42, 0, 0, 0)
	value.Size = UDim2.new(0.58, 0, 0, 14)
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

	local ghost = Instance.new("Frame")
	ghost.Name = "Ghost"
	ghost.Size = UDim2.new(1, 0, 1, 0)
	ghost.BorderSizePixel = 0
	ghost.BackgroundColor3 = Color3.fromRGB(255, 236, 210)
	ghost.BackgroundTransparency = 0.55
	ghost.ZIndex = 2
	ghost.Parent = track
	UiTheme.Corner(ghost, 5)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Colors.Accent
	fill.ZIndex = 3
	fill.Parent = track
	UiTheme.Corner(fill, 5)

	-- Léger reflet organique sur le haut de la barre.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.new(1, 0, 0.45, 0)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.82
	shine.BorderSizePixel = 0
	shine.Parent = fill
	UiTheme.Corner(shine, 5)

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
		Ghost = ghost,
		Stroke = stroke,
		Pulse = pulse,
		Ratio = 1,
		Color = Colors.Accent,
		Warn = false,
	}
end

local function setBar(bar: Bar, ratio: number, color: Color3, valueText: string, warn: boolean)
	bar.Value.Text = valueText
	if math.abs(ratio - bar.Ratio) > 0.001 then
		local target = UDim2.new(ratio, 0, 1, 0)
		if ratio < bar.Ratio - 0.03 then
			-- Perte nette (coup, chute) : la traîne reste un instant à l'ancienne valeur puis glisse.
			-- Les petites baisses régulières (faim) la font suivre directement, sinon le délai la figerait.
			TweenService:Create(bar.Ghost, GHOST_INFO, { Size = target }):Play()
		else
			UiTheme.Tween(bar.Ghost, 0.35, { Size = target }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		end
		bar.Ratio = ratio
		UiTheme.Tween(bar.Fill, 0.35, { Size = target }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
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

local function createTick(track: Frame): Frame
	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.AnchorPoint = Vector2.new(0.5, 0)
	tick.Size = UDim2.new(0, 2, 1, 0)
	tick.BackgroundColor3 = Color3.new(1, 1, 1)
	tick.BackgroundTransparency = 0.28
	tick.BorderSizePixel = 0
	tick.ZIndex = 4
	tick.Parent = track
	return tick
end

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
	-- Garde le panneau hors des encoches / coins arrondis des téléphones.
	screenGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	screenGui.Parent = playerGui

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
	panel.Size = UDim2.new(0, 248, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundTransparency = 0.1
	panel.Parent = screenGui
	local panelStroke = UiTheme.StylePanel(panel, 13, Colors.Border, 0.45)
	UiTheme.Padding(panel, 11, 10)

	local panelShown = panel.Position
	local panelHidden = UDim2.new(panelShown.X.Scale, panelShown.X.Offset - 420, panelShown.Y.Scale, panelShown.Y.Offset)

	local panelScale = Instance.new("UIScale")
	panelScale.Parent = panel
	UiTheme.OnViewportChanged(function(size: Vector2)
		if touchOnly then
			panelScale.Scale = math.clamp(size.Y / 580, 0.55, 1)
		else
			panelScale.Scale = math.clamp(size.Y / 760, 0.75, 1.2)
		end
	end)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = panel

	-- ---------- En-tête avec Portrait 3D en temps réel ----------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 50)
	header.BackgroundTransparency = 1
	header.LayoutOrder = 0
	header.Parent = panel

	local portraitBox = Instance.new("Frame")
	portraitBox.Name = "Portrait3D"
	portraitBox.Size = UDim2.fromOffset(48, 48)
	portraitBox.Position = UDim2.fromOffset(0, 1)
	portraitBox.BackgroundColor3 = Colors.PanelDeep
	portraitBox.BorderSizePixel = 0
	portraitBox.Parent = header
	UiTheme.Corner(portraitBox, 10)
	local portraitStroke = UiTheme.Stroke(portraitBox, Colors.Accent, 1.5, 0.35)

	local portrait3D = CreatureViewport.Create(portraitBox, false, 1.04)

	local speciesLabel = UiTheme.Label(header, Enum.Font.GothamBlack, 14, Colors.Text)
	speciesLabel.Name = "SpeciesLabel"
	speciesLabel.Position = UDim2.fromOffset(56, 4)
	speciesLabel.Size = UDim2.new(1, -56, 0, 18)
	speciesLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local stageBadge = UiTheme.Label(header, Enum.Font.GothamBold, 11, Colors.Accent)
	stageBadge.Name = "StageBadge"
	stageBadge.Position = UDim2.fromOffset(56, 25)
	stageBadge.Size = UDim2.fromOffset(112, 19)
	stageBadge.BackgroundTransparency = 0
	stageBadge.BackgroundColor3 = Colors.CardSelected
	stageBadge.TextXAlignment = Enum.TextXAlignment.Center
	UiTheme.Corner(stageBadge, 6)
	local stageBadgeStroke = UiTheme.Stroke(stageBadge, Colors.Accent, 1, 0.55)

	-- ---------- Jauges ----------
	local hungerBar = createBar(panel, 1, "🍖 Faim")
	local thirstBar = createBar(panel, 2, "💧 Soif")
	local tempBar = createBar(panel, 3, "🌡️ Température")
	local oxygenBar = createBar(panel, 4, "🫧 Oxygène")
	local growthBar = createBar(panel, 5, "🌱 Croissance")
	local boostBar = createBar(panel, 6, "⚡ Boost (Shift)")
	local levelBar = createBar(panel, 7, "⭐ Niveau 1")

	-- Bande visuelle de la zone de température idéale sur la piste de Température
	local idealZone = Instance.new("Frame")
	idealZone.Name = "IdealZone"
	idealZone.BackgroundColor3 = Colors.Accent
	idealZone.BackgroundTransparency = 0.72
	idealZone.BorderSizePixel = 0
	idealZone.ZIndex = 1
	idealZone.Parent = tempBar.Track
	UiTheme.Corner(idealZone, 3)

	local idealMinTick = createTick(tempBar.Track)
	local idealMaxTick = createTick(tempBar.Track)

	local larveTick = createTick(growthBar.Track)
	larveTick.Position = UDim2.new(STAGE_LARVE / 100, 0, 0, 0)
	local coconTick = createTick(growthBar.Track)
	coconTick.Position = UDim2.new(STAGE_COCON / 100, 0, 0, 0)
	local adulteTick = createTick(growthBar.Track)
	adulteTick.Position = UDim2.new(STAGE_ADULTE / 100, 0, 0, 0)

	local hintLabel = UiTheme.Label(panel, Enum.Font.GothamMedium, 11, Colors.Muted)
	hintLabel.Name = "GrowthHint"
	hintLabel.Size = UDim2.new(1, 0, 0, 14)
	hintLabel.LayoutOrder = 6
	hintLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.Size = UDim2.new(1, 0, 0, 38)
	footer.BackgroundColor3 = Colors.Card
	footer.BackgroundTransparency = 0.25
	footer.BorderSizePixel = 0
	footer.LayoutOrder = 7
	footer.Parent = panel
	UiTheme.Corner(footer, 7)
	UiTheme.Padding(footer, 8, 3)

	local seasonLabel = UiTheme.Label(footer, Enum.Font.GothamBold, 11, Colors.Text)
	seasonLabel.Name = "SeasonLabel"
	seasonLabel.Size = UDim2.new(0.65, 0, 0, 15)

	local clockLabel = UiTheme.Label(footer, Enum.Font.GothamBold, 11, Colors.Muted)
	clockLabel.Name = "ClockLabel"
	clockLabel.Position = UDim2.new(0.65, 0, 0, 0)
	clockLabel.Size = UDim2.new(0.35, 0, 0, 15)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Right

	local windLabel = UiTheme.Label(footer, Enum.Font.GothamMedium, 11, Colors.Muted)
	windLabel.Name = "WindLabel"
	windLabel.Position = UDim2.new(0, 0, 0, 17)
	windLabel.Size = UDim2.new(1, 0, 0, 15)
	windLabel.Text = "💨 Vent : Calme"

	-- ---------- Bannière de changement de saison (haut-centre) ----------
	local banner = Instance.new("CanvasGroup")
	banner.Name = "SeasonBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = BANNER_HIDDEN
	banner.Size = UDim2.fromOffset(450, 92)
	banner.BackgroundColor3 = Color3.new(1, 1, 1)
	banner.BackgroundTransparency = 0.06
	banner.BorderSizePixel = 0
	banner.GroupTransparency = 1
	banner.Visible = false
	banner.Parent = screenGui
	UiTheme.Corner(banner, 14)
	local bannerGradient = UiTheme.Gradient(banner, Colors.PanelTop, Colors.PanelDeep, 95)
	local bannerStroke = UiTheme.Stroke(banner, Colors.Accent, 1.5, 0.35)
	UiTheme.BindScale(banner, 480, 320, 0.6, 1.2)

	local bannerTitle = UiTheme.Label(banner, Enum.Font.GothamBlack, 24, Colors.Text)
	bannerTitle.Position = UDim2.fromOffset(14, 10)
	bannerTitle.Size = UDim2.new(1, -28, 0, 32)
	bannerTitle.TextXAlignment = Enum.TextXAlignment.Center

	local bannerBody = UiTheme.Label(banner, Enum.Font.GothamMedium, 13, Colors.Muted)
	bannerBody.Position = UDim2.fromOffset(16, 44)
	bannerBody.Size = UDim2.new(1, -32, 0, 38)
	bannerBody.TextXAlignment = Enum.TextXAlignment.Center
	bannerBody.TextYAlignment = Enum.TextYAlignment.Top
	bannerBody.TextWrapped = true

	local bannerSequence = 0
	local function showSeasonBanner(seasonId: string, titleText: string, bodyText: string)
		bannerSequence += 1
		local mySequence = bannerSequence
		local palette = UiTheme.GetSeasonPalette(seasonId)
		bannerTitle.Text = titleText
		bannerTitle.TextColor3 = palette.Accent
		bannerBody.Text = bodyText
		bannerStroke.Color = palette.Accent
		bannerGradient.Color = ColorSequence.new(palette.Tint, Colors.PanelDeep)
		banner.Position = BANNER_HIDDEN
		banner.Visible = true
		UiTheme.Tween(banner, 0.48, { GroupTransparency = 0, Position = BANNER_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		task.delay(BANNER_SECONDS, function()
			if bannerSequence ~= mySequence then
				return
			end
			local fadeOut = UiTheme.Tween(banner, 0.45, { GroupTransparency = 1, Position = BANNER_HIDDEN })
			fadeOut.Completed:Wait()
			if bannerSequence == mySequence then
				banner.Visible = false
			end
		end)
	end

	-- ---------- Vignette d'alerte vitale (bords d'écran pulsants) ----------
	-- 4 bandes en dégradé plutôt qu'un CanvasGroup plein écran (trop coûteux en mémoire sur mobile).
	local EDGES: { { Position: UDim2, Size: UDim2, Rotation: number } } = {
		{ Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.16), Rotation = 90 },
		{ Position = UDim2.fromScale(0, 0.84), Size = UDim2.fromScale(1, 0.16), Rotation = -90 },
		{ Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(0.1, 1), Rotation = 0 },
		{ Position = UDim2.fromScale(0.9, 0), Size = UDim2.fromScale(0.1, 1), Rotation = 180 },
	}
	local vignetteTransparency = NumberSequence.new(0, 1)
	local vignetteEdges: { Frame } = {}
	local vignettePulses: { Tween } = {}
	for index, edge in ipairs(EDGES) do
		local frame = Instance.new("Frame")
		frame.Name = "DangerEdge" .. index
		frame.Position = edge.Position
		frame.Size = edge.Size
		frame.BackgroundColor3 = Colors.Danger
		frame.BackgroundTransparency = 0.75
		frame.BorderSizePixel = 0
		frame.Active = false
		frame.Visible = false
		frame.ZIndex = 0
		frame.Parent = screenGui
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = edge.Rotation
		gradient.Transparency = vignetteTransparency
		gradient.Parent = frame
		table.insert(vignetteEdges, frame)
		table.insert(vignettePulses, TweenService:Create(frame, PULSE_INFO, { BackgroundTransparency = 0.45 }))
	end

	local dangerOn = false
	local function setDanger(on: boolean)
		if on == dangerOn then
			return
		end
		dangerOn = on
		for index, frame in ipairs(vignetteEdges) do
			frame.Visible = on
			if on then
				frame.BackgroundTransparency = 0.75
				vignettePulses[index]:Play()
			else
				vignettePulses[index]:Cancel()
			end
		end
	end

	-- ---------- Effacement derrière le menu de spawn ----------
	local menuToken = 0
	local function applyMenuState(inMenu: boolean)
		menuToken += 1
		local myToken = menuToken
		if inMenu then
			UiTheme.Tween(panel, 0.28, { Position = panelHidden }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Once(function()
				if menuToken == myToken then
					panel.Visible = false
				end
			end)
		else
			panel.Visible = true
			UiTheme.Tween(panel, 0.4, { Position = panelShown }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end
	ClientState.MenuChanged.Event:Connect(applyMenuState)
	if ClientState.IsInMenu then
		panel.Position = panelHidden
		panel.Visible = false
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

	local function updatePercentBar(bar: Bar, value: number): number
		local clamped = math.clamp(value, 0, 100)
		local color = if clamped >= 50 then Colors.Accent elseif clamped >= LOW_STAT_THRESHOLD then Colors.Warning else Colors.Danger
		setBar(bar, clamped / 100, color, tostring(math.floor(clamped)) .. "%", clamped < LOW_STAT_THRESHOLD)
		return clamped
	end

	local lastPortraitSig = ""
	local function refreshPortrait3D(spin: boolean)
		local speciesId = player:GetAttribute("Species")
		local actualSpecies = if typeof(speciesId) == "string" and InsectData[speciesId] then speciesId else "FourmiRousse"
		local stageAttr = player:GetAttribute("Stage")
		local actualStage = if typeof(stageAttr) == "string" then stageAttr else "Oeuf"
		if player:GetAttribute("IsMolting") == true then
			actualStage = "Mue"
		end
		local mutationAttr = player:GetAttribute("Mutation")
		local mutationId = if typeof(mutationAttr) == "string" and mutationAttr ~= "" then mutationAttr else nil
		local sig = string.format("%s|%s|%s", actualSpecies, actualStage, tostring(mutationId))
		if sig ~= lastPortraitSig then
			lastPortraitSig = sig
			portrait3D.SetCreature(actualSpecies, actualStage, mutationId, false)
			if spin then
				portrait3D.SpinOnce()
			end
		end
	end

	local function refreshGrowth()
		local growth = math.clamp(numberAttribute("Growth", 0), 0, 100)
		local stage = player:GetAttribute("Stage")
		local stageKey = if typeof(stage) == "string" then stage else "Oeuf"
		if player:GetAttribute("IsMolting") == true then
			stageKey = "Mue"
		end
		local stageName = STAGE_NAMES[stageKey] or "🥚 Œuf"
		local isMother = player:GetAttribute("IsMother") == true
		stageBadge.Text = if isMother then "👑 Maman · 100%" else string.format("%s · %d%%", stageName, math.floor(growth))
		local badgeColor = if isMother then Colors.Gold else Colors.Accent
		stageBadge.TextColor3 = badgeColor
		stageBadgeStroke.Color = badgeColor
		portraitStroke.Color = badgeColor

		setBar(growthBar, growth / 100, badgeColor, string.format("%d%%", math.floor(growth)), false)

		local info = speciesInfo()
		local metamorphosis = info == nil or info.GrowthType == "Metamorphose"
		local starving = numberAttribute("Hunger", 100) < GROWTH_PAUSE_THRESHOLD
			or numberAttribute("Thirst", 100) < GROWTH_PAUSE_THRESHOLD

		local hint: string
		local hintColor = Colors.Muted
		if stage == "Oeuf" and growth == 0 and player:GetAttribute("HasConfirmedSpawn") ~= true then
			hint = "🥚 Choisissez une espèce ou un nid pour éclore"
		elseif starving and stage ~= "Cocon" and growth < 100 then
			hint = "⚠ Croissance en pause : mangez et buvez !"
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
		elseif isMother then
			hint = "👑 Maman : votre nid accueille les œufs"
			hintColor = Colors.Gold
		else
			hint = "✨ Croissance max : fondez une colonie !"
			hintColor = Colors.Accent
		end
		hintLabel.Text = hint
		hintLabel.TextColor3 = hintColor
	end

	local function refreshDanger()
		setDanger(
			numberAttribute("Hunger", 100) < CRITICAL_THRESHOLD
				or numberAttribute("Thirst", 100) < CRITICAL_THRESHOLD
				or numberAttribute("Oxygen", 100) < CRITICAL_THRESHOLD
		)
	end

	local function refreshHunger()
		updatePercentBar(hungerBar, numberAttribute("Hunger", 0))
		refreshGrowth()
		refreshDanger()
	end
	local function refreshThirst()
		updatePercentBar(thirstBar, numberAttribute("Thirst", 0))
		refreshGrowth()
		refreshDanger()
	end
	local function refreshOxygen()
		local oxygen = updatePercentBar(oxygenBar, numberAttribute("Oxygen", 100))
		oxygenBar.Container.Visible = oxygen < 99.5
		refreshDanger()
	end

	-- Jauge de boost (MovementService) : masquée quand pleine.
	local function refreshBoost()
		local energy = math.clamp(numberAttribute("BoostEnergy", 1), 0, 1)
		setBar(boostBar, energy, if energy > 0.25 then Colors.Accent else Colors.Warning, tostring(math.floor(energy * 100)), false)
		boostBar.Container.Visible = energy < 0.995
	end

	-- Niveau + XP vers le niveau suivant (chasser et manger).
	local function refreshLevel()
		local level = math.max(1, math.floor(numberAttribute("Level", 1)))
		local xp = numberAttribute("XP", 0)
		local nextXp = numberAttribute("XPNext", 0)
		local label = levelBar.Container:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = "⭐ Niveau " .. level
		end
		if nextXp > 0 then
			setBar(levelBar, math.clamp(xp / nextXp, 0, 1), Colors.Accent, string.format("%d / %d XP", xp, nextXp), false)
		else
			setBar(levelBar, 1, Colors.Warning, "MAX", false)
		end
	end

	local function refreshTemperature()
		local bodyTemp = numberAttribute("BodyTemperature", 22)
		local info = speciesInfo()
		local idealMin = if info then info.IdealTempMin else 10
		local idealMax = if info then info.IdealTempMax else 30

		local color = Colors.Accent
		local state = "idéal"
		if bodyTemp < idealMin then
			color = Colors.Accent:Lerp(Colors.Cold, math.clamp((idealMin - bodyTemp) / 15, 0, 1))
			state = "froid"
		elseif bodyTemp > idealMax then
			color = Colors.Accent:Lerp(Colors.Danger, math.clamp((bodyTemp - idealMax) / 15, 0, 1))
			state = "chaud"
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
		local minR = tempRatio(if info then info.IdealTempMin else 10)
		local maxR = tempRatio(if info then info.IdealTempMax else 30)
		idealMinTick.Position = UDim2.new(minR, 0, 0, 0)
		idealMaxTick.Position = UDim2.new(maxR, 0, 0, 0)
		idealZone.Position = UDim2.new(minR, 0, 0, 0)
		idealZone.Size = UDim2.new(math.max(0.02, maxR - minR), 0, 1, 0)
		coconTick.Visible = info == nil or info.GrowthType == "Metamorphose"
		refreshTemperature()
		refreshGrowth()
		refreshPortrait3D(true)
	end

	local lastStage = player:GetAttribute("Stage")
	local function onStageChanged()
		local stage = player:GetAttribute("Stage")
		if stage ~= lastStage and stage ~= "Oeuf" then
			growthBar.Fill.BackgroundColor3 = Color3.new(1, 1, 1)
			UiTheme.Tween(growthBar.Fill, 0.9, { BackgroundColor3 = Colors.Accent })
			UiTheme.Pop(stageBadge, 0.85, 0.3)
		end
		lastStage = stage
		refreshGrowth()
		refreshPortrait3D(true)
	end

	local lastSeasonId = workspace:GetAttribute("CurrentSeason")
	local function refreshSeason()
		local seasonId = workspace:GetAttribute("CurrentSeason")
		local seasonInfo = if typeof(seasonId) == "string" then SeasonConfig.Seasons[seasonId] else nil
		local displayName = workspace:GetAttribute("SeasonDisplayName")
		if typeof(displayName) ~= "string" then
			displayName = if seasonInfo then seasonInfo.DisplayName else tostring(seasonId or "?")
		end
		local palette = UiTheme.GetSeasonPalette(if typeof(seasonId) == "string" then seasonId else nil)
		seasonLabel.Text = displayName :: string
		seasonLabel.TextColor3 = palette.Accent
		UiTheme.Tween(panelStroke, 0.5, { Color = palette.Accent:Lerp(Colors.Border, 0.5) })

		if typeof(seasonId) == "string" then
			ClientState.CurrentSeason = seasonId
			if lastSeasonId ~= nil and seasonId ~= lastSeasonId and seasonInfo then
				showSeasonBanner(seasonId, seasonInfo.DisplayName, seasonInfo.Description)
				seasonLabel.TextTransparency = 1
				UiTheme.Tween(seasonLabel, 0.8, { TextTransparency = 0 })
			end
			lastSeasonId = seasonId
		end
	end

	local COMPASS_ARROWS = { "→", "↘", "↓", "↙", "←", "↖", "↑", "↗" }
	local function refreshWind()
		if player:GetAttribute("InShelterOrColony") == true then
			windLabel.Text = "🏠 À l'abri (vent & pluie)"
			windLabel.TextColor3 = Colors.Accent
			return
		end
		local precip = workspace:GetAttribute("Precipitation")
		local rainAttr = workspace:GetAttribute("RainIntensity")
		local rainIntensity = if typeof(rainAttr) == "number" then rainAttr else 0
		local isHeavyRain = workspace:GetAttribute("RainHeavy") == true or rainIntensity >= 0.7
		local rainPrefix = ""
		if precip == "Rain" and rainIntensity > 0.03 then
			if isHeavyRain then
				rainPrefix = "⛈️ Déluge · "
			elseif rainIntensity >= 0.42 then
				rainPrefix = "🌧️ Averse · "
			else
				rainPrefix = "🌦️ Pluie fine · "
			end
		elseif precip == "Snow" then
			rainPrefix = "🌨️ Neige · "
		end

		local windAttr = workspace:GetAttribute("WindVector")
		local wind = if typeof(windAttr) == "Vector3" then windAttr else Vector3.zero
		local speed = Vector3.new(wind.X, 0, wind.Z).Magnitude
		if speed < 1.5 then
			windLabel.Text = rainPrefix .. "💨 Vent : Calme"
			windLabel.TextColor3 = if isHeavyRain
				then Colors.Warning
				elseif rainPrefix ~= "" then Colors.Cold
				else Colors.Muted
			return
		end
		local angle = math.atan2(wind.Z, wind.X)
		local sector = (math.floor((angle / (math.pi * 2)) * 8 + 0.5) % 8) + 1
		local arrow = COMPASS_ARROWS[sector] or "→"
		local isGust = workspace:GetAttribute("WindGust") == true or speed >= 19
		local stateText = if isGust
			then "Rafale !"
			elseif speed >= 13 then "Vent fort"
			else "Brise"
		windLabel.Text = string.format("%s💨 %s %s (%d km/h)", rainPrefix, stateText, arrow, math.floor(speed * 2.2))
		windLabel.TextColor3 = if isGust or isHeavyRain
			then Colors.Warning
			elseif speed >= 13 or rainPrefix ~= "" then Colors.Cold
			else Colors.Muted
	end

	refreshHunger()
	refreshThirst()
	refreshOxygen()
	refreshBoost()
	refreshLevel()
	refreshSpecies()
	refreshPortrait3D(false)
	refreshSeason()
	refreshWind()

	player:GetAttributeChangedSignal("Hunger"):Connect(refreshHunger)
	player:GetAttributeChangedSignal("Thirst"):Connect(refreshThirst)
	player:GetAttributeChangedSignal("Oxygen"):Connect(refreshOxygen)
	player:GetAttributeChangedSignal("BoostEnergy"):Connect(refreshBoost)
	for _, attribute in ipairs({ "Level", "XP", "XPNext" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refreshLevel)
	end
	player:GetAttributeChangedSignal("BodyTemperature"):Connect(refreshTemperature)
	player:GetAttributeChangedSignal("Species"):Connect(refreshSpecies)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("Stage"):Connect(onStageChanged)
	player:GetAttributeChangedSignal("IsMolting"):Connect(function()
		refreshGrowth()
		refreshPortrait3D(true)
	end)
	player:GetAttributeChangedSignal("Mutation"):Connect(function()
		refreshPortrait3D(true)
	end)
	player:GetAttributeChangedSignal("IsMother"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("HasConfirmedSpawn"):Connect(refreshGrowth)
	player:GetAttributeChangedSignal("InShelterOrColony"):Connect(refreshWind)
	workspace:GetAttributeChangedSignal("CurrentSeason"):Connect(refreshSeason)
	workspace:GetAttributeChangedSignal("SeasonDisplayName"):Connect(refreshSeason)
	workspace:GetAttributeChangedSignal("WindVector"):Connect(refreshWind)
	workspace:GetAttributeChangedSignal("WindGust"):Connect(refreshWind)
	workspace:GetAttributeChangedSignal("Precipitation"):Connect(refreshWind)
	workspace:GetAttributeChangedSignal("RainIntensity"):Connect(refreshWind)
	workspace:GetAttributeChangedSignal("RainHeavy"):Connect(refreshWind)

	task.spawn(function()
		local lastMinuteOfDay = -1
		while true do
			local minuteOfDay = math.floor(Lighting.ClockTime * 60)
			if minuteOfDay ~= lastMinuteOfDay then
				lastMinuteOfDay = minuteOfDay
				local hour = minuteOfDay // 60
				local isDay = hour >= 6 and hour < 19
				clockLabel.Text = string.format("%s %02d:%02d", if isDay then "☀️" else "🌙", hour, minuteOfDay % 60)
			end
			task.wait(1)
		end
	end)
end

return SurvivalHudView
