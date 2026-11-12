--!strict
-- SpawnMenuView.luau
-- Menu de spawn (GDD §2 "Spawn" / §8.2) : choix d'espèce puis choix/création de nid, affiché
-- tant que le joueur est un Oeuf à 0% de croissance.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)

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

local COLOR_PANEL = Color3.fromRGB(18, 18, 20)
local COLOR_CARD = Color3.fromRGB(32, 32, 36)
local COLOR_ACCENT = Color3.fromRGB(95, 215, 120)
local COLOR_TEXT = Color3.fromRGB(235, 235, 235)

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

local function makeButton(parent: Instance, order: number): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.BackgroundColor3 = COLOR_CARD
	button.Size = UDim2.new(1, 0, 0, 56) -- hauteur minimale ; AutomaticSize grandit pour le texte multi-lignes
	button.AutomaticSize = Enum.AutomaticSize.Y
	button.LayoutOrder = order
	button.Font = Enum.Font.Gotham
	button.TextSize = 13
	button.TextColor3 = COLOR_TEXT
	button.TextWrapped = true
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.TextYAlignment = Enum.TextYAlignment.Top
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = button

	return button
end

local function makeSectionHeader(parent: Instance, order: number, text: string)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 22)
	header.LayoutOrder = order
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextColor3 = COLOR_ACCENT
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = text
	header.Parent = parent
end

local function makeScrollingPage(parent: Instance): ScrollingFrame
	local page = Instance.new("ScrollingFrame")
	page.BackgroundTransparency = 1
	page.Size = UDim2.new(1, 0, 1, 0)
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 6
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = page

	return page
end

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

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.new(0.5, 0, 0.5, 0)
	root.Size = UDim2.fromScale(0.92, 0.9) -- responsive (mobile) ; plafonné ci-dessous sur grand écran
	root.BackgroundColor3 = COLOR_PANEL
	root.Parent = screenGui

	local rootSizeConstraint = Instance.new("UISizeConstraint")
	rootSizeConstraint.MaxSize = Vector2.new(460, 520)
	rootSizeConstraint.Parent = root

	local rootCorner = Instance.new("UICorner")
	rootCorner.CornerRadius = UDim.new(0, 10)
	rootCorner.Parent = root

	local rootPadding = Instance.new("UIPadding")
	rootPadding.PaddingTop = UDim.new(0, 12)
	rootPadding.PaddingBottom = UDim.new(0, 12)
	rootPadding.PaddingLeft = UDim.new(0, 12)
	rootPadding.PaddingRight = UDim.new(0, 12)
	rootPadding.Parent = root

	local rootLayout = Instance.new("UIListLayout")
	rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rootLayout.Padding = UDim.new(0, 8)
	rootLayout.Parent = root

	-- Barre d'onglets : "Choisir une espèce" / "Choisir un nid".
	local tabBar = Instance.new("Frame")
	tabBar.BackgroundTransparency = 1
	tabBar.Size = UDim2.new(1, 0, 0, 32)
	tabBar.LayoutOrder = 1
	tabBar.Parent = root

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Padding = UDim.new(0, 6)
	tabLayout.Parent = tabBar

	local speciesTabButton = Instance.new("TextButton")
	speciesTabButton.Size = UDim2.new(0.5, -3, 1, 0)
	speciesTabButton.Font = Enum.Font.GothamBold
	speciesTabButton.TextSize = 14
	speciesTabButton.Text = "Choisir une espèce"
	speciesTabButton.TextColor3 = COLOR_TEXT
	speciesTabButton.BackgroundColor3 = COLOR_ACCENT
	speciesTabButton.LayoutOrder = 1
	speciesTabButton.Parent = tabBar
	local speciesTabCorner = Instance.new("UICorner")
	speciesTabCorner.CornerRadius = UDim.new(0, 6)
	speciesTabCorner.Parent = speciesTabButton

	local nestTabButton = Instance.new("TextButton")
	nestTabButton.Size = UDim2.new(0.5, -3, 1, 0)
	nestTabButton.Font = Enum.Font.GothamBold
	nestTabButton.TextSize = 14
	nestTabButton.Text = "Choisir un nid"
	nestTabButton.TextColor3 = COLOR_TEXT
	nestTabButton.BackgroundColor3 = COLOR_CARD
	nestTabButton.LayoutOrder = 2
	nestTabButton.Parent = tabBar
	local nestTabCorner = Instance.new("UICorner")
	nestTabCorner.CornerRadius = UDim.new(0, 6)
	nestTabCorner.Parent = nestTabButton

	-- Page conteneur (prend le reste de la hauteur disponible).
	local pageContainer = Instance.new("Frame")
	pageContainer.BackgroundTransparency = 1
	pageContainer.Size = UDim2.new(1, 0, 1, -40)
	pageContainer.LayoutOrder = 2
	pageContainer.Parent = root

	local speciesPage = makeScrollingPage(pageContainer)
	local nestPage = makeScrollingPage(pageContainer)
	nestPage.Visible = false

	local function showSpeciesTab()
		speciesPage.Visible = true
		nestPage.Visible = false
		speciesTabButton.BackgroundColor3 = COLOR_ACCENT
		nestTabButton.BackgroundColor3 = COLOR_CARD
	end
	local function showNestTab()
		speciesPage.Visible = false
		nestPage.Visible = true
		speciesTabButton.BackgroundColor3 = COLOR_CARD
		nestTabButton.BackgroundColor3 = COLOR_ACCENT
	end
	speciesTabButton.MouseButton1Click:Connect(showSpeciesTab)
	nestTabButton.MouseButton1Click:Connect(showNestTab)

	-- --- Page 1 : espèces (groupées par catégorie) ---
	local order = 0
	local lastCategory: string? = nil
	for _, info in ipairs(sortedSpeciesList()) do
		if info.Category ~= lastCategory then
			lastCategory = info.Category
			order += 1
			makeSectionHeader(speciesPage, order, info.Category)
		end
		order += 1
		local card = makeButton(speciesPage, order)
		card.Text = string.format("%s (%s)\n%s", info.Name, info.Diet, info.Description)
		card.MouseButton1Click:Connect(function()
			Remotes.Get("RequestSelectSpecies"):FireServer(info.Id)
		end)
	end

	-- --- Page 2 : nids (bouton "Fonder" statique + liste dynamique des Mamans actives) ---
	local createNestButton = makeButton(nestPage, 1)
	createNestButton.BackgroundColor3 = COLOR_ACCENT
	createNestButton.Text = "Fonder ma propre colonie"
	createNestButton.MouseButton1Click:Connect(function()
		Remotes.Get("RequestCreateNest"):FireServer()
	end)

	local nestListContainer = Instance.new("Frame")
	nestListContainer.Name = "NestListContainer"
	nestListContainer.BackgroundTransparency = 1
	nestListContainer.AutomaticSize = Enum.AutomaticSize.Y
	nestListContainer.Size = UDim2.new(1, 0, 0, 0)
	nestListContainer.LayoutOrder = 2
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
		for index, summary in ipairs(summaries) do
			local row = makeButton(nestListContainer, index)
			local speciesInfo = InsectData[summary.SpeciesId]
			local speciesName = speciesInfo and speciesInfo.Name or summary.SpeciesId
			row.Text = string.format(
				"%s\nNid de %s [%d enfant(s)] — Rejoindre",
				speciesName,
				summary.OwnerName,
				summary.ChildCount
			)
			row.MouseButton1Click:Connect(function()
				Remotes.Get("RequestJoinNest"):FireServer(summary.OwnerUserId)
			end)
		end
	end

	Remotes.Get("NestListChanged").OnClientEvent:Connect(function(summaries: unknown)
		if typeof(summaries) == "table" then
			renderNestList(summaries :: { NestSummary })
		end
	end)

	-- --- Visibilité : uniquement tant que Oeuf à 0% de croissance (attributs pas encore
	-- répliqués au premier Mount -> traité comme caché, les signaux ci-dessous l'afficheront). ---
	local function refreshVisibility()
		local stage = player:GetAttribute("Stage")
		local growth = player:GetAttribute("Growth")
		screenGui.Enabled = stage == "Oeuf" and growth == 0
	end

	refreshVisibility()
	player:GetAttributeChangedSignal("Stage"):Connect(refreshVisibility)
	player:GetAttributeChangedSignal("Growth"):Connect(refreshVisibility)
end

return SpawnMenuView
