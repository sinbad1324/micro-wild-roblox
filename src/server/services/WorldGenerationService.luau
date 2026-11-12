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

local TRUNK_HEIGHT = 120
local TRUNK_DIAMETER = 16
local STUMP_HEIGHT = 7
local STUMP_DIAMETER = 14
-- L'entrée des galeries est décalée hors de l'emprise de la souche/racines (rayon ~12.6 studs) :
-- sinon le cylindre plein de la souche bloquerait physiquement le tunnel d'accès. Partagé par
-- generateStumpAndGalleries (qui creuse la salle/le tunnel) et generateFoodNodes (qui évite d'y
-- faire apparaître des nœuds de bois).
local GALLERY_COLUMN = STUMP_CENTER + Vector3.new(STUMP_DIAMETER * 0.5 + 8, 0, 0)

-- Salle souterraine : dimensions hissées au niveau module pour que le tunnel de secours
-- ci-dessous (et generateFoodNodes) puissent calculer les mêmes points sans dupliquer les chiffres.
local ROOM_CENTER_Y = 20 -- plafond à ROOM_CENTER_Y + ROOM_INNER_SIZE.Y/2 = 24, au moins 16 studs sous la surface
local ROOM_OUTER_SIZE = Vector3.new(20, 16, 20)
local ROOM_INNER_SIZE = Vector3.new(12, 8, 12)
local ROOM_FLOOR_Y = ROOM_CENTER_Y - ROOM_INNER_SIZE.Y / 2 -- 16

-- Tunnel en pente à 45° (jamais un puits vertical) reliant la surface au sol de la salle : son
-- SOL passe exactement par ces deux points (voir carveRamp), donc aucune marche ni chute n'y
-- subsiste. Une espèce non-grimpeuse et non-volante (ex. le Scorpion Empereur) doit pouvoir
-- redescendre ET remonter à pied.
local GALLERY_TUNNEL_BOTTOM = Vector3.new(GALLERY_COLUMN.X + ROOM_INNER_SIZE.X / 2, ROOM_FLOOR_Y, GALLERY_COLUMN.Z)
local GALLERY_TUNNEL_TOP = Vector3.new(GALLERY_TUNNEL_BOTTOM.X + (GROUND_TOP_Y - ROOM_FLOOR_Y), GROUND_TOP_Y, GALLERY_COLUMN.Z)

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

-- Carve un Air en forme de rampe dont le SOL passe exactement par top et bottom (et pas l'axe
-- central du bloc) : pas de marche ni de lèvre à l'arrivée. Toujours praticable à pied, à
-- l'inverse d'un puits vertical qui piégerait une espèce non-grimpeuse et non-volante.
local function carveRamp(terrain: Terrain, top: Vector3, bottom: Vector3, width: number, headroom: number)
	local length = (bottom - top).Magnitude
	local cf = CFrame.lookAt(top:Lerp(bottom, 0.5), bottom) * CFrame.new(0, headroom / 2, 0)
	terrain:FillBlock(cf, Vector3.new(width, headroom, length), Enum.Material.Air)
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

-- Position aléatoire dans un anneau [minRadius, maxRadius] autour de center, en évitant un point
-- (et son rayon) si fourni — quelques tentatives suffisent, l'échec total est négligeable.
local function pickScatterPosition(center: Vector3, minRadius: number, maxRadius: number, avoidPosition: Vector3?, avoidRadius: number?): Vector3
	for _ = 1, 6 do
		local angle = rng:NextNumber() * math.pi * 2
		local distance = minRadius + rng:NextNumber() * math.max(maxRadius - minRadius, 0)
		local candidate = center + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		if not avoidPosition or not avoidRadius then
			return candidate
		end
		local flatDelta = Vector3.new(candidate.X - avoidPosition.X, 0, candidate.Z - avoidPosition.Z)
		if flatDelta.Magnitude >= avoidRadius then
			return candidate
		end
	end
	return center + Vector3.new(minRadius, 0, 0)
end

-- Sol : grande plaine herbeuse 500x500.
local function generateGround()
	workspace.Terrain:FillBlock(
		CFrame.new(0, GROUND_CENTER_Y, 0),
		Vector3.new(MAP_SIZE, GROUND_THICKNESS, MAP_SIZE),
		Enum.Material.Grass
	)
end

-- "Le Coin des Rochers Arides" : patches de Rock/Sable surélevés, rochers épars, et un surplomb
-- qui sert de 2e abri d'hiver (en plus de l'écorce du Chêne et de la galerie de la Souche).
local function generateRockyCorner(root: Folder)
	local terrain = workspace.Terrain
	local folder = Instance.new("Folder")
	folder.Name = "RochersArides"
	folder.Parent = root

	local overhangCenter = ROCKY_CORNER + Vector3.new(15, 0, -15)
	local overhangClearRadius = 15
	local pillarHeight = 10

	for _ = 1, 5 do
		local offset = Vector3.new(rng:NextInteger(-45, 45), 0, rng:NextInteger(-45, 45))
		local center = ROCKY_CORNER + offset
		local footprint = rng:NextInteger(25, 45)
		-- Si ce patch empièterait sur le site du surplomb, il le laisserait entouré d'un plateau
		-- surélevé (donc piégé) une fois la zone dégagée plus bas : on l'ignore complètement.
		if math.abs(center.X - overhangCenter.X) < footprint / 2 + 14 and math.abs(center.Z - overhangCenter.Z) < footprint / 2 + 11 then
			continue
		end
		local raisedTop = GROUND_TOP_Y + rng:NextInteger(3, 9)
		local patchHeight = rng:NextInteger(10, 18)
		local material = if rng:NextNumber() < 0.5 then Enum.Material.Rock else Enum.Material.Sand
		terrain:FillBlock(
			CFrame.new(center.X, raisedTop - patchHeight / 2, center.Z),
			Vector3.new(footprint, patchHeight, footprint),
			material
		)
	end

	-- Dégage le site du surplomb quels que soient les patches aléatoires ci-dessus : la dalle et
	-- son marqueur Shelter ne doivent jamais se retrouver enterrés dans un patch surélevé.
	terrain:FillBlock(
		CFrame.new(overhangCenter.X, GROUND_TOP_Y + 12, overhangCenter.Z),
		Vector3.new(28, 24, 22),
		Enum.Material.Air
	)

	for i = 1, 8 do
		local pos = ROCKY_CORNER + Vector3.new(rng:NextInteger(-45, 45), 0, rng:NextInteger(-45, 45))
		local flatDelta = Vector3.new(pos.X - overhangCenter.X, 0, pos.Z - overhangCenter.Z)
		if flatDelta.Magnitude < overhangClearRadius then
			continue
		end
		local size = rng:NextInteger(4, 9)
		local baseY = GROUND_TOP_Y - size * 0.2 -- s'enfonce légèrement dans le relief plutôt que de flotter dessus
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
	-- Marqueur au ras du sol (pas la dalle en hauteur) : reste à <=14 studs (SHELTER_CHECK_RADIUS)
	-- de tout joueur réfugié dessous.
	local shelterMarker = newPart(
		folder, "SurplombAbri", Vector3.new(16, 1, 10),
		CFrame.new(overhangCenter.X, GROUND_TOP_Y + 0.5, overhangCenter.Z),
		Enum.Material.Rock, Color3.fromRGB(120, 108, 96)
	)
	tagShelter(shelterMarker)
end

-- "La Mare & Le Ruisseau".
local function generatePond(root: Folder)
	local terrain = workspace.Terrain
	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "PondZones"
	zonesFolder.Parent = root

	local waterTop = GROUND_TOP_Y - 8 -- en contrebas du sol : berges visibles tout autour
	local basinBottom = waterTop - 8 -- au moins 16 studs sous la surface, loin de toute galerie
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

	-- Rampe d'accès côté sud de la mare (pente douce ~25°) : son sol est ancré exactement sur la
	-- plaine (GROUND_TOP_Y) d'un côté et sur la berge déjà creusée (waterTop) de l'autre, donc
	-- sans marche. Sans elle, une espèce non-grimpeuse et non-volante qui descend sur la berge
	-- resterait bloquée face au mur de 8 studs.
	local pitEdgeZ = POND_CENTER.Z + mareAirFootprint.Z / 2
	carveRamp(
		terrain,
		Vector3.new(POND_CENTER.X, GROUND_TOP_Y, pitEdgeZ + 16),
		Vector3.new(POND_CENTER.X, waterTop, pitEdgeZ - 1),
		14,
		10
	)

	-- "Le Ruisseau" : bras allongé vers l'intérieur de la carte, même niveau d'eau. Chevauche la
	-- mare de plusieurs studs (empreintes eau ET air) pour qu'il n'y ait pas de coupure visuelle.
	local streamCenterX = POND_CENTER.X - 66
	local streamAirFootprint = Vector3.new(96, airHeight, 16)
	local streamWaterFootprint = Vector3.new(84, waterHeight, 8)
	terrain:FillBlock(CFrame.new(streamCenterX, airCenterY, POND_CENTER.Z), streamAirFootprint, Enum.Material.Air)
	terrain:FillBlock(CFrame.new(streamCenterX, waterCenterY, POND_CENTER.Z), streamWaterFootprint, Enum.Material.Water)

	-- Relit le voxel d'eau réellement empli pour vérifier la valeur analytique ci-dessus (plutôt
	-- que de lui faire confiance aveuglément). Protégé par pcall : ReadVoxels ne doit jamais faire
	-- planter le boot serveur, l'attribut final reste de toute façon la valeur analytique exacte.
	local function readWaterTopY(x: number, z: number, fromY: number, toY: number): number?
		local success, result = pcall(function(): number?
			local region = Region3.new(Vector3.new(x - 2, fromY, z - 2), Vector3.new(x + 2, toY, z + 2)):ExpandToGrid(4)
			local materials, occupancies = terrain:ReadVoxels(region, 4)
			local baseY = region.CFrame.Position.Y - region.Size.Y / 2
			local bestY: number? = nil
			for xi = 1, #materials do
				for yi = 1, #materials[xi] do
					for zi = 1, #materials[xi][yi] do
						if materials[xi][yi][zi] == Enum.Material.Water and occupancies[xi][yi][zi] > 0 then
							local topY = baseY + (yi - 1) * 4 + occupancies[xi][yi][zi] * 4
							if not bestY or topY > bestY then
								bestY = topY
							end
						end
					end
				end
			end
			return bestY
		end)
		if success then
			return result :: number?
		end
		return nil
	end

	local measuredTop = readWaterTopY(POND_CENTER.X, POND_CENTER.Z, basinBottom - 4, GROUND_TOP_Y + 4)
	if measuredTop and math.abs(measuredTop - waterTop) > 0.1 then
		warn(string.format("WorldGenerationService: niveau d'eau mesuré (%.1f) != valeur analytique (%.1f)", measuredTop, waterTop))
	end
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

-- "Le Grand Chêne".
local function generateGrandChene(root: Folder)
	local model = Instance.new("Model")
	model.Name = "GrandChene"
	model.Parent = root

	local barkColor = Color3.fromRGB(74, 52, 36)

	local trunk = Instance.new("Part")
	trunk.Name = "Tronc"
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(TRUNK_HEIGHT, TRUNK_DIAMETER, TRUNK_DIAMETER)
	trunk.CFrame = verticalCylinderCFrame(TREE_POSITION, TRUNK_HEIGHT)
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
		local startHeight = TRUNK_HEIGHT * heightRatio
		local startRadius = TRUNK_DIAMETER * 0.5
		local branchLength = 26 + rng:NextInteger(0, 14)
		local startPoint = TREE_POSITION + Vector3.new(math.cos(angleY) * startRadius, startHeight, math.sin(angleY) * startRadius)
		local endPoint = TREE_POSITION + Vector3.new(
			math.cos(angleY) * (startRadius + branchLength * 0.85),
			startHeight + branchLength * 0.5,
			math.sin(angleY) * (startRadius + branchLength * 0.85)
		)
		linkPart(model, startPoint, endPoint, 3 + rng:NextInteger(0, 2), "Branche" .. i, Enum.Material.Wood, barkColor)
	end

	-- Canopée : amas de feuillage sphérique au sommet du tronc. Solide et escaladable comme le
	-- reste de l'arbre (sinon WallClimbController "accroche" dessus sans vrai support physique).
	local canopyCenter = TREE_POSITION + Vector3.new(0, TRUNK_HEIGHT * 0.92, 0)
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
			{ Shape = Enum.PartType.Ball }
		)
	end

	-- Points d'ancrage laissés en commentaire pour de futurs systèmes (pas construits ici) :
	--   nid d'oiseau   ~ canopyCenter + Vector3.new(15, 10, 0)   (hautes branches, cf. GDD 5.1)
	--   hotte écureuil ~ canopyCenter + Vector3.new(-14, -6, 12) (fourche de branche, cf. GDD 5.5)
	--   ruche          ~ TREE_POSITION + Vector3.new(TRUNK_DIAMETER / 2 + 4, TRUNK_HEIGHT * 0.55, 0)

	-- Chambre creusée à la base de l'écorce : 1er abri d'hiver du GDD ("s'abriter dans l'écorce").
	local chamberFloor = newPart(
		model,
		"ChambreEcorce_Sol",
		Vector3.new(10, 1, 10),
		CFrame.new(TREE_POSITION.X + TRUNK_DIAMETER * 0.5 + 6, TREE_POSITION.Y + 0.5, TREE_POSITION.Z),
		Enum.Material.Wood,
		Color3.fromRGB(58, 40, 28),
		{ CanCollide = true }
	)
	tagShelter(chamberFloor)
end

-- "La Prairie Fleurie". Herbes/fleurs solides et escaladables (GDD : "hautes herbes géantes") :
-- en CanCollide=false elles agiraient comme des surfaces fantômes pour WallClimbController.
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
			Color3.fromRGB(60 + rng:NextInteger(0, 40), 120 + rng:NextInteger(0, 60), 40 + rng:NextInteger(0, 30))
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
			Enum.Material.Grass, Color3.fromRGB(70, 130, 60)
		)
		newPart(
			folder,
			"FleurBouton",
			Vector3.new(4, 4, 4),
			CFrame.new(position.X, position.Y + stemHeight, position.Z),
			Enum.Material.Neon,
			flowerColors[rng:NextInteger(1, #flowerColors)],
			{ Shape = Enum.PartType.Ball }
		)
	end
end

-- "La Souche Pourrie & Les Galeries Souterraines".
local function generateStumpAndGalleries(root: Folder)
	local terrain = workspace.Terrain
	local model = Instance.new("Model")
	model.Name = "SoucheEtGaleries"
	model.Parent = root

	-- Patch de sol en Boue au ras de la surface, sous la souche (complète le sol du point 1).
	terrain:FillBlock(CFrame.new(STUMP_CENTER.X, GROUND_TOP_Y - 4, STUMP_CENTER.Z), Vector3.new(80, 8, 80), Enum.Material.Mud)

	-- La souche elle-même : cylindre large et bas + quelques racines qui dépassent au sol.
	local woodColor = Color3.fromRGB(90, 72, 58)
	local stump = Instance.new("Part")
	stump.Name = "Souche"
	stump.Shape = Enum.PartType.Cylinder
	stump.Size = Vector3.new(STUMP_HEIGHT, STUMP_DIAMETER, STUMP_DIAMETER)
	stump.CFrame = verticalCylinderCFrame(STUMP_CENTER, STUMP_HEIGHT)
	stump.Anchored = true
	stump.CanCollide = true
	stump.Material = Enum.Material.Wood
	stump.Color = woodColor
	stump.Parent = model
	model.PrimaryPart = stump

	for i = 1, 3 do
		local angle = (i / 3) * math.pi * 2
		local rootStart = STUMP_CENTER + Vector3.new(math.cos(angle) * STUMP_DIAMETER * 0.4, 1, math.sin(angle) * STUMP_DIAMETER * 0.4)
		local rootEnd = STUMP_CENTER + Vector3.new(math.cos(angle) * (STUMP_DIAMETER * 0.9), 0, math.sin(angle) * (STUMP_DIAMETER * 0.9))
		linkPart(model, rootStart, rootEnd, 2.5, "Racine" .. i, Enum.Material.Wood, Color3.fromRGB(70, 56, 44))
	end

	-- Petite salle souterraine pré-creusée (Terrain:FillRegion), murée de Boue. Reste compacte :
	-- le marqueur Shelter doit rester à <=14 studs (GameConstants.SHELTER_CHECK_RADIUS) de tout
	-- joueur présent dans la salle.
	local function regionFromCenterSize(center: Vector3, size: Vector3): Region3
		local half = size / 2
		return Region3.new(center - half, center + half):ExpandToGrid(4)
	end

	local roomCenter = Vector3.new(GALLERY_COLUMN.X, ROOM_CENTER_Y, GALLERY_COLUMN.Z)
	terrain:FillRegion(regionFromCenterSize(roomCenter, ROOM_OUTER_SIZE), 4, Enum.Material.Mud)
	terrain:FillRegion(regionFromCenterSize(roomCenter, ROOM_INNER_SIZE), 4, Enum.Material.Air)

	-- Tunnel en pente (GALLERY_TUNNEL_TOP/BOTTOM, module-level) reliant la surface au sol de la
	-- salle sans marche ni chute.
	carveRamp(terrain, GALLERY_TUNNEL_TOP, GALLERY_TUNNEL_BOTTOM, 8, 10)

	-- Trou d'entrée visible, au ras du sol, à l'embouchure du tunnel.
	newPart(
		model, "TrouEntree", Vector3.new(6, 0.2, 6),
		CFrame.new(GALLERY_TUNNEL_TOP.X, GROUND_TOP_Y + 0.1, GALLERY_TUNNEL_TOP.Z),
		Enum.Material.SmoothPlastic, Color3.fromRGB(10, 8, 6), { CanCollide = false }
	)

	local floorY = ROOM_FLOOR_Y + 0.5
	local floorPart = newPart(
		model, "Galerie_Sol", Vector3.new(ROOM_INNER_SIZE.X - 2, 1, ROOM_INNER_SIZE.Z - 2),
		CFrame.new(GALLERY_COLUMN.X, floorY, GALLERY_COLUMN.Z),
		Enum.Material.Ground, Color3.fromRGB(64, 48, 36), { CanCollide = true }
	)
	tagShelter(floorPart)
end

-- Nœuds de nourriture/eau par biome (FoodData.FoodTypeId), en évitant les solides du décor.
local function generateFoodNodes(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "FoodNodes"
	folder.Parent = root

	local placedCount = 0
	local function scatter(
		center: Vector3,
		minRadius: number,
		maxRadius: number,
		count: number,
		foodType: FoodData.FoodTypeId,
		color: Color3,
		heightOffset: number,
		avoidPosition: Vector3?,
		avoidRadius: number?
	)
		for _ = 1, count do
			local candidate = pickScatterPosition(center, minRadius, maxRadius, avoidPosition, avoidRadius)
			spawnFoodNode(folder, Vector3.new(candidate.X, center.Y + heightOffset, candidate.Z), foodType, color)
			placedCount += 1
			if placedCount % 50 == 0 then
				task.wait()
			end
		end
	end

	-- Prairie : feuilles/nectar/graines/miettes, pas d'obstacle à éviter.
	scatter(PRAIRIE_CENTER, 0, 65, 8, "Feuille", Color3.fromRGB(90, 180, 70), 1)
	scatter(PRAIRIE_CENTER, 0, 65, 6, "Nectar", Color3.fromRGB(240, 190, 40), 1)
	scatter(PRAIRIE_CENTER, 0, 65, 4, "Graine", Color3.fromRGB(200, 170, 110), 1)
	scatter(PRAIRIE_CENTER, 0, 65, 3, "Miette", Color3.fromRGB(210, 180, 140), 1)
	-- Chêne : pollen/sève/fruits, hors du tronc (rayon TRUNK_DIAMETER / 2 = 8 + marge).
	scatter(TREE_POSITION, 11, 35, 5, "Pollen", Color3.fromRGB(250, 220, 80), 2)
	scatter(TREE_POSITION, 11, 35, 5, "Seve", Color3.fromRGB(150, 100, 40), 3)
	scatter(TREE_POSITION, 11, 30, 8, "Fruit", Color3.fromRGB(220, 60, 50), 2)
	-- Souche : bois mort, hors de la souche (rayon STUMP_DIAMETER / 2 = 7 + marge) et de
	-- l'embouchure du tunnel (la salle elle-même est sous 20+ studs de terrain plein).
	scatter(STUMP_CENTER, 10, 40, 10, "Bois", Color3.fromRGB(120, 90, 60), 1, GALLERY_TUNNEL_TOP, 10)
end

-- Spawn des œufs près du nid (zone de la Souche), + désactivation des spawns préexistants.
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
