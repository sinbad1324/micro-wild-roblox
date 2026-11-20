--!strict
-- SeasonVisualService.luau
-- Rend les 4 saisons (GDD §4) visibles et jouables, en réagissant à l'attribut CurrentSeason posé
-- par SeasonService :
--   Printemps : pluie + "bombes d'eau", rosée sur les plantes, flaques, fleurs riches en nectar
--   Été       : flaques et rosée asséchées (tout le monde doit boire à la mare), bonus de vol
--   Automne   : feuilles mortes au sol, chute de fruits géants, vent qui pousse les volants
--   Hiver     : neige, herbe blanche, arbre dégarni, mare gelée (glace solide en surface)
-- Tout ce qui est saisonnier vit dans workspace.SeasonalEffects et est détruit au changement.
-- Rendu lourd délégué au client (WorldFxController) :
--   workspace attribut "Precipitation" = "Rain" | "Snow" | "None" (émetteur qui suit la caméra)
--   tag "FxFalling" + attributs FxFallHeight/FxFallDuration/FxFallStart (+ FxSplash) : la part est
--   posée à sa position FINALE par le serveur, le client anime la chute localement.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local DamageService = require(ServerScriptService.services.DamageService)

local SeasonVisualService = {}

local GROUND_Y = GameConstants.GROUND_TOP_Y
local MAP_HALF = WorldLayout.MAP_HALF - 10 -- marge : rien n'est semé au ras du bord
local TREE_POSITION = WorldLayout.TREE_POSITION
-- Au-dessus de la couronne du Chêne : départ des raycasts vers le sol.
local SKY_HEIGHT = WorldLayout.TRUNK_HEIGHT + 80
-- La carte est immense (4000x4000) : on augmente l'échelle de semis tout en gardant un budget mobile raisonnable.
local SCATTER_SCALE = 12
-- Transition de saison : interpolation par pas grossiers (0.5 s) au lieu de tweens serveur à
-- 60 Hz sur tout le feuillage du Chêne.
local TRANSITION_SECONDS = 16
local TRANSITION_STEP = 0.5

type SeasonLook = {
	Grass: Color3,
	Leaves: Color3,
	LeafTransparency: number,
	Tint: Color3,
	Saturation: number,
	AtmosphereColor: Color3,
	Haze: number,
}

local LOOKS: { [string]: SeasonLook } = {
	Printemps = {
		Grass = Color3.fromRGB(110, 175, 75), Leaves = Color3.fromRGB(95, 165, 70), LeafTransparency = 0,
		Tint = Color3.fromRGB(255, 255, 255), Saturation = 0.1,
		AtmosphereColor = Color3.fromRGB(200, 220, 240), Haze = 1,
	},
	Ete = {
		Grass = Color3.fromRGB(150, 165, 70), Leaves = Color3.fromRGB(70, 130, 50), LeafTransparency = 0,
		Tint = Color3.fromRGB(255, 245, 225), Saturation = 0.15,
		AtmosphereColor = Color3.fromRGB(240, 225, 190), Haze = 1.5,
	},
	Automne = {
		Grass = Color3.fromRGB(150, 130, 70), Leaves = Color3.fromRGB(210, 120, 40), LeafTransparency = 0,
		Tint = Color3.fromRGB(255, 235, 210), Saturation = 0.05,
		AtmosphereColor = Color3.fromRGB(220, 190, 160), Haze = 2,
	},
	Hiver = {
		Grass = Color3.fromRGB(235, 240, 245), Leaves = Color3.fromRGB(120, 105, 90), LeafTransparency = 0.65,
		Tint = Color3.fromRGB(225, 235, 255), Saturation = -0.2,
		AtmosphereColor = Color3.fromRGB(215, 225, 240), Haze = 2.5,
	},
}

local seasonalFolder: Folder? = nil
local currentSeason = ""
local seasonToken = 0 -- invalide les boucles d'une saison précédente
local rng = Random.new()

local function getFolder(): Folder
	if seasonalFolder and seasonalFolder.Parent then
		return seasonalFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "SeasonalEffects"
	folder.Parent = workspace
	seasonalFolder = folder
	return folder
end

local function clearSeasonal()
	local folder = getFolder()
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
end

local function anchoredPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number?, collide: boolean?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = collide == true
	part.CanQuery = collide == true
	part.CanTouch = false
	part.Transparency = transparency or 0
	part.Parent = getFolder()
	return part
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

-- Terrain seul : les fruits traversent le feuillage du Chêne et tombent au sol.
local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }

-- Surface la plus haute sous un point (herbe géante, rocher, sol...), en ignorant les effets,
-- les animaux et les personnages (sinon une goutte reste posée sur la tête d'un joueur).
local function surfaceBelow(x: number, z: number): RaycastResult?
	local filter: { Instance } = { getFolder() }
	local animals = workspace:FindFirstChild("Animals")
	if animals then
		table.insert(filter, animals)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end
	groundParams.FilterDescendantsInstances = filter
	return workspace:Raycast(Vector3.new(x, GROUND_Y + SKY_HEIGHT, z), Vector3.new(0, -(SKY_HEIGHT + 60), 0), groundParams)
end

-- Oeufs et cocons sont immobiles et considérés à l'abri : jamais touchés par les impacts.
local function isImpactImmune(player: Player): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Oeuf" or stage == "Cocon" or player:GetAttribute("InShelterOrColony") == true
end

local function randomMapPoint(): (number, number)
	return rng:NextNumber(-MAP_HALF, MAP_HALF), rng:NextNumber(-MAP_HALF, MAP_HALF)
end

local function isPondPosition(position: Vector3, margin: number): boolean
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			local relative = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size * 0.5
			if math.abs(relative.X) <= half.X + margin and math.abs(relative.Z) <= half.Z + margin then
				return true
			end
		end
	end
	return false
end

-- ============================================================
-- Apparence globale (couleurs, lumière)
-- ============================================================

local function getOrCreate(className: string, name: string, parent: Instance): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local function applyLook(look: SeasonLook, season: string, token: number)
	local terrain = workspace.Terrain
	local groundTarget = look.Grass:Lerp(Color3.fromRGB(110, 85, 60), 0.6)
	local leafyTarget = if season == "Automne"
		then Color3.fromRGB(185, 105, 45)
		elseif season == "Hiver" then Color3.fromRGB(220, 230, 240)
		else look.Grass:Lerp(Color3.fromRGB(80, 120, 45), 0.35)
	local grassFrom = terrain:GetMaterialColor(Enum.Material.Grass)
	local groundFrom = terrain:GetMaterialColor(Enum.Material.Ground)
	local leafyFrom = terrain:GetMaterialColor(Enum.Material.LeafyGrass)

	local leaves: { BasePart } = {}
	local fromColors: { Color3 } = {}
	local toColors: { Color3 } = {}
	local fromTransparency: { number } = {}
	local seenLeaves: { [Instance]: boolean } = {}

	local autumnPalette = {
		look.Leaves,
		Color3.fromRGB(225, 90, 40),
		Color3.fromRGB(230, 165, 45),
		Color3.fromRGB(190, 65, 35),
	}

	local function registerLeaf(part: BasePart, indexSeed: number)
		if seenLeaves[part] then
			return
		end
		seenLeaves[part] = true
		local variation = (indexSeed % 5) * 6
		local targetColor = look.Leaves
		if season == "Printemps" and part:GetAttribute("SpringColor") == "Blossom" then
			targetColor = Color3.fromRGB(245, 160, 195)
		elseif season == "Automne" then
			targetColor = autumnPalette[(indexSeed % #autumnPalette) + 1]
		end
		table.insert(leaves, part)
		table.insert(fromColors, part.Color)
		table.insert(toColors, targetColor:Lerp(Color3.new(1, 1, 1), variation / 255))
		table.insert(fromTransparency, part.Transparency)
	end

	for idx, tagged in ipairs(CollectionService:GetTagged("SeasonalLeaf")) do
		if tagged:IsA("BasePart") then
			registerLeaf(tagged, idx)
		end
	end
	local generated = workspace:FindFirstChild("GeneratedWorld")
	local tree = generated and generated:FindFirstChild("GrandChene")
	if tree then
		for idx, part in ipairs(tree:GetChildren()) do
			if part:IsA("BasePart") and string.sub(part.Name, 1, 9) == "Feuillage" then
				registerLeaf(part, (string.byte(part.Name, -1) or idx))
			end
		end
	end

	-- Même boucle à 2 Hz que le feuillage (pas de tween serveur à 60 Hz répliqué à chaque image).
	local correction = getOrCreate("ColorCorrectionEffect", "SeasonTint", Lighting) :: ColorCorrectionEffect
	local atmosphere = getOrCreate("Atmosphere", "SeasonAtmosphere", Lighting) :: Atmosphere
	atmosphere.Density = if season == "Hiver" then 0.36 else 0.3
	local tintFrom, saturationFrom = correction.TintColor, correction.Saturation
	local savedDayAtmo = atmosphere:GetAttribute("DayColor")
	local atmosphereFrom = if typeof(savedDayAtmo) == "Color3" then savedDayAtmo else atmosphere.Color
	local hazeFrom = atmosphere.Haze

	task.spawn(function()
		local steps = math.floor(TRANSITION_SECONDS / TRANSITION_STEP)
		for step = 1, steps do
			task.wait(TRANSITION_STEP)
			if seasonToken ~= token then
				return -- la saison suivante repart des couleurs actuelles
			end
			local alpha = step / steps
			terrain:SetMaterialColor(Enum.Material.Grass, grassFrom:Lerp(look.Grass, alpha))
			terrain:SetMaterialColor(Enum.Material.Ground, groundFrom:Lerp(groundTarget, alpha))
			terrain:SetMaterialColor(Enum.Material.LeafyGrass, leafyFrom:Lerp(leafyTarget, alpha))
			correction.TintColor = tintFrom:Lerp(look.Tint, alpha)
			correction.Saturation = saturationFrom + (look.Saturation - saturationFrom) * alpha
			local dayAtmoColor = atmosphereFrom:Lerp(look.AtmosphereColor, alpha)
			atmosphere:SetAttribute("DayColor", dayAtmoColor)
			atmosphere.Color = dayAtmoColor
			atmosphere.Haze = hazeFrom + (look.Haze - hazeFrom) * alpha
			for i, leaf in ipairs(leaves) do
				if leaf.Parent then
					leaf.Color = fromColors[i]:Lerp(toColors[i], alpha)
					leaf.Transparency = fromTransparency[i] + (look.LeafTransparency - fromTransparency[i]) * alpha
				end
			end
		end
	end)
end

-- Chute rendue côté client : la part est déjà à sa position finale, le client la fait tomber
-- de FxFallHeight studs en FxFallDuration secondes. Attributs posés AVANT le tag.
local function markFalling(part: BasePart, height: number, duration: number)
	part:SetAttribute("FxFallHeight", height)
	part:SetAttribute("FxFallDuration", duration)
	part:SetAttribute("FxFallStart", workspace:GetServerTimeNow())
	CollectionService:AddTag(part, "FxFalling")
end

-- ============================================================
-- Eau saisonnière : rosée, flaques
-- ============================================================

local function spawnDrinkDrop(position: Vector3, isPuddle: boolean)
	local size = if isPuddle then Vector3.new(0.3, 7, 7) else Vector3.one * 1.4
	local cf = if isPuddle then CFrame.new(position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)) else CFrame.new(position + Vector3.new(0, 0.7, 0))
	local drop = anchoredPart(if isPuddle then "Flaque" else "GoutteDeRosee", size, cf, Color3.fromRGB(150, 200, 240), Enum.Material.Glass, 0.25)
	drop.Shape = if isPuddle then Enum.PartType.Cylinder else Enum.PartType.Ball
	drop.Reflectance = 0.3
	drop:SetAttribute("DisplayName", if isPuddle then "Flaque" else "Goutte de rosée")
	drop:SetAttribute("NoRespawn", true)
	drop:SetAttribute("Uses", if isPuddle then 6 else 2)
	CollectionService:AddTag(drop, "DrinkSource")
end

-- Rosée de préférence sur les plantes de la Prairie (GDD : "gouttes de rosée sur les plantes").
local function spawnDew(count: number)
	local generated = workspace:FindFirstChild("GeneratedWorld")
	local prairie = generated and generated:FindFirstChild("PrairieFleurie")
	local plants: { BasePart } = {}
	if prairie then
		for _, descendant in ipairs(prairie:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(plants, descendant)
			end
		end
	end
	for i = 1, count do
		if #plants > 0 and i % 2 == 0 then
			local plant = plants[rng:NextInteger(1, #plants)]
			-- Demi-hauteur MONDE : les cylindres redressés portent leur hauteur sur le X local.
			local cf, size = plant.CFrame, plant.Size
			local halfY = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
			spawnDrinkDrop(plant.Position + Vector3.new(0, halfY, 0), false)
		else
			local x, z = randomMapPoint()
			local hit = surfaceBelow(x, z)
			if hit and hit.Material ~= Enum.Material.Water and not isPondPosition(hit.Position, 4) then
				spawnDrinkDrop(hit.Position, false)
			end
		end
	end
end

local function spawnPuddles(count: number)
	for _ = 1, count do
		local x, z = randomMapPoint()
		local hit = surfaceBelow(x, z)
		if hit and hit.Instance == workspace.Terrain and hit.Material ~= Enum.Material.Water and not isPondPosition(hit.Position, 6) then
			spawnDrinkDrop(hit.Position, true)
		end
	end
end

local function spawnSeasonalFlowers(count: number)
	for _ = 1, count do
		-- Dans le carré inscrit au disque de la Prairie.
		local prairie, reach = WorldLayout.PRAIRIE_CENTER, WorldLayout.PRAIRIE_RADIUS * 0.7
		local x, z = prairie.X + rng:NextNumber(-reach, reach), prairie.Z + rng:NextNumber(-reach, reach)
		local hit = surfaceBelow(x, z)
		if not hit then
			continue
		end
		local base = hit.Position
		anchoredPart("TigeFleur", Vector3.new(0.6, 6, 0.6), CFrame.new(base + Vector3.new(0, 3, 0)), Color3.fromRGB(80, 150, 60), Enum.Material.Grass)
		local petalColor = Color3.fromHSV(rng:NextNumber(), 0.6, 1)
		for i = 1, 5 do
			local angle = i / 5 * math.pi * 2
			local petal = anchoredPart("Petale", Vector3.new(2.2, 0.3, 1.2), CFrame.new(base + Vector3.new(math.cos(angle) * 1.2, 6.1, math.sin(angle) * 1.2)) * CFrame.Angles(0, -angle, 0), petalColor, Enum.Material.SmoothPlastic)
			petal.CanCollide = true
			petal.CanQuery = true
		end
		local heart = anchoredPart("FoodNode_Nectar", Vector3.one * 1.4, CFrame.new(base + Vector3.new(0, 6.5, 0)), Color3.fromRGB(250, 210, 50), Enum.Material.Neon)
		heart.Shape = Enum.PartType.Ball
		heart:SetAttribute("FoodType", if rng:NextNumber() < 0.5 then "Nectar" else "Pollen")
		heart:SetAttribute("Uses", 3)
		heart:SetAttribute("NoRespawn", true)
		CollectionService:AddTag(heart, "FoodNode")
	end
end

-- ============================================================
-- Pluie : "bombes d'eau" (gouttes géantes à l'échelle d'un insecte)
-- ============================================================

local function countDewDrops(): number
	local drops = 0
	for _, child in ipairs(getFolder():GetChildren()) do
		if child.Name == "GoutteDeRosee" then
			drops += 1
		end
	end
	return drops
end

local function dropWaterBomb()
	if workspace:GetAttribute("Precipitation") ~= "Rain" then
		return
	end
	local rainIntensity = (workspace:GetAttribute("RainIntensity") :: number?) or 0
	if rainIntensity < 0.2 then
		return
	end
	local candidates = Players:GetPlayers()
	if #candidates == 0 then
		return
	end
	local player = candidates[rng:NextInteger(1, #candidates)]
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or player:GetAttribute("InShelterOrColony") == true then
		return
	end
	local landing = root.Position + Vector3.new(rng:NextNumber(-12, 12), 0, rng:NextNumber(-12, 12))
	local hit = surfaceBelow(landing.X, landing.Z)
	local ground = if hit then hit.Position else landing
	local drop = anchoredPart("BombeDEau", Vector3.one * 4, CFrame.new(ground + Vector3.new(0, 2, 0)), Color3.fromRGB(160, 200, 245), Enum.Material.Glass, 0.3)
	drop.Shape = Enum.PartType.Ball
	drop:SetAttribute("FxSplash", true) -- éclaboussure locale à l'impact (WorldFxController)
	local fallSeconds = 1.3
	markFalling(drop, 88, fallSeconds)
	task.delay(fallSeconds, function()
		if not drop.Parent then
			return -- saison changée pendant la chute
		end
		drop:Destroy()
		local ok, err = pcall(function()
			-- Une goutte géante qui s'écrase peut laisser une goutte d'eau potable au sol.
			if hit and hit.Material ~= Enum.Material.Water and not isPondPosition(ground, 4) and rng:NextNumber() < 0.4 and countDewDrops() < 50 * SCATTER_SCALE then
				spawnDrinkDrop(ground, false)
			end
			for _, other in ipairs(Players:GetPlayers()) do
				local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if otherRoot and (otherRoot.Position - ground).Magnitude <= 7 and other.Character and not isImpactImmune(other) then
					DamageService.ApplyDamage(other.Character, 6, { IgnoreArmor = true })
					local away = otherRoot.Position - ground
					local flat = Vector3.new(away.X, 0, away.Z)
					Remotes.Get("AbilityCast"):FireClient(other, "Knockback", "Knockback", 0, 0, (if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis) * 35 + Vector3.new(0, 25, 0))
					other:SetAttribute("Thirst", math.min(100, ((other:GetAttribute("Thirst") :: number?) or 0) + 15))
					Remotes.Get("NotifyClient"):FireClient(other, "Une goutte de pluie géante vous percute !", "warning")
				end
			end
		end)
		if not ok then
			warn("[SeasonVisualService] " .. tostring(err))
		end
	end)
end

-- ============================================================
-- Automne : feuilles mortes, fruits qui tombent, vent
-- ============================================================

local function spawnDeadLeaves(count: number)
	for _ = 1, count do
		local x, z = randomMapPoint()
		local hit = surfaceBelow(x, z)
		if hit and not isPondPosition(hit.Position, 2) then
			local color = Color3.fromRGB(rng:NextInteger(170, 220), rng:NextInteger(80, 130), rng:NextInteger(20, 50))
			local leaf = anchoredPart("FeuilleMorte", Vector3.new(rng:NextNumber(6, 10), 0.25, rng:NextNumber(4, 7)), CFrame.new(hit.Position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0), color, Enum.Material.Grass, 0, true)
			-- Une feuille sur trois est assez grande pour s'y cacher (GDD "feuilles mortes pour se
			-- camoufler") : toutes en abri rendraient un sixième de la carte "à l'abri".
			if rng:NextNumber() < 0.33 then
				CollectionService:AddTag(leaf, "Shelter")
			end
		end
	end
end

local FRUITS = {
	{ Food = "Fruit", Name = "Pomme", Color = Color3.fromRGB(200, 40, 35), Size = 6 },
	{ Food = "Fruit", Name = "Baie", Color = Color3.fromRGB(110, 30, 90), Size = 3 },
	{ Food = "Graine", Name = "Gland", Color = Color3.fromRGB(140, 100, 45), Size = 4 },
}

local function dropFruit()
	local fruit = FRUITS[rng:NextInteger(1, #FRUITS)]
	local angle = rng:NextNumber() * math.pi * 2
	-- Du pied du tronc jusque sous le bord de la canopée.
	local radius = rng:NextNumber(WorldLayout.TRUNK_RADIUS + 10, WorldLayout.CANOPY_RADIUS)
	local x, z = TREE_POSITION.X + math.cos(angle) * radius, TREE_POSITION.Z + math.sin(angle) * radius
	local hit = workspace:Raycast(Vector3.new(x, GROUND_Y + SKY_HEIGHT, z), Vector3.new(0, -(SKY_HEIGHT + 60), 0), terrainParams)
	local ground = if hit then hit.Position else Vector3.new(x, GROUND_Y, z)
	local finalCFrame = CFrame.new(ground + Vector3.new(0, fruit.Size / 2, 0))
	local part = anchoredPart("FoodNode_" .. fruit.Food, Vector3.one * fruit.Size, finalCFrame, fruit.Color, Enum.Material.SmoothPlastic)
	part.Shape = Enum.PartType.Ball
	local fallSeconds = 2
	markFalling(part, math.max(GROUND_Y + WorldLayout.TRUNK_HEIGHT - finalCFrame.Position.Y, 0), fallSeconds)
	task.delay(fallSeconds, function()
		if not part.Parent then
			return
		end
		local ok, err = pcall(function()
			-- Un fruit géant nourrit des dizaines d'insectes (GDD §4 Automne).
			part:SetAttribute("FoodType", fruit.Food)
			part:SetAttribute("Uses", 8)
			part:SetAttribute("NoRespawn", true)
			CollectionService:AddTag(part, "FoodNode")
			for _, player in ipairs(Players:GetPlayers()) do
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root and player.Character and (root.Position - ground).Magnitude <= fruit.Size and not isImpactImmune(player) then
					DamageService.ApplyDamage(player.Character, 15, { IgnoreArmor = true })
					Remotes.Get("NotifyClient"):FireClient(player, "Un(e) " .. fruit.Name .. " vous tombe dessus !", "warning")
				end
			end
		end)
		if not ok then
			warn("[SeasonVisualService] " .. tostring(err))
		end
	end)
end

-- ============================================================
-- Hiver : glace sur la mare
-- ============================================================

local function freezePond()
	local waterLevelAttr = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevelAttr then
		return
	end
	local waterLevel: number = waterLevelAttr
	local function iceSlab(minX: number, maxX: number, minZ: number, maxZ: number)
		if maxX - minX < 0.5 then
			return
		end
		local ice = anchoredPart("Glace", Vector3.new(maxX - minX, 1, maxZ - minZ), CFrame.new((minX + maxX) / 2, waterLevel + 0.4, (minZ + maxZ) / 2), Color3.fromRGB(200, 230, 250), Enum.Material.Ice, 0.25, true)
		ice.Reflectance = 0.2
	end
	-- Trou dans la glace au-dessus de la rampe immergée (WorldGenerationService, X = mare + 30,
	-- 16 de large) : un nageur ou une larve devenue adulte peut toujours ressortir.
	local holeMinX = WorldLayout.POND_CENTER.X + 30 - 9
	local holeMaxX = WorldLayout.POND_CENTER.X + 30 + 9
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			local minX, maxX = zone.Position.X - zone.Size.X / 2 - 1, zone.Position.X + zone.Size.X / 2 + 1
			local minZ, maxZ = zone.Position.Z - zone.Size.Z / 2 - 1, zone.Position.Z + zone.Size.Z / 2 + 1
			if zone.Name == "PondZone_Mare" then
				iceSlab(minX, math.min(holeMinX, maxX), minZ, maxZ)
				iceSlab(math.max(holeMaxX, minX), maxX, minZ, maxZ)
			else
				iceSlab(minX, maxX, minZ, maxZ)
			end
		end
	end

	-- Personne ne reste scellé sous la glace : les nageurs sont remontés sur la glace, sauf les
	-- petits aquatiques (ils respirent sous l'eau et leur nurserie est au fond).
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if character and root and root.Position.Y < waterLevel and isPondPosition(root.Position, 0) then
			local speciesId = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
			local species = InsectData[speciesId]
			local aquaticYoung = player:GetAttribute("Stage") ~= "Adulte"
				and (GameConstants.AQUATIC_LARVA_SPECIES[speciesId] == true or (species ~= nil and species.Category == "Aquatique"))
			if not aquaticYoung then
				character:PivotTo(CFrame.new(root.Position.X, waterLevel + 1 + root.Size.Y, root.Position.Z))
			end
		end
	end
end

local function spawnSnowDrifts(count: number)
	for _ = 1, count do
		local x, z = randomMapPoint()
		local hit = surfaceBelow(x, z)
		if hit and hit.Instance == workspace.Terrain and hit.Material ~= Enum.Material.Water and not isPondPosition(hit.Position, 5) then
			local w = rng:NextNumber(8, 18)
			local drift = anchoredPart(
				"Congere", Vector3.new(w, rng:NextNumber(2.2, 4.5), w * rng:NextNumber(0.7, 1.1)),
				CFrame.new(hit.Position + Vector3.new(0, 0.8, 0)) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
				Color3.fromRGB(238, 244, 252), Enum.Material.Snow, 0, true
			)
			drift.Shape = Enum.PartType.Ball
		end
	end
end

local function spawnSummerBlooms(count: number)
	for _ = 1, count do
		local x, z = randomMapPoint()
		local hit = surfaceBelow(x, z)
		if hit and hit.Instance == workspace.Terrain and hit.Material ~= Enum.Material.Water and not isPondPosition(hit.Position, 6) then
			local base = hit.Position
			anchoredPart("TigeFleurEte", Vector3.new(0.7, 7, 0.7), CFrame.new(base + Vector3.new(0, 3.5, 0)), Color3.fromRGB(85, 145, 50), Enum.Material.Grass)
			local head = anchoredPart("FleurSoleil", Vector3.new(4.2, 1.2, 4.2), CFrame.new(base + Vector3.new(0, 7.2, 0)), Color3.fromRGB(255, 200, 35), Enum.Material.SmoothPlastic)
			head.Shape = Enum.PartType.Cylinder
			head.CFrame = CFrame.new(base + Vector3.new(0, 7.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
			local heart = anchoredPart("FoodNode_Pollen", Vector3.one * 1.5, CFrame.new(base + Vector3.new(0, 7.9, 0)), Color3.fromRGB(250, 220, 70), Enum.Material.Neon)
			heart.Shape = Enum.PartType.Ball
			heart:SetAttribute("FoodType", "Pollen")
			heart:SetAttribute("Uses", 3)
			heart:SetAttribute("NoRespawn", true)
			CollectionService:AddTag(heart, "FoodNode")
		end
	end
end

-- ============================================================
-- Vent dynamique & rafales (actif toute l'année, plus fort en Automne et Hiver)
-- ============================================================

type WindProfile = {
	ForceMin: number,
	ForceMax: number,
	GustThreshold: number,
	CalmMin: number,
	CalmMax: number,
	DurationMin: number,
	DurationMax: number,
}

local MAX_WIND_SPEED = 34

local WIND_PROFILES: { [string]: WindProfile } = {
	Printemps = {
		ForceMin = 4.5,
		ForceMax = 22,
		GustThreshold = 15.5,
		CalmMin = 8,
		CalmMax = 24,
		DurationMin = 4,
		DurationMax = 13,
	},
	Ete = {
		ForceMin = 3.5,
		ForceMax = 17,
		GustThreshold = 13,
		CalmMin = 12,
		CalmMax = 30,
		DurationMin = 3.5,
		DurationMax = 10,
	},
	Automne = {
		ForceMin = 7,
		ForceMax = 34,
		GustThreshold = 19,
		CalmMin = 5,
		CalmMax = 16,
		DurationMin = 5,
		DurationMax = 16,
	},
	Hiver = {
		ForceMin = 6,
		ForceMax = 28,
		GustThreshold = 17.5,
		CalmMin = 7,
		CalmMax = 20,
		DurationMin = 4.5,
		DurationMax = 14,
	},
}

local function setGlobalWind(vec: Vector3, gustThreshold: number)
	local horizSpeed = Vector3.new(vec.X, 0, vec.Z).Magnitude
	local strength = math.clamp(horizSpeed / MAX_WIND_SPEED, 0, 1)
	local isGust = horizSpeed >= gustThreshold
	workspace:SetAttribute("WindVector", vec)
	workspace:SetAttribute("WindStrength", strength)
	workspace:SetAttribute("WindGust", isGust)
	pcall(function()
		-- L'herbe 3D du Terrain Roblox s'incline proportionnellement à la force exacte du vent.
		workspace.GlobalWind = vec * (1.2 + strength * 0.7)
	end)
end

local function rampWind(token: number, from: Vector3, to: Vector3, steps: number, stepDelay: number, gustThreshold: number): boolean
	for k = 1, steps do
		task.wait(stepDelay)
		if seasonToken ~= token then
			return false
		end
		local alpha = k / steps
		setGlobalWind(from:Lerp(to, alpha), gustThreshold)
	end
	return true
end

local function startWindCycle(token: number, season: string)
	local profile = WIND_PROFILES[season] or WIND_PROFILES.Printemps
	local currentAngle = rng:NextNumber() * math.pi * 2
	-- Le vent n'est pas constant : on démarre au calme puis chaque épisode tire aléatoirement
	-- son attente (CalmMin..CalmMax), sa durée (DurationMin..DurationMax) et sa force (ForceMin..ForceMax).
	setGlobalWind(Vector3.zero, profile.GustThreshold)

	task.spawn(function()
		local firstCycle = true
		while seasonToken == token do
			local calmDuration = if firstCycle
				then rng:NextNumber(3.5, 9)
				else rng:NextNumber(profile.CalmMin, profile.CalmMax)
			firstCycle = false

			task.wait(calmDuration)
			if seasonToken ~= token then
				return
			end

			-- Force X aléatoire sur tout le spectre de la saison (de la petite brise à la grosse bourrasque).
			local targetSpeed = rng:NextNumber(profile.ForceMin, profile.ForceMax)
			local isStrong = targetSpeed >= profile.GustThreshold
			currentAngle = (currentAngle + rng:NextNumber(-1.25, 1.25)) % (math.pi * 2)
			local verticalLift = if isStrong
				then rng:NextNumber(-0.9, 1.5) * (targetSpeed / MAX_WIND_SPEED)
				else 0
			local target = Vector3.new(math.cos(currentAngle) * targetSpeed, verticalLift, math.sin(currentAngle) * targetSpeed)

			-- 1) Montée progressive jusqu'à la force X tirée
			local rampUpSteps = if isStrong then 5 else 7
			if not rampWind(token, Vector3.zero, target, rampUpSteps, 0.3, profile.GustThreshold) then
				return
			end

			-- 2) Durée X aléatoire du vent, avec une légère respiration autour de la force tirée
			local blowDuration = rng:NextNumber(profile.DurationMin, profile.DurationMax)
			task.wait(blowDuration * 0.5)
			if seasonToken ~= token then
				return
			end
			local swayAngle = currentAngle + rng:NextNumber(-0.3, 0.3)
			local swaySpeed = math.clamp(targetSpeed * rng:NextNumber(0.88, 1.12), profile.ForceMin, profile.ForceMax)
			local swayTarget = Vector3.new(math.cos(swayAngle) * swaySpeed, verticalLift * 0.8, math.sin(swayAngle) * swaySpeed)
			if not rampWind(token, target, swayTarget, 3, 0.25, profile.GustThreshold) then
				return
			end
			task.wait(blowDuration * 0.5)
			if seasonToken ~= token then
				return
			end

			-- 3) Retombée progressive jusqu'au calme plat (0)
			local rampDownSteps = if isStrong then 6 else 8
			if not rampWind(token, swayTarget, Vector3.zero, rampDownSteps, 0.3, profile.GustThreshold) then
				return
			end
			setGlobalWind(Vector3.zero, profile.GustThreshold)
		end
	end)
end

-- ============================================================
-- Pluie dynamique & averses (bruine, averse, déluge / orage)
-- ============================================================

type RainProfile = {
	StartImmediately: boolean,
	IntensityMin: number,
	IntensityMax: number,
	HeavyThreshold: number,
	CalmMin: number,
	CalmMax: number,
	DurationMin: number,
	DurationMax: number,
}

local RAIN_PROFILES: { [string]: RainProfile } = {
	Printemps = {
		StartImmediately = true,
		IntensityMin = 0.42,
		IntensityMax = 1.0,
		HeavyThreshold = 0.72,
		CalmMin = 7,
		CalmMax = 18,
		DurationMin = 16,
		DurationMax = 34,
	},
	Ete = {
		StartImmediately = false,
		IntensityMin = 0.30,
		IntensityMax = 0.78,
		HeavyThreshold = 0.62,
		CalmMin = 24,
		CalmMax = 48,
		DurationMin = 8,
		DurationMax = 16,
	},
	Automne = {
		StartImmediately = true,
		IntensityMin = 0.38,
		IntensityMax = 0.95,
		HeavyThreshold = 0.68,
		CalmMin = 9,
		CalmMax = 22,
		DurationMin = 14,
		DurationMax = 30,
	},
}

local rainOverrideMode: string? = nil -- nil = cycle auto, "Averse", "Deluge", "Sec"
local rainToken = 0

local function setGlobalRain(intensity: number, heavyThreshold: number, season: string)
	local clamped = math.clamp(intensity, 0, 1)
	local isRaining = clamped > 0.02
	local isHeavy = clamped >= heavyThreshold
	if isRaining then
		workspace:SetAttribute("Precipitation", "Rain")
	else
		workspace:SetAttribute("Precipitation", if season == "Hiver" then "Snow" else "None")
	end
	workspace:SetAttribute("RainIntensity", clamped)
	workspace:SetAttribute("RainHeavy", isHeavy)
end

local function rampRain(myRainToken: number, from: number, to: number, steps: number, stepDelay: number, heavyThreshold: number, season: string): boolean
	for k = 1, steps do
		task.wait(stepDelay)
		if rainToken ~= myRainToken or rainOverrideMode ~= nil then
			return false
		end
		local alpha = k / steps
		setGlobalRain(from + (to - from) * alpha, heavyThreshold, season)
	end
	return true
end

local function startRainCycle(season: string)
	rainToken += 1
	local myRainToken = rainToken

	if rainOverrideMode == "Averse" then
		setGlobalRain(0.65, 0.72, season)
		return
	elseif rainOverrideMode == "Deluge" then
		setGlobalRain(1.0, 0.72, season)
		return
	elseif rainOverrideMode == "Sec" then
		setGlobalRain(0, 0.72, season)
		return
	end

	local profile = RAIN_PROFILES[season]
	if not profile then
		-- Hiver : neige par défaut, pas de pluie automatique.
		setGlobalRain(0, 0.72, season)
		return
	end

	task.spawn(function()
		local firstEpisode = true
		while rainToken == myRainToken and rainOverrideMode == nil do
			if not (firstEpisode and profile.StartImmediately) then
				local calmDuration = if firstEpisode
					then rng:NextNumber(8, 16)
					else rng:NextNumber(profile.CalmMin, profile.CalmMax)
				setGlobalRain(0, profile.HeavyThreshold, season)
				task.wait(calmDuration)
				if rainToken ~= myRainToken or rainOverrideMode ~= nil then
					return
				end
			end

			local targetIntensity = if firstEpisode and profile.StartImmediately
				then rng:NextNumber(math.max(0.62, profile.IntensityMin), profile.IntensityMax)
				else rng:NextNumber(profile.IntensityMin, profile.IntensityMax)
			local isHeavy = targetIntensity >= profile.HeavyThreshold

			if firstEpisode and profile.StartImmediately then
				-- Démarre directement sous la pluie dès l'entrée dans la saison pour un impact visuel immédiat.
				setGlobalRain(targetIntensity, profile.HeavyThreshold, season)
			else
				local rampUpSteps = if isHeavy then 5 else 7
				if not rampRain(myRainToken, 0, targetIntensity, rampUpSteps, 0.35, profile.HeavyThreshold, season) then
					return
				end
			end
			firstEpisode = false

			local rainDuration = rng:NextNumber(profile.DurationMin, profile.DurationMax)
			task.wait(rainDuration * 0.5)
			if rainToken ~= myRainToken or rainOverrideMode ~= nil then
				return
			end

			local pulseIntensity = math.clamp(targetIntensity * rng:NextNumber(0.85, 1.18), profile.IntensityMin, profile.IntensityMax)
			if not rampRain(myRainToken, targetIntensity, pulseIntensity, 4, 0.3, profile.HeavyThreshold, season) then
				return
			end

			task.wait(rainDuration * 0.5)
			if rainToken ~= myRainToken or rainOverrideMode ~= nil then
				return
			end

			local rampDownSteps = if isHeavy then 6 else 8
			if not rampRain(myRainToken, pulseIntensity, 0, rampDownSteps, 0.35, profile.HeavyThreshold, season) then
				return
			end
			setGlobalRain(0, profile.HeavyThreshold, season)
		end
	end)
end

function SeasonVisualService.CycleRainOverride(): string
	local currentIntensity = (workspace:GetAttribute("RainIntensity") :: number?) or 0
	if rainOverrideMode == nil then
		rainOverrideMode = if currentIntensity >= 0.5 then "Deluge" else "Averse"
	elseif rainOverrideMode == "Averse" then
		rainOverrideMode = "Deluge"
	elseif rainOverrideMode == "Deluge" then
		rainOverrideMode = "Sec"
	else
		rainOverrideMode = nil
	end

	local season = if currentSeason ~= "" then currentSeason else ((workspace:GetAttribute("CurrentSeason") :: string?) or "Printemps")
	startRainCycle(season)

	if rainOverrideMode == "Averse" then
		return "🌧️ Averse de pluie forcée"
	elseif rainOverrideMode == "Deluge" then
		return "⛈️ Déluge / Orage forcé !"
	elseif rainOverrideMode == "Sec" then
		return "☀️ Pluie coupée (ciel dégagé)"
	else
		return "🔄 Météo automatique (selon la saison)"
	end
end

-- ============================================================
-- Changement de saison
-- ============================================================

local function startLoop(token: number, interval: () -> number, action: () -> ())
	task.spawn(function()
		while seasonToken == token do
			task.wait(interval())
			if seasonToken ~= token then
				break
			end
			local ok, err = pcall(action)
			if not ok then
				warn("[SeasonVisualService] " .. tostring(err))
			end
		end
	end)
end

local function onSeasonChanged()
	local season = (workspace:GetAttribute("CurrentSeason") :: string?) or "Printemps"
	if season == currentSeason then
		return
	end
	currentSeason = season
	seasonToken += 1
	local token = seasonToken
	clearSeasonal()
	workspace:SetAttribute("FlightSeasonBonus", if season == "Ete" then 1.15 else 1)
	startWindCycle(token, season)

	local look = LOOKS[season] or LOOKS.Printemps
	applyLook(look, season, token)
	startRainCycle(season)
	workspace:SetAttribute(
		"SeasonAmbientFx",
		if season == "Printemps"
			then "SpringPollen"
			elseif season == "Ete" then "SummerFireflies"
			elseif season == "Automne" then "AutumnLeaves"
			else "WinterFrost"
	)

	-- Gouttes géantes ("bombes d'eau") dès qu'il pleut, avec cadence accélérée sous une forte averse.
	startLoop(token, function()
		local intensity = (workspace:GetAttribute("RainIntensity") :: number?) or 0
		if workspace:GetAttribute("Precipitation") == "Rain" and intensity >= 0.72 then
			return rng:NextNumber(3.5, 7)
		end
		return rng:NextNumber(6.5, 12)
	end, dropWaterBomb)

	if season == "Printemps" then
		spawnDew(45 * SCATTER_SCALE)
		spawnPuddles(18 * SCATTER_SCALE)
		spawnSeasonalFlowers(16 * SCATTER_SCALE)
		-- La rosée se reforme au fil de la saison.
		startLoop(token, function()
			return 90
		end, function()
			-- Plafond : la rosée non bue ne s'accumule pas sur toute la saison (budget mobile).
			if countDewDrops() < 45 * SCATTER_SCALE then
				spawnDew(12 * SCATTER_SCALE)
			end
		end)
	elseif season == "Ete" then
		-- Assèchement : rien à boire hors de la mare (zone PvP intense, GDD §4).
		spawnDew(6 * SCATTER_SCALE)
		spawnSummerBlooms(8 * SCATTER_SCALE)
	elseif season == "Automne" then
		spawnDeadLeaves(70 * SCATTER_SCALE)
		spawnPuddles(8 * SCATTER_SCALE)
		spawnDew(15 * SCATTER_SCALE)
		startLoop(token, function()
			return rng:NextNumber(15, 28)
		end, dropFruit)
	elseif season == "Hiver" then
		freezePond()
		spawnSnowDrifts(18 * SCATTER_SCALE)
		-- Un peu de neige fondue à boire près des abris.
		spawnPuddles(6 * SCATTER_SCALE)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		Remotes.Get("NotifyClient"):FireClient(player, "Nouvelle saison : " .. tostring(workspace:GetAttribute("SeasonDisplayName") or season), "info")
	end
end

function SeasonVisualService.Start()
	workspace:GetAttributeChangedSignal("CurrentSeason"):Connect(onSeasonChanged)
	onSeasonChanged()
end

return SeasonVisualService
