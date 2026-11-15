--!strict
-- SeasonVisualService.luau
-- Rend les 4 saisons (GDD §4) visibles et jouables, en réagissant à l'attribut CurrentSeason posé
-- par SeasonService :
--   Printemps : pluie + "bombes d'eau", rosée sur les plantes, flaques, fleurs riches en nectar
--   Été       : flaques et rosée asséchées (tout le monde doit boire à la mare), bonus de vol
--   Automne   : feuilles mortes au sol, chute de fruits géants, vent qui pousse les volants
--   Hiver     : neige, herbe blanche, arbre dégarni, mare gelée (glace solide en surface)
-- Tout ce qui est saisonnier vit dans workspace.SeasonalEffects et est détruit au changement.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

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
-- La carte est 9x plus vaste qu'à l'origine (500 -> 1500 de côté) : on sème 4x plus d'effets
-- (pas 9x : le nombre de parts doit rester raisonnable sur mobile).
local SCATTER_SCALE = 4

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

-- Surface la plus haute sous un point (herbe géante, rocher, sol...), en ignorant les effets.
local function surfaceBelow(x: number, z: number): RaycastResult?
	groundParams.FilterDescendantsInstances = { getFolder(), workspace:FindFirstChild("Animals") or getFolder() }
	return workspace:Raycast(Vector3.new(x, GROUND_Y + SKY_HEIGHT, z), Vector3.new(0, -(SKY_HEIGHT + 60), 0), groundParams)
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

local function applyLook(look: SeasonLook)
	local terrain = workspace.Terrain
	terrain:SetMaterialColor(Enum.Material.Grass, look.Grass)
	terrain:SetMaterialColor(Enum.Material.Ground, look.Grass:Lerp(Color3.fromRGB(110, 85, 60), 0.6))

	local generated = workspace:FindFirstChild("GeneratedWorld")
	local tree = generated and generated:FindFirstChild("GrandChene")
	if tree then
		for _, part in ipairs(tree:GetChildren()) do
			if part:IsA("BasePart") and string.sub(part.Name, 1, 9) == "Feuillage" then
				local variation = (string.byte(part.Name, -1) or 0) % 5 * 6
				TweenService:Create(part, TweenInfo.new(4), {
					Color = look.Leaves:Lerp(Color3.new(1, 1, 1), variation / 255),
					Transparency = look.LeafTransparency,
				}):Play()
			end
		end
	end

	local correction = getOrCreate("ColorCorrectionEffect", "SeasonTint", Lighting) :: ColorCorrectionEffect
	TweenService:Create(correction, TweenInfo.new(4), { TintColor = look.Tint, Saturation = look.Saturation }):Play()
	local atmosphere = getOrCreate("Atmosphere", "SeasonAtmosphere", Lighting) :: Atmosphere
	atmosphere.Density = 0.3
	TweenService:Create(atmosphere, TweenInfo.new(4), { Color = look.AtmosphereColor, Haze = look.Haze }):Play()
end

-- ============================================================
-- Précipitations (neige / pluie) : un grand émetteur au-dessus de la carte
-- ============================================================

local function createSkyEmitter(kind: "Rain" | "Snow")
	local sky = anchoredPart("Ciel_" .. kind, Vector3.new(MAP_HALF * 2, 1, MAP_HALF * 2), CFrame.new(0, GROUND_Y + 180, 0), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, 1)
	local emitter = Instance.new("ParticleEmitter")
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.LightInfluence = 1
	if kind == "Snow" then
		-- shortcut: un émetteur global dilue 9x la neige/pluie sur la grande carte ; le débit est
		-- seulement triplé (budget particules mobile). À remplacer par un émetteur client qui suit la caméra.
		emitter.Rate = 1200
		emitter.Lifetime = NumberRange.new(12, 16)
		emitter.Speed = NumberRange.new(10, 16)
		emitter.SpreadAngle = Vector2.new(20, 20)
		emitter.Size = NumberSequence.new(0.6)
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.RotSpeed = NumberRange.new(-60, 60)
	else
		emitter.Rate = 1800
		emitter.Lifetime = NumberRange.new(3, 4)
		emitter.Speed = NumberRange.new(55, 65)
		emitter.Size = NumberSequence.new(0.15)
		emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 230))
		emitter.Transparency = NumberSequence.new(0.4)
		emitter.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
		emitter.Squash = NumberSequence.new(-3)
	end
	emitter.Parent = sky
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
			spawnDrinkDrop(plant.Position + Vector3.new(0, plant.Size.Y / 2, 0), false)
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
-- Printemps : "bombes d'eau"
-- ============================================================

local function dropWaterBomb()
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
	local drop = anchoredPart("BombeDEau", Vector3.one * 4, CFrame.new(ground + Vector3.new(0, 90, 0)), Color3.fromRGB(160, 200, 245), Enum.Material.Glass, 0.3)
	drop.Shape = Enum.PartType.Ball
	local fall = TweenService:Create(drop, TweenInfo.new(1.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(ground + Vector3.new(0, 2, 0)) })
	fall.Completed:Connect(function()
		drop:Destroy()
		local splash = anchoredPart("Eclaboussure", Vector3.new(0.4, 8, 8), CFrame.new(ground + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(170, 210, 250), Enum.Material.Glass, 0.4)
		splash.Shape = Enum.PartType.Cylinder
		TweenService:Create(splash, TweenInfo.new(0.6), { Size = Vector3.new(0.2, 16, 16), Transparency = 1 }):Play()
		task.delay(0.7, function()
			splash:Destroy()
		end)
		for _, other in ipairs(Players:GetPlayers()) do
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if otherRoot and (otherRoot.Position - ground).Magnitude <= 7 and other.Character then
				DamageService.ApplyDamage(other.Character, 6, { IgnoreArmor = true })
				local away = otherRoot.Position - ground
				local flat = Vector3.new(away.X, 0, away.Z)
				Remotes.Get("AbilityCast"):FireClient(other, "Knockback", "Knockback", 0, 0, (if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis) * 35 + Vector3.new(0, 25, 0))
				other:SetAttribute("Thirst", math.min(100, ((other:GetAttribute("Thirst") :: number?) or 0) + 15))
				Remotes.Get("NotifyClient"):FireClient(other, "Une goutte de pluie géante vous percute !", "warning")
			end
		end
	end)
	fall:Play()
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
	local hit = surfaceBelow(x, z)
	local ground = if hit then hit.Position else Vector3.new(x, GROUND_Y, z)
	local start = Vector3.new(x, GROUND_Y + WorldLayout.TRUNK_HEIGHT, z)
	local part = anchoredPart("FoodNode_" .. fruit.Food, Vector3.one * fruit.Size, CFrame.new(start), fruit.Color, Enum.Material.SmoothPlastic)
	part.Shape = Enum.PartType.Ball
	local fall = TweenService:Create(part, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(ground + Vector3.new(0, fruit.Size / 2, 0)) })
	fall.Completed:Connect(function()
		if not part.Parent then
			return
		end
		-- Un fruit géant nourrit des dizaines d'insectes (GDD §4 Automne).
		part:SetAttribute("FoodType", fruit.Food)
		part:SetAttribute("Uses", 8)
		part:SetAttribute("NoRespawn", true)
		CollectionService:AddTag(part, "FoodNode")
		for _, player in ipairs(Players:GetPlayers()) do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and player.Character and (root.Position - ground).Magnitude <= fruit.Size then
				DamageService.ApplyDamage(player.Character, 15, { IgnoreArmor = true })
				Remotes.Get("NotifyClient"):FireClient(player, "Un(e) " .. fruit.Name .. " vous tombe dessus !", "warning")
			end
		end
	end)
	fall:Play()
end

-- ============================================================
-- Hiver : glace sur la mare
-- ============================================================

local function freezePond()
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevel then
		return
	end
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			local ice = anchoredPart("Glace", Vector3.new(zone.Size.X + 2, 1, zone.Size.Z + 2), CFrame.new(zone.Position.X, waterLevel + 0.4, zone.Position.Z), Color3.fromRGB(200, 230, 250), Enum.Material.Ice, 0.25, true)
			ice.Reflectance = 0.2
		end
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
	workspace:SetAttribute("WindVector", Vector3.zero)
	workspace:SetAttribute("FlightSeasonBonus", if season == "Ete" then 1.15 else 1)

	local look = LOOKS[season] or LOOKS.Printemps
	applyLook(look)

	if season == "Printemps" then
		createSkyEmitter("Rain")
		spawnDew(45 * SCATTER_SCALE)
		spawnPuddles(18 * SCATTER_SCALE)
		spawnSeasonalFlowers(10 * SCATTER_SCALE)
		startLoop(token, function()
			return rng:NextNumber(6, 12)
		end, dropWaterBomb)
		-- La rosée se reforme au fil de la saison.
		startLoop(token, function()
			return 90
		end, function()
			spawnDew(12 * SCATTER_SCALE)
		end)
	elseif season == "Ete" then
		-- Assèchement : rien à boire hors de la mare (zone PvP intense, GDD §4).
		spawnDew(6 * SCATTER_SCALE)
	elseif season == "Automne" then
		spawnDeadLeaves(60 * SCATTER_SCALE)
		spawnPuddles(8 * SCATTER_SCALE)
		spawnDew(15 * SCATTER_SCALE)
		startLoop(token, function()
			return rng:NextNumber(15, 28)
		end, dropFruit)
		startLoop(token, function()
			return 25
		end, function()
			local angle = rng:NextNumber() * math.pi * 2
			workspace:SetAttribute("WindVector", Vector3.new(math.cos(angle), 0, math.sin(angle)) * rng:NextNumber(10, 22))
		end)
	elseif season == "Hiver" then
		createSkyEmitter("Snow")
		freezePond()
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
