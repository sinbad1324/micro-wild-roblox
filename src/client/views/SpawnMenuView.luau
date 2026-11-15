--!strict
-- SpawnMenuView.luau
-- Menu de spawn (GDD §2 "Spawn" / §8.2) : choix d'espèce (cartes filtrables par catégorie et par
-- nom, fiche détaillée de l'espèce sélectionnée, bouton "Éclore") ou naissance dans le nid d'une
-- Maman. Affiché tant que le joueur est un Oeuf à 0% de croissance sans choix confirmé.
-- Responsive : mise en page paysage (liste à gauche, fiche à droite) ou portrait (fiche en bas),
-- le tout mis à l'échelle par un UIScale. Aucun travail par frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local UiTheme = require(script.Parent.UiTheme)
local ClientState = require(script.Parent.Parent.state.ClientState)

-- ServerScriptService n'est pas répliqué au client : on redéfinit localement la forme attendue
-- plutôt que de requérir ServerTypes (doit rester identique à ServerTypes.NestSummary).
type NestSummary = {
	OwnerUserId: number,
	OwnerName: string,
	SpeciesId: string,
	ChildCount: number,
}

local SpawnMenuView = {}

local mounted = false

local Colors = UiTheme.Colors

local CATEGORIES = { "Tous", "Terrestre", "Volant", "Aquatique" }
local DIET_COLORS: { [string]: Color3 } = {
	Herbivore = Colors.Accent,
	Carnivore = Colors.Danger,
	Omnivore = Colors.Warning,
}
local SLOT_LABELS: { [string]: string } = { LeftClick = "Clic", E = "E", R = "R", F = "F" }

-- Tailles de conception (avant UIScale) des deux mises en page.
local LANDSCAPE_SIZE = Vector2.new(720, 440)
local PORTRAIT_SIZE = Vector2.new(400, 660)
local PORTRAIT_DETAIL_HEIGHT = 200
local FILTER_ROW_HEIGHT = 30
local PAGES_TOP = 86

local ROOT_SHOWN = UDim2.fromScale(0.5, 0.5)
local ROOT_HIDDEN = UDim2.new(0.5, 0, 0.5, 28)

-- Liste ordonnée (catégorie puis nom) pour un affichage stable : pairs() sur InsectData ne
-- garantit aucun ordre.
local function sortedSpeciesList(): { InsectData.InsectInfo }
	local list: { InsectData.InsectInfo } = {}
	for _, info in pairs(InsectData) do
		table.insert(list, info)
	end
	local categoryOrder: { [string]: number } = { Terrestre = 1, Volant = 2, Aquatique = 3 }
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

-- "JetAcideFormique" -> "Jet Acide Formique"
local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return spaced
end

-- "Grimpe · Vole · Nage" : résumé des déplacements pour la carte.
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
		table.insert(traits, "Patine sur l'eau")
	end
	if #traits == 0 then
		return "Marcheur"
	end
	return table.concat(traits, " · ")
end

-- "[E] Jet Acide Formique  [R] ...  Passifs : ..." pour la fiche.
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
	local text = table.concat(actives, "   ")
	if #passives > 0 then
		if text ~= "" then
			text ..= "\n"
		end
		text ..= "Passifs : " .. table.concat(passives, ", ")
	end
	return text
end

-- Bouton "pilule" (onglets, filtres).
local function makePill(parent: Instance, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = Colors.Card
	button.BorderSizePixel = 0
	button.LayoutOrder = order
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Colors.Text
	button.Text = text
	button.Parent = parent
	UiTheme.Corner(button, 8)
	return button
end

local function setPillActive(button: TextButton, active: boolean)
	UiTheme.Tween(button, 0.15, {
		BackgroundColor3 = if active then Colors.Accent else Colors.Card,
		TextColor3 = if active then Colors.AccentDark else Colors.Text,
	})
end

local function makeScrollingPage(parent: Instance): ScrollingFrame
	local page = Instance.new("ScrollingFrame")
	page.BackgroundTransparency = 1
	page.Size = UDim2.new(1, 0, 1, 0)
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 5
	page.ScrollBarImageColor3 = Colors.Muted
	page.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.Parent = parent
	-- Marge pour que le contour (UIStroke) des cartes ne soit pas rogné par le défilement.
	UiTheme.Padding(page, 3, 3)
	return page
end

type SpeciesCard = {
	Button: TextButton,
	Stroke: UIStroke,
	Info: InsectData.InsectInfo,
	SearchName: string,
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
	screenGui.IgnoreGuiInset = true -- zone sûre de l'appareil respectée (encoches), barre Roblox ignorée
	screenGui.DisplayOrder = 10
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	-- Voile sombre derrière le panneau.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screenGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = ROOT_SHOWN
	root.Size = UDim2.fromOffset(LANDSCAPE_SIZE.X, LANDSCAPE_SIZE.Y)
	root.BackgroundColor3 = Colors.Panel
	root.BackgroundTransparency = 0.04
	root.BorderSizePixel = 0
	root.Parent = screenGui
	UiTheme.Corner(root, 14)
	UiTheme.Stroke(root, Color3.new(1, 1, 1), 1, 0.88)
	UiTheme.Padding(root, 14, 14)

	local rootScale = Instance.new("UIScale")
	rootScale.Parent = root

	-- ---------- En-tête ----------
	local title = UiTheme.Label(root, Enum.Font.GothamBlack, 20, Colors.Text)
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 24)
	title.Text = "Choisissez votre insecte"

	local subtitle = UiTheme.Label(root, Enum.Font.Gotham, 12, Colors.Muted)
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromOffset(0, 24)
	subtitle.Size = UDim2.new(1, 0, 0, 16)
	subtitle.TextTruncate = Enum.TextTruncate.AtEnd
	subtitle.Text = "Chaque vie commence dans un œuf : restez au chaud, puis mangez pour grandir."

	-- ---------- Onglets "Espèces" / "Nids" ----------
	local tabBar = Instance.new("Frame")
	tabBar.Name = "Tabs"
	tabBar.BackgroundTransparency = 1
	tabBar.Position = UDim2.fromOffset(0, 46)
	tabBar.Size = UDim2.new(1, 0, 0, 32)
	tabBar.Parent = root

	local speciesTabButton = makePill(tabBar, "Choisir une espèce", 1)
	speciesTabButton.Size = UDim2.new(0.5, -3, 1, 0)
	local nestTabButton = makePill(tabBar, "Naître dans un nid (0)", 2)
	nestTabButton.Position = UDim2.new(0.5, 3, 0, 0)
	nestTabButton.Size = UDim2.new(0.5, -3, 1, 0)

	local pageContainer = Instance.new("Frame")
	pageContainer.Name = "Pages"
	pageContainer.BackgroundTransparency = 1
	pageContainer.Position = UDim2.fromOffset(0, PAGES_TOP)
	pageContainer.Size = UDim2.new(1, 0, 1, -PAGES_TOP)
	pageContainer.Parent = root

	-- ================= Page 1 : espèces =================
	local speciesPage = Instance.new("Frame")
	speciesPage.Name = "SpeciesPage"
	speciesPage.BackgroundTransparency = 1
	speciesPage.Size = UDim2.fromScale(1, 1)
	speciesPage.Parent = pageContainer

	-- Rangée de filtres : catégories + recherche (paysage uniquement, faute de place en portrait).
	local filterRow = Instance.new("Frame")
	filterRow.Name = "Filters"
	filterRow.BackgroundTransparency = 1
	filterRow.Size = UDim2.new(0.6, 0, 0, FILTER_ROW_HEIGHT)
	filterRow.Parent = speciesPage

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Padding = UDim.new(0, 6)
	filterLayout.Parent = filterRow

	local categoryButtons: { [string]: TextButton } = {}
	for index, category in ipairs(CATEGORIES) do
		local button = makePill(filterRow, category, index)
		button.Size = UDim2.new(0, 72, 1, 0)
		button.TextSize = 12
		categoryButtons[category] = button
	end

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "Search"
	searchBox.LayoutOrder = #CATEGORIES + 1
	searchBox.Size = UDim2.new(0, 96, 1, 0)
	searchBox.BackgroundColor3 = Colors.Track
	searchBox.BorderSizePixel = 0
	searchBox.ClearTextOnFocus = false
	searchBox.Font = Enum.Font.Gotham
	searchBox.TextSize = 12
	searchBox.TextColor3 = Colors.Text
	searchBox.PlaceholderText = "Rechercher…"
	searchBox.PlaceholderColor3 = Colors.Muted
	searchBox.Text = ""
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.TextTruncate = Enum.TextTruncate.AtEnd
	searchBox.Parent = filterRow
	UiTheme.Corner(searchBox, 8)
	UiTheme.Padding(searchBox, 8, 0)

	local grid = makeScrollingPage(speciesPage)
	grid.Name = "Grid"
	grid.Position = UDim2.fromOffset(0, FILTER_ROW_HEIGHT + 8)

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.CellSize = UDim2.new(0.5, -6, 0, 74) -- 2 colonnes ; -6 : marge d'arrondi pour ne jamais retomber à 1
	gridLayout.Parent = grid

	local emptyLabel = UiTheme.Label(speciesPage, Enum.Font.Gotham, 13, Colors.Muted)
	emptyLabel.Name = "Empty"
	emptyLabel.Position = UDim2.fromOffset(6, FILTER_ROW_HEIGHT + 16)
	emptyLabel.Size = UDim2.new(0.6, -12, 0, 20)
	emptyLabel.Text = "Aucune espèce ne correspond."
	emptyLabel.Visible = false

	-- Fiche de l'espèce sélectionnée + bouton de confirmation.
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.BackgroundColor3 = Colors.Card
	detail.BorderSizePixel = 0
	detail.Parent = speciesPage
	UiTheme.Corner(detail, 10)
	UiTheme.Padding(detail, 12, 12)

	local detailName = UiTheme.Label(detail, Enum.Font.GothamBlack, 17, Colors.Text)
	detailName.Name = "Name"
	detailName.Size = UDim2.new(1, 0, 0, 22)
	detailName.TextTruncate = Enum.TextTruncate.AtEnd

	local detailTags = UiTheme.Label(detail, Enum.Font.GothamBold, 12, Colors.Accent)
	detailTags.Name = "Tags"
	detailTags.Position = UDim2.fromOffset(0, 23)
	detailTags.Size = UDim2.new(1, 0, 0, 16)
	detailTags.TextTruncate = Enum.TextTruncate.AtEnd

	local detailBody = UiTheme.Label(detail, Enum.Font.Gotham, 12, Colors.Text)
	detailBody.Name = "Body"
	detailBody.Position = UDim2.fromOffset(0, 44)
	detailBody.Size = UDim2.new(1, 0, 1, -(44 + 52))
	detailBody.TextWrapped = true
	detailBody.TextYAlignment = Enum.TextYAlignment.Top
	detailBody.TextTruncate = Enum.TextTruncate.AtEnd
	detailBody.TextTransparency = 0.1

	local confirmButton = Instance.new("TextButton")
	confirmButton.Name = "Confirm"
	confirmButton.AnchorPoint = Vector2.new(0, 1)
	confirmButton.Position = UDim2.fromScale(0, 1)
	confirmButton.Size = UDim2.new(1, 0, 0, 44)
	confirmButton.BackgroundColor3 = Colors.Accent
	confirmButton.BorderSizePixel = 0
	confirmButton.AutoButtonColor = true
	confirmButton.Font = Enum.Font.GothamBold
	confirmButton.TextSize = 15
	confirmButton.TextColor3 = Colors.AccentDark
	confirmButton.TextTruncate = Enum.TextTruncate.AtEnd
	confirmButton.Text = "Éclore"
	confirmButton.Parent = detail
	UiTheme.Corner(confirmButton, 10)

	-- --- Cartes d'espèce ---
	local cards: { [string]: SpeciesCard } = {}
	local speciesList = sortedSpeciesList()
	local selectedId: string? = nil
	local activeCategory = "Tous"

	local function selectSpecies(speciesId: string)
		local card = cards[speciesId]
		if not card or selectedId == speciesId then
			return
		end
		local previous = if selectedId then cards[selectedId] else nil
		if previous then
			UiTheme.Tween(previous.Button, 0.15, { BackgroundColor3 = Colors.Card })
			UiTheme.Tween(previous.Stroke, 0.15, { Transparency = 1 })
		end
		selectedId = speciesId
		ClientState.SelectedSpecies = speciesId
		UiTheme.Tween(card.Button, 0.15, { BackgroundColor3 = Colors.CardHover })
		UiTheme.Tween(card.Stroke, 0.15, { Transparency = 0 })

		local info = card.Info
		detailName.Text = info.Name
		detailTags.Text = string.format("%s  ·  %s  ·  %s", info.Diet, info.Category, if info.GrowthType == "Metamorphose" then "Métamorphose" else "Mues")
		detailTags.TextColor3 = DIET_COLORS[info.Diet] or Colors.Accent
		detailBody.Text = string.format(
			"%s\nPV %d  ·  Vitesse %d  ·  Dégâts %d  ·  Idéal %d à %d°C\n%s",
			info.Description,
			info.MaxHealth,
			info.WalkSpeed,
			info.Damage,
			info.IdealTempMin,
			info.IdealTempMax,
			abilitySummary(info)
		)
		confirmButton.Text = "Éclore : " .. info.Name
	end

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
		local stroke = UiTheme.Stroke(button, Colors.Accent, 2, 1)

		local nameLabel = UiTheme.Label(button, Enum.Font.GothamBold, 14, Colors.Text)
		nameLabel.Position = UDim2.fromOffset(10, 8)
		nameLabel.Size = UDim2.new(1, -20, 0, 18)
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Text = info.Name

		local dietLabel = UiTheme.Label(button, Enum.Font.GothamBold, 11, DIET_COLORS[info.Diet] or Colors.Accent)
		dietLabel.Position = UDim2.fromOffset(10, 29)
		dietLabel.Size = UDim2.new(1, -20, 0, 14)
		dietLabel.TextTruncate = Enum.TextTruncate.AtEnd
		dietLabel.Text = string.format("%s  ·  %s", info.Diet, info.Category)

		local traitLabel = UiTheme.Label(button, Enum.Font.Gotham, 11, Colors.Muted)
		traitLabel.Position = UDim2.fromOffset(10, 48)
		traitLabel.Size = UDim2.new(1, -20, 0, 14)
		traitLabel.TextTruncate = Enum.TextTruncate.AtEnd
		traitLabel.Text = traitSummary(info)

		cards[info.Id] = { Button = button, Stroke = stroke, Info = info, SearchName = string.lower(info.Name) }

		button.MouseEnter:Connect(function()
			if selectedId ~= info.Id then
				UiTheme.Tween(button, 0.12, { BackgroundColor3 = Colors.CardHover })
			end
		end)
		button.MouseLeave:Connect(function()
			if selectedId ~= info.Id then
				UiTheme.Tween(button, 0.12, { BackgroundColor3 = Colors.Card })
			end
		end)
		button.MouseButton1Click:Connect(function()
			selectSpecies(info.Id)
		end)
	end

	local function applyFilter()
		local query = string.lower(searchBox.Text)
		local anyVisible = false
		for _, card in pairs(cards) do
			local visible = (activeCategory == "Tous" or card.Info.Category == activeCategory)
				and (query == "" or string.find(card.SearchName, query, 1, true) ~= nil)
			card.Button.Visible = visible
			anyVisible = anyVisible or visible
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

	-- Sélection initiale : la dernière espèce choisie (ClientState) si elle existe, sinon la première.
	if cards[ClientState.SelectedSpecies] then
		selectSpecies(ClientState.SelectedSpecies)
	elseif speciesList[1] then
		selectSpecies(speciesList[1].Id)
	end

	local confirmLocked = false
	confirmButton.MouseButton1Click:Connect(function()
		local speciesId = selectedId
		if confirmLocked or not speciesId then
			return
		end
		-- Anti double-clic (le serveur limite aussi la cadence). Si le serveur refuse, un toast
		-- l'explique et le bouton redevient cliquable.
		confirmLocked = true
		confirmButton.Text = "Éclosion…"
		Remotes.Get("RequestSelectSpecies"):FireServer(speciesId)
		task.delay(1, function()
			confirmLocked = false
			local card = if selectedId then cards[selectedId] else nil
			confirmButton.Text = if card then "Éclore : " .. card.Info.Name else "Éclore"
		end)
	end)

	-- ================= Page 2 : nids =================
	-- Fonder une colonie exige d'être adulte à 100% (bouton dans la barre de pouvoirs) : ici on
	-- ne fait que naître dans le nid d'une Maman, dont on hérite l'espèce.
	local nestPage = makeScrollingPage(pageContainer)
	nestPage.Name = "NestPage"
	nestPage.Visible = false

	local nestPageLayout = Instance.new("UIListLayout")
	nestPageLayout.SortOrder = Enum.SortOrder.LayoutOrder
	nestPageLayout.Padding = UDim.new(0, 8)
	nestPageLayout.Parent = nestPage

	local nestHint = UiTheme.Label(nestPage, Enum.Font.Gotham, 13, Colors.Text)
	nestHint.Name = "Hint"
	nestHint.LayoutOrder = 1
	nestHint.Size = UDim2.new(1, 0, 0, 0)
	nestHint.AutomaticSize = Enum.AutomaticSize.Y
	nestHint.BackgroundTransparency = 0
	nestHint.BackgroundColor3 = Colors.Card
	nestHint.TextWrapped = true
	nestHint.Text = "Naître dans le nid d'une Maman : vous serez de son espèce et elle vous nourrira.\n(Aucun nid ? Choisissez une espèce : un nid sauvage vous accueillera.)"
	UiTheme.Corner(nestHint, 10)
	UiTheme.Padding(nestHint, 12, 10)

	local nestEmpty = UiTheme.Label(nestPage, Enum.Font.Gotham, 13, Colors.Muted)
	nestEmpty.Name = "Empty"
	nestEmpty.LayoutOrder = 2
	nestEmpty.Size = UDim2.new(1, 0, 0, 28)
	nestEmpty.TextXAlignment = Enum.TextXAlignment.Center
	nestEmpty.Text = "Aucune colonie active pour l'instant."

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

	local function renderNestList(summaries: { NestSummary })
		for _, child in ipairs(nestListContainer:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local count = 0
		for index, summary in ipairs(summaries) do
			if typeof(summary) ~= "table" or typeof(summary.OwnerUserId) ~= "number" then
				continue
			end
			count += 1
			local speciesInfo = InsectData[summary.SpeciesId]
			local speciesName = if speciesInfo then speciesInfo.Name else tostring(summary.SpeciesId)

			local row = Instance.new("TextButton")
			row.Name = "Nest"
			row.AutoButtonColor = true
			row.BackgroundColor3 = Colors.Card
			row.BorderSizePixel = 0
			row.LayoutOrder = index
			row.Size = UDim2.new(1, 0, 0, 54)
			row.Text = ""
			row.Parent = nestListContainer
			UiTheme.Corner(row, 10)

			local nameLabel = UiTheme.Label(row, Enum.Font.GothamBold, 14, Colors.Text)
			nameLabel.Position = UDim2.fromOffset(12, 9)
			nameLabel.Size = UDim2.new(1, -130, 0, 18)
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Text = speciesName

			local ownerLabel = UiTheme.Label(row, Enum.Font.Gotham, 12, Colors.Muted)
			ownerLabel.Position = UDim2.fromOffset(12, 29)
			ownerLabel.Size = UDim2.new(1, -130, 0, 16)
			ownerLabel.TextTruncate = Enum.TextTruncate.AtEnd
			ownerLabel.Text = string.format("Nid de %s  ·  %d enfant(s)", tostring(summary.OwnerName), tonumber(summary.ChildCount) or 0)

			local joinLabel = UiTheme.Label(row, Enum.Font.GothamBold, 13, Colors.AccentDark)
			joinLabel.AnchorPoint = Vector2.new(1, 0.5)
			joinLabel.Position = UDim2.new(1, -10, 0.5, 0)
			joinLabel.Size = UDim2.fromOffset(100, 32)
			joinLabel.BackgroundTransparency = 0
			joinLabel.BackgroundColor3 = Colors.Accent
			joinLabel.TextXAlignment = Enum.TextXAlignment.Center
			joinLabel.Text = "Rejoindre"
			UiTheme.Corner(joinLabel, 8)

			row.MouseButton1Click:Connect(function()
				Remotes.Get("RequestJoinNest"):FireServer(summary.OwnerUserId)
			end)
		end
		nestEmpty.Visible = count == 0
		nestTabButton.Text = string.format("Naître dans un nid (%d)", count)
	end

	Remotes.Get("NestListChanged").OnClientEvent:Connect(function(summaries: unknown)
		if typeof(summaries) == "table" then
			renderNestList(summaries :: { NestSummary })
		end
	end)

	-- ---------- Onglets ----------
	local function showTab(showSpecies: boolean)
		speciesPage.Visible = showSpecies
		nestPage.Visible = not showSpecies
		setPillActive(speciesTabButton, showSpecies)
		setPillActive(nestTabButton, not showSpecies)
	end
	speciesTabButton.MouseButton1Click:Connect(function()
		showTab(true)
	end)
	nestTabButton.MouseButton1Click:Connect(function()
		showTab(false)
	end)
	showTab(true)

	-- ---------- Mise en page responsive (recalculée seulement au redimensionnement) ----------
	local lastPortrait: boolean? = nil
	UiTheme.OnViewportChanged(function(size: Vector2)
		local portrait = size.X < size.Y * 0.9
		local design = if portrait then PORTRAIT_SIZE else LANDSCAPE_SIZE
		rootScale.Scale = math.clamp(math.min(size.X / (design.X + 24), size.Y / (design.Y + 24)), 0.45, 1.4)
		if portrait == lastPortrait then
			return
		end
		lastPortrait = portrait
		root.Size = UDim2.fromOffset(design.X, design.Y)
		searchBox.Visible = not portrait
		if portrait then
			-- Portrait : grille pleine largeur, fiche en bas.
			filterRow.Size = UDim2.new(1, 0, 0, FILTER_ROW_HEIGHT)
			grid.Size = UDim2.new(1, 0, 1, -(FILTER_ROW_HEIGHT + 8 + PORTRAIT_DETAIL_HEIGHT + 8))
			emptyLabel.Size = UDim2.new(1, -12, 0, 20)
			detail.Position = UDim2.new(0, 0, 1, -PORTRAIT_DETAIL_HEIGHT)
			detail.Size = UDim2.new(1, 0, 0, PORTRAIT_DETAIL_HEIGHT)
		else
			-- Paysage : grille à gauche (60%), fiche à droite sur toute la hauteur.
			filterRow.Size = UDim2.new(0.6, 0, 0, FILTER_ROW_HEIGHT)
			grid.Size = UDim2.new(0.6, 0, 1, -(FILTER_ROW_HEIGHT + 8))
			emptyLabel.Size = UDim2.new(0.6, -12, 0, 20)
			detail.Position = UDim2.new(0.6, 10, 0, 0)
			detail.Size = UDim2.new(0.4, -10, 1, 0)
		end
	end)
	-- Caméra pas encore dimensionnée au montage : mise en page paysage par défaut en attendant.
	if lastPortrait == nil then
		grid.Size = UDim2.new(0.6, 0, 1, -(FILTER_ROW_HEIGHT + 8))
		detail.Position = UDim2.new(0.6, 10, 0, 0)
		detail.Size = UDim2.new(0.4, -10, 1, 0)
	end

	-- --- Visibilité : uniquement tant que Oeuf à 0% de croissance (attributs pas encore
	-- répliqués au premier Mount -> traité comme caché, les signaux ci-dessous l'afficheront). ---
	local shown = false
	local function refreshVisibility()
		local stage = player:GetAttribute("Stage")
		local growth = player:GetAttribute("Growth")
		local show = stage == "Oeuf" and growth == 0 and player:GetAttribute("HasConfirmedSpawn") ~= true
		if show == shown then
			return
		end
		shown = show
		ClientState.IsInMenu = show
		screenGui.Enabled = show
		if show then
			-- Entrée : le voile s'assombrit, le panneau remonte en place.
			showTab(true)
			backdrop.BackgroundTransparency = 1
			root.Position = ROOT_HIDDEN
			UiTheme.Tween(backdrop, 0.3, { BackgroundTransparency = 0.45 })
			UiTheme.Tween(root, 0.35, { Position = ROOT_SHOWN }, Enum.EasingStyle.Back)
		else
			searchBox:ReleaseFocus()
		end
	end

	refreshVisibility()
	player:GetAttributeChangedSignal("HasConfirmedSpawn"):Connect(refreshVisibility)
	player:GetAttributeChangedSignal("Stage"):Connect(refreshVisibility)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshVisibility)
end

return SpawnMenuView
