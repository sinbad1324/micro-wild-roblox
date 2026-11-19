--!strict
-- SpawnMenuView.luau
-- Menu de spawn (GDD §2 "Spawn" / §8.2) : choix d'espèce (cartes filtrables par catégorie et par
-- nom, fiche détaillée de l'espèce sélectionnée, bouton "Éclore"), naissance dans le nid d'une
-- Maman (joueur ou PNJ), ou "Être une Maman" (adulte à 100%, débloqué par le profil). Affiché tant que le joueur est un Oeuf à 0% de croissance sans choix confirmé.
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
	IsNpc: boolean?, -- nid d'une Maman PNJ
	MotherAlive: boolean?, -- nid PNJ : false si sa Maman est morte
	Biome: string?,
}

-- Les trois façons de naître : espèce libre (nid sauvage), nid d'une Maman, ou Maman directement.
type MenuMode = "Species" | "Nest" | "Mother"

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
local MAX_NEST_CHILDREN = 6 -- miroir de SpawnMenuNetworkService (le serveur fait foi)
local PAGES_TOP = 86

local ROOT_SHOWN = UDim2.fromScale(0.5, 0.5)
local ROOT_HIDDEN = UDim2.new(0.5, 0, 0.5, 28)
local ROOT_OFFSCREEN = UDim2.fromScale(0.5, 1.6) -- fermeture : le panneau sort par le bas

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

-- "Clic Morsure · E Jet Acide Formique" : pouvoirs actifs en une ligne pour la carte.
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

	-- ---------- Onglets "Mon espèce" / "Nids" / "Être Maman" ----------
	local tabBar = Instance.new("Frame")
	tabBar.Name = "Tabs"
	tabBar.BackgroundTransparency = 1
	tabBar.Position = UDim2.fromOffset(0, 46)
	tabBar.Size = UDim2.new(1, 0, 0, 32)
	tabBar.Parent = root

	local function makeTab(text: string, order: number): TextButton
		local button = makePill(tabBar, text, order)
		button.Position = UDim2.new((order - 1) / 3, (order - 1) * 2, 0, 0)
		button.Size = UDim2.new(1 / 3, -4, 1, 0)
		button.TextTruncate = Enum.TextTruncate.AtEnd
		return button
	end
	local speciesTabButton = makeTab("Mon espèce", 1)
	local nestTabButton = makeTab("Dans un nid (0)", 2)
	local motherTabButton = makeTab("Être une Maman", 3)

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
	gridLayout.CellSize = UDim2.new(0.5, -6, 0, 88) -- 2 colonnes ; -6 : marge d'arrondi pour ne jamais retomber à 1
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
	local mode: MenuMode = "Species"
	local confirmLocked = false
	local joinLocked = false -- anti double-clic des lignes de nid (même principe que confirmLocked)
	-- Dernier mode utilisé pour naître : le menu s'y rouvre à la vie suivante.
	local lastConfirmedMode: MenuMode = "Species"
	local shown = false -- menu affiché (déclaré ici : lu par refreshConfirmText)
	local cooldownTicking = false

	-- Mode "Être une Maman" : déblocage décidé par le serveur (attribut posé par ProgressionService).
	local function motherUnlockState(): boolean?
		local unlocked = player:GetAttribute("MotherSpawnUnlocked")
		return if typeof(unlocked) == "boolean" then unlocked else nil
	end

	-- Secondes restantes avant de pouvoir renaître Maman (attribut posé par SpawnMenuNetworkService).
	local function motherCooldownLeft(): number
		local readyAt = player:GetAttribute("MotherSpawnReadyAt")
		if typeof(readyAt) ~= "number" then
			return 0
		end
		return readyAt - workspace:GetServerTimeNow()
	end

	-- Seul endroit qui écrit le texte du bouton (mode, verrou, envoi en cours).
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
					"Verrouillé : devenez adulte une fois ou atteignez %d PE (vous : %d)",
					tonumber(player:GetAttribute("MotherSpawnMinPoints")) or 500,
					tonumber(player:GetAttribute("EvolutionPoints")) or 0
				)
			else
				local remaining = motherCooldownLeft()
				if remaining > 0 then
					available = false
					text = string.format("Maman de nouveau dans %d s", math.ceil(remaining))
					-- Un seul tic à la fois, seulement onglet Maman ouvert : aucun coût hors de ce cas.
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
					text = if card then "Naître Maman : " .. speciesName else "Naître Maman"
				end
			end
		else
			text = if card then "Éclore : " .. speciesName else "Éclore"
		end
		confirmButton.Text = text
		confirmButton.TextWrapped = not available
		confirmButton.TextSize = if available then 15 else 12
		confirmButton.AutoButtonColor = available
		confirmButton.BackgroundColor3 = if not available then Colors.Track elseif mode == "Mother" then Colors.Warning else Colors.Accent
		confirmButton.TextColor3 = if available then Colors.AccentDark else Colors.Muted
	end

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
		refreshConfirmText()
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

		local abilityLabel = UiTheme.Label(button, Enum.Font.Gotham, 11, Colors.Text)
		abilityLabel.Position = UDim2.fromOffset(10, 66)
		abilityLabel.Size = UDim2.new(1, -20, 0, 14)
		abilityLabel.TextTruncate = Enum.TextTruncate.AtEnd
		abilityLabel.TextTransparency = 0.25
		abilityLabel.Text = activeAbilityLine(info)

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

	confirmButton.MouseButton1Click:Connect(function()
		local speciesId = selectedId
		if confirmLocked or not speciesId then
			return
		end
		local asMother = mode == "Mother"
		if asMother and (motherUnlockState() ~= true or motherCooldownLeft() > 0) then
			return -- verrouillé ou délai en cours : la raison est déjà écrite sur le bouton
		end
		-- Anti double-clic (le serveur limite aussi la cadence). Si le serveur refuse, un toast
		-- l'explique et le bouton redevient cliquable.
		confirmLocked = true
		lastConfirmedMode = mode
		confirmButton.Text = if asMother then "Naissance…" else "Éclosion…"
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

	-- Rang d'affichage : nids de joueurs, puis PNJ avec Maman vivante, puis nids orphelins.
	local function nestRank(summary: NestSummary): number
		if summary.IsNpc ~= true then
			return 1
		end
		return if summary.MotherAlive ~= false then 2 else 3
	end

	-- Le serveur parcourt ses nids avec pairs() : ordre instable. On trie, et on ne reconstruit
	-- les lignes que si la liste a vraiment changé (sinon un clic peut tomber sur une ligne détruite).
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

			local isNpc = summary.IsNpc == true
			local row = Instance.new("TextButton")
			row.Name = "Nest"
			row.AutoButtonColor = true
			row.BackgroundColor3 = Colors.Card
			row.BorderSizePixel = 0
			row.LayoutOrder = index -- ordre déjà trié (joueurs, PNJ, orphelins)
			row.Size = UDim2.new(1, 0, 0, 54)
			row.Text = ""
			row.Parent = nestListContainer
			UiTheme.Corner(row, 10)

			-- Pastille "PNJ" devant le nom de l'espèce (Maman gérée par le serveur).
			local nameX = 12
			if isNpc then
				local badge = UiTheme.Label(row, Enum.Font.GothamBold, 11, Colors.AccentDark)
				badge.Position = UDim2.fromOffset(12, 10)
				badge.Size = UDim2.fromOffset(34, 16)
				badge.BackgroundTransparency = 0
				badge.BackgroundColor3 = if summary.MotherAlive == false then Colors.Muted else Colors.Warning
				badge.TextXAlignment = Enum.TextXAlignment.Center
				badge.Text = "PNJ"
				UiTheme.Corner(badge, 5)
				nameX = 52
			end

			local nameLabel = UiTheme.Label(row, Enum.Font.GothamBold, 14, Colors.Text)
			nameLabel.Position = UDim2.fromOffset(nameX, 9)
			nameLabel.Size = UDim2.new(1, -(118 + nameX), 0, 18)
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Text = speciesName

			local ownerLabel = UiTheme.Label(row, Enum.Font.Gotham, 12, Colors.Muted)
			ownerLabel.Position = UDim2.fromOffset(12, 29)
			ownerLabel.Size = UDim2.new(1, -130, 0, 16)
			ownerLabel.TextTruncate = Enum.TextTruncate.AtEnd
			local biomeName = summary.Biome
			local biome = if typeof(biomeName) == "string" then "  ·  " .. biomeName else ""
			ownerLabel.Text = string.format(
				"%s  ·  %d bébé(s)%s",
				tostring(summary.OwnerName),
				tonumber(summary.ChildCount) or 0,
				biome
			)

			local joinLabel = UiTheme.Label(row, Enum.Font.GothamBold, 13, Colors.AccentDark)
			joinLabel.AnchorPoint = Vector2.new(1, 0.5)
			joinLabel.Position = UDim2.new(1, -10, 0.5, 0)
			joinLabel.Size = UDim2.fromOffset(100, 32)
			joinLabel.BackgroundTransparency = 0
			joinLabel.BackgroundColor3 = Colors.Accent
			joinLabel.TextXAlignment = Enum.TextXAlignment.Center
			joinLabel.Text = "Rejoindre"
			-- Nid PNJ orphelin : rejoignable, mais personne ne vous nourrira (GDD §8.2).
			if isNpc and summary.MotherAlive == false then
				joinLabel.Text = "Sans mère"
				joinLabel.BackgroundColor3 = Colors.Track
				joinLabel.TextColor3 = Colors.Muted
			end
			-- Nid plein : la ligne reste cliquable, le serveur explique le refus.
			if (tonumber(summary.ChildCount) or 0) >= MAX_NEST_CHILDREN then
				joinLabel.Text = "Complet"
				joinLabel.BackgroundColor3 = Colors.Track
				joinLabel.TextColor3 = Colors.Muted
			end
			UiTheme.Corner(joinLabel, 8)

			row.MouseButton1Click:Connect(function()
				if joinLocked then
					return
				end
				joinLocked = true
				lastConfirmedMode = "Nest"
				local idleText = joinLabel.Text
				joinLabel.Text = "…"
				Remotes.Get("RequestJoinNest"):FireServer(summary.OwnerUserId)
				-- La liste n'est reconstruite que si elle change : on remet le texte en cas de refus.
				task.delay(1, function()
					joinLocked = false
					if joinLabel.Parent then
						joinLabel.Text = idleText
					end
				end)
			end)
		end
		nestEmpty.Visible = count == 0
		nestTabButton.Text = string.format("Dans un nid (%d)", count)
	end

	-- Liste reçue même menu caché, mais rendue seulement quand le menu est visible (pas de
	-- reconstruction des lignes pendant toute la vie adulte).
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
	-- "Mon espèce" et "Être une Maman" partagent la page des espèces : seul le bouton change.
	local SUBTITLES: { [MenuMode]: string } = {
		Species = "Chaque vie commence dans un œuf : restez au chaud, puis mangez pour grandir.",
		Nest = "Naissez dans le nid d'une Maman (joueur ou PNJ) : elle vous nourrit et vous protège.",
		Mother = "Naissez adulte à 100% et fondez votre colonie près du nid de votre espèce.",
	}
	local function showTab(newMode: MenuMode)
		mode = newMode
		speciesPage.Visible = newMode ~= "Nest"
		nestPage.Visible = newMode == "Nest"
		setPillActive(speciesTabButton, newMode == "Species")
		setPillActive(nestTabButton, newMode == "Nest")
		setPillActive(motherTabButton, newMode == "Mother")
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
	local visibilityToken = 0 -- invalide une fermeture en cours si le menu se rouvre entre-temps
	local function refreshVisibility()
		local stage = player:GetAttribute("Stage")
		local growth = player:GetAttribute("Growth")
		-- Corps vivant requis : pendant le délai de réapparition, le serveur refuse tout choix.
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local show = stage == "Oeuf" and growth == 0 and player:GetAttribute("HasConfirmedSpawn") ~= true
			and humanoid ~= nil and humanoid.Health > 0
		if show == shown then
			return
		end
		shown = show
		ClientState.IsInMenu = show
		visibilityToken += 1
		local token = visibilityToken
		if show then
			-- Entrée : le voile s'assombrit, le panneau remonte en place.
			screenGui.Enabled = true
			-- Rouvre sur le dernier mode utilisé, sauf s'il n'est plus disponible.
			local reopenMode = lastConfirmedMode
			if (reopenMode == "Mother" and motherUnlockState() ~= true)
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
			UiTheme.Tween(backdrop, 0.3, { BackgroundTransparency = 0.45 })
			UiTheme.Tween(root, 0.35, { Position = ROOT_SHOWN }, Enum.EasingStyle.Back)
		else
			-- Sortie : le panneau glisse vers le bas et le voile s'éclaircit, puis on désactive.
			searchBox:ReleaseFocus()
			UiTheme.Tween(backdrop, 0.3, { BackgroundTransparency = 1 })
			UiTheme.Tween(root, 0.3, { Position = ROOT_OFFSCREEN }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function()
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
	-- Le menu s'ouvre une fois le nouveau corps apparu (et se ferme dès la mort).
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
