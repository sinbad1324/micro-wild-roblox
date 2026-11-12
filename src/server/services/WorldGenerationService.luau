--!strict
-- WorldGenerationService.luau
-- Génère procéduralement la Grande Map (GDD section 4), entièrement en code, au boot serveur.
--
-- Contrat posé pour SurvivalService (lu dès son tout premier tick, d'où l'appel AVANT son
-- Start() dans ServerBootstrap) : workspace:SetAttribute("PondWaterLevel", <Y>), tag
-- CollectionService "PondZone" sur les volumes de test de submersion, et tag "Shelter" sur
-- chaque abri (écorce du Chêne, galerie de la Souche, surplomb des Rochers).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FoodData = require(ReplicatedStorage.shared.FoodData)

local WorldGenerationService = {}

-- Graine fixe : la carte doit être strictement reproductible d'un boot serveur à l'autre
-- (math.random est ré-amorcé aléatoirement par le moteur, Random.new(seed) ne l'est jamais).
local rng = Random.new(1992417)

local GROUND_TOP_Y = 48 -- au-dessus de tout contenu Workspace préexistant (Baseplate inclus)
local GROUND_BOTTOM_Y = 8
local GROUND_THICKNESS = GROUND_TOP_Y - GROUND_BOTTOM_Y
local GROUND_CENTER_Y = (GROUND_TOP_Y + GROUND_BOTTOM_Y) / 2
local MAP_SIZE = 500

-- Un biome par quadrant (le Chêne reste au centre), largement à l'intérieur du carré 500x500.
local ROCKY_CORNER = Vector3.new(170, GROUND_TOP_Y, 170) -- "Le Coin des Rochers Arides"
local PRAIRIE_CENTER = Vector3.new(-170, GROUND_TOP_Y, 170) -- "La Prairie Fleurie"
local POND_CENTER = Vector3.new(170, GROUND_TOP_Y, -170) -- "La Mare & Le Ruisseau"
local STUMP_CENTER = Vector3.new(-170, GROUND_TOP_Y, -170) -- "La Souche Pourrie & Les Galeries Souterraines"
local TREE_POSITION = Vector3.new(0, GROUND_TOP_Y, 0) -- "Le Grand Chêne"

type PartOptions = {
	CanCollide: boolean?,
	CanQuery: boolean?,
	CanTouch: boolean?,
	Transparency: number?,
	Shape: Enum.PartType?,
}

local function newPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	options: PartOptions?
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Material = material
	part.Color = color
	part.Anchored = true
	if options then
		if options.Shape then
			part.Shape = options.Shape :: Enum.PartType
		end
		if options.CanCollide ~= nil then
			part.CanCollide = options.CanCollide :: boolean
		end
		if options.CanQuery ~= nil then
			part.CanQuery = options.CanQuery :: boolean
		end
		if options.CanTouch ~= nil then
			part.CanTouch = options.CanTouch :: boolean
		end
		if options.Transparency then
			part.Transparency = options.Transparency :: number
		end
	end
	part.Parent = parent
	return part
end

-- Un cylindre Roblox a son axe le long de son X local : cette rotation de 90° autour de Z le
-- redresse à la verticale (même technique que le champignon de CarcassService).
local function verticalCylinderCFrame(basePosition: Vector3, height: number): CFrame
	return CFrame.new(basePosition + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

-- Relie deux points par un bloc rectangulaire (branches, racines) : plus simple et plus fiable
-- qu'un cylindre orienté arbitrairement dans l'espace.
local function linkPart(parent: Instance, from: Vector3, to: Vector3, thickness: number, name: string, material: Enum.Material, color: Color3): BasePart
	local length = math.max((to - from).Magnitude, 0.1)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(thickness, thickness, length)
	part.CFrame = CFrame.new(from:Lerp(to, 0.5), to)
	part.Anchored = true
	part.CanCollide = true
	part.Material = material
	part.Color = color
	part.Parent = parent
	return part
end

local function tagShelter(instance: Instance)
	CollectionService:AddTag(instance, "Shelter")
end

local function spawnFoodNode(parent: Instance, position: Vector3, foodType: FoodData.FoodTypeId, color: Color3)
	local node = Instance.new("Part")
	node.Name = "FoodNode_" .. foodType
	node.Shape = Enum.PartType.Ball
	node.Size = Vector3.new(1.6, 1.6, 1.6)
	node.CFrame = CFrame.new(position)
	node.Anchored = true
	node.CanCollide = false
	node.Material = Enum.Material.Neon
	node.Color = color
	node.Parent = parent
	node:SetAttribute("FoodType", foodType)
	CollectionService:AddTag(node, "FoodNode")
end

------------------------------------------------------------------------------------------------
-- 1. Sol : grande plaine herbeuse 500x500.
------------------------------------------------------------------------------------------------
local function generateGround()
	workspace.Terrain:FillBlock(
		CFrame.new(0, GROUND_CENTER_Y, 0),
		Vector3.new(MAP_SIZE, GROUND_THICKNESS, MAP_SIZE),
		Enum.Material.Grass
	)
end

------------------------------------------------------------------------------------------------
-- "Le Coin des Rochers Arides" : patches de Rock/Sable surélevés, rochers épars, et un surplomb
-- qui sert de 2e abri d'hiver (en plus de l'écorce du Chêne et de la galerie de la Souche).
------------------------------------------------------------------------------------------------
local function generateRockyCorner(root: Folder)
	local terrain = workspace.Terrain
	local folder = Instance.new("Folder")
	folder.Name = "RochersArides"
	folder.Parent = root

	for _ = 1, 5 do
		local offset = Vector3.new(rng:NextInteger(-45, 45), 0, rng:NextInteger(-45, 45))
		local center = ROCKY_CORNER + offset
		local footprint = rng:NextInteger(25, 45)
		local raisedTop = GROUND_TOP_Y + rng:NextInteger(3, 9)
		local patchHeight = rng:NextInteger(10, 18)
		local material = if rng:NextNumber() < 0.5 then Enum.Material.Rock else Enum.Material.Sand
		terrain:FillBlock(
			CFrame.new(center.X, raisedTop - patchHeight / 2, center.Z),
			Vector3.new(footprint, patchHeight, footprint),
			material
		)
	end

	for i = 1, 8 do
		local pos = ROCKY_CORNER + Vector3.new(rng:NextInteger(-45, 45), 0, rng:NextInteger(-45, 45))
		local size = rng:NextInteger(4, 9)
		local baseY = GROUND_TOP_Y + rng:NextInteger(2, 8)
		newPart(
			folder,
			"Rocher" .. i,
			Vector3.new(size, size * 0.8, size),
			CFrame.new(pos.X, baseY + size * 0.4, pos.Z)
				* CFrame.Angles(math.rad(rng:NextInteger(0, 359)), math.rad(rng:NextInteger(0, 359)), 0),
			Enum.Material.Rock,
			Color3.fromRGB(118, 108, 96),
			{ Shape = Enum.PartType.Ball }
		)
	end

	-- Surplomb rocheux : pierres chaudes au soleil le jour, abri la nuit/en hiver (GDD section 4/8).
	local overhangCenter = ROCKY_CORNER + Vector3.new(15, 0, -15)
	local pillarHeight = 10
	newPart(
		folder, "SurplombPilierA", Vector3.new(4, pillarHeight, 4),
		CFrame.new(overhangCenter.X - 7, GROUND_TOP_Y + pillarHeight / 2, overhangCenter.Z),
		Enum.Material.Rock, Color3.fromRGB(110, 100, 90)
	)
	newPart(
		folder, "SurplombPilierB", Vector3.new(4, pillarHeight, 4),
		CFrame.new(overhangCenter.X + 7, GROUND_TOP_Y + pillarHeight / 2, overhangCenter.Z),
		Enum.Material.Rock, Color3.fromRGB(110, 100, 90)
	)
	newPart(
		folder, "SurplombDalle", Vector3.new(20, 3, 14),
		CFrame.new(overhangCenter.X, GROUND_TOP_Y + pillarHeight + 1.5, overhangCenter.Z),
		Enum.Material.Rock, Color3.fromRGB(130, 118, 104)
	)
	-- Marqueur au ras du sol (pas la dalle en hauteur) : reste à <=14 tiges (SHELTER_CHECK_RADIUS)
	-- de tout joueur réfugié dessous.
	local shelterMarker = newPart(
		folder, "SurplombAbri", Vector3.new(16, 1, 10),
		CFrame.new(overhangCenter.X, GROUND_TOP_Y + 0.5, overhangCenter.Z),
		Enum.Material.Rock, Color3.fromRGB(120, 108, 96)
	)
	tagShelter(shelterMarker)
end

------------------------------------------------------------------------------------------------
-- 2. "La Mare & Le Ruisseau".
------------------------------------------------------------------------------------------------
local function generatePond(root: Folder)
	local terrain = workspace.Terrain
	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "PondZones"
	zonesFolder.Parent = root

	local waterTop = GROUND_TOP_Y - 8 -- en contrebas du sol : berges visibles tout autour
	local basinBottom = waterTop - 8 -- au moins 16 tiges sous la surface, loin de toute galerie
	local airCenterY = (waterTop + GROUND_TOP_Y) / 2
	local airHeight = GROUND_TOP_Y - waterTop
	local waterCenterY = (basinBottom + waterTop) / 2
	local waterHeight = waterTop - basinBottom

	-- "La Mare" : on creuse d'abord l'air au-dessus du niveau d'eau avec une empreinte plus large
	-- (ça dessine la berge), puis on remplit l'eau en dessous avec une empreinte plus étroite qui
	-- repose directement sur le fond non creusé : jamais d'eau en lévitation.
	local mareAirFootprint = Vector3.new(72, airHeight, 52)
	local mareWaterFootprint = Vector3.new(60, waterHeight, 40)
	terrain:FillBlock(CFrame.new(POND_CENTER.X, airCenterY, POND_CENTER.Z), mareAirFootprint, Enum.Material.Air)
	terrain:FillBlock(CFrame.new(POND_CENTER.X, waterCenterY, POND_CENTER.Z), mareWaterFootprint, Enum.Material.Water)

	-- "Le Ruisseau" : bras allongé vers l'intérieur de la carte, même niveau d'eau. Chevauche la
	-- mare de quelques tiges pour qu'il n'y ait pas de coupure visuelle entre les deux.
	local streamCenterX = POND_CENTER.X - 80
	local streamAirFootprint = Vector3.new(96, airHeight, 16)
	local streamWaterFootprint = Vector3.new(84, waterHeight, 8)
	terrain:FillBlock(CFrame.new(streamCenterX, airCenterY, POND_CENTER.Z), streamAirFootprint, Enum.Material.Air)
	terrain:FillBlock(CFrame.new(streamCenterX, waterCenterY, POND_CENTER.Z), streamWaterFootprint, Enum.Material.Water)

	-- Le niveau d'eau est dérivé directement des paramètres de remplissage ci-dessus (pas de
	-- Terrain:ReadVoxels) : on contrôle exactement la géométrie remplie, donc aucune ambiguïté
	-- d'occupation de voxel à interpréter.
	workspace:SetAttribute("PondWaterLevel", waterTop)
	workspace:SetAttribute("PondFrozen", false) -- informatif seulement ; SurvivalService gère "PondFrozenNow"

	local mareZone = newPart(
		zonesFolder, "PondZone_Mare",
		Vector3.new(mareWaterFootprint.X, 4, mareWaterFootprint.Z),
		CFrame.new(POND_CENTER.X, waterCenterY, POND_CENTER.Z),
		Enum.Material.Water, Color3.new(0, 0, 1),
		{ CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1 }
	)
	CollectionService:AddTag(mareZone, "PondZone")

	local streamZone = newPart(
		zonesFolder, "PondZone_Ruisseau",
		Vector3.new(streamWaterFootprint.X, 4, streamWaterFootprint.Z),
		CFrame.new(streamCenterX, waterCenterY, POND_CENTER.Z),
		Enum.Material.Water, Color3.new(0, 0, 1),
		{ CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1 }
	)
	CollectionService:AddTag(streamZone, "PondZone")
end

------------------------------------------------------------------------------------------------
-- 3. "Le Grand Chêne".
------------------------------------------------------------------------------------------------
local function generateGrandChene(root: Folder)
	local model = Instance.new("Model")
	model.Name = "GrandChene"
	model.Parent = root

	local trunkHeight = 120
	local trunkDiameter = 16
	local barkColor = Color3.fromRGB(74, 52, 36)

	local trunk = Instance.new("Part")
	trunk.Name = "Tronc"
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(trunkHeight, trunkDiameter, trunkDiameter)
	trunk.CFrame = verticalCylinderCFrame(TREE_POSITION, trunkHeight)
	trunk.Anchored = true
	trunk.CanCollide = true
	trunk.Material = Enum.Material.Wood
	trunk.Color = barkColor
	trunk.Parent = model
	model.PrimaryPart = trunk

	-- 5 branches qui s'écartent du tronc entre 65% et 95% de sa hauteur.
	local branchCount = 5
	for i = 1, branchCount do
		local angleY = (i / branchCount) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local heightRatio = 0.65 + ((i - 1) % 3) * 0.1
		local startHeight = trunkHeight * heightRatio
		local startRadius = trunkDiameter * 0.5
		local branchLength = 26 + rng:NextInteger(0, 14)
		local startPoint = TREE_POSITION + Vector3.new(math.cos(angleY) * startRadius, startHeight, math.sin(angleY) * startRadius)
		local endPoint = TREE_POSITION + Vector3.new(
			math.cos(angleY) * (startRadius + branchLength * 0.85),
			startHeight + branchLength * 0.5,
			math.sin(angleY) * (startRadius + branchLength * 0.85)
		)
		linkPart(model, startPoint, endPoint, 3 + rng:NextInteger(0, 2), "Branche" .. i, Enum.Material.Wood, barkColor)
	end

	-- Canopée : amas de feuillage sphérique au sommet du tronc.
	local canopyCenter = TREE_POSITION + Vector3.new(0, trunkHeight * 0.92, 0)
	for i = 1, 16 do
		local offset = Vector3.new(rng:NextInteger(-28, 28), rng:NextInteger(-10, 14), rng:NextInteger(-28, 28))
		local leafSize = 10 + rng:NextInteger(0, 8)
		newPart(
			model,
			"Feuillage" .. i,
			Vector3.new(leafSize, leafSize, leafSize),
			CFrame.new(canopyCenter + offset),
			Enum.Material.Grass,
			Color3.fromRGB(50 + rng:NextInteger(0, 40), 110 + rng:NextInteger(0, 50), 40 + rng:NextInteger(0, 30)),
			{ CanCollide = false }
		)
	end

	-- Points d'ancrage laissés en commentaire pour de futurs systèmes (pas construits ici) :
	--   nid d'oiseau   ~ canopyCenter + Vector3.new(15, 10, 0)   (hautes branches, cf. GDD 5.1)
	--   hotte écureuil ~ canopyCenter + Vector3.new(-14, -6, 12) (fourche de branche, cf. GDD 5.5)
	--   ruche          ~ TREE_POSITION + Vector3.new(startRadius + 4, trunkHeight * 0.55, 0)

	-- Chambre creusée à la base de l'écorce : 1er abri d'hiver du GDD ("s'abriter dans l'écorce").
	local chamberFloor = newPart(
		model,
		"ChambreEcorce_Sol",
		Vector3.new(10, 1, 10),
		CFrame.new(TREE_POSITION.X + trunkDiameter * 0.5 + 6, TREE_POSITION.Y + 0.5, TREE_POSITION.Z),
		Enum.Material.Wood,
		Color3.fromRGB(58, 40, 28),
		{ CanCollide = true }
	)
	tagShelter(chamberFloor)
end

------------------------------------------------------------------------------------------------
-- 4. "La Prairie Fleurie".
------------------------------------------------------------------------------------------------
local function generatePrairieFleurie(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "PrairieFleurie"
	folder.Parent = root

	local bladeCount = rng:NextInteger(40, 80)
	for i = 1, bladeCount do
		local offset = Vector3.new(rng:NextInteger(-65, 65), 0, rng:NextInteger(-65, 65))
		local position = PRAIRIE_CENTER + offset
		local height = rng:NextInteger(20, 45)
		local width = 0.6 + rng:NextNumber() * 0.6
		newPart(
			folder,
			"HerbeHaute",
			Vector3.new(width, height, width),
			CFrame.new(position.X, position.Y + height / 2, position.Z)
				* CFrame.Angles(0, math.rad(rng:NextInteger(0, 359)), math.rad(rng:NextInteger(-6, 6))),
			Enum.Material.Grass,
			Color3.fromRGB(60 + rng:NextInteger(0, 40), 120 + rng:NextInteger(0, 60), 40 + rng:NextInteger(0, 30)),
			{ CanCollide = false }
		)
		if i % 50 == 0 then
			task.wait()
		end
	end

	local flowerColors = {
		Color3.fromRGB(230, 60, 90),
		Color3.fromRGB(250, 210, 40),
		Color3.fromRGB(180, 80, 230),
		Color3.fromRGB(250, 250, 250),
	}
	for _ = 1, 12 do
		local offset = Vector3.new(rng:NextInteger(-65, 65), 0, rng:NextInteger(-65, 65))
		local position = PRAIRIE_CENTER + offset
		local stemHeight = rng:NextInteger(20, 35)
		newPart(
			folder, "FleurTige", Vector3.new(0.8, stemHeight, 0.8),
			CFrame.new(position.X, position.Y + stemHeight / 2, position.Z),
			Enum.Material.Grass, Color3.fromRGB(70, 130, 60), { CanCollide = false }
		)
		newPart(
			folder,
			"FleurBouton",
			Vector3.new(4, 4, 4),
			CFrame.new(position.X, position.Y + stemHeight, position.Z),
			Enum.Material.Neon,
			flowerColors[rng:NextInteger(1, #flowerColors)],
			{ CanCollide = false, Shape = Enum.PartType.Ball }
		)
	end
end

------------------------------------------------------------------------------------------------
-- 5. "La Souche Pourrie & Les Galeries Souterraines".
------------------------------------------------------------------------------------------------
local function generateStumpAndGalleries(root: Folder)
	local terrain = workspace.Terrain
	local model = Instance.new("Model")
	model.Name = "SoucheEtGaleries"
	model.Parent = root

	-- Patch de sol en Boue au ras de la surface, sous la souche (complète le sol du point 1).
	terrain:FillBlock(CFrame.new(STUMP_CENTER.X, GROUND_TOP_Y - 4, STUMP_CENTER.Z), Vector3.new(80, 8, 80), Enum.Material.Mud)

	-- La souche elle-même : cylindre large et bas + quelques racines qui dépassent au sol.
	local stumpHeight = 7
	local stumpDiameter = 14
	local woodColor = Color3.fromRGB(90, 72, 58)
	local stump = Instance.new("Part")
	stump.Name = "Souche"
	stump.Shape = Enum.PartType.Cylinder
	stump.Size = Vector3.new(stumpHeight, stumpDiameter, stumpDiameter)
	stump.CFrame = verticalCylinderCFrame(STUMP_CENTER, stumpHeight)
	stump.Anchored = true
	stump.CanCollide = true
	stump.Material = Enum.Material.Wood
	stump.Color = woodColor
	stump.Parent = model
	model.PrimaryPart = stump

	for i = 1, 3 do
		local angle = (i / 3) * math.pi * 2
		local rootStart = STUMP_CENTER + Vector3.new(math.cos(angle) * stumpDiameter * 0.4, 1, math.sin(angle) * stumpDiameter * 0.4)
		local rootEnd = STUMP_CENTER + Vector3.new(math.cos(angle) * (stumpDiameter * 0.9), 0, math.sin(angle) * (stumpDiameter * 0.9))
		linkPart(model, rootStart, rootEnd, 2.5, "Racine" .. i, Enum.Material.Wood, Color3.fromRGB(70, 56, 44))
	end

	-- L'entrée des galeries est décalée loin de l'emprise de la souche/racines (rayon ~12.6) :
	-- sinon le cylindre plein de la souche bloquerait physiquement le puits d'accès.
	local galleryColumn = STUMP_CENTER + Vector3.new(stumpDiameter * 0.5 + 8, 0, 0)

	-- Trou d'entrée visible, au ras du sol, juste au-dessus du puits creusé plus bas.
	newPart(
		model, "TrouEntree", Vector3.new(6, 0.2, 6),
		CFrame.new(galleryColumn.X, GROUND_TOP_Y + 0.1, galleryColumn.Z),
		Enum.Material.SmoothPlastic, Color3.fromRGB(10, 8, 6), { CanCollide = false }
	)

	-- Petite salle souterraine pré-creusée (Terrain:FillRegion), murée de Boue, + puits d'accès
	-- vertical depuis la surface. Reste volontairement compacte : le marqueur Shelter doit rester
	-- à <=14 tiges (GameConstants.SHELTER_CHECK_RADIUS) de tout joueur présent dans la salle.
	local roomCenterY = 20 -- au moins 16 tiges sous la surface (GROUND_TOP_Y - roomCenterY = 28)
	local outerSize = Vector3.new(20, 16, 20)
	local innerSize = Vector3.new(12, 8, 12)

	local function regionFromCenterSize(center: Vector3, size: Vector3): Region3
		local half = size / 2
		return Region3.new(center - half, center + half):ExpandToGrid(4)
	end

	local roomCenter = Vector3.new(galleryColumn.X, roomCenterY, galleryColumn.Z)
	terrain:FillRegion(regionFromCenterSize(roomCenter, outerSize), 4, Enum.Material.Mud)
	terrain:FillRegion(regionFromCenterSize(roomCenter, innerSize), 4, Enum.Material.Air)

	-- Puits vertical : relie le trou d'entrée (surface) au plafond de la salle, sans interruption.
	local shaftTopY = GROUND_TOP_Y
	local shaftBottomY = roomCenterY + innerSize.Y / 2
	local shaftCenterY = (shaftTopY + shaftBottomY) / 2
	local shaftSize = Vector3.new(8, shaftTopY - shaftBottomY, 8)
	terrain:FillRegion(
		regionFromCenterSize(Vector3.new(galleryColumn.X, shaftCenterY, galleryColumn.Z), shaftSize),
		4,
		Enum.Material.Air
	)

	local floorY = roomCenterY - innerSize.Y / 2 + 0.5
	local floorPart = newPart(
		model, "Galerie_Sol", Vector3.new(innerSize.X - 2, 1, innerSize.Z - 2),
		CFrame.new(galleryColumn.X, floorY, galleryColumn.Z),
		Enum.Material.Ground, Color3.fromRGB(64, 48, 36), { CanCollide = true }
	)
	tagShelter(floorPart)
end

------------------------------------------------------------------------------------------------
-- 6. Nœuds de nourriture/eau par biome (FoodData.FoodTypeId).
------------------------------------------------------------------------------------------------
local function generateFoodNodes(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "FoodNodes"
	folder.Parent = root

	local placedCount = 0
	local function scatter(center: Vector3, radius: number, count: number, foodType: FoodData.FoodTypeId, color: Color3, heightOffset: number)
		for _ = 1, count do
			local angle = rng:NextNumber() * math.pi * 2
			local distance = rng:NextNumber() * radius
			local offset = Vector3.new(math.cos(angle) * distance, heightOffset, math.sin(angle) * distance)
			spawnFoodNode(folder, center + offset, foodType, color)
			placedCount += 1
			if placedCount % 50 == 0 then
				task.wait()
			end
		end
	end

	-- Prairie : feuilles/nectar/graines/miettes.
	scatter(PRAIRIE_CENTER, 65, 8, "Feuille", Color3.fromRGB(90, 180, 70), 1)
	scatter(PRAIRIE_CENTER, 65, 6, "Nectar", Color3.fromRGB(240, 190, 40), 1)
	scatter(PRAIRIE_CENTER, 65, 4, "Graine", Color3.fromRGB(200, 170, 110), 1)
	scatter(PRAIRIE_CENTER, 65, 3, "Miette", Color3.fromRGB(210, 180, 140), 1)
	-- Chêne : pollen/sève sur le tronc, fruits sous la canopée.
	scatter(TREE_POSITION, 35, 5, "Pollen", Color3.fromRGB(250, 220, 80), 2)
	scatter(TREE_POSITION, 35, 5, "Seve", Color3.fromRGB(150, 100, 40), 3)
	scatter(TREE_POSITION, 30, 8, "Fruit", Color3.fromRGB(220, 60, 50), 2)
	-- Souche : bois mort.
	scatter(STUMP_CENTER, 40, 10, "Bois", Color3.fromRGB(120, 90, 60), 1)
end

------------------------------------------------------------------------------------------------
-- 7. Spawn des œufs près du nid (zone de la Souche), + désactivation des spawns préexistants.
------------------------------------------------------------------------------------------------
local function generateSpawnLocation(root: Folder)
	for _, instance in ipairs(workspace:GetDescendants()) do
		if instance:IsA("SpawnLocation") then
			(instance :: SpawnLocation).Enabled = false
		end
	end

	local spawnPart = Instance.new("SpawnLocation")
	spawnPart.Name = "OeufSpawn"
	spawnPart.Size = Vector3.new(12, 1, 12)
	spawnPart.CFrame = CFrame.new(STUMP_CENTER.X + 30, GROUND_TOP_Y + 0.5, STUMP_CENTER.Z + 20)
	spawnPart.Anchored = true
	spawnPart.CanCollide = true
	spawnPart.Material = Enum.Material.Ground
	spawnPart.Color = Color3.fromRGB(110, 90, 70)
	spawnPart.Neutral = true
	spawnPart.Duration = 0
	spawnPart.Enabled = true
	spawnPart.Parent = root
end

function WorldGenerationService.Start()
	if workspace:FindFirstChild("GeneratedWorld") then
		return -- déjà généré (ex : redémarrage rapide en Studio) : on ne duplique pas la carte
	end

	local root = Instance.new("Folder")
	root.Name = "GeneratedWorld"
	root.Parent = workspace

	-- Ordre important : le sol, la mare (PondWaterLevel/PondZone) et tous les abris (Shelter)
	-- doivent exister avant le tout premier tick de SurvivalService.
	generateGround()
	generateRockyCorner(root)
	generatePond(root)
	generateGrandChene(root)
	generateStumpAndGalleries(root)
	generateSpawnLocation(root)

	-- Le reste est purement décoratif : peut s'étaler sur plusieurs frames (task.wait() interne)
	-- sans jamais risquer de casser le contrat déjà posé ci-dessus.
	generatePrairieFleurie(root)
	generateFoodNodes(root)

	workspace:SetAttribute("WorldGenerated", true)
end

return WorldGenerationService
