--!strict
-- WorldGenerationService.luau
-- Génère procéduralement la Grande Map (GDD section 4), entièrement en code, au boot serveur.
-- Toute la géométrie (taille, centres des biomes, mare, ruisseau, arbre) vient de
-- shared/WorldLayout : ne jamais dupliquer ces nombres ici.
--
-- Contrat posé pour SurvivalService (lu dès son tout premier tick, d'où l'appel AVANT son
-- Start() dans ServerBootstrap) : workspace:SetAttribute("PondWaterLevel", <Y>), tag
-- CollectionService "PondZone" sur les volumes de test de submersion, et tag "Shelter" sur
-- chaque abri (écorce du Chêne, galeries de la Souche, surplombs des Rochers).
-- Tout ce contrat est posé SANS aucun yield ; seul le décor qui suit s'étale sur plusieurs frames.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConstants = require(ServerScriptService.constant.GameConstants)
local FoodData = require(ReplicatedStorage.shared.FoodData)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)

local WorldGenerationService = {}

-- Graine fixe : la carte doit être strictement reproductible d'un boot serveur à l'autre
-- (math.random est ré-amorcé aléatoirement par le moteur, Random.new(seed) ne l'est jamais).
local rng = Random.new(1992417)

local GROUND_TOP_Y = WorldLayout.GROUND_TOP_Y
local GROUND_BOTTOM_Y = WorldLayout.GROUND_BOTTOM_Y
local MAP_SIZE = WorldLayout.MAP_SIZE
local MAP_HALF = WorldLayout.MAP_HALF

local ROCKY_CORNER = WorldLayout.ROCKS_CENTER -- "Le Coin des Rochers Arides"
local PRAIRIE_CENTER = WorldLayout.PRAIRIE_CENTER -- "La Prairie Fleurie"
local POND_CENTER = WorldLayout.POND_CENTER -- "La Mare & Le Ruisseau"
local STUMP_CENTER = WorldLayout.STUMP_CENTER -- "La Souche Pourrie & Les Galeries Souterraines"
local TREE_POSITION = WorldLayout.TREE_POSITION -- "Le Grand Chêne"

local TRUNK_HEIGHT = WorldLayout.TRUNK_HEIGHT
local TRUNK_RADIUS = WorldLayout.TRUNK_RADIUS
local STUMP_HEIGHT = 16
local STUMP_DIAMETER = 40

local WATER_TOP = WorldLayout.POND_WATER_LEVEL

-- Galeries : 4 salles reliées en boucle par des couloirs, toutes au même niveau (sol à
-- ROOM_FLOOR_Y, plafond au moins 24 studs sous la surface). Positions sur la grille de voxels.
local ROOM_FLOOR_Y = 16
local ROOM_CEILING_Y = 24
local ROOM_HALF = 8
local CORRIDOR_HALF = 4
local GALLERY_ROOMS: { Vector3 } = {
	Vector3.new(STUMP_CENTER.X + 40, ROOM_FLOOR_Y, STUMP_CENTER.Z), -- salle d'entrée (est)
	Vector3.new(STUMP_CENTER.X + 40, ROOM_FLOOR_Y, STUMP_CENTER.Z - 48),
	Vector3.new(STUMP_CENTER.X - 8, ROOM_FLOOR_Y, STUMP_CENTER.Z - 48), -- salle de la sortie ouest
	Vector3.new(STUMP_CENTER.X - 8, ROOM_FLOOR_Y, STUMP_CENTER.Z), -- sous la souche
}

-- Tunnels en pente à 45° (jamais un puits vertical) reliant la surface au sol d'une salle : leur
-- SOL passe exactement par ces points (voir carveRamp), donc aucune marche ni chute n'y
-- subsiste. Une espèce non-grimpeuse et non-volante (ex. le Scorpion Empereur) doit pouvoir
-- redescendre ET remonter à pied.
local GALLERY_DROP = GROUND_TOP_Y - ROOM_FLOOR_Y
local EAST_TUNNEL_BOTTOM = GALLERY_ROOMS[1] + Vector3.new(ROOM_HALF, 0, 0)
local EAST_TUNNEL_TOP = Vector3.new(EAST_TUNNEL_BOTTOM.X + GALLERY_DROP, GROUND_TOP_Y, EAST_TUNNEL_BOTTOM.Z)
local WEST_TUNNEL_BOTTOM = GALLERY_ROOMS[3] - Vector3.new(ROOM_HALF, 0, 0)
local WEST_TUNNEL_TOP = Vector3.new(WEST_TUNNEL_BOTTOM.X - GALLERY_DROP, GROUND_TOP_Y, WEST_TUNNEL_BOTTOM.Z)

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

-- Cylindre vertical posé sur basePosition (tiges, pierres plates, chapeaux de champignon...).
local function newCylinder(
	parent: Instance,
	name: string,
	basePosition: Vector3,
	height: number,
	diameter: number,
	material: Enum.Material,
	color: Color3
): BasePart
	return newPart(
		parent, name, Vector3.new(height, diameter, diameter),
		verticalCylinderCFrame(basePosition, height), material, color,
		{ Shape = Enum.PartType.Cylinder }
	)
end

-- Relie deux points par un bloc rectangulaire (branches, racines) : plus simple et plus fiable
-- qu'un cylindre orienté arbitrairement dans l'espace. Le bout -Z du bloc est à "to".
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

-- Remplit une boîte de Terrain alignée sur les axes, donnée par ses bornes.
local function fillBox(minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number, material: Enum.Material)
	workspace.Terrain:FillBlock(
		CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2),
		Vector3.new(maxX - minX, maxY - minY, maxZ - minZ),
		material
	)
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

-- Marqueur d'abri invisible (creux d'une bûche, dessous d'une racine...) : SurvivalService teste
-- la distance à la Position du marqueur (<= GameConstants.SHELTER_CHECK_RADIUS = 14 studs).
local function shelterMarker(parent: Instance, name: string, position: Vector3)
	local marker = newPart(
		parent, name, Vector3.new(4, 1, 4), CFrame.new(position),
		Enum.Material.SmoothPlastic, Color3.new(0, 0, 0),
		{ CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1 }
	)
	tagShelter(marker)
end

local function getFoodFolder(root: Folder): Folder
	local existing = root:FindFirstChild("FoodNodes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "FoodNodes"
	folder.Parent = root
	return folder
end

local function spawnFoodNode(parent: Instance, position: Vector3, foodType: FoodData.FoodTypeId, color: Color3)
	local node = Instance.new("Part")
	node.Name = "FoodNode_" .. foodType
	node.Shape = Enum.PartType.Ball
	node.Size = Vector3.new(1.6, 1.6, 1.6)
	node.CFrame = CFrame.new(position)
	node.Anchored = true
	node.CanCollide = false
	node.CastShadow = false
	node.Material = Enum.Material.Neon
	node.Color = color
	node.Parent = parent
	node:SetAttribute("FoodType", foodType)
	CollectionService:AddTag(node, "FoodNode")
end

-- ============================================================
-- Relief analytique + zones interdites au décor
-- ============================================================

-- Collines et cuvettes = calottes de sphère (Terrain:FillBall). On garde leur équation pour
-- calculer la hauteur du sol sans raycast (le Terrain fraîchement écrit n'est pas fiable à lire).
type Mound = { X: number, Z: number, CenterY: number, Radius: number, Dip: boolean }
local mounds: { Mound } = {}

local function groundHeightAt(x: number, z: number): number
	local y = GROUND_TOP_Y
	for _, mound in ipairs(mounds) do
		local dx, dz = x - mound.X, z - mound.Z
		local distanceSq = dx * dx + dz * dz
		local radiusSq = mound.Radius * mound.Radius
		if distanceSq < radiusSq then
			local rise = math.sqrt(radiusSq - distanceSq)
			if mound.Dip then
				y = math.min(y, mound.CenterY - rise)
			else
				y = math.max(y, mound.CenterY + rise)
			end
		end
	end
	return y
end

-- Colline douce : sphère enterrée dont seule une calotte de "height" studs dépasse du sol.
local function addHill(x: number, z: number, radius: number, height: number, material: Enum.Material)
	local centerY = GROUND_TOP_Y + height - radius
	workspace.Terrain:FillBall(Vector3.new(x, centerY, z), radius, material)
	table.insert(mounds, { X = x, Z = z, CenterY = centerY, Radius = radius, Dip = false })
end

-- Cuvette douce : sphère d'Air posée au-dessus du sol, qui n'en mord que "depth" studs.
local function addDip(x: number, z: number, radius: number, depth: number)
	local centerY = GROUND_TOP_Y - depth + radius
	workspace.Terrain:FillBall(Vector3.new(x, centerY, z), radius, Enum.Material.Air)
	table.insert(mounds, { X = x, Z = z, CenterY = centerY, Radius = radius, Dip = true })
end

-- Zones où rien ne doit être semé : eau, berges, rampes, tronc, souche, spawn.
type Circle = { X: number, Z: number, Radius: number }
local blockedBoxes: { WorldLayout.Box } = {}
local blockedCircles: { Circle } = {}

local function blockBox(minX: number, maxX: number, minZ: number, maxZ: number)
	table.insert(blockedBoxes, { MinX = minX, MaxX = maxX, MinZ = minZ, MaxZ = maxZ })
end

local function blockCircle(x: number, z: number, radius: number)
	table.insert(blockedCircles, { X = x, Z = z, Radius = radius })
end

local function isFree(x: number, z: number, margin: number): boolean
	local limit = MAP_HALF - 10 - margin
	if math.abs(x) > limit or math.abs(z) > limit then
		return false
	end
	for _, box in ipairs(blockedBoxes) do
		if x > box.MinX - margin and x < box.MaxX + margin and z > box.MinZ - margin and z < box.MaxZ + margin then
			return false
		end
	end
	for _, circle in ipairs(blockedCircles) do
		local dx, dz = x - circle.X, z - circle.Z
		local reach = circle.Radius + margin
		if dx * dx + dz * dz < reach * reach then
			return false
		end
	end
	return true
end

-- Point aléatoire (densité uniforme) dans l'anneau [minRadius, maxRadius] autour de center.
local function randomInDisc(center: Vector3, minRadius: number, maxRadius: number): (number, number)
	local angle = rng:NextNumber() * math.pi * 2
	local distance = math.sqrt(minRadius * minRadius + rng:NextNumber() * (maxRadius * maxRadius - minRadius * minRadius))
	return center.X + math.cos(angle) * distance, center.Z + math.sin(angle) * distance
end

-- Position libre posée sur le relief, ou nil si quelques tentatives échouent (l'appelant saute).
local function pickSpot(center: Vector3, minRadius: number, maxRadius: number, margin: number): Vector3?
	for _ = 1, 8 do
		local x, z = randomInDisc(center, minRadius, maxRadius)
		if isFree(x, z, margin) then
			return Vector3.new(x, groundHeightAt(x, z), z)
		end
	end
	return nil
end

-- Le décor (hors contrat) cède la main régulièrement pour ne pas figer le boot serveur.
local heavySteps = 0
local function breathe()
	heavySteps += 1
	if heavySteps % 60 == 0 then
		task.wait()
	end
end

-- ============================================================
-- Sol + relief
-- ============================================================

-- Sol : grande plaine herbeuse, remplie par dalles pour ne jamais demander un bloc géant d'un coup.
local function generateGround(root: Folder)
	local tiles = 3
	local tileSize = MAP_SIZE / tiles
	for ix = 0, tiles - 1 do
		for iz = 0, tiles - 1 do
			local minX = -MAP_HALF + ix * tileSize
			local minZ = -MAP_HALF + iz * tileSize
			fillBox(minX, minX + tileSize, GROUND_BOTTOM_Y, GROUND_TOP_Y, minZ, minZ + tileSize, Enum.Material.Grass)
		end
	end

	-- Murs invisibles au bord : personne ne tombe dans le vide (à pied ou en vol).
	local wallOptions: PartOptions = { CanCollide = true, CanQuery = false, CanTouch = false, Transparency = 1 }
	local wallLength, wallHeight, wallY = MAP_SIZE + 20, 400, GROUND_TOP_Y + 150
	local function wall(name: string, size: Vector3, position: Vector3)
		newPart(root, name, size, CFrame.new(position), Enum.Material.SmoothPlastic, Color3.new(1, 1, 1), wallOptions)
	end
	wall("BordNord", Vector3.new(wallLength, wallHeight, 4), Vector3.new(0, wallY, -MAP_HALF - 2))
	wall("BordSud", Vector3.new(wallLength, wallHeight, 4), Vector3.new(0, wallY, MAP_HALF + 2))
	wall("BordEst", Vector3.new(4, wallHeight, wallLength), Vector3.new(MAP_HALF + 2, wallY, 0))
	local westX = -MAP_HALF - 2
	if GameConstants.SHOWCASE_IN_GAME then
		-- Passage vers la galerie 3D (plateforme de ShowcaseService : Z de ORIGIN-20 à ORIGIN+242).
		local gapMinZ = WorldLayout.SHOWCASE_ORIGIN.Z - 20
		local gapMaxZ = WorldLayout.SHOWCASE_ORIGIN.Z + 242
		local wallMinZ, wallMaxZ = -MAP_HALF - 10, MAP_HALF + 10
		wall("BordOuestA", Vector3.new(4, wallHeight, gapMinZ - wallMinZ), Vector3.new(westX, wallY, (wallMinZ + gapMinZ) / 2))
		wall("BordOuestB", Vector3.new(4, wallHeight, wallMaxZ - gapMaxZ), Vector3.new(westX, wallY, (gapMaxZ + wallMaxZ) / 2))
	else
		wall("BordOuest", Vector3.new(4, wallHeight, wallLength), Vector3.new(westX, wallY, 0))
	end
end

-- Relief doux entre les biomes (GDD : le voyage doit rester intéressant). Positions choisies à
-- la main, loin de l'eau, des galeries, du spawn et du bord ouest (galerie 3D).
local function generateRelief()
	local grass = Enum.Material.Grass
	-- x, z, rayon de la sphère, hauteur de la calotte
	addHill(-250, 250, 80, 12, grass)
	addHill(250, 250, 90, 14, grass)
	addHill(-260, -230, 70, 10, grass)
	addHill(0, 420, 85, 12, grass)
	addHill(-30, -480, 80, 11, grass)
	addHill(420, 60, 75, 10, grass)
	addHill(-450, 20, 85, 13, grass)
	addHill(600, -150, 70, 9, grass)
	addHill(-150, 620, 70, 9, grass)
	addHill(150, -620, 80, 10, grass)
	addHill(-620, -200, 70, 9, grass)
	addHill(640, 180, 60, 8, grass)
	-- Cuvettes (les flaques de pluie s'y forment naturellement).
	addDip(-120, 250, 70, 7)
	addDip(330, -130, 70, 7)
	addDip(-300, -620, 60, 6)
	addDip(100, 150, 60, 6)
end

-- ============================================================
-- "Le Coin des Rochers Arides"
-- ============================================================

-- Surplomb rocheux : pierres chaudes au soleil le jour, abri la nuit/en hiver (GDD section 4/8).
local function buildOverhang(folder: Instance, center: Vector3)
	local pillarHeight = 10
	local pillarColor = Color3.fromRGB(110, 100, 90)
	newPart(
		folder, "SurplombPilierA", Vector3.new(4, pillarHeight, 4),
		CFrame.new(center.X - 7, GROUND_TOP_Y + pillarHeight / 2, center.Z),
		Enum.Material.Rock, pillarColor
	)
	newPart(
		folder, "SurplombPilierB", Vector3.new(4, pillarHeight, 4),
		CFrame.new(center.X + 7, GROUND_TOP_Y + pillarHeight / 2, center.Z),
		Enum.Material.Rock, pillarColor
	)
	newPart(
		folder, "SurplombDalle", Vector3.new(20, 3, 14),
		CFrame.new(center.X, GROUND_TOP_Y + pillarHeight + 1.5, center.Z),
		Enum.Material.Rock, Color3.fromRGB(130, 118, 104)
	)
	-- Marqueur au ras du sol (pas la dalle en hauteur) : reste à <=14 studs (SHELTER_CHECK_RADIUS)
	-- de tout joueur réfugié dessous.
	local marker = newPart(
		folder, "SurplombAbri", Vector3.new(16, 1, 10),
		CFrame.new(center.X, GROUND_TOP_Y + 0.5, center.Z),
		Enum.Material.Rock, Color3.fromRGB(120, 108, 96)
	)
	tagShelter(marker)
end

-- Pierres plates empilées, chauffées par le soleil : bonus de température (tag "WarmSpot").
local function buildCairn(folder: Instance, base: Vector3)
	local stone = Color3.fromRGB(156, 132, 106)
	local bottom = newCylinder(folder, "PierreChaude", base - Vector3.new(0, 0.5, 0), 3.5, 14, Enum.Material.Slate, stone)
	newCylinder(folder, "PierreChaude", base + Vector3.new(1, 3, -0.5), 2.5, 10, Enum.Material.Slate, Color3.fromRGB(168, 142, 112))
	newCylinder(folder, "PierreChaude", base + Vector3.new(-0.5, 5.5, 0.8), 2, 6.5, Enum.Material.Slate, Color3.fromRGB(176, 150, 120))
	CollectionService:AddTag(bottom, "WarmSpot")
	bottom:SetAttribute("WarmBonus", 6)
	bottom:SetAttribute("WarmRadius", 18)
end

local function generateRockyCorner(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "RochersArides"
	folder.Parent = root

	local overhangs = {
		ROCKY_CORNER + Vector3.new(40, 0, -40),
		ROCKY_CORNER + Vector3.new(-90, 0, 60),
		ROCKY_CORNER + Vector3.new(70, 0, 110),
	}
	local cairns = {
		ROCKY_CORNER + Vector3.new(-30, 0, -20),
		ROCKY_CORNER + Vector3.new(110, 0, 10),
		ROCKY_CORNER + Vector3.new(-60, 0, -110),
		ROCKY_CORNER + Vector3.new(20, 0, 80),
	}
	-- Les sites fixes restent sur du plat : aucune butte ni rocher ne doit les enterrer.
	local function nearFixedSite(x: number, z: number, clearance: number): boolean
		for _, list in ipairs({ overhangs, cairns }) do
			for _, site in ipairs(list) do
				local dx, dz = x - site.X, z - site.Z
				if dx * dx + dz * dz < clearance * clearance then
					return true
				end
			end
		end
		return false
	end

	-- Plaques de sable au ras du sol (remplacent juste la couche d'herbe).
	for _ = 1, 7 do
		local x = math.round((ROCKY_CORNER.X + rng:NextInteger(-130, 130)) / 4) * 4
		local z = math.round((ROCKY_CORNER.Z + rng:NextInteger(-130, 130)) / 4) * 4
		local half = rng:NextInteger(6, 12) * 4
		fillBox(x - half, x + half, GROUND_TOP_Y - 4, GROUND_TOP_Y, z - half, z + half, Enum.Material.Sand)
	end

	-- Buttes de roche et de grès : des calottes (pas des falaises), toujours praticables à pied.
	for _ = 1, 10 do
		local x = ROCKY_CORNER.X + rng:NextInteger(-140, 140)
		local z = ROCKY_CORNER.Z + rng:NextInteger(-140, 140)
		local radius = rng:NextInteger(40, 65)
		local height = rng:NextInteger(6, 12)
		local footprint = math.sqrt(2 * radius * height - height * height)
		if not nearFixedSite(x, z, footprint + 22) then
			addHill(x, z, radius, height, if rng:NextNumber() < 0.5 then Enum.Material.Rock else Enum.Material.Sandstone)
		end
	end

	for _, site in ipairs(overhangs) do
		buildOverhang(folder, site)
	end
	for _, site in ipairs(cairns) do
		buildCairn(folder, site)
	end

	for i = 1, 40 do
		local x, z = randomInDisc(ROCKY_CORNER, 0, WorldLayout.ROCKS_RADIUS)
		if nearFixedSite(x, z, 16) then
			continue
		end
		local size = rng:NextInteger(4, 11)
		-- S'enfonce légèrement dans le relief plutôt que de flotter dessus.
		newPart(
			folder,
			"Rocher" .. i,
			Vector3.new(size, size, size),
			CFrame.new(x, groundHeightAt(x, z) + size * 0.2, z),
			Enum.Material.Rock,
			Color3.fromRGB(108 + rng:NextInteger(0, 20), 100 + rng:NextInteger(0, 16), 90 + rng:NextInteger(0, 12)),
			{ Shape = Enum.PartType.Ball }
		)
	end
end

-- ============================================================
-- "La Mare & Le Ruisseau"
-- ============================================================

local function generatePond(root: Folder)
	local terrain = workspace.Terrain
	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "PondZones"
	zonesFolder.Parent = root

	local pondHalf = WorldLayout.POND_WATER_SIZE / 2
	local pondBank = WorldLayout.POND_BANK_WIDTH
	local pondMinX, pondMaxX = POND_CENTER.X - pondHalf.X, POND_CENTER.X + pondHalf.X
	local pondMinZ, pondMaxZ = POND_CENTER.Z - pondHalf.Z, POND_CENTER.Z + pondHalf.Z
	local basinBottom = WATER_TOP - WorldLayout.POND_DEPTH

	-- Un bassin = une boîte d'eau non tournée. La mare d'abord, puis chaque tronçon du ruisseau.
	type Basin = { Name: string, Box: WorldLayout.Box, Depth: number, Bank: number, Floor: Enum.Material }
	local basins: { Basin } = {
		{
			Name = "PondZone_Mare",
			Box = { MinX = pondMinX, MaxX = pondMaxX, MinZ = pondMinZ, MaxZ = pondMaxZ },
			Depth = WorldLayout.POND_DEPTH,
			Bank = pondBank,
			Floor = Enum.Material.Mud,
		},
	}
	for i, segment in ipairs(WorldLayout.STREAM_SEGMENTS) do
		table.insert(basins, {
			Name = "PondZone_Ruisseau" .. i,
			Box = segment,
			Depth = WorldLayout.STREAM_DEPTH,
			Bank = WorldLayout.STREAM_BANK_WIDTH,
			Floor = Enum.Material.Sand,
		})
	end

	-- Quatre passes sur TOUS les bassins (et pas bassin par bassin) : là où deux boîtes se
	-- chevauchent (coudes du ruisseau, embouchure), l'eau doit toujours être écrite en dernier.
	-- 1) Air au-dessus du niveau d'eau, empreinte élargie d'une berge : ça dessine la rive.
	for _, basin in ipairs(basins) do
		local box, bank = basin.Box, basin.Bank
		fillBox(box.MinX - bank, box.MaxX + bank, WATER_TOP, GROUND_TOP_Y, box.MinZ - bank, box.MaxZ + bank, Enum.Material.Air)
	end
	-- 2) Berge de sable au niveau de l'eau.
	for _, basin in ipairs(basins) do
		local box, bank = basin.Box, basin.Bank
		fillBox(box.MinX - bank, box.MaxX + bank, WATER_TOP - 4, WATER_TOP, box.MinZ - bank, box.MaxZ + bank, Enum.Material.Sand)
	end
	-- 3) Fond (vase de la mare, sable du ruisseau), juste sous l'eau.
	for _, basin in ipairs(basins) do
		local box = basin.Box
		local bottom = WATER_TOP - basin.Depth
		fillBox(box.MinX, box.MaxX, bottom - 4, bottom, box.MinZ, box.MaxZ, basin.Floor)
	end
	-- 4) Eau, posée directement sur le fond non creusé : jamais d'eau en lévitation.
	for _, basin in ipairs(basins) do
		local box = basin.Box
		fillBox(box.MinX, box.MaxX, WATER_TOP - basin.Depth, WATER_TOP, box.MinZ, box.MaxZ, Enum.Material.Water)
	end

	-- Rampes d'accès à la mare (pente douce ~25°), au sud et au nord : leur sol est ancré
	-- exactement sur la plaine (GROUND_TOP_Y) d'un côté et sur la berge (WATER_TOP) de l'autre,
	-- donc sans marche. Sans elles, une espèce non-grimpeuse et non-volante qui descend sur la
	-- berge resterait bloquée face au mur de 8 studs.
	local southEdgeZ = pondMaxZ + pondBank
	local northEdgeZ = pondMinZ - pondBank
	carveRamp(
		terrain,
		Vector3.new(POND_CENTER.X, GROUND_TOP_Y, southEdgeZ + 16),
		Vector3.new(POND_CENTER.X, WATER_TOP, southEdgeZ - 1),
		20,
		12
	)
	carveRamp(
		terrain,
		Vector3.new(POND_CENTER.X, GROUND_TOP_Y, northEdgeZ - 16),
		Vector3.new(POND_CENTER.X, WATER_TOP, northEdgeZ + 1),
		20,
		12
	)

	-- Rampe immergée (dalle inclinée) de la berge sud jusqu'au fond de vase : une espèce qui
	-- marche au fond peut ressortir à pied. Décalée en X pour laisser libre la nurserie
	-- aquatique de GrowthAndNestService (au centre, près de la berge sud).
	do
		local from = Vector3.new(POND_CENTER.X + 30, WATER_TOP, pondMaxZ)
		local to = Vector3.new(POND_CENTER.X + 30, basinBottom, pondMaxZ - 32)
		newPart(
			zonesFolder, "RampeMare", Vector3.new(16, 2, (to - from).Magnitude),
			CFrame.lookAt(from:Lerp(to, 0.5), to) * CFrame.new(0, -1, 0),
			Enum.Material.Ground, Color3.fromRGB(86, 70, 52)
		)
	end

	-- Rampes du ruisseau : une de chaque côté, au milieu de chaque tronçon. Le lit forme une
	-- tranchée de 8 studs ; personne ne doit y rester coincé.
	local streamBank = WorldLayout.STREAM_BANK_WIDTH
	for _, segment in ipairs(WorldLayout.STREAM_SEGMENTS) do
		local midX = (segment.MinX + segment.MaxX) / 2
		local midZ = (segment.MinZ + segment.MaxZ) / 2
		local alongX = (segment.MaxX - segment.MinX) > (segment.MaxZ - segment.MinZ)
		for _, side in ipairs({ -1, 1 }) do
			if alongX then
				local edge = (if side > 0 then segment.MaxZ else segment.MinZ) + side * streamBank
				carveRamp(terrain, Vector3.new(midX, GROUND_TOP_Y, edge + side * 16), Vector3.new(midX, WATER_TOP, edge - side), 12, 10)
			else
				local edge = (if side > 0 then segment.MaxX else segment.MinX) + side * streamBank
				carveRamp(terrain, Vector3.new(edge + side * 16, GROUND_TOP_Y, midZ), Vector3.new(edge - side, WATER_TOP, midZ), 12, 10)
			end
		end
		-- Rien n'est semé dans la tranchée ni sur ses rampes.
		blockBox(segment.MinX - 26, segment.MaxX + 26, segment.MinZ - 26, segment.MaxZ + 26)
	end
	-- Mare + berges + rampes + terrier du Crabe (creusé par AnimalService dans la berge est).
	blockBox(pondMinX - pondBank - 6, pondMaxX + pondBank + 44, pondMinZ - pondBank - 22, pondMaxZ + pondBank + 22)

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
	if measuredTop and math.abs(measuredTop - WATER_TOP) > 0.1 then
		warn(string.format("WorldGenerationService: niveau d'eau mesuré (%.1f) != valeur analytique (%.1f)", measuredTop, WATER_TOP))
	end
	workspace:SetAttribute("PondWaterLevel", WATER_TOP)
	workspace:SetAttribute("PondFrozen", false) -- informatif seulement ; SurvivalService gère "PondFrozenNow"

	-- Zones de submersion : boîtes NON tournées couvrant exactement l'eau (test XZ partout).
	for _, basin in ipairs(basins) do
		local box = basin.Box
		local zone = newPart(
			zonesFolder, basin.Name,
			Vector3.new(box.MaxX - box.MinX, 4, box.MaxZ - box.MinZ),
			CFrame.new((box.MinX + box.MaxX) / 2, WATER_TOP - basin.Depth / 2, (box.MinZ + box.MaxZ) / 2),
			Enum.Material.Water, Color3.new(0, 0, 1),
			{ CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1 }
		)
		CollectionService:AddTag(zone, "PondZone")
	end
end

-- Décor de la mare (hors contrat) : roseaux, galets, nénuphars, rochers immergés.
local function generatePondDecor(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "MareDecor"
	folder.Parent = root

	local half = WorldLayout.POND_WATER_SIZE / 2
	local basinBottom = WATER_TOP - WorldLayout.POND_DEPTH

	-- Point sur la berge (à "inset" studs de l'eau), ou nil devant une rampe, l'embouchure du
	-- ruisseau (ouest) ou le terrier du Crabe (est).
	local function bankPoint(inset: number): Vector3?
		local side = rng:NextInteger(1, 4)
		local t = rng:NextNumber(-1, 1)
		if side <= 2 then
			local x = POND_CENTER.X + t * half.X
			if math.abs(x - POND_CENTER.X) < 16 or math.abs(x - (POND_CENTER.X + 30)) < 11 then
				return nil
			end
			local z = if side == 1 then POND_CENTER.Z + half.Z + inset else POND_CENTER.Z - half.Z - inset
			return Vector3.new(x, WATER_TOP, z)
		end
		local z = POND_CENTER.Z + t * half.Z
		if math.abs(z - POND_CENTER.Z) < 22 then
			return nil
		end
		local x = if side == 3 then POND_CENTER.X + half.X + inset else POND_CENTER.X - half.X - inset
		return Vector3.new(x, WATER_TOP, z)
	end

	for _ = 1, 48 do
		local base = bankPoint(rng:NextNumber(-3, 5)) -- certains roseaux ont les pieds dans l'eau
		if base then
			local height = rng:NextInteger(14, 26)
			local reed = newCylinder(
				folder, "Roseau", base - Vector3.new(0, 3, 0), height + 3, 0.8,
				Enum.Material.Grass, Color3.fromRGB(96 + rng:NextInteger(0, 30), 140 + rng:NextInteger(0, 30), 70)
			)
			reed.CastShadow = false
			if rng:NextNumber() < 0.5 then
				newCylinder(folder, "Massette", base + Vector3.new(0, height - 4, 0), 4, 1.8, Enum.Material.Fabric, Color3.fromRGB(92, 60, 38)).CastShadow = false
			end
		end
		breathe()
	end

	for _ = 1, 30 do
		local base = bankPoint(rng:NextNumber(1, 7))
		if base then
			local size = rng:NextNumber(1.5, 4.5)
			newPart(
				folder, "Galet", Vector3.new(size, size, size), CFrame.new(base + Vector3.new(0, size * 0.25, 0)),
				Enum.Material.Pebble, Color3.fromRGB(130 + rng:NextInteger(0, 40), 130 + rng:NextInteger(0, 30), 125 + rng:NextInteger(0, 30)),
				{ Shape = Enum.PartType.Ball }
			).CastShadow = false
		end
		breathe()
	end

	-- Nénuphars : plateformes flottantes (solides), certaines fleuries avec du nectar.
	local foodFolder = getFoodFolder(root)
	for i = 1, 16 do
		local x = POND_CENTER.X + rng:NextNumber(-half.X + 14, half.X - 14)
		local z = POND_CENTER.Z + rng:NextNumber(-half.Z + 14, half.Z - 14)
		local diameter = rng:NextInteger(10, 16)
		newCylinder(
			folder, "Nenuphar", Vector3.new(x, WATER_TOP - 0.15, z), 0.4, diameter,
			Enum.Material.Grass, Color3.fromRGB(60 + rng:NextInteger(0, 20), 135 + rng:NextInteger(0, 30), 70)
		)
		if i % 3 == 0 then
			newPart(
				folder, "FleurNenuphar", Vector3.new(2.6, 2.6, 2.6), CFrame.new(x, WATER_TOP + 1.4, z),
				Enum.Material.Neon, Color3.fromRGB(245, 170, 205), { Shape = Enum.PartType.Ball, CanCollide = false }
			)
			spawnFoodNode(foodFolder, Vector3.new(x + 2.4, WATER_TOP + 1.2, z), "Nectar", Color3.fromRGB(240, 190, 40))
		end
		breathe()
	end

	-- Rochers posés sur la vase, hors du centre (cuvettes de frai, patrouille du Crabe, nurserie).
	for _ = 1, 12 do
		local dx = rng:NextNumber(-half.X + 12, half.X - 12)
		local dz = rng:NextNumber(-half.Z + 12, half.Z - 12)
		if math.abs(dx) > 44 or math.abs(dz) > 46 then
			local size = rng:NextInteger(6, 12)
			newPart(
				folder, "RocherImmerge", Vector3.new(size, size, size),
				CFrame.new(POND_CENTER.X + dx, basinBottom + size * 0.25, POND_CENTER.Z + dz),
				Enum.Material.Slate, Color3.fromRGB(84, 92, 86), { Shape = Enum.PartType.Ball }
			)
		end
		breathe()
	end
end

-- ============================================================
-- "Le Grand Chêne"
-- ============================================================

local function generateGrandChene(root: Folder)
	local model = Instance.new("Model")
	model.Name = "GrandChene"
	model.Parent = root

	local barkColor = Color3.fromRGB(74, 52, 36)
	local darkBark = Color3.fromRGB(58, 40, 28)
	local trunkDiameter = TRUNK_RADIUS * 2
	local foodFolder = getFoodFolder(root)

	local trunk = Instance.new("Part")
	trunk.Name = "Tronc"
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(TRUNK_HEIGHT, trunkDiameter, trunkDiameter)
	trunk.CFrame = verticalCylinderCFrame(TREE_POSITION, TRUNK_HEIGHT)
	trunk.Anchored = true
	trunk.CanCollide = true
	trunk.Material = Enum.Material.Wood
	trunk.Color = barkColor
	trunk.Parent = model
	model.PrimaryPart = trunk

	-- Empattement : le pied du tronc s'évase (sous la zone de patrouille du Caméléon).
	newCylinder(model, "TroncBase", TREE_POSITION, 10, trunkDiameter + 10, Enum.Material.Wood, barkColor)
	blockCircle(TREE_POSITION.X, TREE_POSITION.Z, TRUNK_RADIUS + 7)

	local leafCount = 0
	local function addFoliage(center: Vector3, size: number)
		leafCount += 1
		-- Solide et escaladable comme le reste de l'arbre (sinon WallClimbController "accroche"
		-- dessus sans vrai support physique). Nom "FeuillageN" : recoloré par SeasonVisualService.
		newPart(
			model,
			"Feuillage" .. leafCount,
			Vector3.new(size, size, size),
			CFrame.new(center),
			Enum.Material.Grass,
			Color3.fromRGB(50 + rng:NextInteger(0, 40), 110 + rng:NextInteger(0, 50), 40 + rng:NextInteger(0, 30)),
			{ Shape = Enum.PartType.Ball }
		)
	end

	-- Branches sur 4 étages. Parts "BrancheN" construites le long de Z, pointe côté -Z :
	-- AnimalService en déduit les perchoirs (nid de l'Oiseau sur la plus haute, hotte de
	-- l'Écureuil sur la 3e). Les rameaux et racines ne doivent donc PAS s'appeler "Branche...".
	local tiers = {
		{ Ratio = 0.42, Count = 3, Length = 70, Thickness = 7 },
		{ Ratio = 0.58, Count = 4, Length = 62, Thickness = 6 },
		{ Ratio = 0.74, Count = 4, Length = 52, Thickness = 5 },
		{ Ratio = 0.88, Count = 3, Length = 40, Thickness = 4 },
	}
	local tips: { Vector3 } = {}
	local branchIndex = 0
	for tierIndex, tier in ipairs(tiers) do
		for i = 1, tier.Count do
			branchIndex += 1
			local angleY = (i / tier.Count) * math.pi * 2 + tierIndex * 0.7 + rng:NextNumber(-0.2, 0.2)
			local outward = Vector3.new(math.cos(angleY), 0, math.sin(angleY))
			local length = tier.Length + rng:NextInteger(-6, 8)
			local startPoint = TREE_POSITION + outward * (TRUNK_RADIUS - 1) + Vector3.new(0, TRUNK_HEIGHT * tier.Ratio, 0)
			local endPoint = startPoint + outward * (length * 0.85) + Vector3.new(0, length * 0.4, 0)
			linkPart(model, startPoint, endPoint, tier.Thickness, "Branche" .. branchIndex, Enum.Material.Wood, barkColor)
			table.insert(tips, endPoint)

			-- Rameau latéral à 60% de la branche.
			local side = Vector3.new(-outward.Z, 0, outward.X) * (if branchIndex % 2 == 0 then 1 else -1)
			local twigStart = startPoint:Lerp(endPoint, 0.6)
			local twigEnd = twigStart + (outward * 0.5 + side * 0.8).Unit * (length * 0.35) + Vector3.new(0, length * 0.15, 0)
			linkPart(model, twigStart, twigEnd, math.max(2, tier.Thickness - 3), "Rameau", Enum.Material.Wood, barkColor)

			-- Feuillage juste AU-DELÀ de la pointe (la pointe reste dégagée : c'est un perchoir).
			local leafSize = 22 + rng:NextInteger(0, 10)
			addFoliage(endPoint + outward * (leafSize * 0.5) + Vector3.new(0, leafSize * 0.2, 0), leafSize)
			local twigLeaf = 14 + rng:NextInteger(0, 6)
			addFoliage(twigEnd + Vector3.new(0, twigLeaf * 0.3, 0), twigLeaf)

			-- Un fruit mûr posé sur une branche sur trois (récompense de l'escalade).
			if branchIndex % 3 == 0 then
				spawnFoodNode(foodFolder, startPoint:Lerp(endPoint, 0.5) + Vector3.new(0, tier.Thickness / 2 + 1, 0), "Fruit", Color3.fromRGB(220, 60, 50))
			end
		end
	end

	-- Couronne : amas de feuillage au sommet du tronc, sans jamais enterrer une pointe de branche.
	local crownCenter = TREE_POSITION + Vector3.new(0, TRUNK_HEIGHT + 6, 0)
	for _ = 1, 16 do
		for _ = 1, 6 do
			local leafSize = 24 + rng:NextInteger(0, 12)
			local center = crownCenter + Vector3.new(rng:NextInteger(-45, 45), rng:NextInteger(-8, 22), rng:NextInteger(-45, 45))
			local clear = true
			for _, tip in ipairs(tips) do
				if (tip + Vector3.new(0, 8, 0) - center).Magnitude < leafSize / 2 + 18 then
					clear = false
					break
				end
			end
			if clear then
				addFoliage(center, leafSize)
				break
			end
		end
	end

	-- Racines en arche : on passe dessous à pied. Aucune dans l'axe +X (chambre d'écorce).
	for i = 1, 7 do
		local angle = (i / 7) * math.pi * 2 + 0.45
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local base = TREE_POSITION + outward * (TRUNK_RADIUS - 2) + Vector3.new(0, 16, 0)
		local apex = TREE_POSITION + outward * (TRUNK_RADIUS + 22) + Vector3.new(0, 15 + rng:NextInteger(0, 4), 0)
		local foot = TREE_POSITION + outward * (TRUNK_RADIUS + 48 + rng:NextInteger(0, 10)) + Vector3.new(0, -2, 0)
		linkPart(model, base, apex, 5, "Racine", Enum.Material.Wood, darkBark)
		linkPart(model, apex, foot, 4, "Racine", Enum.Material.Wood, darkBark)
	end

	-- Corniches d'écorce en spirale : prises et paliers pour les grimpeurs, avec un peu de sève.
	local ledgeCount = 22
	for i = 1, ledgeCount do
		local angle = i * 2.4 -- angle d'or : jamais deux corniches superposées
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local height = 14 + (i - 1) * (TRUNK_HEIGHT * 0.8 - 14) / (ledgeCount - 1)
		local position = TREE_POSITION + outward * (TRUNK_RADIUS + 1.5) + Vector3.new(0, height, 0)
		newPart(model, "Corniche", Vector3.new(9, 1.2, 5), CFrame.lookAt(position, position + outward), Enum.Material.Wood, darkBark)
		if i % 4 == 0 then
			spawnFoodNode(foodFolder, position + outward * 1.5 + Vector3.new(0, 1.6, 0), "Seve", Color3.fromRGB(150, 100, 40))
		end
	end

	-- Noeuds creux : petits abris en hauteur (plancher tagué Shelter, fond sombre, auvent).
	for k = 1, 3 do
		local angle = 2 + k * 2.1
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local height = TRUNK_HEIGHT * (0.1 + k * 0.19)
		local anchor = TREE_POSITION + Vector3.new(0, height, 0)
		local floorPosition = anchor + outward * (TRUNK_RADIUS + 3.5)
		local floor = newPart(model, "NoeudCreux_Sol", Vector3.new(12, 1.5, 9), CFrame.lookAt(floorPosition, floorPosition + outward), Enum.Material.Wood, darkBark)
		tagShelter(floor)
		local roofPosition = anchor + outward * (TRUNK_RADIUS + 2.5) + Vector3.new(0, 11, 0)
		newPart(model, "NoeudCreux_Toit", Vector3.new(12, 1.2, 7), CFrame.lookAt(roofPosition, roofPosition + outward), Enum.Material.Wood, darkBark)
		-- Disque sombre plaqué sur le tronc (axe X du cylindre tourné vers l'extérieur).
		local holePosition = anchor + outward * (TRUNK_RADIUS + 0.2) + Vector3.new(0, 6, 0)
		newPart(
			model, "NoeudCreux_Fond", Vector3.new(0.6, 10, 10),
			CFrame.lookAt(holePosition, holePosition + outward) * CFrame.Angles(0, math.rad(90), 0),
			Enum.Material.SmoothPlastic, Color3.fromRGB(14, 10, 8), { Shape = Enum.PartType.Cylinder, CanCollide = false }
		)
	end

	-- Emplacement de la ruche (WorldLayout.HIVE_POSITION) : large corniche côté -X.
	do
		local hive = WorldLayout.HIVE_POSITION
		newPart(
			model, "EmplacementRuche", Vector3.new(14, 1.5, 10),
			CFrame.lookAt(hive - Vector3.new(0, 1.75, 0), hive - Vector3.new(1, 1.75, 0)),
			Enum.Material.Wood, darkBark
		)
	end

	-- Chambre creusée à la base de l'écorce : 1er abri d'hiver du GDD ("s'abriter dans l'écorce").
	-- Ouverte côté +X, fermée sur les côtés et couverte.
	local chamberX = TREE_POSITION.X + TRUNK_RADIUS + 13
	local chamberFloor = newPart(
		model,
		"ChambreEcorce_Sol",
		Vector3.new(14, 1, 14),
		CFrame.new(chamberX, TREE_POSITION.Y + 0.5, TREE_POSITION.Z),
		Enum.Material.Wood,
		darkBark,
		{ CanCollide = true }
	)
	tagShelter(chamberFloor)
	newPart(model, "ChambreEcorce_Toit", Vector3.new(16, 2, 16), CFrame.new(chamberX - 1, TREE_POSITION.Y + 11, TREE_POSITION.Z), Enum.Material.Wood, barkColor)
	newPart(model, "ChambreEcorce_Mur", Vector3.new(14, 10, 1), CFrame.new(chamberX, TREE_POSITION.Y + 5, TREE_POSITION.Z - 7.5), Enum.Material.Wood, barkColor)
	newPart(model, "ChambreEcorce_Mur", Vector3.new(14, 10, 1), CFrame.new(chamberX, TREE_POSITION.Y + 5, TREE_POSITION.Z + 7.5), Enum.Material.Wood, barkColor)
	blockBox(chamberX - 8, chamberX + 9, TREE_POSITION.Z - 9, TREE_POSITION.Z + 9)
end

-- ============================================================
-- "La Prairie Fleurie"
-- ============================================================

-- Herbes/fleurs solides et escaladables (GDD : "hautes herbes géantes") : en CanCollide=false
-- elles agiraient comme des surfaces fantômes pour WallClimbController.
local function generatePrairieFleurie(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "PrairieFleurie"
	folder.Parent = root

	local radius = WorldLayout.PRAIRIE_RADIUS
	local foodFolder = getFoodFolder(root)

	for _ = 1, 300 do
		local x, z = randomInDisc(PRAIRIE_CENTER, 0, radius)
		local height = rng:NextInteger(20, 48)
		local width = 0.6 + rng:NextNumber() * 0.8
		newPart(
			folder,
			"HerbeHaute",
			Vector3.new(width, height, width),
			CFrame.new(x, GROUND_TOP_Y + height / 2 - 1, z)
				* CFrame.Angles(0, math.rad(rng:NextInteger(0, 359)), math.rad(rng:NextInteger(-7, 7))),
			Enum.Material.Grass,
			Color3.fromRGB(60 + rng:NextInteger(0, 40), 120 + rng:NextInteger(0, 60), 40 + rng:NextInteger(0, 30))
		)
		breathe()
	end

	local flowerColors = {
		Color3.fromRGB(230, 60, 90),
		Color3.fromRGB(250, 210, 40),
		Color3.fromRGB(180, 80, 230),
		Color3.fromRGB(250, 250, 250),
		Color3.fromRGB(255, 140, 60),
	}
	for _ = 1, 40 do
		local x, z = randomInDisc(PRAIRIE_CENTER, 0, radius)
		local stemHeight = rng:NextInteger(20, 38)
		local base = Vector3.new(x, GROUND_TOP_Y, z)
		newCylinder(folder, "FleurTige", base, stemHeight, 1, Enum.Material.Grass, Color3.fromRGB(70, 130, 60))
		-- Feuille à mi-hauteur : un palier pour se reposer pendant l'escalade.
		newCylinder(folder, "FleurFeuille", base + Vector3.new(2.5, stemHeight * 0.5, 0), 0.5, 7, Enum.Material.Grass, Color3.fromRGB(80, 150, 65))
		newPart(
			folder,
			"FleurBouton",
			Vector3.new(5, 5, 5),
			CFrame.new(x, GROUND_TOP_Y + stemHeight + 1.5, z),
			Enum.Material.Neon,
			flowerColors[rng:NextInteger(1, #flowerColors)],
			{ Shape = Enum.PartType.Ball }
		)
		breathe()
	end

	-- Trèfles : tige courte + 3 folioles plates (plateformes basses).
	for _ = 1, 30 do
		local x, z = randomInDisc(PRAIRIE_CENTER, 0, radius)
		local stemHeight = rng:NextInteger(6, 11)
		local base = Vector3.new(x, GROUND_TOP_Y, z)
		local green = Color3.fromRGB(60 + rng:NextInteger(0, 20), 150 + rng:NextInteger(0, 30), 70)
		newCylinder(folder, "TrefleTige", base, stemHeight, 0.7, Enum.Material.Grass, Color3.fromRGB(70, 130, 60)).CastShadow = false
		for leaf = 1, 3 do
			local angle = leaf / 3 * math.pi * 2
			newCylinder(
				folder, "TrefleFeuille",
				base + Vector3.new(math.cos(angle) * 2.4, stemHeight - 0.2, math.sin(angle) * 2.4),
				0.4, 5, Enum.Material.Grass, green
			)
		end
		breathe()
	end

	-- Champignons : pied + chapeau large. Un sur trois abrite (pied tagué Shelter), un sur deux nourrit.
	for i = 1, 22 do
		local x, z = randomInDisc(PRAIRIE_CENTER, 0, radius)
		local stemHeight = rng:NextInteger(8, 16)
		local capDiameter = rng:NextInteger(12, 20)
		local base = Vector3.new(x, GROUND_TOP_Y, z)
		local capColor = if rng:NextNumber() < 0.5 then Color3.fromRGB(190, 60, 45) else Color3.fromRGB(200, 170, 120)
		local stem = newCylinder(folder, "ChampignonPied", base - Vector3.new(0, 1, 0), stemHeight + 1, 3.5, Enum.Material.SmoothPlastic, Color3.fromRGB(235, 228, 210))
		newCylinder(folder, "ChampignonChapeau", base + Vector3.new(0, stemHeight, 0), 2.5, capDiameter, Enum.Material.SmoothPlastic, capColor)
		newCylinder(folder, "ChampignonChapeau", base + Vector3.new(0, stemHeight + 2.5, 0), 2, capDiameter * 0.6, Enum.Material.SmoothPlastic, capColor)
		if i % 3 == 0 then
			tagShelter(stem)
		end
		if i % 2 == 0 then
			spawnFoodNode(foodFolder, base + Vector3.new(3.5, 1.2, 0), "Champignon", Color3.fromRGB(220, 200, 170))
		end
		breathe()
	end
end

-- ============================================================
-- "La Souche Pourrie & Les Galeries Souterraines"
-- ============================================================

local function generateStumpAndGalleries(root: Folder)
	local terrain = workspace.Terrain
	local model = Instance.new("Model")
	model.Name = "SoucheEtGaleries"
	model.Parent = root

	-- Patch de sol en Boue au ras de la surface, autour de la souche.
	fillBox(STUMP_CENTER.X - 80, STUMP_CENTER.X + 80, GROUND_TOP_Y - 4, GROUND_TOP_Y, STUMP_CENTER.Z - 80, STUMP_CENTER.Z + 80, Enum.Material.Mud)

	-- La souche elle-même : cylindre large et bas + racines en arche qui dépassent au sol.
	local woodColor = Color3.fromRGB(90, 72, 58)
	local rootColor = Color3.fromRGB(70, 56, 44)
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
	blockCircle(STUMP_CENTER.X, STUMP_CENTER.Z, STUMP_DIAMETER / 2 + 4)

	local stumpRadius = STUMP_DIAMETER / 2
	for i = 1, 6 do
		-- Décalées de 30° : aucune racine dans l'axe +X (tunnel est) ni vers la sortie ouest.
		local angle = (i / 6) * math.pi * 2 + math.rad(30)
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local base = STUMP_CENTER + outward * (stumpRadius - 2) + Vector3.new(0, 9, 0)
		local apex = STUMP_CENTER + outward * (stumpRadius + 9) + Vector3.new(0, 9, 0)
		local foot = STUMP_CENTER + outward * (stumpRadius + 20) + Vector3.new(0, -1.5, 0)
		linkPart(model, base, apex, 3.5, "Racine" .. i, Enum.Material.Wood, rootColor)
		linkPart(model, apex, foot, 3, "Racine" .. i, Enum.Material.Wood, rootColor)
		if i == 2 then
			-- Sous cette arche : un abri de surface, à deux pas du spawn.
			shelterMarker(model, "SoucheAbri", STUMP_CENTER + outward * (stumpRadius + 8) + Vector3.new(0, 1, 0))
		end
	end

	-- Polypores : champignons en console sur le flanc de la souche (paliers d'escalade).
	for i = 1, 5 do
		local angle = i * 1.3
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		newCylinder(
			model, "Polypore",
			STUMP_CENTER + outward * (stumpRadius + 2) + Vector3.new(0, 2 + i * 2.2, 0),
			1, 8, Enum.Material.SmoothPlastic, Color3.fromRGB(205, 170, 120)
		)
	end

	-- Galeries pré-creusées : un bloc de Boue, puis les salles et couloirs taillés dedans.
	-- Chaque salle reste compacte : son marqueur Shelter doit rester à <=14 studs
	-- (GameConstants.SHELTER_CHECK_RADIUS) de tout joueur présent dans la salle.
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, room in ipairs(GALLERY_ROOMS) do
		minX, maxX = math.min(minX, room.X), math.max(maxX, room.X)
		minZ, maxZ = math.min(minZ, room.Z), math.max(maxZ, room.Z)
	end
	local envelope = ROOM_HALF + 8
	fillBox(minX - envelope, maxX + envelope, ROOM_FLOOR_Y - 4, ROOM_CEILING_Y + 4, minZ - envelope, maxZ + envelope, Enum.Material.Mud)

	local foodFolder = getFoodFolder(root)
	for i, room in ipairs(GALLERY_ROOMS) do
		fillBox(room.X - ROOM_HALF, room.X + ROOM_HALF, ROOM_FLOOR_Y, ROOM_CEILING_Y, room.Z - ROOM_HALF, room.Z + ROOM_HALF, Enum.Material.Air)
		-- Couloir vers la salle suivante (la dernière reboucle sur la première).
		local nextRoom = GALLERY_ROOMS[i % #GALLERY_ROOMS + 1]
		fillBox(
			math.min(room.X, nextRoom.X) - CORRIDOR_HALF, math.max(room.X, nextRoom.X) + CORRIDOR_HALF,
			ROOM_FLOOR_Y, ROOM_CEILING_Y,
			math.min(room.Z, nextRoom.Z) - CORRIDOR_HALF, math.max(room.Z, nextRoom.Z) + CORRIDOR_HALF,
			Enum.Material.Air
		)

		local floorPart = newPart(
			model, if i == 1 then "Galerie_Sol" else "Galerie_Sol" .. i, Vector3.new(ROOM_HALF * 2 - 2, 1, ROOM_HALF * 2 - 2),
			CFrame.new(room.X, ROOM_FLOOR_Y + 0.5, room.Z),
			Enum.Material.Ground, Color3.fromRGB(64, 48, 36), { CanCollide = true }
		)
		tagShelter(floorPart)

		-- Champignon luminescent : seul éclairage des galeries.
		local glow = newPart(
			model, "ChampignonLumineux", Vector3.new(1.6, 1.6, 1.6),
			CFrame.new(room.X - ROOM_HALF + 1.5, ROOM_FLOOR_Y + 2, room.Z - ROOM_HALF + 1.5),
			Enum.Material.Neon, Color3.fromRGB(120, 230, 190), { Shape = Enum.PartType.Ball, CanCollide = false }
		)
		local light = Instance.new("PointLight")
		light.Color = glow.Color
		light.Range = 18
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = glow

		-- Réserves au fond des galeries (pas dans la salle d'entrée).
		if i > 1 then
			spawnFoodNode(foodFolder, Vector3.new(room.X + 4, ROOM_FLOOR_Y + 2, room.Z + 3), "Bois", Color3.fromRGB(120, 90, 60))
			spawnFoodNode(foodFolder, Vector3.new(room.X - 3, ROOM_FLOOR_Y + 2, room.Z + 5), "Champignon", Color3.fromRGB(220, 200, 170))
		end
	end

	-- Deux tunnels en pente (est et ouest) : sol continu de la surface au sol des salles.
	carveRamp(terrain, EAST_TUNNEL_TOP, EAST_TUNNEL_BOTTOM, 8, 10)
	carveRamp(terrain, WEST_TUNNEL_TOP, WEST_TUNNEL_BOTTOM, 8, 10)
	for _, top in ipairs({ EAST_TUNNEL_TOP, WEST_TUNNEL_TOP }) do
		-- Trou d'entrée visible, au ras du sol, à l'embouchure du tunnel.
		newPart(
			model, "TrouEntree", Vector3.new(6, 0.2, 6),
			CFrame.new(top.X, GROUND_TOP_Y + 0.1, top.Z),
			Enum.Material.SmoothPlastic, Color3.fromRGB(10, 8, 6), { CanCollide = false }
		)
	end
	-- Rien n'est semé sur les rampes ni devant leurs embouchures.
	blockBox(EAST_TUNNEL_BOTTOM.X - 4, EAST_TUNNEL_TOP.X + 10, EAST_TUNNEL_TOP.Z - 8, EAST_TUNNEL_TOP.Z + 8)
	blockBox(WEST_TUNNEL_TOP.X - 10, WEST_TUNNEL_BOTTOM.X + 4, WEST_TUNNEL_TOP.Z - 8, WEST_TUNNEL_TOP.Z + 8)
end

-- ============================================================
-- Repères entre les biomes
-- ============================================================

-- Bûche creuse : 7 planches en octogone (une manque : fissure par où entrent les volants).
local function buildHollowLog(folder: Instance, center: Vector3, direction: Vector3, length: number)
	local apothem = 9
	local axis = CFrame.lookAt(center + Vector3.new(0, apothem - 0.5, 0), center + Vector3.new(0, apothem - 0.5, 0) + direction)
	for k = 0, 7 do
		if k ~= 3 then
			newPart(
				folder, "BucheCreuse", Vector3.new(8.4, 2, length),
				axis * CFrame.Angles(0, 0, math.rad(k * 45)) * CFrame.new(0, -apothem, 0),
				Enum.Material.Wood, Color3.fromRGB(96 - (k % 2) * 10, 74 - (k % 2) * 8, 54)
			)
		end
	end
	for _, along in ipairs({ -length * 0.33, 0, length * 0.33 }) do
		shelterMarker(folder, "BucheCreuse_Abri", center + direction * along + Vector3.new(0, 2, 0))
	end
	-- Plus rien ne pousse sous la bûche.
	local reach = length / 2 + 6
	blockCircle(center.X, center.Z, 14)
	blockCircle(center.X + direction.X * reach * 0.5, center.Z + direction.Z * reach * 0.5, reach * 0.5 + 6)
	blockCircle(center.X - direction.X * reach * 0.5, center.Z - direction.Z * reach * 0.5, reach * 0.5 + 6)
end

local function generateLandmarks(root: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "Decor"
	folder.Parent = root

	local trenchWidth = 16 + WorldLayout.STREAM_BANK_WIDTH * 2

	-- Grande bûche creuse entre la Souche, la Prairie et le Chêne : abri à mi-chemin.
	buildHollowLog(folder, Vector3.new(-250, GROUND_TOP_Y, 40), Vector3.new(math.cos(math.rad(15)), 0, math.sin(math.rad(15))), 110)

	-- Ponts de bois mort en travers du ruisseau (hors des rampes, au milieu des tronçons).
	-- x, z = centre du pont ; alongZ = le tronc est couché le long de Z (tronçon orienté X).
	local bridges = {
		{ X = 290, Z = -500, AlongZ = true },
		{ X = 248, Z = -450, AlongZ = false },
		{ X = 208, Z = -332, AlongZ = true },
		{ X = 88, Z = -216, AlongZ = false },
		{ X = -44, Z = -180, AlongZ = true },
	}
	for _, bridge in ipairs(bridges) do
		newPart(
			folder, "PontTronc", Vector3.new(trenchWidth + 12, 6, 6),
			CFrame.new(bridge.X, GROUND_TOP_Y - 2.5, bridge.Z) * CFrame.Angles(0, if bridge.AlongZ then math.rad(90) else 0, 0),
			Enum.Material.Wood, Color3.fromRGB(104, 80, 58), { Shape = Enum.PartType.Cylinder }
		)
	end

	-- Litière de feuilles : plaques de Terrain feuillu + grandes feuilles mortes (une sur trois
	-- assez grande pour s'y cacher, comme les feuilles d'automne de SeasonVisualService).
	for _ = 1, 8 do
		local spot = pickSpot(TREE_POSITION, 110, 300, 44)
		if spot and spot.Y == GROUND_TOP_Y then
			local x, z = math.round(spot.X / 4) * 4, math.round(spot.Z / 4) * 4
			local half = rng:NextInteger(5, 8) * 4
			-- Jamais à cheval sur une colline ou une cuvette (on réécrirait leur surface).
			if groundHeightAt(x - half, z - half) == GROUND_TOP_Y and groundHeightAt(x + half, z + half) == GROUND_TOP_Y
				and groundHeightAt(x - half, z + half) == GROUND_TOP_Y and groundHeightAt(x + half, z - half) == GROUND_TOP_Y then
				fillBox(x - half, x + half, GROUND_TOP_Y - 4, GROUND_TOP_Y, z - half, z + half, Enum.Material.LeafyGrass)
			end
		end
	end
	for i = 1, 36 do
		local spot = pickSpot(TREE_POSITION, TRUNK_RADIUS + 20, 280, 6)
		if spot then
			local leaf = newPart(
				folder, "FeuilleLitiere", Vector3.new(rng:NextNumber(8, 12), 0.3, rng:NextNumber(5, 8)),
				CFrame.new(spot + Vector3.new(0, 0.4, 0)) * CFrame.Angles(math.rad(rng:NextInteger(-6, 6)), rng:NextNumber() * math.pi * 2, 0),
				Enum.Material.Grass, Color3.fromRGB(rng:NextInteger(120, 190), rng:NextInteger(90, 130), rng:NextInteger(30, 60))
			)
			leaf.CastShadow = false
			if i % 3 == 0 then
				tagShelter(leaf)
			end
		end
		breathe()
	end

	-- Champs de galets : un semis serré autour de quelques points fixes.
	for _, field in ipairs({ Vector3.new(130, 0, 330), Vector3.new(-330, 0, -60), Vector3.new(380, 0, -250), Vector3.new(-80, 0, -420) }) do
		for _ = 1, 14 do
			local spot = pickSpot(field, 0, 24, 2)
			if spot then
				local size = rng:NextNumber(2, 7)
				newPart(
					folder, "Galet", Vector3.new(size, size, size), CFrame.new(spot + Vector3.new(0, size * 0.2, 0)),
					Enum.Material.Pebble, Color3.fromRGB(125 + rng:NextInteger(0, 40), 125 + rng:NextInteger(0, 35), 120 + rng:NextInteger(0, 35)),
					{ Shape = Enum.PartType.Ball }
				).CastShadow = false
			end
			breathe()
		end
	end

	-- Brindilles tombées autour du Chêne.
	for _ = 1, 18 do
		local spot = pickSpot(TREE_POSITION, TRUNK_RADIUS + 30, 320, 14)
		if spot then
			local angle = rng:NextNumber() * math.pi * 2
			local length = rng:NextInteger(12, 26)
			local endX, endZ = spot.X + math.cos(angle) * length, spot.Z + math.sin(angle) * length
			linkPart(
				folder, spot + Vector3.new(0, 0.7, 0), Vector3.new(endX, groundHeightAt(endX, endZ) + 0.7, endZ),
				rng:NextNumber(1.2, 2.2), "Brindille", Enum.Material.Wood, Color3.fromRGB(100, 78, 56)
			).CastShadow = false
		end
		breathe()
	end

	-- Cailloux et gros blocs épars sur toute la carte.
	local mapCenter = Vector3.new(0, GROUND_TOP_Y, 0)
	for i = 1, 60 do
		local spot = pickSpot(mapCenter, 60, MAP_HALF - 20, 6)
		if spot then
			local size = if i % 8 == 0 then rng:NextInteger(14, 22) else rng:NextInteger(3, 9)
			newPart(
				folder, "Caillou", Vector3.new(size, size, size), CFrame.new(spot + Vector3.new(0, size * 0.2, 0)),
				Enum.Material.Slate, Color3.fromRGB(112 + rng:NextInteger(0, 24), 110 + rng:NextInteger(0, 20), 104 + rng:NextInteger(0, 18)),
				{ Shape = Enum.PartType.Ball }
			)
		end
		breathe()
	end

	-- Touffes d'herbe basses : purement visuelles (ni collision ni raycast, donc aucune surface
	-- fantôme pour WallClimbController), hors des Rochers et de la boue de la Souche.
	for _ = 1, 170 do
		local spot = pickSpot(mapCenter, 40, MAP_HALF - 20, 2)
		if spot
			and (spot - ROCKY_CORNER).Magnitude > WorldLayout.ROCKS_RADIUS * 0.8
			and (spot - STUMP_CENTER).Magnitude > 100
		then
			local height = rng:NextInteger(6, 14)
			local width = rng:NextNumber(0.5, 1)
			newPart(
				folder, "TouffeHerbe", Vector3.new(width, height, width),
				CFrame.new(spot + Vector3.new(0, height / 2 - 1, 0))
					* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, math.rad(rng:NextInteger(-10, 10))),
				Enum.Material.Grass, Color3.fromRGB(70 + rng:NextInteger(0, 30), 130 + rng:NextInteger(0, 40), 50),
				{ CanCollide = false, CanQuery = false, CanTouch = false }
			).CastShadow = false
		end
		breathe()
	end
end

-- ============================================================
-- Nourriture
-- ============================================================

-- Nœuds de nourriture/eau par biome (FoodData.FoodTypeId), posés sur le relief et hors des
-- zones interdites (eau, rampes, solides du décor). Proportionnés à la nouvelle surface.
local function generateFoodNodes(root: Folder)
	local folder = getFoodFolder(root)

	local function scatter(
		center: Vector3,
		minRadius: number,
		maxRadius: number,
		count: number,
		foodType: FoodData.FoodTypeId,
		color: Color3,
		heightOffset: number
	)
		for _ = 1, count do
			local spot = pickSpot(center, minRadius, maxRadius, 3)
			if spot then
				spawnFoodNode(folder, spot + Vector3.new(0, heightOffset, 0), foodType, color)
			end
			breathe()
		end
	end

	local leafColor = Color3.fromRGB(90, 180, 70)
	local nectarColor = Color3.fromRGB(240, 190, 40)
	local seedColor = Color3.fromRGB(200, 170, 110)
	local crumbColor = Color3.fromRGB(210, 180, 140)
	local fruitColor = Color3.fromRGB(220, 60, 50)

	-- Prairie : feuilles/nectar/graines/miettes.
	local prairieRadius = WorldLayout.PRAIRIE_RADIUS
	scatter(PRAIRIE_CENTER, 0, prairieRadius, 40, "Feuille", leafColor, 1)
	scatter(PRAIRIE_CENTER, 0, prairieRadius, 30, "Nectar", nectarColor, 1)
	scatter(PRAIRIE_CENTER, 0, prairieRadius, 20, "Graine", seedColor, 1)
	scatter(PRAIRIE_CENTER, 0, prairieRadius, 12, "Miette", crumbColor, 1)
	-- Chêne : pollen/sève/fruits tombés, hors du tronc (zone interdite) jusque sous la canopée.
	local oakRadius = WorldLayout.OAK_RADIUS
	scatter(TREE_POSITION, TRUNK_RADIUS + 10, oakRadius, 18, "Pollen", Color3.fromRGB(250, 220, 80), 2)
	scatter(TREE_POSITION, TRUNK_RADIUS + 10, oakRadius * 0.6, 14, "Seve", Color3.fromRGB(150, 100, 40), 3)
	scatter(TREE_POSITION, TRUNK_RADIUS + 10, oakRadius, 24, "Fruit", fruitColor, 2)
	-- Souche : bois mort, hors de la souche et des embouchures de tunnel (zones interdites).
	scatter(STUMP_CENTER, STUMP_DIAMETER / 2 + 8, 130, 36, "Bois", Color3.fromRGB(120, 90, 60), 1)
	scatter(STUMP_CENTER, STUMP_DIAMETER / 2 + 8, 110, 8, "Champignon", Color3.fromRGB(220, 200, 170), 1)
	-- Rochers : graines et miettes portées par le vent.
	local rocksRadius = WorldLayout.ROCKS_RADIUS
	scatter(ROCKY_CORNER, 0, rocksRadius, 14, "Graine", seedColor, 1)
	scatter(ROCKY_CORNER, 0, rocksRadius, 10, "Miette", crumbColor, 1)
	-- Abords de la mare : végétation de berge (la zone d'eau elle-même est interdite).
	scatter(POND_CENTER, WorldLayout.POND_RADIUS, WorldLayout.POND_RADIUS + 70, 16, "Feuille", leafColor, 1)
	-- Entre les biomes : de quoi grignoter en voyage, sur toute la carte.
	local mapCenter = Vector3.new(0, GROUND_TOP_Y, 0)
	scatter(mapCenter, 140, MAP_HALF - 30, 16, "Graine", seedColor, 1)
	scatter(mapCenter, 140, MAP_HALF - 30, 14, "Miette", crumbColor, 1)
	scatter(mapCenter, 140, MAP_HALF - 30, 14, "Feuille", leafColor, 1)
	scatter(mapCenter, 140, MAP_HALF - 30, 8, "Fruit", fruitColor, 2)
end

-- Spawn des œufs près du nid (zone de la Souche), + désactivation des spawns préexistants.
local function generateSpawnLocation(root: Folder)
	for _, instance in ipairs(workspace:GetDescendants()) do
		if instance:IsA("SpawnLocation") then
			(instance :: SpawnLocation).Enabled = false
		end
	end

	local spawnPosition = WorldLayout.SPAWN_POSITION
	local spawnPart = Instance.new("SpawnLocation")
	spawnPart.Name = "OeufSpawn"
	spawnPart.Size = Vector3.new(12, 1, 12)
	spawnPart.CFrame = CFrame.new(spawnPosition)
	spawnPart.Anchored = true
	spawnPart.CanCollide = true
	spawnPart.Material = Enum.Material.Ground
	spawnPart.Color = Color3.fromRGB(110, 90, 70)
	spawnPart.Neutral = true
	spawnPart.Duration = 0
	spawnPart.Enabled = true
	spawnPart.Parent = root
	-- Dalle + "nid sauvage" de GrowthAndNestService (14 studs à l'ouest) : rien n'y est semé.
	blockCircle(spawnPosition.X - 7, spawnPosition.Z, 32)
end

function WorldGenerationService.Start()
	if workspace:FindFirstChild("GeneratedWorld") then
		return -- déjà généré (ex : redémarrage rapide en Studio) : on ne duplique pas la carte
	end

	local root = Instance.new("Folder")
	root.Name = "GeneratedWorld"
	root.Parent = workspace

	-- Ordre important : le sol, la mare (PondWaterLevel/PondZone) et tous les abris (Shelter)
	-- doivent exister avant le tout premier tick de SurvivalService. AUCUN yield dans ce bloc.
	generateGround(root)
	generateRelief()
	generateRockyCorner(root)
	generatePond(root)
	generateGrandChene(root)
	generateStumpAndGalleries(root)
	generateSpawnLocation(root)

	-- Le reste est purement décoratif : s'étale sur plusieurs frames (breathe() -> task.wait())
	-- sans jamais risquer de casser le contrat déjà posé ci-dessus.
	generatePondDecor(root)
	generatePrairieFleurie(root)
	generateLandmarks(root)
	generateFoodNodes(root)

	workspace:SetAttribute("WorldGenerated", true)
end

return WorldGenerationService
