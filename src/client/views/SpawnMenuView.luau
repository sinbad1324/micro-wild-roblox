--!strict
-- SpawnMenuView.luau
-- Menu de spawn (GDD §2 "Spawn" / §8.2) : thème organique « Micro Wild », miniatures 3D sur chaque
-- carte d'espèce et de nid, vitrine 3D interactive (rotation au glisser + plateau tournant + socle
-- de biome) avec sélecteur de stade (Œuf / Larve / Cocon ou Mue / Adulte) et jauges de stats animées.
-- Responsive : paysage (grille à gauche, fiche 3D à droite) ou portrait (fiche 3D en bas).
-- Le plateau tournant 3D est coupé dès que le menu est fermé : aucun coût par frame en jeu.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local UiTheme = require(script.Parent.UiTheme)
local CreatureViewport = require(script.Parent.CreatureViewport)
local ClientState = require(script.Parent.Parent.state.ClientState)

type NestSummary = {
	OwnerUserId: number,
	OwnerName: string,
	SpeciesId: string,
	ChildCount: number,
	IsNpc: boolean?,
	MotherAlive: boolean?,
	Biome: string?,
}

type MenuMode = "Species" | "Nest" | "Mother"

local SpawnMenuView = {}

local mounted = false

local Colors = UiTheme.Colors

local CATEGORIES = { "Tous", "Terrestre", "Volant", "Aquatique", "Animal" }
local CATEGORY_ICONS: { [string]: string } = {
	Tous = "🌿 Tous",
	Terrestre = "🪵 Terrestre",
	Volant = "🍃 Volant",
	Aquatique = "💧 Aquatique",
	Animal = "🐿️ Animaux",
}
local DIET_COLORS: { [string]: Color3 } = {
	Herbivore = Colors.Accent,
	Carnivore = Colors.Danger,
	Omnivore = Colors.Warning,
}
local SLOT_LABELS: { [string]: string } = { LeftClick = "Clic", E = "E", R = "R", F = "F" }

-- Tailles de conception (avant UIScale) des deux mises en page.
local LANDSCAPE_SIZE = Vector2.new(780, 480)
local PORTRAIT_SIZE = Vector2.new(420, 680)
local PORTRAIT_DETAIL_HEIGHT = 248
local FILTER_ROW_HEIGHT = 30
local PAGES_TOP = 90

local ROOT_SHOWN = UDim2.fromScale(0.5, 0.5)
local ROOT_HIDDEN = UDim2.new(0.5, 0, 0.5, 32)
local ROOT_OFFSCREEN = UDim2.fromScale(0.5, 1.6)

-- Bornes max pour normaliser les jauges comparatives de la fiche espèce.
local MAX_HP_STAT = 280
local MAX_SPEED_STAT = 32
local MAX_DMG_STAT = 45

local function sortedSpeciesList(): { InsectData.InsectInfo }
	local list: { InsectData.InsectInfo } = {}
	for _, info in pairs(InsectData) do
		table.insert(list, info)
	end
	local categoryOrder: { [string]: number } = { Terrestre = 1, Volant = 2, Aquatique = 3, Animal = 4 }
	table.sort(list, function(a, b)
		local orderA = categoryOrder[a.Category] or 99
		local orderB = categoryOrder[b.Category] or 99
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.Name < b.Name
	end)
	return list
end

local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return spaced
end

local function traitSummary(info: InsectData.InsectInfo): string
	local traits = {}
	if info.CanClimbWalls then
		table.insert(traits, "Grimpe")
	end
	if info.CanFly then
		table.insert(traits, "Vole")
	end
	if info.CanSwim then
		table.insert(traits, "Nage")
	end
	if info.CanWalkOnWater then
		table.insert(traits, "Patine")
	end
	if #traits == 0 then
		return "Marcheur"
	end
	return table.concat(traits, " · ")
end

local function abilitySummary(info: InsectData.InsectInfo): string
	local actives = {}
	local passives = {}
	for _, id in ipairs(info.Abilities) do
		local definition = AbilityCatalog[id]
		if definition then
			local slotLabel = SLOT_LABELS[definition.Slot]
			if slotLabel then
				table.insert(actives, string.format("[%s] %s", slotLabel, prettify(id)))
			elseif definition.Slot == "Passive" then
				table.insert(passives, prettify(id))
			end
		end
	end
	local text = table.concat(actives, "  ")
	if #passives > 0 then
		if text ~= "" then
			text ..= " · "
		end
		text ..= "Passif : " .. table.concat(passives, ", ")
	end
	return text
end

local function activeAbilityLine(info: InsectData.InsectInfo): string
	local parts = {}
	for _, id in ipairs(info.Abilities) do
		local definition = AbilityCatalog[id]
		local slotLabel = if definition then SLOT_LABELS[definition.Slot] else nil
		if slotLabel then
			table.insert(parts, slotLabel .. " " .. prettify(id))
		end
	end
	return if #parts > 0 then table.concat(parts, " · ") else "Aucun pouvoir actif"
end

local function makePill(parent: Instance, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = Colors.Card
	button.BorderSizePixel = 0
	button.LayoutOrder = order
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.TextColor3 = Colors.Text
	button.Text = text
	button.Parent = parent
	UiTheme.Corner(button, 8)
	UiTheme.Stroke(button, Colors.Border, 1, 0.72)
	UiTheme.BindButtonFX(button, 1.04, 0.94)
	return button
end

local function setPillActive(button: TextButton, active: boolean, activeColor: Color3?, darkText: Color3?)
	local fill = activeColor or Colors.Accent
	local textCol = darkText or Colors.AccentDark
	UiTheme.Tween(button, 0.18, {
		BackgroundColor3 = if active then fill else Colors.Card,
		TextColor3 = if active then textCol else Colors.Text,
	})
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		UiTheme.Tween(stroke, 0.18, {
			Color = if active then fill else Colors.Border,
			Transparency = if active then 0.15 else 0.72,
		})
	end
end

local function makeScrollingPage(parent: Instance): ScrollingFrame
	local page = Instance.new("ScrollingFrame")
	page.BackgroundTransparency = 1
	page.Size = UDim2.new(1, 0, 1, 0)
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 5
	page.ScrollBarImageColor3 = Colors.Accent
	page.ScrollBarImageTransparency = 0.35
	page.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.Parent = parent
	UiTheme.Padding(page, 4, 4)
	return page
end

type SpeciesCard = {
	Button: TextButton,
	Scale: UIScale,
	Stroke: UIStroke,
	ViewportFrame: Frame,
	Info: InsectData.InsectInfo,
	SearchName: string,
}

type MiniStatBar = {
	Fill: Frame,
	ValueLabel: TextLabel,
}

function SpawnMenuView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SpawnMenuView"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	-- Voile forestier sombre derrière le panneau.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(6, 12, 8)
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screenGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = ROOT_SHOWN
	root.Size = UDim2.fromOffset(LANDSCAPE_SIZE.X, LANDSCAPE_SIZE.Y)
	root.BackgroundTransparency = 0.03
	root.Parent = screenGui
	UiTheme.StylePanel(root, 16, Colors.Border, 0.4)
	UiTheme.Padding(root, 16, 14)

	-- Liseré supérieur lumineux (effet bioluminescent).
	local topAccent = Instance.new("Frame")
	topAccent.Name = "TopAccent"
	topAccent.AnchorPoint = Vector2.new(0.5, 0)
	topAccent.Position = UDim2.new(0.5, 0, 0, -6)
	topAccent.Size = UDim2.new(0.45, 0, 0, 3)
	topAccent.BackgroundColor3 = Colors.Accent
	topAccent.BackgroundTransparency = 0.25
	topAccent.BorderSizePixel = 0
	topAccent.Parent = root
	UiTheme.Corner(topAccent, 2)

	local rootScale = Instance.new("UIScale")
	rootScale.Parent = root

	-- ---------- En-tête ----------
	local headerBadge = Instance.new("Frame")
	headerBadge.Name = "HeaderBadge"
	headerBadge.Size = UDim2.fromOffset(30, 30)
	headerBadge.Position = UDim2.fromOffset(0, 2)
	headerBadge.BackgroundColor3 = Colors.CardSelected
	headerBadge.BorderSizePixel = 0
	headerBadge.Parent = root
	UiTheme.Corner(headerBadge, 9)
	UiTheme.Stroke(headerBadge, Colors.Accent, 1.5, 0.35)

	local badgeIcon = UiTheme.Label(headerBadge, Enum.Font.GothamBlack, 17, Colors.Accent)
	badgeIcon.Size = UDim2.fromScale(1, 1)
	badgeIcon.TextXAlignment = Enum.TextXAlignment.Center
	badgeIcon.Text = "🪲"

	local title = UiTheme.Label(root, Enum.Font.GothamBlack, 20, Colors.Text)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(38, 0)
	title.Size = UDim2.new(1, -40, 0, 22)
	title.Text = "MICRO WILD — Choisissez votre incarnation"

	local subtitle = UiTheme.Label(root, Enum.Font.GothamMedium, 12, Colors.Muted)
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromOffset(38, 22)
	subtitle.Size = UDim2.new(1, -40, 0, 16)
	subtitle.TextTruncate = Enum.TextTruncate.AtEnd
	subtitle.Text = "Chaque vie commence dans un œuf : restez au chaud, puis mangez pour grandir."

	-- ---------- Onglets "Mon espèce" / "Nids" / "Être Maman" avec curseur glissant ----------
	local tabBar = Instance.new("Frame")
	tabBar.Name = "Tabs"
	tabBar.BackgroundColor3 = Colors.Track
	tabBar.BackgroundTransparency = 0.2
	tabBar.BorderSizePixel = 0
	tabBar.Position = UDim2.fromOffset(0, 46)
	tabBar.Size = UDim2.new(1, 0, 0, 34)
	tabBar.Parent = root
	UiTheme.Corner(tabBar, 10)
	UiTheme.Stroke(tabBar, Colors.Border, 1, 0.7)
	UiTheme.Padding(tabBar, 3, 3)

	-- Curseur animé qui glisse sous l'onglet actif.
	local tabIndicator = Instance.new("Frame")
	tabIndicator.Name = "Indicator"
	tabIndicator.Size = UDim2.new(1 / 3, -4, 1, 0)
	tabIndicator.Position = UDim2.fromScale(0, 0)
	tabIndicator.BackgroundColor3 = Colors.Accent
	tabIndicator.BorderSizePixel = 0
	tabIndicator.ZIndex = 1
	tabIndicator.Parent = tabBar
	UiTheme.Corner(tabIndicator, 8)

	local function makeTab(text: string, order: number): TextButton
		local button = Instance.new("TextButton")
		button.AutoButtonColor = false
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.LayoutOrder = order
		button.Position = UDim2.new((order - 1) / 3, 2, 0, 0)
		button.Size = UDim2.new(1 / 3, -4, 1, 0)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 13
		button.TextColor3 = Colors.Text
		button.TextTruncate = Enum.TextTruncate.AtEnd
		button.Text = text
		button.ZIndex = 2
		button.Parent = tabBar
		UiTheme.BindButtonFX(button, 1.02, 0.96)
		return button
	end
	local speciesTabButton = makeTab("🥚 Mon espèce", 1)
	local nestTabButton = makeTab("🪺 Dans un nid (0)", 2)
	local motherTabButton = makeTab("👑 Être une Maman", 3)

	local pageContainer = Instance.new("Frame")
	pageContainer.Name = "Pages"
	pageContainer.BackgroundTransparency = 1
	pageContainer.Position = UDim2.fromOffset(0, PAGES_TOP)
	pageContainer.Size = UDim2.new(1, 0, 1, -PAGES_TOP)
	pageContainer.Parent = root

	-- ================= Page 1 : espèces + vitrine 3D =================
	local speciesPage = Instance.new("Frame")
	speciesPage.Name = "SpeciesPage"
	speciesPage.BackgroundTransparency = 1
	speciesPage.Size = UDim2.fromScale(1, 1)
	speciesPage.Parent = pageContainer

	local filterRow = Instance.new("Frame")
	filterRow.Name = "Filters"
	filterRow.BackgroundTransparency = 1
	filterRow.Size = UDim2.new(0.56, 0, 0, FILTER_ROW_HEIGHT)
	filterRow.Parent = speciesPage

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Padding = UDim.new(0, 6)
	filterLayout.Parent = filterRow

	local categoryButtons: { [string]: TextButton } = {}
	for index, category in ipairs(CATEGORIES) do
		local button = makePill(filterRow, CATEGORY_ICONS[category] or category, index)
		button.Size = UDim2.new(0, if category == "Tous" then 68 else 86, 1, 0)
		button.TextSize = 11
		categoryButtons[category] = button
	end

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "Search"
	searchBox.LayoutOrder = #CATEGORIES + 1
	searchBox.Size = UDim2.new(0, 92, 1, 0)
	searchBox.BackgroundColor3 = Colors.Track
	searchBox.BorderSizePixel = 0
	searchBox.ClearTextOnFocus = false
	searchBox.Font = Enum.Font.GothamMedium
	searchBox.TextSize = 12
	searchBox.TextColor3 = Colors.Text
	searchBox.PlaceholderText = "🔍 Filtrer…"
	searchBox.PlaceholderColor3 = Colors.Muted
	searchBox.Text = ""
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.TextTruncate = Enum.TextTruncate.AtEnd
	searchBox.Parent = filterRow
	UiTheme.Corner(searchBox, 8)
	UiTheme.Stroke(searchBox, Colors.Border, 1, 0.72)
	UiTheme.Padding(searchBox, 8, 0)

	local grid = makeScrollingPage(speciesPage)
	grid.Name = "Grid"
	grid.Position = UDim2.fromOffset(0, FILTER_ROW_HEIGHT + 8)

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.CellSize = UDim2.new(0.5, -6, 0, 88)
	gridLayout.Parent = grid

	local emptyLabel = UiTheme.Label(speciesPage, Enum.Font.GothamMedium, 13, Colors.Muted)
	emptyLabel.Name = "Empty"
	emptyLabel.Position = UDim2.fromOffset(6, FILTER_ROW_HEIGHT + 16)
	emptyLabel.Size = UDim2.new(0.56, -12, 0, 20)
	emptyLabel.Text = "Aucune espèce ne correspond à votre recherche."
	emptyLabel.Visible = false

	-- ---------- Fiche détaillée à droite avec Vitrine 3D interactive ----------
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.BackgroundColor3 = Color3.new(1, 1, 1)
	detail.BorderSizePixel = 0
	detail.Parent = speciesPage
	UiTheme.Corner(detail, 12)
	UiTheme.Gradient(detail, Colors.CardTop, Colors.PanelDeep, 95)
	UiTheme.Stroke(detail, Colors.Border, 1.5, 0.45)
	UiTheme.Padding(detail, 12, 10)

	-- En-tête de la fiche (nom + tags régime/catégorie)
	local detailName = UiTheme.Label(detail, Enum.Font.GothamBlack, 17, Colors.Text)
	detailName.Name = "Name"
	detailName.Size = UDim2.new(1, 0, 0, 20)
	detailName.TextTruncate = Enum.TextTruncate.AtEnd

	local detailTags = UiTheme.Label(detail, Enum.Font.GothamBold, 11, Colors.Accent)
	detailTags.Name = "Tags"
	detailTags.Position = UDim2.fromOffset(0, 20)
	detailTags.Size = UDim2.new(1, 0, 0, 15)
	detailTags.TextTruncate = Enum.TextTruncate.AtEnd

	-- Cadre de la vitrine 3D interactive
	local previewBox = Instance.new("Frame")
	previewBox.Name = "Preview3DBox"
	previewBox.Position = UDim2.fromOffset(0, 38)
	previewBox.Size = UDim2.new(1, 0, 0, 138)
	previewBox.BackgroundColor3 = Color3.new(1, 1, 1)
	previewBox.BorderSizePixel = 0
	previewBox.ClipsDescendants = true
	previewBox.Parent = detail
	UiTheme.Corner(previewBox, 10)
	UiTheme.Gradient(previewBox, Color3.fromRGB(28, 48, 34), Color3.fromRGB(12, 20, 15), 90)
	local previewStroke = UiTheme.Stroke(previewBox, Colors.Accent, 1, 0.55)

	local showcase3D = CreatureViewport.Create(previewBox, true, 1.02)

	-- Indice "↻ Glisser pour tourner 3D"
	local rotateHint = UiTheme.Label(previewBox, Enum.Font.GothamMedium, 10, Colors.Muted)
	rotateHint.Name = "RotateHint"
	rotateHint.AnchorPoint = Vector2.new(1, 0)
	rotateHint.Position = UDim2.new(1, -6, 0, 4)
	rotateHint.Size = UDim2.fromOffset(120, 14)
	rotateHint.TextXAlignment = Enum.TextXAlignment.Right
	rotateHint.TextTransparency = 0.2
	rotateHint.Text = "↻ Glisser en 3D"

	-- Sélecteur de stade 3D superposé au bas de la vitrine (Œuf / Larve / Cocon ou Mue / Adulte)
	local stageBar = Instance.new("Frame")
	stageBar.Name = "StageSelector"
	stageBar.AnchorPoint = Vector2.new(0.5, 1)
	stageBar.Position = UDim2.new(0.5, 0, 1, -5)
	stageBar.Size = UDim2.new(1, -10, 0, 22)
	stageBar.BackgroundTransparency = 1
	stageBar.ZIndex = 3
	stageBar.Parent = previewBox

	local stageBarLayout = Instance.new("UIListLayout")
	stageBarLayout.FillDirection = Enum.FillDirection.Horizontal
	stageBarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stageBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stageBarLayout.Padding = UDim.new(0, 4)
	stageBarLayout.Parent = stageBar

	local previewStage = "Adulte"
	local stageButtons: { [string]: TextButton } = {}
	local STAGE_ORDER = { "Oeuf", "Larve", "Mid", "Adulte" }
	local STAGE_SHORT_LABELS: { [string]: string } = {
		Oeuf = "🥚 Œuf",
		Larve = "🐛 Larve",
		Mid = "🐚 Cocon",
		Adulte = "🪲 Adulte",
	}
	for idx, key in ipairs(STAGE_ORDER) do
		local btn = Instance.new("TextButton")
		btn.Name = key
		btn.LayoutOrder = idx
		btn.AutoButtonColor = false
		btn.Size = UDim2.new(0.25, -4, 1, 0)
		btn.BackgroundColor3 = Colors.PanelDeep
		btn.BackgroundTransparency = 0.2
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 10
		btn.TextColor3 = Colors.Text
		btn.Text = STAGE_SHORT_LABELS[key]
		btn.ZIndex = 4
		btn.Parent = stageBar
		UiTheme.Corner(btn, 6)
		UiTheme.Stroke(btn, Colors.Border, 1, 0.6)
		UiTheme.BindButtonFX(btn, 1.05, 0.93)
		stageButtons[key] = btn
	end

	-- Mini jauges comparatives (PV, Vitesse, Dégâts, Température idéale)
	local statsGrid = Instance.new("Frame")
	statsGrid.Name = "StatsGrid"
	statsGrid.Position = UDim2.fromOffset(0, 180)
	statsGrid.Size = UDim2.new(1, 0, 0, 42)
	statsGrid.BackgroundTransparency = 1
	statsGrid.Parent = detail

	local function createMiniStat(col: number, row: number, labelText: string, barColor: Color3): MiniStatBar
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.Position = UDim2.new((col - 1) * 0.5, if col == 2 then 4 else 0, (row - 1) * 0.5, 0)
		cell.Size = UDim2.new(0.5, -4, 0, 19)
		cell.Parent = statsGrid

		local lbl = UiTheme.Label(cell, Enum.Font.GothamBold, 10, Colors.Muted)
		lbl.Size = UDim2.new(0.55, 0, 0, 11)
		lbl.Text = labelText

		local val = UiTheme.Label(cell, Enum.Font.GothamBold, 10, Colors.Text)
		val.Position = UDim2.new(0.45, 0, 0, 0)
		val.Size = UDim2.new(0.55, 0, 0, 11)
		val.TextXAlignment = Enum.TextXAlignment.Right

		local track = Instance.new("Frame")
		track.Position = UDim2.fromOffset(0, 13)
		track.Size = UDim2.new(1, 0, 0, 5)
		track.BackgroundColor3 = Colors.Track
		track.BorderSizePixel = 0
		track.Parent = cell
		UiTheme.Corner(track, 3)

		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = barColor
		fill.BorderSizePixel = 0
		fill.Parent = track
		UiTheme.Corner(fill, 3)

		return { Fill = fill, ValueLabel = val }
	end

	local hpStat = createMiniStat(1, 1, "♥ PV", Colors.Accent)
	local speedStat = createMiniStat(2, 1, "⚡ Vitesse", Colors.Info)
	local dmgStat = createMiniStat(1, 2, "⚔ Dégâts", Colors.Danger)
	local tempStat = createMiniStat(2, 2, "🌡 Temp. idéale", Colors.Warning)

	local detailBody = UiTheme.Label(detail, Enum.Font.Gotham, 11, Colors.Text)
	detailBody.Name = "Body"
	detailBody.Position = UDim2.fromOffset(0, 226)
	detailBody.Size = UDim2.new(1, 0, 1, -(226 + 48))
	detailBody.TextWrapped = true
	detailBody.TextYAlignment = Enum.TextYAlignment.Top
	detailBody.TextTruncate = Enum.TextTruncate.AtEnd
	detailBody.TextTransparency = 0.08

	local confirmButton = Instance.new("TextButton")
	confirmButton.Name = "Confirm"
	confirmButton.AnchorPoint = Vector2.new(0, 1)
	confirmButton.Position = UDim2.fromScale(0, 1)
	confirmButton.Size = UDim2.new(1, 0, 0, 42)
	confirmButton.BackgroundColor3 = Colors.Accent
	confirmButton.BorderSizePixel = 0
	confirmButton.AutoButtonColor = false
	confirmButton.Font = Enum.Font.GothamBlack
	confirmButton.TextSize = 15
	confirmButton.TextColor3 = Colors.AccentDark
	confirmButton.TextTruncate = Enum.TextTruncate.AtEnd
	confirmButton.Text = "🥚 Éclore"
	confirmButton.Parent = detail
	UiTheme.Corner(confirmButton, 10)
	local confirmStroke = UiTheme.Stroke(confirmButton, Color3.new(1, 1, 1), 1.5, 0.55)
	UiTheme.BindButtonFX(confirmButton, 1.025, 0.95)

	local confirmPulse = TweenService:Create(
		confirmStroke,
		TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.15 }
	)

	-- --- État de sélection et des cartes ---
	local cards: { [string]: SpeciesCard } = {}
	local speciesList = sortedSpeciesList()
	local selectedId: string? = nil
	local activeCategory = "Tous"
	local mode: MenuMode = "Species"
	local confirmLocked = false
	local joinLocked = false
	local lastConfirmedMode: MenuMode = "Species"
	local pendingMode: MenuMode = "Species"
	local shown = false
	local cooldownTicking = false

	local function motherUnlockState(): boolean?
		local unlocked = player:GetAttribute("MotherSpawnUnlocked")
		return if typeof(unlocked) == "boolean" then unlocked else nil
	end

	local function motherCooldownLeft(): number
		local readyAt = player:GetAttribute("MotherSpawnReadyAt")
		if typeof(readyAt) ~= "number" then
			return 0
		end
		return readyAt - workspace:GetServerTimeNow()
	end

	-- Résout la clé "Mid" en "Cocon" ou "Mue" selon le type de croissance de l'espèce active.
	local function resolveStageKey(stageKey: string, info: InsectData.InsectInfo?): string
		if stageKey == "Mid" then
			return if info and info.GrowthType == "Mue" then "Mue" else "Cocon"
		end
		return stageKey
	end

	local function refreshStageSelector(info: InsectData.InsectInfo, spin: boolean)
		local isMolt = info.GrowthType == "Mue"
		stageButtons.Mid.Text = if isMolt then "🦎 Mue" else "🐚 Cocon"
		for key, btn in pairs(stageButtons) do
			local active = key == previewStage
			UiTheme.Tween(btn, 0.15, {
				BackgroundColor3 = if active then Colors.Accent else Colors.PanelDeep,
				BackgroundTransparency = if active then 0 else 0.25,
				TextColor3 = if active then Colors.AccentDark else Colors.Text,
			})
		end
		local actualStage = resolveStageKey(previewStage, info)
		local mutationId = player:GetAttribute("Mutation")
		showcase3D.SetCreature(info.Id, actualStage, if typeof(mutationId) == "string" then mutationId else nil, true)
		if spin then
			showcase3D.SpinOnce()
		end
	end

	for key, btn in pairs(stageButtons) do
		btn.MouseButton1Click:Connect(function()
			if previewStage == key then
				return
			end
			previewStage = key
			local card = if selectedId then cards[selectedId] else nil
			if card then
				refreshStageSelector(card.Info, true)
			end
		end)
	end

	local function refreshConfirmText()
		if confirmLocked then
			return
		end
		local card = if selectedId then cards[selectedId] else nil
		local speciesName = if card then card.Info.Name else ""
		local available = true
		local text: string
		if mode == "Mother" then
			local unlocked = motherUnlockState()
			if unlocked == nil then
				available = false
				text = "Chargement du profil…"
			elseif not unlocked then
				available = false
				text = string.format(
					"🔒 Devenez adulte 1× ou atteignez %d PE (vous : %d)",
					tonumber(player:GetAttribute("MotherSpawnMinPoints")) or 500,
					tonumber(player:GetAttribute("EvolutionPoints")) or 0
				)
			else
				local remaining = motherCooldownLeft()
				if remaining > 0 then
					available = false
					text = string.format("⏳ Maman disponible dans %d s", math.ceil(remaining))
					if not cooldownTicking then
						cooldownTicking = true
						task.delay(1, function()
							cooldownTicking = false
							if shown and mode == "Mother" then
								refreshConfirmText()
							end
						end)
					end
				else
					text = if card then "👑 Naître Maman : " .. speciesName else "👑 Naître Maman"
				end
			end
		else
			text = if card then "🥚 Éclore : " .. speciesName else "🥚 Éclore"
		end
		confirmButton.Text = text
		confirmButton.TextWrapped = not available
		confirmButton.TextSize = if available then 15 else 12
		confirmButton.Active = available
		local targetBg = if not available then Colors.Track elseif mode == "Mother" then Colors.Gold else Colors.Accent
		local targetFg = if not available then Colors.Muted elseif mode == "Mother" then Colors.GoldDark else Colors.AccentDark
		UiTheme.Tween(confirmButton, 0.18, {
			BackgroundColor3 = targetBg,
			TextColor3 = targetFg,
		})
	end

	local function selectSpecies(speciesId: string, forceSpin: boolean?)
		local card = cards[speciesId]
		if not card then
			return
		end
		local changed = selectedId ~= speciesId
		if not changed and not forceSpin then
			return
		end
		local previous = if selectedId and selectedId ~= speciesId then cards[selectedId] else nil
		if previous then
			UiTheme.Tween(previous.Button, 0.16, { BackgroundColor3 = Colors.Card })
			UiTheme.Tween(previous.Stroke, 0.16, { Color = Colors.Border, Transparency = 0.72 })
			UiTheme.Tween(previous.ViewportFrame, 0.16, { BackgroundColor3 = Colors.PanelDeep })
		end
		selectedId = speciesId
		ClientState.SelectedSpecies = speciesId
		local dietColor = DIET_COLORS[card.Info.Diet] or Colors.Accent
		UiTheme.Tween(card.Button, 0.18, { BackgroundColor3 = Colors.CardSelected })
		UiTheme.Tween(card.Stroke, 0.18, { Color = dietColor, Transparency = 0.05 })
		UiTheme.Tween(card.ViewportFrame, 0.18, { BackgroundColor3 = Colors.CardTop })
		UiTheme.Tween(previewStroke, 0.2, { Color = dietColor })

		local info = card.Info
		detailName.Text = info.Name
		detailTags.Text = string.format(
			"%s  ·  %s  ·  %s  ·  %s",
			info.Diet,
			info.Category,
			if info.GrowthType == "Metamorphose" then "Métamorphose" else "Mues",
			traitSummary(info)
		)
		detailTags.TextColor3 = dietColor

		-- Animation fluide des mini jauges de statistiques
		hpStat.ValueLabel.Text = tostring(info.MaxHealth)
		UiTheme.Tween(hpStat.Fill, 0.28, { Size = UDim2.fromScale(math.clamp(info.MaxHealth / MAX_HP_STAT, 0.08, 1), 1) })

		speedStat.ValueLabel.Text = tostring(info.WalkSpeed)
		UiTheme.Tween(speedStat.Fill, 0.28, { Size = UDim2.fromScale(math.clamp(info.WalkSpeed / MAX_SPEED_STAT, 0.08, 1), 1) })

		dmgStat.ValueLabel.Text = tostring(info.Damage)
		UiTheme.Tween(dmgStat.Fill, 0.28, { Size = UDim2.fromScale(math.clamp(info.Damage / MAX_DMG_STAT, 0.08, 1), 1) })

		tempStat.ValueLabel.Text = string.format("%d..%d°C", info.IdealTempMin, info.IdealTempMax)
		local tempSpan = math.clamp((info.IdealTempMax - info.IdealTempMin) / 40, 0.15, 1)
		UiTheme.Tween(tempStat.Fill, 0.28, { Size = UDim2.fromScale(tempSpan, 1) })

		detailBody.Text = string.format("%s\n%s", info.Description, abilitySummary(info))

		refreshStageSelector(info, changed or forceSpin == true)
		refreshConfirmText()
	end

	-- Construction des 30 cartes d'espèces avec miniature 3D
	for index, info in ipairs(speciesList) do
		local button = Instance.new("TextButton")
		button.Name = info.Id
		button.AutoButtonColor = false
		button.BackgroundColor3 = Colors.Card
		button.BorderSizePixel = 0
		button.LayoutOrder = index
		button.Text = ""
		button.Parent = grid
		UiTheme.Corner(button, 10)
		local stroke = UiTheme.Stroke(button, Colors.Border, 1.5, 0.72)
		local cardScale = UiTheme.BindButtonFX(button, 1.025, 0.96)

		-- Cadre miniature 3D à gauche de la carte
		local thumbBox = Instance.new("Frame")
		thumbBox.Name = "Thumb3D"
		thumbBox.AnchorPoint = Vector2.new(0, 0.5)
		thumbBox.Position = UDim2.new(0, 8, 0.5, 0)
		thumbBox.Size = UDim2.fromOffset(64, 68)
		thumbBox.BackgroundColor3 = Colors.PanelDeep
		thumbBox.BorderSizePixel = 0
		thumbBox.Parent = button
		UiTheme.Corner(thumbBox, 8)
		UiTheme.Stroke(thumbBox, DIET_COLORS[info.Diet] or Colors.Accent, 1, 0.65)

		local thumb3D = CreatureViewport.Create(thumbBox, false, 1.05)
		thumb3D.SetCreature(info.Id, "Adulte", nil, false)

		local textX = 80
		local nameLabel = UiTheme.Label(button, Enum.Font.GothamBold, 13, Colors.Text)
		nameLabel.Position = UDim2.fromOffset(textX, 8)
		nameLabel.Size = UDim2.new(1, -(textX + 8), 0, 17)
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Text = info.Name

		local dietLabel = UiTheme.Label(button, Enum.Font.GothamBold, 11, DIET_COLORS[info.Diet] or Colors.Accent)
		dietLabel.Position = UDim2.fromOffset(textX, 27)
		dietLabel.Size = UDim2.new(1, -(textX + 8), 0, 14)
		dietLabel.TextTruncate = Enum.TextTruncate.AtEnd
		dietLabel.Text = string.format("%s · %s", info.Diet, info.Category)

		local traitLabel = UiTheme.Label(button, Enum.Font.Gotham, 10, Colors.Muted)
		traitLabel.Position = UDim2.fromOffset(textX, 45)
		traitLabel.Size = UDim2.new(1, -(textX + 8), 0, 13)
		traitLabel.TextTruncate = Enum.TextTruncate.AtEnd
		traitLabel.Text = traitSummary(info)

		local abilityLabel = UiTheme.Label(button, Enum.Font.GothamMedium, 10, Colors.Text)
		abilityLabel.Position = UDim2.fromOffset(textX, 62)
		abilityLabel.Size = UDim2.new(1, -(textX + 8), 0, 13)
		abilityLabel.TextTruncate = Enum.TextTruncate.AtEnd
		abilityLabel.TextTransparency = 0.22
		abilityLabel.Text = activeAbilityLine(info)

		cards[info.Id] = {
			Button = button,
			Scale = cardScale,
			Stroke = stroke,
			ViewportFrame = thumbBox,
			Info = info,
			SearchName = string.lower(info.Name),
		}

		button.MouseEnter:Connect(function()
			if selectedId ~= info.Id then
				UiTheme.Tween(button, 0.14, { BackgroundColor3 = Colors.CardHover })
			end
		end)
		button.MouseLeave:Connect(function()
			if selectedId ~= info.Id then
				UiTheme.Tween(button, 0.14, { BackgroundColor3 = Colors.Card })
			end
		end)
		button.MouseButton1Click:Connect(function()
			selectSpecies(info.Id, true)
		end)
	end

	local function applyFilter()
		local query = string.lower(searchBox.Text)
		local anyVisible = false
		for _, card in pairs(cards) do
			local visible = (activeCategory == "Tous" or card.Info.Category == activeCategory)
				and (query == "" or string.find(card.SearchName, query, 1, true) ~= nil)
			card.Button.Visible = visible
			if visible then
				anyVisible = true
			end
		end
		emptyLabel.Visible = not anyVisible
		grid.CanvasPosition = Vector2.zero
	end

	for category, button in pairs(categoryButtons) do
		button.MouseButton1Click:Connect(function()
			if activeCategory == category then
				return
			end
			setPillActive(categoryButtons[activeCategory], false)
			activeCategory = category
			setPillActive(button, true)
			applyFilter()
		end)
	end
	setPillActive(categoryButtons[activeCategory], true)
	searchBox:GetPropertyChangedSignal("Text"):Connect(applyFilter)

	if cards[ClientState.SelectedSpecies] then
		selectSpecies(ClientState.SelectedSpecies, false)
	elseif speciesList[1] then
		selectSpecies(speciesList[1].Id, false)
	end

	confirmButton.MouseButton1Click:Connect(function()
		local speciesId = selectedId
		if confirmLocked or joinLocked or not speciesId then
			return
		end
		local asMother = mode == "Mother"
		if asMother and (motherUnlockState() ~= true or motherCooldownLeft() > 0) then
			return
		end
		confirmLocked = true
		pendingMode = mode
		confirmButton.Text = if asMother then "👑 Naissance en cours…" else "🥚 Éclosion en cours…"
		if asMother then
			Remotes.Get("RequestSpawnAsMother"):FireServer(speciesId)
		else
			Remotes.Get("RequestSelectSpecies"):FireServer(speciesId)
		end
		task.delay(1, function()
			confirmLocked = false
			refreshConfirmText()
		end)
	end)
	player:GetAttributeChangedSignal("MotherSpawnUnlocked"):Connect(refreshConfirmText)
	player:GetAttributeChangedSignal("EvolutionPoints"):Connect(function()
		if mode == "Mother" then
			refreshConfirmText()
		end
	end)
	player:GetAttributeChangedSignal("MotherSpawnReadyAt"):Connect(function()
		if mode == "Mother" then
			refreshConfirmText()
		end
	end)
	player:GetAttributeChangedSignal("Mutation"):Connect(function()
		local card = if selectedId then cards[selectedId] else nil
		if card and shown then
			refreshStageSelector(card.Info, true)
		end
	end)

	-- ================= Page 2 : nids avec aperçu 3D =================
	local nestPage = makeScrollingPage(pageContainer)
	nestPage.Name = "NestPage"
	nestPage.Visible = false

	local nestPageLayout = Instance.new("UIListLayout")
	nestPageLayout.SortOrder = Enum.SortOrder.LayoutOrder
	nestPageLayout.Padding = UDim.new(0, 8)
	nestPageLayout.Parent = nestPage

	local nestHint = UiTheme.Label(nestPage, Enum.Font.GothamMedium, 13, Colors.Text)
	nestHint.Name = "Hint"
	nestHint.LayoutOrder = 1
	nestHint.Size = UDim2.new(1, 0, 0, 0)
	nestHint.AutomaticSize = Enum.AutomaticSize.Y
	nestHint.BackgroundTransparency = 0
	nestHint.BackgroundColor3 = Colors.Card
	nestHint.TextWrapped = true
	nestHint.Text = "🪺 Naître dans le nid d'une Maman : vous héritez de son espèce et elle vous nourrit pour accélérer votre croissance.\n(Aucun nid actif ? Choisissez une espèce libre dans le premier onglet.)"
	UiTheme.Corner(nestHint, 10)
	UiTheme.Stroke(nestHint, Colors.Border, 1, 0.65)
	UiTheme.Padding(nestHint, 12, 10)

	local nestEmpty = UiTheme.Label(nestPage, Enum.Font.GothamMedium, 13, Colors.Muted)
	nestEmpty.Name = "Empty"
	nestEmpty.LayoutOrder = 2
	nestEmpty.Size = UDim2.new(1, 0, 0, 28)
	nestEmpty.TextXAlignment = Enum.TextXAlignment.Center
	nestEmpty.Text = "Aucune colonie active sur le serveur pour l'instant."

	local nestListContainer = Instance.new("Frame")
	nestListContainer.Name = "NestListContainer"
	nestListContainer.BackgroundTransparency = 1
	nestListContainer.AutomaticSize = Enum.AutomaticSize.Y
	nestListContainer.Size = UDim2.new(1, 0, 0, 0)
	nestListContainer.LayoutOrder = 3
	nestListContainer.Parent = nestPage

	local nestListLayout = Instance.new("UIListLayout")
	nestListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	nestListLayout.Padding = UDim.new(0, 6)
	nestListLayout.Parent = nestListContainer

	local function nestRank(summary: NestSummary): number
		if summary.IsNpc ~= true then
			return 1
		end
		return if summary.MotherAlive ~= false then 2 else 3
	end

	local lastNestSignature: string? = nil
	local function renderNestList(summaries: { NestSummary })
		local sorted: { NestSummary } = {}
		for _, summary in ipairs(summaries) do
			if typeof(summary) == "table" and typeof(summary.OwnerUserId) == "number" then
				table.insert(sorted, summary)
			end
		end
		table.sort(sorted, function(a, b)
			local rankA, rankB = nestRank(a), nestRank(b)
			if rankA ~= rankB then
				return rankA < rankB
			end
			local childrenA, childrenB = tonumber(a.ChildCount) or 0, tonumber(b.ChildCount) or 0
			if childrenA ~= childrenB then
				return childrenA < childrenB
			end
			return a.OwnerUserId < b.OwnerUserId
		end)
		local parts = table.create(#sorted)
		for _, summary in ipairs(sorted) do
			table.insert(parts, string.format("%s:%s:%s:%s:%s:%s", tostring(summary.OwnerUserId), tostring(summary.ChildCount), tostring(summary.MotherAlive), tostring(summary.SpeciesId), tostring(summary.OwnerName), tostring(summary.Biome)))
		end
		local signature = table.concat(parts, "|")
		if signature == lastNestSignature then
			return
		end
		lastNestSignature = signature

		for _, child in ipairs(nestListContainer:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local count = 0
		for index, summary in ipairs(sorted) do
			count += 1
			local speciesInfo = InsectData[summary.SpeciesId]
			local speciesName = if speciesInfo then speciesInfo.Name else tostring(summary.SpeciesId)
			local dietColor = if speciesInfo then (DIET_COLORS[speciesInfo.Diet] or Colors.Accent) else Colors.Accent

			local isNpc = summary.IsNpc == true
			local row = Instance.new("TextButton")
			row.Name = "Nest"
			row.AutoButtonColor = false
			row.BackgroundColor3 = Colors.Card
			row.BorderSizePixel = 0
			row.LayoutOrder = index
			row.Size = UDim2.new(1, 0, 0, 62)
			row.Text = ""
			row.Parent = nestListContainer
			UiTheme.Corner(row, 10)
			UiTheme.Stroke(row, Colors.Border, 1.5, 0.65)
			UiTheme.BindButtonFX(row, 1.015, 0.97)

			-- Miniature 3D de l'espèce de la Maman
			local nestThumb = Instance.new("Frame")
			nestThumb.Name = "NestThumb3D"
			nestThumb.AnchorPoint = Vector2.new(0, 0.5)
			nestThumb.Position = UDim2.new(0, 8, 0.5, 0)
			nestThumb.Size = UDim2.fromOffset(48, 48)
			nestThumb.BackgroundColor3 = Colors.PanelDeep
			nestThumb.BorderSizePixel = 0
			nestThumb.Parent = row
			UiTheme.Corner(nestThumb, 8)
			UiTheme.Stroke(nestThumb, dietColor, 1, 0.55)

			local nestPreview = CreatureViewport.Create(nestThumb, false, 1.08)
			nestPreview.SetCreature(summary.SpeciesId, "Adulte", nil, false)

			local nameX = 66
			if isNpc then
				local badge = UiTheme.Label(row, Enum.Font.GothamBold, 11, Colors.GoldDark)
				badge.Position = UDim2.fromOffset(66, 11)
				badge.Size = UDim2.fromOffset(36, 17)
				badge.BackgroundTransparency = 0
				badge.BackgroundColor3 = if summary.MotherAlive == false then Colors.Muted else Colors.Gold
				badge.TextXAlignment = Enum.TextXAlignment.Center
				badge.Text = "PNJ"
				UiTheme.Corner(badge, 5)
				nameX = 108
			else
				local badge = UiTheme.Label(row, Enum.Font.GothamBold, 11, Colors.AccentDark)
				badge.Position = UDim2.fromOffset(66, 11)
				badge.Size = UDim2.fromOffset(52, 17)
				badge.BackgroundTransparency = 0
				badge.BackgroundColor3 = Colors.Accent
				badge.TextXAlignment = Enum.TextXAlignment.Center
				badge.Text = "JOUEUR"
				UiTheme.Corner(badge, 5)
				nameX = 124
			end

			local nameLabel = UiTheme.Label(row, Enum.Font.GothamBold, 14, Colors.Text)
			nameLabel.Position = UDim2.fromOffset(nameX, 10)
			nameLabel.Size = UDim2.new(1, -(124 + nameX), 0, 18)
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Text = speciesName

			local ownerLabel = UiTheme.Label(row, Enum.Font.GothamMedium, 12, Colors.Muted)
			ownerLabel.Position = UDim2.fromOffset(66, 33)
			ownerLabel.Size = UDim2.new(1, -184, 0, 16)
			ownerLabel.TextTruncate = Enum.TextTruncate.AtEnd
			local biomeName = summary.Biome
			local biome = if typeof(biomeName) == "string" then "  ·  📍 " .. biomeName else ""
			ownerLabel.Text = string.format(
				"👑 %s  ·  🥚 %d bébé(s)%s",
				tostring(summary.OwnerName),
				tonumber(summary.ChildCount) or 0,
				biome
			)

			local joinLabel = UiTheme.Label(row, Enum.Font.GothamBold, 13, Colors.AccentDark)
			joinLabel.AnchorPoint = Vector2.new(1, 0.5)
			joinLabel.Position = UDim2.new(1, -12, 0.5, 0)
			joinLabel.Size = UDim2.fromOffset(104, 34)
			joinLabel.BackgroundTransparency = 0
			joinLabel.BackgroundColor3 = Colors.Accent
			joinLabel.TextXAlignment = Enum.TextXAlignment.Center
			joinLabel.Text = "Rejoindre"
			if isNpc and summary.MotherAlive == false then
				joinLabel.Text = "Sans mère"
				joinLabel.BackgroundColor3 = Colors.Track
				joinLabel.TextColor3 = Colors.Muted
			end
			UiTheme.Corner(joinLabel, 8)

			row.MouseEnter:Connect(function()
				UiTheme.Tween(row, 0.14, { BackgroundColor3 = Colors.CardHover })
			end)
			row.MouseLeave:Connect(function()
				UiTheme.Tween(row, 0.14, { BackgroundColor3 = Colors.Card })
			end)
			row.MouseButton1Click:Connect(function()
				if joinLocked or confirmLocked then
					return
				end
				joinLocked = true
				pendingMode = "Nest"
				local idleText = joinLabel.Text
				joinLabel.Text = "…"
				Remotes.Get("RequestJoinNest"):FireServer(summary.OwnerUserId)
				task.delay(1, function()
					joinLocked = false
					if joinLabel.Parent then
						joinLabel.Text = idleText
					end
				end)
			end)
		end
		nestEmpty.Visible = count == 0
		nestTabButton.Text = string.format("🪺 Dans un nid (%d)", count)
	end

	local latestSummaries: { NestSummary }? = nil
	task.spawn(function()
		local ok, remote = pcall(Remotes.Get, "NestListChanged")
		if not ok then
			warn("[SpawnMenuView] NestListChanged introuvable : " .. tostring(remote))
			return
		end
		(remote :: RemoteEvent).OnClientEvent:Connect(function(summaries: unknown)
			if typeof(summaries) == "table" then
				latestSummaries = summaries :: { NestSummary }
				if shown then
					renderNestList(summaries :: { NestSummary })
				end
			end
		end)
	end)

	-- ---------- Onglets ----------
	local SUBTITLES: { [MenuMode]: string } = {
		Species = "Chaque vie commence dans un œuf : restez au chaud, puis mangez pour grandir.",
		Nest = "Naissez dans le nid d'une Maman (joueur ou PNJ) : elle vous nourrit et vous protège.",
		Mother = "Naissez adulte à 100% et fondez votre colonie près du nid de votre espèce.",
	}
	local TAB_INDEX: { [MenuMode]: number } = { Species = 0, Nest = 1, Mother = 2 }

	local function showTab(newMode: MenuMode)
		mode = newMode
		speciesPage.Visible = newMode ~= "Nest"
		nestPage.Visible = newMode == "Nest"

		local idx = TAB_INDEX[newMode] or 0
		local indicatorColor = if newMode == "Mother" then Colors.Gold else Colors.Accent
		local activeTextColor = if newMode == "Mother" then Colors.GoldDark else Colors.AccentDark
		UiTheme.Tween(tabIndicator, 0.25, {
			Position = UDim2.new(idx / 3, 2, 0, 0),
			BackgroundColor3 = indicatorColor,
		}, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		UiTheme.Tween(topAccent, 0.25, { BackgroundColor3 = indicatorColor })

		UiTheme.Tween(speciesTabButton, 0.18, { TextColor3 = if newMode == "Species" then activeTextColor else Colors.Text })
		UiTheme.Tween(nestTabButton, 0.18, { TextColor3 = if newMode == "Nest" then activeTextColor else Colors.Text })
		UiTheme.Tween(motherTabButton, 0.18, { TextColor3 = if newMode == "Mother" then activeTextColor else Colors.Text })

		subtitle.Text = SUBTITLES[newMode]
		refreshConfirmText()
	end
	speciesTabButton.MouseButton1Click:Connect(function()
		showTab("Species")
	end)
	nestTabButton.MouseButton1Click:Connect(function()
		showTab("Nest")
	end)
	motherTabButton.MouseButton1Click:Connect(function()
		showTab("Mother")
	end)
	showTab("Species")

	-- ---------- Mise en page responsive ----------
	local lastPortrait: boolean? = nil
	local function applyResponsiveLayout(portrait: boolean)
		local design = if portrait then PORTRAIT_SIZE else LANDSCAPE_SIZE
		root.Size = UDim2.fromOffset(design.X, design.Y)
		searchBox.Visible = not portrait
		if portrait then
			filterRow.Size = UDim2.new(1, 0, 0, FILTER_ROW_HEIGHT)
			grid.Size = UDim2.new(1, 0, 1, -(FILTER_ROW_HEIGHT + 8 + PORTRAIT_DETAIL_HEIGHT + 8))
			emptyLabel.Size = UDim2.new(1, -12, 0, 20)
			detail.Position = UDim2.new(0, 0, 1, -PORTRAIT_DETAIL_HEIGHT)
			detail.Size = UDim2.new(1, 0, 0, PORTRAIT_DETAIL_HEIGHT)
			-- En portrait : vitrine 3D à gauche, stats/texte à droite dans la fiche du bas
			previewBox.Position = UDim2.fromOffset(0, 36)
			previewBox.Size = UDim2.new(0.44, -4, 1, -84)
			statsGrid.Position = UDim2.new(0.44, 6, 0, 36)
			statsGrid.Size = UDim2.new(0.56, -6, 0, 42)
			detailBody.Position = UDim2.new(0.44, 6, 0, 82)
			detailBody.Size = UDim2.new(0.56, -6, 1, -(82 + 46))
		else
			filterRow.Size = UDim2.new(0.56, 0, 0, FILTER_ROW_HEIGHT)
			grid.Size = UDim2.new(0.56, 0, 1, -(FILTER_ROW_HEIGHT + 8))
			emptyLabel.Size = UDim2.new(0.56, -12, 0, 20)
			detail.Position = UDim2.new(0.56, 12, 0, 0)
			detail.Size = UDim2.new(0.44, -12, 1, 0)
			previewBox.Position = UDim2.fromOffset(0, 38)
			previewBox.Size = UDim2.new(1, 0, 0, 138)
			statsGrid.Position = UDim2.fromOffset(0, 180)
			statsGrid.Size = UDim2.new(1, 0, 0, 42)
			detailBody.Position = UDim2.fromOffset(0, 226)
			detailBody.Size = UDim2.new(1, 0, 1, -(226 + 46))
		end
	end

	UiTheme.OnViewportChanged(function(size: Vector2)
		local portrait = size.X < size.Y * 0.9
		local design = if portrait then PORTRAIT_SIZE else LANDSCAPE_SIZE
		rootScale.Scale = math.clamp(math.min(size.X / (design.X + 24), size.Y / (design.Y + 24)), 0.45, 1.4)
		if portrait == lastPortrait then
			return
		end
		lastPortrait = portrait
		applyResponsiveLayout(portrait)
	end)
	if lastPortrait == nil then
		applyResponsiveLayout(false)
	end

	-- ---------- Visibilité et animations d'ouverture / fermeture ----------
	local visibilityToken = 0
	local function refreshVisibility()
		local stage = player:GetAttribute("Stage")
		local growth = player:GetAttribute("Growth")
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local show = stage == "Oeuf" and growth == 0 and player:GetAttribute("HasConfirmedSpawn") ~= true
			and humanoid ~= nil and humanoid.Health > 0
		if show == shown then
			return
		end
		shown = show
		ClientState.SetInMenu(show)
		showcase3D.SetTurntableActive(show)
		visibilityToken += 1
		local token = visibilityToken
		if show then
			screenGui.Enabled = true
			confirmPulse:Play()
			local reopenMode = lastConfirmedMode
			if (reopenMode == "Mother" and (motherUnlockState() ~= true or motherCooldownLeft() > 0))
				or (reopenMode == "Nest" and (latestSummaries == nil or #(latestSummaries :: { NestSummary }) == 0))
			then
				reopenMode = "Species"
			end
			showTab(reopenMode)
			if latestSummaries then
				renderNestList(latestSummaries)
			end
			backdrop.BackgroundTransparency = 1
			root.Position = ROOT_HIDDEN
			UiTheme.Tween(backdrop, 0.32, { BackgroundTransparency = 0.38 })
			UiTheme.Tween(root, 0.38, { Position = ROOT_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			showcase3D.SpinOnce()
		else
			confirmPulse:Cancel()
			confirmStroke.Transparency = 0.55
			if humanoid ~= nil and humanoid.Health > 0 then
				lastConfirmedMode = pendingMode
			end
			searchBox:ReleaseFocus()
			UiTheme.Tween(backdrop, 0.28, { BackgroundTransparency = 1 })
			UiTheme.Tween(root, 0.28, { Position = ROOT_OFFSCREEN }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function()
				if token == visibilityToken then
					screenGui.Enabled = false
				end
			end)
		end
	end

	refreshVisibility()
	player:GetAttributeChangedSignal("HasConfirmedSpawn"):Connect(refreshVisibility)
	player:GetAttributeChangedSignal("Stage"):Connect(refreshVisibility)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshVisibility)

	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			humanoid.Died:Connect(refreshVisibility)
		end
		refreshVisibility()
	end
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
end

return SpawnMenuView
