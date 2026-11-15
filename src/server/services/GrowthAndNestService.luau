--!strict
-- GrowthAndNestService.luau
-- Nids (Maman/Colonie, GDD §2 et §8.2) + progression de croissance des insectes.
-- API utilisée par SpawnMenuNetworkService / FoodService / PlayerLifecycleService :
--   CreateNest(motherPlayer), RemoveNest(ownerUserId), JoinNest(childPlayer, motherUserId),
--   LeaveNest(childPlayer), GetNestSummaries(), RefreshNestDisplay(ownerUserId), GetDefaultHome(speciesId)
--
-- Chaque nid est un modèle 3D construit selon l'espèce de la Maman (fourmilière, ruche, toile...),
-- tagué "Shelter" (chaleur, abri d'hiver). Deux "nids IA" (sol + mare) accueillent les joueurs
-- qui naissent sans Maman joueuse.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local MathUtils = require(ServerScriptService.utils.MathUtils)
local MovementService = require(ServerScriptService.services.MovementService)
local ServerTypes = require(ServerScriptService.types.ServerTypes)

local GrowthAndNestService = {}
GrowthAndNestService.ActiveNests = {} :: { [number]: ServerTypes.NestData }
-- (player, newStage) : écouté par ProgressionService (points d'évolution, récompense de la Maman).
GrowthAndNestService.StageChanged = Instance.new("BindableEvent")

local NEST_FED_GROWTH_MULTIPLIER = 1.5

-- Rythme de croissance, en points PAR SECONDE (hors saison / nid nourri). Équilibrage pour une
-- session normale sur la carte 1500x1500 : oeuf ~25 s, larve ~4,5 min, cocon = COCOON_DURATION_SECONDS,
-- soit adulte en ~5,5 min (métamorphose) / ~6,5 min (mues), puis ~6 min jusqu'à 100% (colonie).
local GROWTH_TICK_SECONDS = math.min(GameConstants.GROWTH_TICK_INTERVAL, 1) -- pas fin : jauge fluide
local EGG_GROWTH_PER_SECOND = 0.4
local LARVA_GROWTH_PER_SECOND = 0.15
local LATE_NYMPH_MULTIPLIER = 2 -- espèces à mues entre 50 et 75% (pendant que les autres sont en cocon)
local COCOON_GROWTH_PER_SECOND = (GameConstants.STAGE_THRESHOLDS.ADULTE - GameConstants.STAGE_THRESHOLDS.COCON)
	/ GameConstants.COCOON_DURATION_SECONDS
local ADULT_GROWTH_PER_SECOND = 0.07

-- Laisse des larves : avertissement + ralentissement progressif avant tout retour forcé au nid.
local LEASH_TICK_SECONDS = 0.5
local LEASH_WARN_RATIO = 0.8 -- la laisse "tire" à partir de 80% du rayon
local LEASH_HARD_RATIO = 1.3 -- au-delà (projeté, agrippé...) : retour immédiat
local LEASH_GRACE_SECONDS = 5 -- temps toléré hors du rayon avant le retour au nid
local LEASH_MODIFIER_KEY = "LarvaLeash"
local leashOutsideSince: { [Player]: number } = {}
local leashWarned: { [Player]: boolean } = {}

local nestsFolder: Folder? = nil
local landAINestPosition: Vector3? = nil
local pondAINestPosition: Vector3? = nil

local function familyIdFor(motherUserId: number): string
	return "Nest_" .. tostring(motherUserId)
end

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function getNestsFolder(): Folder
	if nestsFolder and nestsFolder.Parent then
		return nestsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Nests"
	folder.Parent = workspace
	nestsFolder = folder
	return folder
end

-- ============================================================
-- Modèles 3D de nids
-- ============================================================

local function nestPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?, transparency: number?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	if shape then
		part.Shape = shape
	end
	part.Transparency = transparency or 0
	part.Parent = model
	return part
end

local function ellipsoidPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number?): Part
	local part = nestPart(model, name, size, cf, color, material, nil, transparency)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

type NestStyle = "Fourmiliere" | "Termitiere" | "Ruche" | "NidPapier" | "Toile" | "Ootheque" | "Cloche" | "Brindilles" | "IA"

local function nestStyleFor(speciesId: string): NestStyle
	if speciesId == "FourmiRousse" then
		return "Fourmiliere"
	elseif speciesId == "TermiteSoldat" then
		return "Termitiere"
	elseif speciesId == "AbeilleMellifere" then
		return "Ruche"
	elseif speciesId == "FrelonAsiatique" or speciesId == "GuepeEmeraude" then
		return "NidPapier"
	elseif speciesId == "VeuveNoire" or speciesId == "AraigneeSauteuse" then
		return "Toile"
	elseif speciesId == "ManteReligieuse" or speciesId == "PhasmeBaton" then
		return "Ootheque"
	elseif speciesId == "Argyronete" then
		return "Cloche"
	end
	return "Brindilles"
end

local NEST_STYLE_NAMES: { [string]: string } = {
	Fourmiliere = "Fourmilière",
	Termitiere = "Termitière",
	Ruche = "Ruche",
	NidPapier = "Nid de papier",
	Toile = "Toile maternelle",
	Ootheque = "Oothèque",
	Cloche = "Cloche de plongée",
	Brindilles = "Nid",
	IA = "Nid sauvage",
}

-- Construit le nid posé au sol à `groundPosition`. Retourne le modèle et sa part centrale.
local function buildNestModel(style: NestStyle, groundPosition: Vector3, eggColor: Color3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Nid_" .. style
	local base = CFrame.new(groundPosition)
	local core: BasePart

	if style == "Fourmiliere" or style == "Termitiere" then
		local color = if style == "Fourmiliere" then Color3.fromRGB(120, 85, 55) else Color3.fromRGB(170, 130, 85)
		if style == "Fourmiliere" then
			-- Dôme d'aiguilles et de terre + entrée sombre.
			core = ellipsoidPart(model, "Dome", Vector3.new(20, 9, 20), base * CFrame.new(0, 2, 0), color, Enum.Material.Ground)
			for i = 1, 14 do
				local angle = i * 2.4
				nestPart(model, "Aiguille", Vector3.new(4, 0.3, 0.3), base * CFrame.new(math.cos(angle) * 6, 5.5, math.sin(angle) * 6) * CFrame.Angles(0, angle, math.rad(25)), Color3.fromRGB(150, 110, 60), Enum.Material.Wood)
			end
		else
			-- Termitière : cheminées coniques empilées.
			core = nestPart(model, "Base", Vector3.new(6, 16, 16), base * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.Sandstone, Enum.PartType.Cylinder)
			for i = 1, 4 do
				nestPart(model, "Cheminee", Vector3.new(10 - i * 1.5, 7 - i, 7 - i), base * CFrame.new(math.cos(i) * 2, 6 + i * 3.5, math.sin(i) * 2) * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.Sandstone, Enum.PartType.Cylinder)
			end
		end
		nestPart(model, "Entree", Vector3.new(0.5, 3, 3), base * CFrame.new(0, 2, -9.5) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(20, 15, 10), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	elseif style == "Ruche" then
		-- Rayons de cire hexagonaux (cylindres à 6 faces simulés par des cylindres serrés).
		local wax = Color3.fromRGB(235, 180, 50)
		core = nestPart(model, "Socle", Vector3.new(12, 1, 12), base * CFrame.new(0, 0.5, 0), Color3.fromRGB(200, 150, 40), Enum.Material.Plastic)
		for row = 0, 4 do
			for col = -3, 3 do
				local x = col * 2.1 + (row % 2) * 1.05
				nestPart(model, "Alveole", Vector3.new(2.4, 2, 2), base * CFrame.new(x, 2 + row * 1.8, 0) * CFrame.Angles(0, math.rad(90), 0), wax, Enum.Material.Plastic, Enum.PartType.Cylinder)
				if (row + col) % 3 == 0 then
					nestPart(model, "Miel", Vector3.new(0.3, 1.5, 1.5), base * CFrame.new(x, 2 + row * 1.8, -1.2) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(255, 200, 40), Enum.Material.Glass, Enum.PartType.Cylinder, 0.2)
				end
			end
		end
	elseif style == "NidPapier" then
		local paper = Color3.fromRGB(170, 160, 145)
		core = ellipsoidPart(model, "Boule", Vector3.new(14, 16, 14), base * CFrame.new(0, 8, 0), paper, Enum.Material.Fabric)
		for i = 1, 5 do
			ellipsoidPart(model, "Strie", Vector3.new(14.3, 1, 14.3), base * CFrame.new(0, 2 + i * 2.6, 0), paper:Lerp(Color3.fromRGB(110, 100, 90), 0.4), Enum.Material.Fabric)
		end
		nestPart(model, "Entree", Vector3.new(0.4, 3, 3), base * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(25, 20, 15), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	elseif style == "Toile" then
		core = nestPart(model, "Ancre", Vector3.new(1, 1, 1), base * CFrame.new(0, 0.5, 0), Color3.fromRGB(240, 240, 240), Enum.Material.Fabric, nil, 1)
		local silk = Color3.fromRGB(240, 240, 245)
		for i = 1, 8 do
			local angle = i / 8 * math.pi * 2
			nestPart(model, "Fil", Vector3.new(16, 0.08, 0.08), base * CFrame.new(math.cos(angle) * 8, 6, math.sin(angle) * 8) * CFrame.Angles(0, -angle, 0), silk, Enum.Material.Neon, nil, 0.3)
		end
		for ring = 1, 4 do
			for i = 1, 8 do
				local angle = (i + 0.5) / 8 * math.pi * 2
				nestPart(model, "Spirale", Vector3.new(0.08, 0.08, ring * 3.9), base * CFrame.new(math.cos(angle) * ring * 3.7, 6, math.sin(angle) * ring * 3.7) * CFrame.Angles(0, -angle, 0), silk, Enum.Material.Neon, nil, 0.4)
			end
		end
		ellipsoidPart(model, "SacOeufs", Vector3.new(3, 3.6, 3), base * CFrame.new(0, 6, 0), Color3.fromRGB(235, 225, 200), Enum.Material.Fabric)
	elseif style == "Ootheque" then
		nestPart(model, "Tige", Vector3.new(14, 0.6, 0.6), base * CFrame.new(0, 7, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(95, 75, 45), Enum.Material.Wood, Enum.PartType.Cylinder)
		core = ellipsoidPart(model, "Ootheque", Vector3.new(3.6, 5, 4.5), base * CFrame.new(0, 9, -1.2), Color3.fromRGB(205, 175, 120), Enum.Material.Sand)
		for i = 1, 5 do
			ellipsoidPart(model, "Bourrelet", Vector3.new(3.7, 0.5, 4.6), base * CFrame.new(0, 7 + i * 0.8, -1.2), Color3.fromRGB(180, 150, 100), Enum.Material.Sand)
		end
	elseif style == "Cloche" then
		core = ellipsoidPart(model, "Bulle", Vector3.new(10, 8, 10), base * CFrame.new(0, 4, 0), Color3.fromRGB(215, 230, 245), Enum.Material.Glass, 0.45)
		core.Reflectance = 0.35
		for i = 1, 6 do
			local angle = i / 6 * math.pi * 2
			nestPart(model, "FilAmarre", Vector3.new(0.08, 6, 0.08), base * CFrame.new(math.cos(angle) * 4.5, 1.5, math.sin(angle) * 4.5), Color3.fromRGB(240, 240, 240), Enum.Material.Neon, nil, 0.3)
		end
	else
		-- "Brindilles" / "IA" : coupe de brindilles + mousse.
		local twig = Color3.fromRGB(110, 80, 50)
		core = nestPart(model, "Mousse", Vector3.new(2, 14, 14), base * CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(80, 120, 60), Enum.Material.Grass, Enum.PartType.Cylinder)
		for i = 1, 18 do
			local angle = i / 18 * math.pi * 2
			nestPart(model, "Brindille", Vector3.new(7, 0.6, 0.6), base * CFrame.new(math.cos(angle) * 6.5, 2 + (i % 3) * 0.6, math.sin(angle) * 6.5) * CFrame.Angles(0, -angle + math.rad(90), math.rad(15)), twig, Enum.Material.Wood)
		end
	end

	-- Quelques oeufs visibles dans chaque nid.
	if style ~= "Toile" and style ~= "Ootheque" then
		for i = 1, 5 do
			local angle = i / 5 * math.pi * 2
			ellipsoidPart(model, "Oeuf", Vector3.new(1.1, 1.5, 1.1), base * CFrame.new(math.cos(angle) * 2.2, 2.2, math.sin(angle) * 2.2), eggColor, Enum.Material.SmoothPlastic)
		end
	end

	model.PrimaryPart = core
	CollectionService:AddTag(core, "Shelter")
	model.Parent = getNestsFolder()
	return model, core
end

-- Utilisé par ShowcaseService (galerie de modèles) : construit un nid d'exemple.
function GrowthAndNestService.BuildNestModel(style: string, groundPosition: Vector3, eggColor: Color3): (Model, BasePart)
	return buildNestModel(style :: NestStyle, groundPosition, eggColor)
end

GrowthAndNestService.NestStyleNames = NEST_STYLE_NAMES

local function attachNestLabel(core: BasePart, text: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NestLabel"
	billboard.Size = UDim2.fromOffset(220, 50)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 12, 0)
	billboard.MaxDistance = 140
	billboard.AlwaysOnTop = false
	billboard.Parent = core

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 240, 200)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.Parent = billboard
end

local function setNestLabel(core: BasePart, text: string)
	local billboard = core:FindFirstChild("NestLabel")
	local label = billboard and billboard:FindFirstChild("Text") :: TextLabel?
	if label then
		label.Text = text
	end
end

-- ============================================================
-- Nids de joueurs
-- ============================================================

-- Pose le nid au sol sous la Maman (ou au fond de l'eau pour l'Argyronète).
local function findGroundBelow(position: Vector3, ignore: { Instance }): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local result = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), params)
	return if result then result.Position else position - Vector3.new(0, 2, 0)
end

function GrowthAndNestService.CreateNest(motherPlayer: Player): boolean
	local growth = (motherPlayer:GetAttribute("Growth") :: number?) or 0
	if growth < GameConstants.NEST_MIN_GROWTH or motherPlayer:GetAttribute("Stage") ~= "Adulte" then
		return false
	end
	local character = motherPlayer.Character
	if not character or not character.PrimaryPart then
		return false
	end
	-- On ne fonde pas une colonie au sommet de l'arbre ou en plein vol : il faut être posé.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local motherSpecies = InsectData[(motherPlayer:GetAttribute("Species") :: string?) or ""]
	local swimming = motherSpecies ~= nil and motherSpecies.CanSwim and humanoid ~= nil and humanoid:GetState() == Enum.HumanoidStateType.Swimming
	if humanoid and humanoid.FloorMaterial == Enum.Material.Air and not swimming then
		notify(motherPlayer, "Posez-vous au sol pour construire votre nid.", "warning")
		return false
	end

	local speciesId = (motherPlayer:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	local plan = InsectBodyPlans.Get(speciesId)
	local style = nestStyleFor(speciesId)
	local groundPosition = findGroundBelow(character.PrimaryPart.Position, { character })
	local model, core = buildNestModel(style, groundPosition, plan.LarvaColor:Lerp(Color3.new(1, 1, 1), 0.6))
	model.Name = "Nid_" .. motherPlayer.Name
	core:SetAttribute("OwnerUserId", motherPlayer.UserId)
	attachNestLabel(core, "")

	GrowthAndNestService.ActiveNests[motherPlayer.UserId] = {
		OwnerUserId = motherPlayer.UserId,
		FamilyId = familyIdFor(motherPlayer.UserId),
		SpeciesId = speciesId,
		Position = groundPosition + Vector3.new(0, 2, 0),
		StoredFood = 100,
		Children = {},
		Model = model,
		Style = NEST_STYLE_NAMES[style] or "Nid",
	}
	motherPlayer:SetAttribute("IsMother", true)
	motherPlayer:SetAttribute("FamilyId", familyIdFor(motherPlayer.UserId))
	motherPlayer:SetAttribute("HomePosition", groundPosition + Vector3.new(0, 2, 0))
	GrowthAndNestService.RefreshNestDisplay(motherPlayer.UserId)
	return true
end

function GrowthAndNestService.RemoveNest(ownerUserId: number)
	local nest = GrowthAndNestService.ActiveNests[ownerUserId]
	GrowthAndNestService.ActiveNests[ownerUserId] = nil
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if owner then
		owner:SetAttribute("IsMother", false)
		owner:SetAttribute("FamilyId", nil)
	end
	if not nest then
		return
	end
	for _, child in ipairs(nest.Children) do
		if child.Parent then
			child:SetAttribute("FamilyId", nil)
			child:SetAttribute("OwnerNestUserId", nil)
			-- Orphelin : rattaché au nid sauvage (sinon tenu en laisse autour d'un nid disparu).
			child:SetAttribute("HomePosition", GrowthAndNestService.GetDefaultHome((child:GetAttribute("Species") :: string?) or ""))
			notify(child, "Votre Maman est morte : le nid est détruit !", "warning")
		end
	end
	if nest.Model then
		nest.Model:Destroy()
	end
end

function GrowthAndNestService.JoinNest(childPlayer: Player, motherUserId: number): boolean
	local nest = GrowthAndNestService.ActiveNests[motherUserId]
	if not nest then
		return false
	end
	table.insert(nest.Children, childPlayer)
	childPlayer:SetAttribute("FamilyId", nest.FamilyId)
	childPlayer:SetAttribute("OwnerNestUserId", motherUserId)
	GrowthAndNestService.RefreshNestDisplay(motherUserId)
	return true
end

function GrowthAndNestService.LeaveNest(childPlayer: Player)
	if childPlayer:GetAttribute("IsMother") == true then
		return -- une Maman ne "quitte" pas sa propre famille (voir RemoveNest)
	end
	local ownerUserId = childPlayer:GetAttribute("OwnerNestUserId") :: number?
	if ownerUserId then
		local nest = GrowthAndNestService.ActiveNests[ownerUserId]
		if nest then
			local index = table.find(nest.Children, childPlayer)
			if index then
				table.remove(nest.Children, index)
			end
			GrowthAndNestService.RefreshNestDisplay(ownerUserId)
		end
	end
	childPlayer:SetAttribute("FamilyId", nil)
	childPlayer:SetAttribute("OwnerNestUserId", nil)
	if ownerUserId and childPlayer:GetAttribute("CanLeaveNest") ~= true then
		childPlayer:SetAttribute("HomePosition", GrowthAndNestService.GetDefaultHome((childPlayer:GetAttribute("Species") :: string?) or ""))
	end
end

function GrowthAndNestService.GetNest(ownerUserId: number): ServerTypes.NestData?
	return GrowthAndNestService.ActiveNests[ownerUserId]
end

function GrowthAndNestService.RefreshNestDisplay(ownerUserId: number)
	local nest = GrowthAndNestService.ActiveNests[ownerUserId]
	if not nest or not nest.Model or not nest.Model.PrimaryPart then
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	local species = InsectData[nest.SpeciesId]
	setNestLabel(
		nest.Model.PrimaryPart,
		string.format(
			"%s de %s (%s)\n%d bébé(s) • Réserve : %d",
			nest.Style or "Nid",
			if owner then owner.Name else "?",
			if species then species.Name else nest.SpeciesId,
			#nest.Children,
			math.floor(nest.StoredFood)
		)
	)
end

function GrowthAndNestService.GetNestSummaries(): { ServerTypes.NestSummary }
	local summaries: { ServerTypes.NestSummary } = {}
	for ownerUserId, nest in pairs(GrowthAndNestService.ActiveNests) do
		local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
		if ownerPlayer then
			table.insert(summaries, {
				OwnerUserId = ownerUserId,
				OwnerName = ownerPlayer.Name,
				SpeciesId = nest.SpeciesId,
				ChildCount = #nest.Children,
			})
		else
			GrowthAndNestService.RemoveNest(ownerUserId)
		end
	end
	return summaries
end

-- Maison par défaut d'un joueur sans Maman : la mare pour les larves aquatiques, sinon le nid IA.
function GrowthAndNestService.GetDefaultHome(speciesId: string): Vector3?
	local species = InsectData[speciesId]
	local aquaticLarva = GameConstants.AQUATIC_LARVA_SPECIES[speciesId] == true
		or (species ~= nil and species.Category == "Aquatique")
	if aquaticLarva and pondAINestPosition then
		return pondAINestPosition
	end
	return landAINestPosition
end

-- ============================================================
-- Nids IA
-- ============================================================

local function createAINests()
	local generated = workspace:FindFirstChild("GeneratedWorld")
	local spawnLocation = generated and generated:FindFirstChild("OeufSpawn")
	if spawnLocation and spawnLocation:IsA("BasePart") then
		local groundPosition = spawnLocation.Position + Vector3.new(-14, -0.5, 0)
		local model, core = buildNestModel("IA", groundPosition, Color3.fromRGB(245, 240, 225))
		model.Name = "NidSauvage_Terre"
		CollectionService:AddTag(core, "AINest")
		attachNestLabel(core, "Nid sauvage (protégé par l'IA)")
		landAINestPosition = groundPosition + Vector3.new(0, 2, 0)
	end

	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	local pondZone: BasePart? = nil
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") and zone.Name == "PondZone_Mare" then
			pondZone = zone
		end
	end
	if waterLevel and pondZone then
		-- Sous l'eau, 2 studs au-dessus de la vase, près de la berge sud (là où arrive la rampe d'accès).
		local groundPosition = Vector3.new(pondZone.Position.X, waterLevel - WorldLayout.POND_DEPTH + 2, pondZone.Position.Z + pondZone.Size.Z * 0.3)
		local model, core = buildNestModel("Brindilles", groundPosition, Color3.fromRGB(230, 235, 210))
		model.Name = "NidSauvage_Mare"
		CollectionService:AddTag(core, "AINest")
		attachNestLabel(core, "Nurserie aquatique (IA)")
		pondAINestPosition = groundPosition + Vector3.new(0, 2, 0)
	end
end

-- ============================================================
-- Croissance
-- ============================================================

local function applyMoltWindow(player: Player, speciesId: string, growthAtTrigger: number)
	player:SetAttribute("IsMolting", true)
	task.spawn(EvolutionDomain.SetStage, player, speciesId, "Mue")
	local lifeToken = player:GetAttribute("LifeToken")

	task.delay(GameConstants.MOLT_SOFT_SHELL_SECONDS, function()
		-- Mort / nouvelle vie pendant la mue : ce rappel appartient à l'ancienne vie.
		if not player.Parent or player:GetAttribute("LifeToken") ~= lifeToken or player:GetAttribute("Species") ~= speciesId then
			return
		end
		player:SetAttribute("IsMolting", false)
		local currentGrowth = (player:GetAttribute("Growth") :: number?) or growthAtTrigger
		local settledStage = EvolutionDomain.GetStageForGrowth(speciesId, currentGrowth)
		EvolutionDomain.SetStage(player, speciesId, settledStage)
	end)
end

local function releaseLeash(player: Player)
	if leashWarned[player] == nil and leashOutsideSince[player] == nil then
		return
	end
	leashWarned[player] = nil
	leashOutsideSince[player] = nil
	MovementService.RemoveModifier(player, LEASH_MODIFIER_KEY)
	player:SetAttribute("LeashStrain", 0)
end

-- Laisse : une larve trop jeune ne quitte pas son nid/sa mare (GDD §2 étape 2). Plus elle tire sur
-- la laisse, plus elle ralentit (attribut LeashStrain 0..1 lisible par le client) ; elle n'est
-- ramenée au nid que si elle reste dehors malgré l'avertissement.
local function enforceLarvaLeash(player: Player, now: number)
	local stage = player:GetAttribute("Stage")
	local home = player:GetAttribute("HomePosition") :: Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if player:GetAttribute("CanLeaveNest") == true or (stage ~= "Larve" and stage ~= "Mue") or not home or not character or not root then
		releaseLeash(player)
		return
	end

	local radius = GameConstants.LARVA_LEASH_RADIUS
	local distance = (root.Position - home).Magnitude
	local strain = math.clamp((distance - radius * LEASH_WARN_RATIO) / (radius * (1 - LEASH_WARN_RATIO)), 0, 1)
	if strain <= 0 then
		releaseLeash(player)
		return
	end

	player:SetAttribute("LeashStrain", MathUtils.RoundToDecimal(strain, 1))
	MovementService.AddModifier(player, LEASH_MODIFIER_KEY, "Multiplier", 1 - 0.6 * strain)
	if not leashWarned[player] then
		leashWarned[player] = true
		notify(player, "Vous vous éloignez trop du nid : faites demi-tour !", "warning")
	end

	if distance <= radius then
		leashOutsideSince[player] = nil
		return
	end
	local since = leashOutsideSince[player] or now
	leashOutsideSince[player] = since
	if distance > radius * LEASH_HARD_RATIO or now - since >= LEASH_GRACE_SECONDS then
		character:PivotTo(CFrame.new(home + Vector3.new(0, 3, 0)))
		releaseLeash(player)
		notify(player, "Trop jeune pour quitter le nid ! Grandissez d'abord.", "warning")
	end
end

local function growPlayer(player: Player, seasonInfo: SeasonConfig.SeasonInfo, now: number)
	-- La croissance ne démarre qu'après le choix d'espèce dans le menu de spawn.
	if player:GetAttribute("HasConfirmedSpawn") ~= true then
		return
	end

	if player:GetAttribute("IsMolting") == true then
		return
	end

	local hunger = (player:GetAttribute("Hunger") :: number?) or 0
	local thirst = (player:GetAttribute("Thirst") :: number?) or 0
	-- Un cocon immobile ne peut pas manger : sa croissance ne dépend plus de la faim/soif.
	if (hunger < 20 or thirst < 20) and player:GetAttribute("Stage") ~= "Cocon" then
		return
	end

	local growth = (player:GetAttribute("Growth") :: number?) or 0
	if growth >= GameConstants.STAGE_THRESHOLDS.MAX_GROWTH then
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	local previousStage = (player:GetAttribute("Stage") :: string?) or "Oeuf"
	local previousGrowth = growth

	local thresholds = GameConstants.STAGE_THRESHOLDS
	local rate: number
	if growth < thresholds.LARVE then
		rate = EGG_GROWTH_PER_SECOND -- durée fixe : attendre dans l'oeuf n'est pas du jeu
	elseif previousStage == "Cocon" then
		rate = COCOON_GROWTH_PER_SECOND -- durée fixe (GDD : 30 à 45 s)
	else
		rate = if growth >= thresholds.ADULTE then ADULT_GROWTH_PER_SECOND else LARVA_GROWTH_PER_SECOND
		if growth >= thresholds.COCON and growth < thresholds.ADULTE then
			rate *= LATE_NYMPH_MULTIPLIER
		end
		rate *= seasonInfo.GrowthSpeedMultiplier
		local fedUntil = player:GetAttribute("NestFedUntil") :: number?
		if fedUntil and fedUntil > now then
			rate *= NEST_FED_GROWTH_MULTIPLIER
		end
	end

	growth = math.clamp(growth + rate * GROWTH_TICK_SECONDS, 0, thresholds.MAX_GROWTH)
	-- 2 décimales : un pas de 0.07 arrondi à 0.1 fausserait le rythme.
	player:SetAttribute("Growth", MathUtils.RoundToDecimal(growth, 2))

	if EvolutionDomain.ShouldTriggerMolt(speciesId, previousGrowth, growth) then
		applyMoltWindow(player, speciesId, growth)
		notify(player, "Vous muez ! Votre carapace est molle quelques secondes.", "warning")
		return
	end

	local newStage = EvolutionDomain.GetStageForGrowth(speciesId, growth)
	if newStage ~= previousStage then
		if newStage == "Adulte" then
			player:SetAttribute("CanLeaveNest", true)
			notify(player, "Vous êtes ADULTE ! Explorez, chassez, et à 100% fondez une colonie.", "info")
		elseif newStage == "Cocon" then
			notify(player, "Métamorphose : vous tissez votre cocon...", "info")
			-- Réserves de départ : le cocon (immobile) ne doit pas mourir de faim pendant ~50 s.
			player:SetAttribute("Hunger", math.max(50, (player:GetAttribute("Hunger") :: number?) or 0))
			player:SetAttribute("Thirst", math.max(50, (player:GetAttribute("Thirst") :: number?) or 0))
		elseif newStage == "Larve" then
			notify(player, "Éclosion ! Vous êtes une larve. Mangez pour grandir.", "info")
		end
		-- SetStage peut céder (WaitForChild) : ne bloque pas la boucle des autres joueurs.
		task.spawn(EvolutionDomain.SetStage, player, speciesId, newStage)
		GrowthAndNestService.StageChanged:Fire(player, newStage)
	end
	if growth >= GameConstants.STAGE_THRESHOLDS.MAX_GROWTH and previousGrowth < GameConstants.STAGE_THRESHOLDS.MAX_GROWTH then
		notify(player, "Croissance maximale ! Vous pouvez fonder votre colonie (bouton « Fonder une colonie »).", "info")
	end
end

function GrowthAndNestService.Start()
	createAINests()

	task.spawn(function()
		while true do
			task.wait(GROWTH_TICK_SECONDS)

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string?) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps
			local now = os.clock()

			for _, player in ipairs(Players:GetPlayers()) do
				-- Un joueur en erreur (corps 3D, attribut inattendu) ne fige pas la croissance des autres.
				local ok, err = pcall(growPlayer, player, seasonInfo, now)
				if not ok then
					warn("[GrowthAndNestService] " .. player.Name .. " : " .. tostring(err))
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(LEASH_TICK_SECONDS)
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				local ok, err = pcall(enforceLarvaLeash, player, now)
				if not ok then
					warn("[GrowthAndNestService] laisse de " .. player.Name .. " : " .. tostring(err))
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		leashOutsideSince[player] = nil
		leashWarned[player] = nil
	end)
end

return GrowthAndNestService
