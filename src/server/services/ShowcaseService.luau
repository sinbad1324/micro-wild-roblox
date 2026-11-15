--!strict
-- ShowcaseService.luau
-- Galerie d'exemples de TOUS les modèles 3D du jeu, posée sur une plateforme à l'ouest de la
-- carte (on y va à pied depuis le spawn, ou caméra libre en mode Run F8) :
--   * les 30 insectes, chacun à chaque stade (Oeuf, Larve, Mue ou Cocon, Adulte)
--   * les 5 mutations rares
--   * les 5 animaux géants + un alevin
--   * les nids (7 nids d'insectes, nid sauvage, nid d'oiseau, hotte d'écureuil)
--
-- Utilisable aussi EN MODE ÉDITION (sans lancer le jeu) depuis la Command Bar de Studio, pour
-- garder les modèles dans la place :
--   require(game.ServerScriptService.services.ShowcaseService).Build()
-- et pour l'effacer :
--   require(game.ServerScriptService.services.ShowcaseService).Clear()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local AnimalData = require(ReplicatedStorage.shared.AnimalData)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)
local AnimalModels = require(ServerScriptService.services.AnimalModels)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local ShowcaseService = {}

local FOLDER_NAME = "Galerie3D"
-- Juste au-delà du bord ouest de la carte : la galerie s'étend vers l'ouest, accessible à pied
-- depuis le spawn.
local ORIGIN = WorldLayout.SHOWCASE_ORIGIN
local DISPLAY_SCALE = 2 -- les insectes sont grossis x2 pour être bien visibles
local COLUMN_SPACING = 16 -- entre deux espèces (axe -X)
local STAGE_SPACING = 13 -- entre deux stades (axe +Z)

-- Échelle du personnage à chaque stade (identique à EvolutionDomain.ApplyStageStats).
local STAGE_SCALE: { [string]: number } = { Oeuf = 0.25, Larve = 0.45, Mue = 0.55, Cocon = 0.6, Adulte = 1 }

local CATEGORY_ORDER: { [string]: number } = { Terrestre = 1, Volant = 2, Aquatique = 3 }

local function label(parent: BasePart, text: string, offsetY: number, color: Color3?, size: Vector2?)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Etiquette"
	billboard.Size = UDim2.fromOffset((size or Vector2.new(170, 40)).X, (size or Vector2.new(170, 40)).Y)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	billboard.MaxDistance = 160
	billboard.LightInfluence = 0
	billboard.Parent = parent

	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextScaled = true
	textLabel.TextColor3 = color or Color3.fromRGB(255, 245, 220)
	textLabel.TextStrokeTransparency = 0.2
	textLabel.Text = text
	textLabel.Parent = billboard
end

local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.Parent = parent
	return part
end

-- Socle + mannequin invisible (HumanoidRootPart ancré) habillé par InsectVisualService, exactement
-- comme un vrai joueur.
local function displayInsect(parent: Instance, speciesId: string, stage: string, mutationId: string?, groundPosition: Vector3, caption: string?)
	block(parent, "Socle", Vector3.new(10, 1, 10), CFrame.new(groundPosition - Vector3.new(0, 0.5, 0)), Color3.fromRGB(70, 60, 50), Enum.Material.WoodPlanks)

	local dummy = Instance.new("Model")
	dummy.Name = string.format("%s_%s%s", speciesId, stage, if mutationId then "_" .. mutationId else "")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	-- Tête vers -Z dans le repère de l'insecte : on tourne le mannequin pour qu'il regarde l'allée.
	root.CFrame = CFrame.new(groundPosition + Vector3.new(0, 1, 0)) * CFrame.Angles(0, math.rad(-90), 0)
	root.Parent = dummy
	dummy.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HipHeight = 0
	humanoid.Parent = dummy
	dummy.Parent = parent

	dummy:ScaleTo((STAGE_SCALE[stage] or 1) * DISPLAY_SCALE)
	-- Après ScaleTo le root a grandi : on repose son bas exactement sur le socle.
	root.CFrame = CFrame.new(groundPosition + Vector3.new(0, root.Size.Y / 2, 0)) * root.CFrame.Rotation
	InsectVisualService.ApplyVisual(dummy, speciesId, stage, mutationId)

	if caption then
		label(root, caption, 6, nil, Vector2.new(150, 30))
	end
end

local function sortedSpecies(): { InsectData.InsectInfo }
	local list: { InsectData.InsectInfo } = {}
	for _, info in pairs(InsectData) do
		table.insert(list, info)
	end
	table.sort(list, function(a, b)
		local orderA = CATEGORY_ORDER[a.Category] or 99
		local orderB = CATEGORY_ORDER[b.Category] or 99
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.Name < b.Name
	end)
	return list
end

local function stagesFor(species: InsectData.InsectInfo): { string }
	if species.GrowthType == "Metamorphose" then
		return { "Oeuf", "Larve", "Cocon", "Adulte" }
	end
	return { "Oeuf", "Larve", "Mue", "Adulte" }
end

function ShowcaseService.Clear()
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
end

function ShowcaseService.Build(origin: Vector3?): Folder
	ShowcaseService.Clear()
	local base = origin or ORIGIN
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace

	local species = sortedSpecies()
	local insectWidth = #species * COLUMN_SPACING + 20
	local animalsZ = base.Z + 4 * STAGE_SPACING + 70
	local nestsZ = animalsZ + 90
	local depth = (nestsZ - base.Z) + 50

	-- Plateforme : de la bordure de la carte vers l'ouest, au ras du sol de la carte.
	block(
		folder,
		"Plateforme",
		Vector3.new(insectWidth, 2, depth),
		CFrame.new(base.X - insectWidth / 2 + 14, base.Y - 1, base.Z - 20 + depth / 2), -- chevauche le bord ouest de la carte
		Color3.fromRGB(95, 125, 70),
		Enum.Material.Grass
	)
	local title = block(folder, "Titre", Vector3.new(1, 1, 1), CFrame.new(base + Vector3.new(-insectWidth / 2, 30, -10)), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	title.Transparency = 1
	title.CanCollide = false
	label(title, "GALERIE 3D — MICRO WILD : SURVIVAL", 0, Color3.fromRGB(255, 220, 120), Vector2.new(600, 70))

	-- ---------- 1. Les 30 insectes, chaque stade ----------
	local insects = Instance.new("Folder")
	insects.Name = "Insectes"
	insects.Parent = folder
	local lastCategory = ""
	for index, info in ipairs(species) do
		local x = base.X - (index - 1) * COLUMN_SPACING
		if info.Category ~= lastCategory then
			lastCategory = info.Category
			local header = block(insects, "Categorie", Vector3.one, CFrame.new(x, base.Y + 18, base.Z - 12), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
			header.Transparency = 1
			header.CanCollide = false
			label(header, "▼ " .. info.Category .. "s", 0, Color3.fromRGB(150, 230, 255), Vector2.new(260, 50))
		end
		local column = Instance.new("Folder")
		column.Name = info.Id
		column.Parent = insects
		for stageIndex, stage in ipairs(stagesFor(info)) do
			local position = Vector3.new(x, base.Y, base.Z + (stageIndex - 1) * STAGE_SPACING)
			local caption = if stageIndex == 1 then info.Name .. "\n" .. stage else stage
			local ok, err = pcall(displayInsect, column, info.Id, stage, nil, position, caption)
			if not ok then
				warn(string.format("[Galerie] %s %s : %s", info.Id, stage, tostring(err)))
			end
		end
	end

	-- ---------- 2. Mutations rares ----------
	local mutations = Instance.new("Folder")
	mutations.Name = "Mutations"
	mutations.Parent = folder
	local mutationZ = base.Z + 4 * STAGE_SPACING + 22
	for index, mutationId in ipairs(InsectBodyPlans.MutationOrder) do
		local position = Vector3.new(base.X - (index - 1) * COLUMN_SPACING, base.Y, mutationZ)
		local info = InsectBodyPlans.Mutations[mutationId]
		pcall(displayInsect, mutations, "ScarabeeHercule", "Adulte", mutationId, position, "Mutation " .. info.Name)
	end
	local normal = Vector3.new(base.X - #InsectBodyPlans.MutationOrder * COLUMN_SPACING, base.Y, mutationZ)
	pcall(displayInsect, mutations, "ScarabeeHercule", "Adulte", nil, normal, "Normal (sans mutation)")

	-- ---------- 3. Les 5 animaux géants + alevin ----------
	local animals = Instance.new("Folder")
	animals.Name = "Animaux"
	animals.Parent = folder
	-- (constructeur, nom, hauteur de la Root au-dessus du sol pour que les pattes touchent le socle)
	local animalEntries: { { build: () -> Model, name: string, lift: number } } = {
		{ build = function() return AnimalModels.BuildBird(AnimalData.Oiseau.MaxHealth) end, name = AnimalData.Oiseau.Name, lift = 11 },
		{ build = function() return AnimalModels.BuildChameleon(AnimalData.Cameleon.MaxHealth) end, name = AnimalData.Cameleon.Name, lift = 8.5 },
		{ build = function() return AnimalModels.BuildGoldfish(AnimalData.PoissonRouge.MaxHealth, 0.7, "Poisson Rouge") end, name = AnimalData.PoissonRouge.Name, lift = 6 },
		{ build = function() return AnimalModels.BuildGoldfish(40, 0.18, "Alevin") end, name = "Alevin (proie)", lift = 2 },
		{ build = function() return AnimalModels.BuildCrab(AnimalData.Crabe.MaxHealth) end, name = AnimalData.Crabe.Name, lift = 5 },
		{ build = function() return AnimalModels.BuildSquirrel(AnimalData.Ecureuil.MaxHealth) end, name = AnimalData.Ecureuil.Name, lift = 9 },
	}
	for index, entry in ipairs(animalEntries) do
		local ok, err = pcall(function()
			local ground = Vector3.new(base.X - 20 - (index - 1) * 60, base.Y, animalsZ)
			block(animals, "Socle", Vector3.new(44, 1, 44), CFrame.new(ground - Vector3.new(0, 0.5, 0)), Color3.fromRGB(80, 70, 55), Enum.Material.Slate)
			local model = entry.build()
			model:PivotTo(CFrame.new(ground + Vector3.new(0, entry.lift, 0)) * CFrame.Angles(0, math.rad(-90), 0))
			-- Pas d'IA ici : ce ne sont que des statues (aucun tag "Animal").
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			end
			model.Parent = animals
			label(model.PrimaryPart :: BasePart, entry.name, 22, Color3.fromRGB(255, 180, 140), Vector2.new(260, 50))
		end)
		if not ok then
			warn("[Galerie] animal " .. entry.name .. " : " .. tostring(err))
		end
	end

	-- ---------- 4. Les nids ----------
	local nests = Instance.new("Folder")
	nests.Name = "Nids"
	nests.Parent = folder
	local nestStyles = { "Fourmiliere", "Termitiere", "Ruche", "NidPapier", "Toile", "Ootheque", "Cloche", "Brindilles", "IA" }
	for index, style in ipairs(nestStyles) do
		local ok, err = pcall(function()
			local ground = Vector3.new(base.X - 15 - (index - 1) * 30, base.Y, nestsZ)
			local model, core = GrowthAndNestService.BuildNestModel(style, ground, Color3.fromRGB(245, 240, 225))
			model.Parent = nests
			label(core, GrowthAndNestService.NestStyleNames[style] or style, 16, Color3.fromRGB(200, 255, 170), Vector2.new(200, 40))
		end)
		if not ok then
			warn("[Galerie] nid " .. style .. " : " .. tostring(err))
		end
	end
	local birdNestGround = Vector3.new(base.X - 15 - #nestStyles * 30 - 10, base.Y + 1.5, nestsZ)
	local birdNest, birdFloor = AnimalModels.BuildBirdNest(birdNestGround)
	birdNest.Parent = nests
	label(birdFloor, "Nid de l'Oiseau", 16, Color3.fromRGB(200, 255, 170), Vector2.new(200, 40))
	local dreyCenter = Vector3.new(birdNestGround.X - 40, base.Y + 9, nestsZ)
	local drey, dreyFloor = AnimalModels.BuildDrey(dreyCenter)
	drey.Parent = nests
	label(dreyFloor, "Hotte de l'Écureuil", 18, Color3.fromRGB(200, 255, 170), Vector2.new(200, 40))

	return folder
end

return ShowcaseService
