--!strict
-- AnimalService.luau
-- IA des 5 animaux géants (GDD §6) + alevins, leurs nids/terriers (GDD §7.A) et leurs carcasses
-- (Festin de Kaiju, GDD §7.B). Chaque animal est une petite machine à états mise à jour à 20 Hz ;
-- il est déplacé par PivotTo de sa Root ancrée (pas de physique serveur à synchroniser).
--
--   Oiseau   : perché dans le Chêne, fond en piqué sur un insecte qui BOUGE à découvert ;
--              fuit s'il se fait piquer (essaim), ramasse des brindilles, nid géant chauffé.
--   Caméléon : grimpe le tronc en changeant de couleur, langue-grappin (un allié qui le mord
--              libère la proie), creuse un terrier de ponte au pied de l'arbre.
--   Poisson  : patrouille la mare, aspire les nageurs, saute hors de l'eau ; alevins chassables ;
--              cuvettes de frai avec des oeufs à voler.
--   Crabe    : blindé de face (FrontInvulnerable), patrouille fond/berges, terrier boueux.
--   Écureuil : bondit de branche en branche (tremblements), casse des noix (miettes), enterre
--              des provisions dans le sol ; quasi impossible à tuer (régénération).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AnimalData = require(ReplicatedStorage.shared.AnimalData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local AnimalModels = require(ServerScriptService.services.AnimalModels)
local DamageService = require(ServerScriptService.services.DamageService)
local MovementService = require(ServerScriptService.services.MovementService)
local StatusEffectService = require(ServerScriptService.services.StatusEffectService)
local CarcassService = require(ServerScriptService.services.CarcassService)
local DigService = require(ServerScriptService.services.DigService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local AnimalService = {
	SchoolCenter = nil :: Vector3?, -- point de rassemblement du banc d'alevins
}

type Animal = {
	Id: string,
	DisplayName: string,
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Mode: string,
	Timer: number,
	Cooldown: number,
	Goal: Vector3?,
	Prey: Player?,
	Giant: boolean,
	CarcassScale: number,
	RespawnSeconds: number,
	Respawn: () -> (),
	DamageLog: { { At: number, Amount: number } },
	LastDamagedAt: number,
	Data: { [string]: any },
	Update: (Animal, number) -> (),
}

local TICK = 1 / 20
local GROUND_Y = GameConstants.GROUND_TOP_Y
-- Géométrie du monde : source unique dans shared/WorldLayout.
local TREE_POSITION = WorldLayout.TREE_POSITION
local TRUNK_RADIUS = WorldLayout.TRUNK_RADIUS
local TRUNK_HEIGHT = WorldLayout.TRUNK_HEIGHT
local CANOPY_RADIUS = WorldLayout.CANOPY_RADIUS
local POND_DEPTH = WorldLayout.POND_DEPTH
-- Au-dessus de la couronne du Chêne : départ des raycasts vers le sol.
local SKY_HEIGHT = TRUNK_HEIGHT + 80

local animals: { Animal } = {}
local animalsFolder: Folder? = nil
local rng = Random.new()

-- Proies tenues par un animal (langue du caméléon) : victime -> état de prise.
type Hold = { Animal: Animal, Presses: number, PressTimes: { number }, HealthAtStart: number }
local holds: { [Player]: Hold } = {}
local HOLD_ESCAPE_PRESSES = 18

-- ============================================================
-- Utilitaires
-- ============================================================

local function getFolder(): Folder
	if animalsFolder and animalsFolder.Parent then
		return animalsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Animals"
	folder.Parent = workspace
	animalsFolder = folder
	return folder
end

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function knockback(player: Player, velocity: Vector3)
	if velocity.Magnitude ~= velocity.Magnitude then
		return -- NaN (direction nulle) : ne jamais envoyer le joueur hors de la carte
	end
	Remotes.Get("AbilityCast"):FireClient(player, "Knockback", "Knockback", 0, 0, velocity)
end

-- Direction horizontale sûre (jamais NaN).
local function flatDirection(from: Vector3, to: Vector3, fallback: Vector3): Vector3
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return if delta.Magnitude > 0.01 then delta.Unit else fallback
end

local function getPlayerRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return root
end

-- Proie "visible" : vivante, éclose, ni camouflée ni à l'abri (attribut posé par SurvivalService).
local function isExposed(player: Player): boolean
	local character = player.Character
	if not character or character:GetAttribute("Camouflaged") ~= nil then
		return false
	end
	local stage = player:GetAttribute("Stage")
	if stage == "Oeuf" or stage == "Cocon" or player:GetAttribute("HasConfirmedSpawn") ~= true then
		return false
	end
	return player:GetAttribute("InShelterOrColony") ~= true and not holds[player] and player:GetAttribute("IsGrabbed") ~= true
end

local function findPrey(origin: Vector3, range: number, filter: ((Player, BasePart) -> boolean)?): (Player?, BasePart?)
	local bestPlayer: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = range
	for _, player in ipairs(Players:GetPlayers()) do
		local root = getPlayerRoot(player)
		if root and isExposed(player) then
			local distance = (root.Position - origin).Magnitude
			if distance <= bestDistance and (not filter or filter(player, root)) then
				bestPlayer = player
				bestRoot = root
				bestDistance = distance
			end
		end
	end
	return bestPlayer, bestRoot
end

local function hasLineOfSight(from: Vector3, toRoot: BasePart, ignore: { Instance }): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local result = workspace:Raycast(from, toRoot.Position - from, params)
	return result == nil or result.Instance:IsDescendantOf(toRoot.Parent :: Instance)
end

local function hitPlayer(player: Player, amount: number, push: Vector3?, message: string?)
	local character = player.Character
	if not character then
		return
	end
	DamageService.ApplyDamage(character, amount, {})
	if push then
		knockback(player, push)
	end
	if message then
		notify(player, message, "warning")
	end
end

local function speedFactor(animal: Animal): number
	return StatusEffectService.GetSpeedFactor(animal.Model)
end

-- Déplace l'animal vers `goal` ; `facing` (optionnel) impose une direction de regard.
-- Retourne vrai une fois arrivé.
local function moveToward(animal: Animal, goal: Vector3, speed: number, dt: number, facing: Vector3?, up: Vector3?): boolean
	local position = animal.Root.Position
	local delta = goal - position
	local distance = delta.Magnitude
	local step = math.min(speed * speedFactor(animal) * dt, distance)
	local newPosition = if distance > 0.01 then position + delta.Unit * step else position
	local look = facing or (if distance > 0.01 then delta.Unit else animal.Root.CFrame.LookVector)
	if math.abs(look.Y) > 0.97 and not up then
		look = Vector3.new(look.X, 0, look.Z)
		if look.Magnitude < 0.01 then
			look = animal.Root.CFrame.LookVector
		end
	end
	animal.Model:PivotTo(CFrame.lookAt(newPosition, newPosition + look.Unit, up or Vector3.yAxis))
	return distance <= math.max(step, 0.5)
end

-- Parabole entre deux points (bonds de l'écureuil, saut du poisson). t dans [0,1].
local function arcPosition(from: Vector3, to: Vector3, height: number, t: number): Vector3
	return from:Lerp(to, t) + Vector3.new(0, math.sin(math.pi * t) * height, 0)
end

local function recentDamage(animal: Animal, window: number): number
	local now = os.clock()
	local total = 0
	for i = #animal.DamageLog, 1, -1 do
		local entry = animal.DamageLog[i]
		if now - entry.At > 30 then
			table.remove(animal.DamageLog, i)
		elseif now - entry.At <= window then
			total += entry.Amount
		end
	end
	return total
end

local function groundBelow(position: Vector3, ignore: { Instance }?): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = ignore or { getFolder() }
	-- Le feuillage et les branches du Chêne ne sont pas "le sol".
	local generated = workspace:FindFirstChild("GeneratedWorld")
	local tree = generated and generated:FindFirstChild("GrandChene")
	if tree and not ignore then
		table.insert(filter, tree)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	local result = workspace:Raycast(position, Vector3.new(0, -(SKY_HEIGHT + 60), 0), params)
	return if result then result.Position else Vector3.new(position.X, GROUND_Y, position.Z)
end

local function spawnFood(position: Vector3, foodType: string, color: Color3, uses: number?, size: number?)
	local node = Instance.new("Part")
	node.Name = "FoodNode_" .. foodType
	node.Shape = Enum.PartType.Ball
	node.Size = Vector3.one * (size or 1.6)
	node.CFrame = CFrame.new(position)
	node.Anchored = true
	node.CanCollide = false
	node.Material = Enum.Material.SmoothPlastic
	node.Color = color
	node:SetAttribute("FoodType", foodType)
	node:SetAttribute("NoRespawn", true)
	node:SetAttribute("Uses", uses or 1)
	node.Parent = getFolder()
	CollectionService:AddTag(node, "FoodNode")
	task.delay(240, function()
		if node.Parent then
			node:Destroy()
		end
	end)
end

local function shelterMarker(name: string, position: Vector3, size: Vector3): Part
	local marker = Instance.new("Part")
	marker.Name = name
	marker.Size = size
	marker.CFrame = CFrame.new(position)
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.Transparency = 1
	marker.Parent = getFolder()
	CollectionService:AddTag(marker, "Shelter")
	return marker
end

-- Points d'extrémité des branches du Grand Chêne (perchoirs).
local function getBranchTips(): { Vector3 }
	local tips: { Vector3 } = {}
	local generated = workspace:FindFirstChild("GeneratedWorld")
	local tree = generated and generated:FindFirstChild("GrandChene")
	if tree then
		for _, child in ipairs(tree:GetChildren()) do
			if child:IsA("BasePart") and string.sub(child.Name, 1, 7) == "Branche" then
				local tip = (child.CFrame * CFrame.new(0, child.Size.Y / 2, -child.Size.Z / 2 + 2)).Position
				table.insert(tips, tip)
			end
		end
	end
	if #tips == 0 then
		table.insert(tips, TREE_POSITION + Vector3.new(TRUNK_RADIUS + 12, TRUNK_HEIGHT * 0.6, 0))
	end
	table.sort(tips, function(a, b)
		return a.Y > b.Y
	end)
	return tips
end

local cachedPondZone: BasePart? = nil

local function getPondInfo(): (Vector3?, Vector3?, number?)
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not cachedPondZone or not cachedPondZone.Parent then
		cachedPondZone = nil
		for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
			if zone:IsA("BasePart") and zone.Name == "PondZone_Mare" then
				cachedPondZone = zone
			end
		end
	end
	local zone = cachedPondZone
	if zone then
		return zone.Position, zone.Size, waterLevel
	end
	return nil, nil, waterLevel
end

local function isSubmergedOrSurface(root: BasePart, center: Vector3, size: Vector3, waterLevel: number): boolean
	local offset = root.Position - center
	return math.abs(offset.X) <= size.X / 2 + 2 and math.abs(offset.Z) <= size.Z / 2 + 2 and root.Position.Y < waterLevel + 2
end

-- ============================================================
-- Prises (langue du caméléon) : QTE d'évasion partagé avec GrabPromptView
-- ============================================================

local function releaseHold(player: Player, message: string?)
	local hold = holds[player]
	if not hold then
		return
	end
	holds[player] = nil
	player:SetAttribute("IsGrabbed", false)
	MovementService.RemoveModifier(player, "AnimalHold")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = false
		-- Rend la physique au client tout de suite (sinon le recul envoyé juste après est perdu).
		pcall(function()
			root:SetNetworkOwner(player)
		end)
	end
	Remotes.Get("GrabStateChanged"):FireClient(player, false, nil)
	if message then
		notify(player, message, "info")
	end
	hold.Animal.Data.HeldPlayer = nil
end

local function startHold(animal: Animal, player: Player)
	holds[player] = { Animal = animal, Presses = 0, PressTimes = {}, HealthAtStart = animal.Humanoid.Health }
	animal.Data.HeldPlayer = player
	player:SetAttribute("IsGrabbed", true)
	MovementService.AddModifier(player, "AnimalHold", "Override", 0, 6)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	Remotes.Get("GrabStateChanged"):FireClient(player, true, animal.DisplayName, HOLD_ESCAPE_PRESSES)
end

local function onEscapePress(player: Player)
	local hold = holds[player]
	if not hold then
		return
	end
	local now = os.clock()
	while #hold.PressTimes > 0 and now - hold.PressTimes[1] > 1 do
		table.remove(hold.PressTimes, 1)
	end
	-- Écart minimal : une rafale d'événements dans la même frame ne compte qu'une fois.
	if #hold.PressTimes >= 14 or (#hold.PressTimes > 0 and now - hold.PressTimes[#hold.PressTimes] < 1 / 14) then
		return
	end
	table.insert(hold.PressTimes, now)
	hold.Presses += 1
	if hold.Presses >= HOLD_ESCAPE_PRESSES then
		releaseHold(player, "Vous vous arrachez à la langue !")
	end
end

-- ============================================================
-- Mort, carcasse, réapparition
-- ============================================================

local function buildCarcassTemplate(model: Model): Model
	local template = Instance.new("Model")
	template.Name = "Carcasse"
	local first: BasePart? = nil
	for _, descendant in ipairs(model:GetChildren()) do
		if descendant:IsA("BasePart") and descendant.Name ~= "Root" then
			local copy = descendant:Clone()
			for _, child in ipairs(copy:GetChildren()) do
				if child:IsA("WeldConstraint") then
					child:Destroy()
				end
			end
			copy.Anchored = true
			copy.CanQuery = true
			copy.Color = copy.Color:Lerp(Color3.fromRGB(80, 60, 45), 0.3)
			copy.Parent = template
			first = first or copy
		end
	end
	if first then
		template.PrimaryPart = first
	end
	return template
end

local terrainOnlyParams = RaycastParams.new()
terrainOnlyParams.FilterType = Enum.RaycastFilterType.Include
terrainOnlyParams.FilterDescendantsInstances = { workspace.Terrain }
terrainOnlyParams.IgnoreWater = true

-- Couche la carcasse sur le flanc (axe horizontal de l'animal) et pose le bas de sa boîte
-- englobante exactement sur le sol.
local function layCarcass(template: Model, animalRoot: BasePart, ground: Vector3)
	local look = animalRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local yaw = if flatLook.Magnitude > 0.1 then CFrame.lookAt(Vector3.zero, flatLook.Unit) else CFrame.identity
	local layCF = CFrame.new(ground) * yaw * CFrame.Angles(0, 0, math.rad(80))
	local inverseRoot = animalRoot.CFrame:Inverse()
	for _, part in ipairs(template:GetChildren()) do
		if part:IsA("BasePart") then
			part.CFrame = layCF * inverseRoot * part.CFrame
			part.CanCollide = true -- le squelette doit pouvoir servir d'abri solide
		end
	end
	template.WorldPivot = CFrame.new(ground)
	local boxCFrame, boxSize = template:GetBoundingBox()
	local lift = ground.Y - (boxCFrame.Position.Y - boxSize.Y / 2)
	for _, part in ipairs(template:GetChildren()) do
		if part:IsA("BasePart") then
			part.CFrame += Vector3.new(0, lift, 0)
		end
	end
end

local function onAnimalDied(animal: Animal)
	if animal.Mode == "Dead" then
		return
	end
	animal.Mode = "Dead"
	local held = animal.Data.HeldPlayer :: Player?
	if held then
		releaseHold(held, nil)
	end
	if animal.Data.Tongue then
		(animal.Data.Tongue :: Instance):Destroy()
	end
	local position = animal.Root.Position
	local killer = animal.Model:GetAttribute("LastAttackerUserId") :: number?
	ProgressionService.RecordKill(killer, animal.DisplayName, animal.Giant)
	if animal.Giant then
		-- Seul le Terrain compte comme "sol" : une carcasse ne reste pas coincée dans l'arbre.
		local hit = workspace:Raycast(position + Vector3.new(0, 5, 0), Vector3.new(0, -400, 0), terrainOnlyParams)
		local feastPosition = if hit then hit.Position else Vector3.new(position.X, GROUND_Y, position.Z)
		local template = buildCarcassTemplate(animal.Model)
		layCarcass(template, animal.Root, feastPosition)
		CarcassService.SpawnCarcassFor(feastPosition, animal.DisplayName, true, animal.CarcassScale, template)
	else
		CarcassService.SpawnCarcassFor(position, animal.DisplayName, false, animal.CarcassScale, nil)
	end
	animal.Model:Destroy()
	local index = table.find(animals, animal)
	if index then
		table.remove(animals, index)
	end
	task.delay(animal.RespawnSeconds, animal.Respawn)
end

local function register(
	id: string,
	model: Model,
	spawnCFrame: CFrame,
	giant: boolean,
	carcassScale: number,
	respawnSeconds: number,
	hitRadius: number,
	update: (Animal, number) -> (),
	respawn: () -> ()
): Animal
	model:PivotTo(spawnCFrame)
	model:SetAttribute("AnimalId", id)
	model:SetAttribute("HitRadius", hitRadius)
	model.Parent = getFolder()
	CollectionService:AddTag(model, "Animal")

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local info = AnimalData[id]
	local animal: Animal = {
		Id = id,
		DisplayName = if info then info.Name else humanoid.DisplayName,
		Model = model,
		Root = model.PrimaryPart :: BasePart,
		Humanoid = humanoid,
		Mode = "Idle",
		Timer = 2,
		Cooldown = 3,
		Goal = nil,
		Prey = nil,
		Giant = giant,
		CarcassScale = carcassScale,
		RespawnSeconds = respawnSeconds,
		Respawn = respawn,
		DamageLog = {},
		LastDamagedAt = 0,
		Data = {},
		Update = update,
	}
	if not giant then
		animal.DisplayName = humanoid.DisplayName
	end
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		local now = os.clock()
		if health < lastHealth then
			table.insert(animal.DamageLog, { At = now, Amount = lastHealth - health })
			animal.LastDamagedAt = now
		end
		while #animal.DamageLog > 0 and now - animal.DamageLog[1].At > 30 do
			table.remove(animal.DamageLog, 1)
		end
		lastHealth = health
		-- Humanoid sans HumanoidRootPart : on ne compte pas uniquement sur Died.
		if health <= 0 then
			onAnimalDied(animal)
		end
	end)
	humanoid.Died:Connect(function()
		onAnimalDied(animal)
	end)
	table.insert(animals, animal)
	return animal
end

-- ============================================================
-- 1. OISEAU
-- ============================================================

local birdNestCenter: Vector3? = nil
local BIRD_LEG_OFFSET = 11

local function birdUpdate(bird: Animal, dt: number)
	bird.Cooldown -= dt
	bird.Timer -= dt
	local perches = bird.Data.Perches :: { Vector3 }
	local home = bird.Data.Home :: Vector3

	-- Un essaim qui le pique le fait fuir (GDD : frelons/abeilles lui piquent les yeux).
	if bird.Mode ~= "Flee" and recentDamage(bird, 10) >= 150 then
		bird.Mode = "Flee"
		bird.Timer = 30
		bird.Goal = home + Vector3.new(rng:NextNumber(-400, 400), 120, rng:NextNumber(-400, 400))
		for _, player in ipairs(Players:GetPlayers()) do
			notify(player, "L'oiseau s'enfuit, chassé par l'essaim !", "info")
		end
	end

	if bird.Mode == "Idle" or bird.Mode == "Perch" then
		bird.Mode = "Perch"
		-- Petite oscillation de tête : il "guette".
		local root = bird.Root
		if not bird.Data.PerchRotation then
			local flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			bird.Data.PerchRotation = CFrame.lookAt(Vector3.zero, if flatLook.Magnitude > 0.1 then flatLook.Unit else Vector3.zAxis)
		end
		bird.Model:PivotTo(CFrame.new(root.Position) * (bird.Data.PerchRotation :: CFrame) * CFrame.Angles(0, math.sin(os.clock() * 1.3) * 0.5, 0))
		if bird.Cooldown <= 0 then
			-- Perché à ~200 studs de haut : 400 de portée = ~340 studs au sol autour du Chêne.
			local prey = findPrey(root.Position, 400, function(_player, playerRoot)
				-- Il ne voit que ce qui BOUGE à découvert (pas sous l'eau, pas sous terre).
				local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
				if waterLevel and playerRoot.Position.Y < waterLevel then
					return false
				end
				return playerRoot.AssemblyLinearVelocity.Magnitude > 2 and hasLineOfSight(root.Position, playerRoot, { getFolder() })
			end)
			if prey then
				bird.Mode = "Dive"
				bird.Prey = prey
				bird.Timer = 6
				return
			end
		end
		if bird.Timer <= 0 then
			if rng:NextNumber() < 0.25 then
				-- Va chercher des brindilles au sol (fenêtre de vulnérabilité pour un essaim).
				local angle = rng:NextNumber() * math.pi * 2
				local distance = rng:NextNumber(CANOPY_RADIUS, CANOPY_RADIUS + 220)
				local spot = groundBelow(TREE_POSITION + Vector3.new(math.cos(angle) * distance, SKY_HEIGHT, math.sin(angle) * distance))
				bird.Mode = "Gather"
				bird.Goal = spot + Vector3.new(0, BIRD_LEG_OFFSET, 0)
				bird.Timer = 20
			else
				bird.Mode = "Fly"
				bird.Goal = if rng:NextNumber() < 0.4 then home else perches[rng:NextInteger(1, #perches)] + Vector3.new(0, BIRD_LEG_OFFSET, 0)
			end
		end
	elseif bird.Mode == "Fly" or bird.Mode == "Return" then
		bird.Data.PerchRotation = nil
		if moveToward(bird, bird.Goal or home, 45, dt) then
			bird.Mode = "Perch"
			bird.Timer = rng:NextNumber(6, 14)
		end
	elseif bird.Mode == "Gather" then
		if moveToward(bird, bird.Goal or home, 45, dt) then
			bird.Mode = "Pecking"
			bird.Timer = 3
		end
	elseif bird.Mode == "Pecking" then
		if bird.Timer <= 0 then
			bird.Mode = "Return"
			bird.Goal = home
		end
	elseif bird.Mode == "Dive" then
		local prey = bird.Prey
		local preyRoot = prey and getPlayerRoot(prey)
		if not prey or not preyRoot or not isExposed(prey) or bird.Timer <= 0 then
			bird.Mode = "Return"
			bird.Goal = home
			bird.Cooldown = 4
			return
		end
		moveToward(bird, preyRoot.Position + Vector3.new(0, 4, 0), 85, dt)
		if (bird.Root.Position - preyRoot.Position).Magnitude <= 9 then
			local push = flatDirection(bird.Root.Position, preyRoot.Position, bird.Root.CFrame.LookVector)
			hitPlayer(prey, (AnimalData.Oiseau.AttackDamage) * 0.5, push * 60 + Vector3.new(0, 50, 0), "L'oiseau fond sur vous !")
			bird.Mode = "Return"
			bird.Goal = home
			bird.Cooldown = 9
		end
	elseif bird.Mode == "Flee" then
		moveToward(bird, bird.Goal or home, 60, dt)
		if bird.Timer <= 0 then
			bird.Mode = "Return"
			bird.Goal = home
			bird.Cooldown = 10
		end
	end
end

local function spawnBird()
	local info = AnimalData.Oiseau
	local tips = getBranchTips()
	local home = (birdNestCenter or tips[1]) + Vector3.new(0, BIRD_LEG_OFFSET + 2, 0)
	local model = AnimalModels.BuildBird(info.MaxHealth)
	local bird = register("Oiseau", model, CFrame.new(home), true, 6, 480, 9, birdUpdate, spawnBird)
	bird.Data.Home = home
	bird.Data.Perches = tips
end

-- ============================================================
-- 2. CAMÉLÉON
-- ============================================================

local CHAMELEON_PALETTE = {
	Color3.fromRGB(90, 170, 70),
	Color3.fromRGB(70, 130, 60),
	Color3.fromRGB(110, 85, 55),
	Color3.fromRGB(150, 160, 70),
	Color3.fromRGB(80, 110, 90),
}
local CHAMELEON_SKIP_COLOR = { Eye = true, EyeShine = true, Pupil = true, Root = true, Jaw = true, LangueCameleon = true }
local CHAMELEON_TRUNK_OFFSET = TRUNK_RADIUS + 7
-- Terrier de ponte : une seule position par serveur (pas un nouveau trou à chaque descente).
-- Jamais dans l'axe +X : la chambre d'écorce du Chêne s'y trouve.
local chameleonBurrowAngle = rng:NextNumber(0.7, math.pi * 2 - 0.7)
local chameleonBurrowMarker: BasePart? = nil

local function trunkPoint(angle: number, height: number): (Vector3, Vector3)
	local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	-- +7 : le ventre et les pattes (8 studs sous la Root) restent posés sur l'écorce, pas dedans.
	return TREE_POSITION + outward * (TRUNK_RADIUS + 7) + Vector3.new(0, height, 0), outward
end

local function chameleonRecolor(chameleon: Animal)
	local target = CHAMELEON_PALETTE[rng:NextInteger(1, #CHAMELEON_PALETTE)]
	for _, part in ipairs(chameleon.Model:GetChildren()) do
		if part:IsA("BasePart") and not CHAMELEON_SKIP_COLOR[part.Name] then
			part.Color = part.Color:Lerp(target, 0.6)
		end
	end
end

local function chameleonMouth(chameleon: Animal): Vector3
	return (chameleon.Root.CFrame * CFrame.new(0, 0, -16)).Position
end

local function destroyTongue(chameleon: Animal)
	local tongue = chameleon.Data.Tongue :: BasePart?
	if tongue then
		tongue:Destroy()
		chameleon.Data.Tongue = nil
	end
end

local function updateTongue(chameleon: Animal, tipPosition: Vector3)
	local tongue = chameleon.Data.Tongue :: BasePart?
	local mouth = chameleonMouth(chameleon)
	local length = (tipPosition - mouth).Magnitude
	if length < 0.2 then
		return
	end
	if not tongue then
		local part = Instance.new("Part")
		part.Name = "LangueCameleon"
		part.Shape = Enum.PartType.Cylinder
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(230, 110, 140)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = chameleon.Model
		tongue = part
		chameleon.Data.Tongue = part
	end
	local t = tongue :: BasePart
	t.Size = Vector3.new(length, 1.2, 1.2)
	t.CFrame = CFrame.lookAt(mouth:Lerp(tipPosition, 0.5), tipPosition) * CFrame.Angles(0, math.rad(90), 0)
end

-- Avance le long de la surface du tronc (angle + hauteur), ventre contre l'écorce, tête dans le
-- sens de la marche. Retourne vrai une fois arrivé.
local function climbStep(chameleon: Animal, goalAngle: number, goalHeight: number, speed: number, dt: number): boolean
	local angle = chameleon.Data.Angle :: number
	local height = chameleon.Data.Height :: number
	local deltaAngle = goalAngle - angle
	local deltaHeight = goalHeight - height
	local arc = deltaAngle * CHAMELEON_TRUNK_OFFSET
	local distance = math.sqrt(arc * arc + deltaHeight * deltaHeight)
	local step = speed * speedFactor(chameleon) * dt
	local arrived = distance <= math.max(step, 0.05)
	local fraction = if arrived then 1 else step / distance
	local newAngle = angle + deltaAngle * fraction
	local newHeight = height + deltaHeight * fraction
	chameleon.Data.Angle = newAngle
	chameleon.Data.Height = newHeight
	local position, outward = trunkPoint(newAngle, newHeight)
	local tangent = Vector3.new(-math.sin(newAngle), 0, math.cos(newAngle)) * (if deltaAngle >= 0 then 1 else -1)
	local travel = tangent * math.abs(arc) + Vector3.new(0, deltaHeight, 0)
	local facing = if travel.Magnitude > 0.05 then travel.Unit else Vector3.yAxis
	chameleon.Model:PivotTo(CFrame.lookAt(position, position + facing, outward))
	return arrived
end

local function chameleonUpdate(chameleon: Animal, dt: number)
	chameleon.Cooldown -= dt
	chameleon.Timer -= dt
	chameleon.Data.ColorTimer = (chameleon.Data.ColorTimer or 4) - dt
	if chameleon.Data.ColorTimer <= 0 then
		chameleon.Data.ColorTimer = 4
		chameleonRecolor(chameleon)
	end

	local mode = chameleon.Mode
	if mode == "Idle" or mode == "Watch" or mode == "Climb" then
		-- Langue-grappin : proie exposée à portée moyenne, en ligne de vue.
		if chameleon.Cooldown <= 0 then
			local mouth = chameleonMouth(chameleon)
			local prey, preyRoot = findPrey(mouth, 40, function(_player, playerRoot)
				return hasLineOfSight(mouth, playerRoot, { chameleon.Model })
			end)
			if prey and preyRoot then
				chameleon.Mode = "Tongue"
				chameleon.Prey = prey
				chameleon.Timer = 0.7
				chameleon.Data.TongueStart = preyRoot.Position
				startHold(chameleon, prey)
				notify(prey, "La langue du caméléon vous attrape ! (ESPACE, ou un allié mord le caméléon)", "warning")
				return
			end
		end
	end

	if mode == "Idle" then
		chameleon.Mode = "Climb"
		chameleon.Data.GoalAngle = nil
	elseif mode == "Climb" then
		if not chameleon.Data.GoalAngle then
			-- Petits déplacements autour du tronc (jamais à travers).
			chameleon.Data.GoalAngle = (chameleon.Data.Angle :: number) + rng:NextNumber(-1.2, 1.2)
			chameleon.Data.GoalHeight = rng:NextNumber(20, TRUNK_HEIGHT * 0.8)
		end
		if climbStep(chameleon, chameleon.Data.GoalAngle :: number, chameleon.Data.GoalHeight :: number, 4, dt) then
			chameleon.Data.GoalAngle = nil
			chameleon.Mode = "Watch"
			chameleon.Timer = rng:NextNumber(5, 10)
		end
	elseif mode == "Watch" then
		if chameleon.Timer <= 0 then
			chameleon.Data.BurrowTimer = (chameleon.Data.BurrowTimer or rng:NextNumber(120, 200)) - 10
			if chameleon.Data.BurrowTimer <= 0 then
				chameleon.Data.BurrowTimer = rng:NextNumber(150, 240)
				chameleon.Mode = "Descend"
			else
				chameleon.Mode = "Climb"
			end
		end
	elseif mode == "Descend" then
		-- Descend le long du tronc jusqu'au terrier de ponte (GDD §6.2).
		if climbStep(chameleon, chameleonBurrowAngle, 6, 6, dt) then
			local outward = Vector3.new(math.cos(chameleonBurrowAngle), 0, math.sin(chameleonBurrowAngle))
			local holeCenter = Vector3.new(TREE_POSITION.X, GROUND_Y - 2, TREE_POSITION.Z) + outward * (CHAMELEON_TRUNK_OFFSET + 10)
			if not chameleonBurrowMarker or not chameleonBurrowMarker.Parent then
				DigService.CarveHole(holeCenter, 6)
				DigService.CarveHole(holeCenter + Vector3.new(0, -4, 0) + outward * 3, 5)
				chameleonBurrowMarker = shelterMarker("TerrierCameleon", holeCenter, Vector3.new(8, 6, 8))
			end
			chameleon.Mode = "Digging"
			chameleon.Timer = 8
		end
	elseif mode == "Digging" then
		if chameleon.Timer <= 0 then
			chameleon.Mode = "Climb"
		end
	elseif mode == "Tongue" then
		local prey = chameleon.Prey
		local preyRoot = prey and getPlayerRoot(prey)
		if not prey or not preyRoot or not holds[prey] then
			if prey and holds[prey] then
				releaseHold(prey, nil)
			end
			destroyTongue(chameleon)
			chameleon.Mode = "Climb"
			chameleon.Cooldown = 10
			return
		end
		-- La langue ramène la proie jusqu'à la bouche.
		local t = 1 - math.clamp(chameleon.Timer / 0.7, 0, 1)
		local start = chameleon.Data.TongueStart :: Vector3
		local position = start:Lerp(chameleonMouth(chameleon), t)
		preyRoot.CFrame = CFrame.new(position)
		updateTongue(chameleon, position)
		if chameleon.Timer <= 0 then
			chameleon.Mode = "Swallow"
			chameleon.Timer = 3
		end
	elseif mode == "Swallow" then
		local prey = chameleon.Prey
		local preyRoot = prey and getPlayerRoot(prey)
		local hold = prey and holds[prey]
		if not prey or not preyRoot or not hold then
			if prey and holds[prey] then
				releaseHold(prey, nil)
			end
			destroyTongue(chameleon)
			chameleon.Mode = "Climb"
			chameleon.Cooldown = 12
			return
		end
		preyRoot.CFrame = CFrame.new(chameleonMouth(chameleon))
		updateTongue(chameleon, chameleonMouth(chameleon))
		hitPlayer(prey, AnimalData.Cameleon.AttackDamage / 3 * dt, nil, nil)
		-- Un allié qui mord le caméléon (>= 40 dégâts depuis la prise) libère la proie.
		if hold.HealthAtStart - chameleon.Humanoid.Health >= 40 then
			releaseHold(prey, "Un allié vous a libéré de la langue !")
			knockback(prey, chameleon.Root.CFrame.LookVector * 40 + Vector3.new(0, 30, 0))
		elseif chameleon.Timer <= 0 then
			releaseHold(prey, "Le caméléon vous recrache !")
			knockback(prey, chameleon.Root.CFrame.LookVector * 50 + Vector3.new(0, 20, 0))
		end
		if not holds[prey] then
			destroyTongue(chameleon)
			chameleon.Mode = "Climb"
			chameleon.Cooldown = 12
		end
	end
end

local function spawnChameleon()
	local info = AnimalData.Cameleon
	local startAngle = rng:NextNumber() * math.pi * 2
	local position, outward = trunkPoint(startAngle, 40)
	local model = AnimalModels.BuildChameleon(info.MaxHealth)
	local chameleon = register(
		"Cameleon",
		model,
		CFrame.lookAt(position, position + Vector3.yAxis, outward),
		true,
		5,
		420,
		8,
		chameleonUpdate,
		spawnChameleon
	)
	chameleon.Data.Outward = outward
	chameleon.Data.Angle = startAngle
	chameleon.Data.Height = 40
	chameleon.Cooldown = 8
end

-- ============================================================
-- 3. POISSON ROUGE + ALEVINS
-- ============================================================

local GOLDFISH_SCALE = 0.7
local GOLDFISH_CRUISE_DEPTH = POND_DEPTH * 0.4 -- assez haut pour que le saut (arc de 16) crève la surface
local FRY_COUNT = 16 -- la mare est ~3x plus grande qu'à l'origine (6 alevins)
local FRY_SCALE = 0.18

local function randomPointInPond(center: Vector3, size: Vector3, y: number, inset: number): Vector3
	return Vector3.new(
		center.X + rng:NextNumber(-size.X / 2 + inset, size.X / 2 - inset),
		y,
		center.Z + rng:NextNumber(-size.Z / 2 + inset, size.Z / 2 - inset)
	)
end

local function goldfishUpdate(fish: Animal, dt: number)
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	fish.Cooldown -= dt
	fish.Timer -= dt
	local cruiseY = waterLevel - GOLDFISH_CRUISE_DEPTH
	local frozen = workspace:GetAttribute("PondFrozenNow") == true
	local mouth = (fish.Root.CFrame * CFrame.new(0, 0, -8.5)).Position

	if fish.Mode == "Idle" or fish.Mode == "Swim" then
		fish.Mode = "Swim"
		if not fish.Goal or ((fish.Goal :: Vector3) - fish.Root.Position).Magnitude < 2 then
			fish.Goal = randomPointInPond(center, size, cruiseY, 9)
		end
		moveToward(fish, fish.Goal :: Vector3, if frozen then 4 else 9, dt)
		-- Aspiration : attire les insectes proches vers sa bouche (GDD §6.3).
		if fish.Cooldown <= 0 then
			local prey, preyRoot = findPrey(mouth, 16, function(_player, playerRoot)
				return isSubmergedOrSurface(playerRoot, center, size, waterLevel)
			end)
			if prey and preyRoot then
				local pull = mouth - preyRoot.Position
				knockback(prey, if pull.Magnitude > 0.01 then pull.Unit * 40 else Vector3.zero)
				notify(prey, "Le poisson rouge vous aspire !", "warning")
				fish.Cooldown = 5
				task.delay(0.5, function()
					local root = getPlayerRoot(prey)
					if root and fish.Mode ~= "Dead" and (root.Position - mouth).Magnitude <= 10 then
						hitPlayer(prey, AnimalData.PoissonRouge.AttackDamage * 0.4, nil, nil)
					end
				end)
			end
		end
		fish.Data.JumpTimer = (fish.Data.JumpTimer or rng:NextNumber(30, 60)) - dt
		if fish.Data.JumpTimer <= 0 and not frozen then
			fish.Data.JumpTimer = rng:NextNumber(35, 70)
			fish.Mode = "Jump"
			fish.Timer = 1.5
			fish.Data.JumpFrom = fish.Root.Position
			local forward = fish.Root.CFrame.LookVector
			local target = fish.Root.Position + Vector3.new(forward.X, 0, forward.Z).Unit * 14
			fish.Data.JumpTo = Vector3.new(
				math.clamp(target.X, center.X - size.X / 2 + 9, center.X + size.X / 2 - 9),
				cruiseY,
				math.clamp(target.Z, center.Z - size.Z / 2 + 9, center.Z + size.Z / 2 - 9)
			)
		end
	elseif fish.Mode == "Jump" then
		local t = 1 - math.clamp(fish.Timer / 1.5, 0, 1)
		local from = fish.Data.JumpFrom :: Vector3
		local to = fish.Data.JumpTo :: Vector3
		local position = arcPosition(from, to, 16, t)
		local nextPosition = arcPosition(from, to, 16, math.min(1, t + 0.05))
		local look = nextPosition - position
		fish.Model:PivotTo(CFrame.lookAt(position, position + (if look.Magnitude > 0.01 then look.Unit else fish.Root.CFrame.LookVector)))
		if fish.Timer <= 0 then
			fish.Mode = "Swim"
			-- Retombée : grosse vague qui assomme les insectes en surface.
			for _, player in ipairs(Players:GetPlayers()) do
				local root = getPlayerRoot(player)
				if root and (root.Position - to).Magnitude <= 12 and root.Position.Y > waterLevel - 3 then
					hitPlayer(player, AnimalData.PoissonRouge.AttackDamage * 0.5, flatDirection(to, root.Position, Vector3.xAxis) * 40 + Vector3.new(0, 30, 0), "Le poisson rouge retombe sur vous !")
				end
			end
		end
	end
end

local function fryUpdate(fry: Animal, dt: number)
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	if fry.Model:GetAttribute("GrabbedBy") ~= nil then
		return -- tenu dans les pattes d'un prédateur
	end
	local y = waterLevel - rng:NextNumber(2.5, 5)
	-- Fuit les insectes qui s'approchent, sinon nage en banc autour d'un point commun.
	local threat: Vector3? = nil
	for _, player in ipairs(Players:GetPlayers()) do
		local root = getPlayerRoot(player)
		if root and (root.Position - fry.Root.Position).Magnitude < 9 then
			threat = root.Position
			break
		end
	end
	if threat then
		local away = fry.Root.Position - threat
		local goal = fry.Root.Position + Vector3.new(away.X, 0, away.Z).Unit * 6
		goal = Vector3.new(
			math.clamp(goal.X, center.X - size.X / 2 + 2, center.X + size.X / 2 - 2),
			fry.Root.Position.Y,
			math.clamp(goal.Z, center.Z - size.Z / 2 + 2, center.Z + size.Z / 2 - 2)
		)
		moveToward(fry, goal, 13, dt)
		return
	end
	fry.Timer -= dt
	if not fry.Goal or fry.Timer <= 0 then
		local school = AnimalService.SchoolCenter or center
		fry.Goal = Vector3.new(
			math.clamp(school.X + rng:NextNumber(-6, 6), center.X - size.X / 2 + 2, center.X + size.X / 2 - 2),
			y,
			math.clamp(school.Z + rng:NextNumber(-6, 6), center.Z - size.Z / 2 + 2, center.Z + size.Z / 2 - 2)
		)
		fry.Timer = rng:NextNumber(1.5, 3.5)
	end
	moveToward(fry, fry.Goal :: Vector3, 6, dt)
end

local function spawnGoldfish()
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	local info = AnimalData.PoissonRouge
	local model = AnimalModels.BuildGoldfish(info.MaxHealth, GOLDFISH_SCALE, "Poisson Rouge")
	register("PoissonRouge", model, CFrame.new(randomPointInPond(center, size, waterLevel - GOLDFISH_CRUISE_DEPTH, 10)), true, 4, 360, 7, goldfishUpdate, spawnGoldfish)
end

local function spawnFry()
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	local model = AnimalModels.BuildGoldfish(40, FRY_SCALE, "Alevin")
	model:SetAttribute("Grabbable", true)
	register("Alevin", model, CFrame.new(randomPointInPond(center, size, waterLevel - 3, 4)), false, 0.6, 60, 1.5, fryUpdate, spawnFry)
end

-- Cuvettes de frai creusées dans la vase, garnies d'oeufs que les insectes peuvent voler.
local function createSpawningPits()
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	local bottom = waterLevel - POND_DEPTH
	for _, offset in ipairs({ Vector3.new(-40, 0, -24), Vector3.new(36, 0, 26) }) do
		local pit = Vector3.new(center.X + offset.X, bottom, center.Z + offset.Z)
		workspace.Terrain:FillBall(pit, 4, Enum.Material.Water)
		for i = 1, 3 do
			local angle = i / 3 * math.pi * 2
			local node = Instance.new("Part")
			node.Name = "FoodNode_OeufsPoisson"
			node.Shape = Enum.PartType.Ball
			node.Size = Vector3.one * 1.3
			node.CFrame = CFrame.new(pit + Vector3.new(math.cos(angle) * 1.2, -1.5, math.sin(angle) * 1.2))
			node.Anchored = true
			node.CanCollide = false
			node.Material = Enum.Material.Glass
			node.Color = Color3.fromRGB(255, 170, 90)
			node.Transparency = 0.15
			node:SetAttribute("FoodType", "OeufsPoisson")
			node:SetAttribute("Uses", 2)
			node.Parent = getFolder()
			CollectionService:AddTag(node, "FoodNode")
		end
	end
end

-- ============================================================
-- 4. CRABE
-- ============================================================

local function crabUpdate(crab: Animal, dt: number)
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	crab.Cooldown -= dt
	crab.Timer -= dt
	local root = crab.Root

	-- Fait face à l'intrus le plus proche : sa carapace frontale est impénétrable (GDD §6.4).
	local threat, threatRoot = findPrey(root.Position, 26, nil)
	if threat and threatRoot then
		local toThreat = threatRoot.Position - root.Position
		local flat = Vector3.new(toThreat.X, 0, toThreat.Z)
		if flat.Magnitude > 0.1 then
			local current = root.CFrame.LookVector
			local turned = current:Lerp(flat.Unit, math.clamp(dt * 2.2, 0, 1))
			crab.Model:PivotTo(CFrame.lookAt(root.Position, root.Position + Vector3.new(turned.X, 0, turned.Z).Unit))
		end
		local inFront = flat.Magnitude > 0.1 and root.CFrame.LookVector:Dot(flat.Unit) > 0.55
		if crab.Cooldown <= 0 and inFront and flat.Magnitude <= 14 and hasLineOfSight(root.Position, threatRoot, { getFolder() }) then
			crab.Cooldown = 2.5
			hitPlayer(threat, AnimalData.Crabe.AttackDamage, flat.Unit * 70 + Vector3.new(0, 35, 0), "Les pinces du crabe vous broient !")
		end
		return
	end

	-- Patrouille latérale entre fond de la mare, berges et terrier.
	local points = crab.Data.Patrol :: { Vector3 }
	if os.clock() < ((crab.Data.PauseUntil :: number?) or 0) then
		return -- petite pause entre deux points de patrouille
	end
	if not crab.Goal or crab.Timer <= 0 then
		crab.Goal = points[rng:NextInteger(1, #points)]
		crab.Timer = 25
	end
	local goal = crab.Goal :: Vector3
	local travel = goal - root.Position
	local flatTravel = Vector3.new(travel.X, 0, travel.Z)
	local sideways = if flatTravel.Magnitude > 0.1 then Vector3.yAxis:Cross(flatTravel.Unit) else root.CFrame.LookVector
	if moveToward(crab, goal, 7, dt, sideways) then
		crab.Goal = nil
		crab.Data.PauseUntil = os.clock() + rng:NextNumber(3, 8)
	end
end

local crabDen: Vector3? = nil

local function createCrabBurrow()
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	-- Galerie boueuse creusée dans la berge est (entre l'eau et la terre ferme).
	-- Tunnel (rayon 4) et chambre (rayon 6) centrés assez bas pour garder un plafond de terre.
	local y = waterLevel + 2.5
	local entranceX = center.X + size.X / 2 + 8
	for i = 0, 5 do
		workspace.Terrain:FillBall(Vector3.new(entranceX + i * 4, y, center.Z), 4, Enum.Material.Air)
	end
	local den = Vector3.new(entranceX + 26, waterLevel, center.Z)
	workspace.Terrain:FillBall(den, 6, Enum.Material.Air)
	workspace.Terrain:FillBlock(CFrame.new(den - Vector3.new(0, 6, 0)), Vector3.new(12, 4, 12), Enum.Material.Mud)
	shelterMarker("TerrierCrabe", den, Vector3.new(10, 6, 10))
	crabDen = den
	-- Restes de repas du crabe (posés sur le sol boueux, à y = den - 4) : à piller au risque
	-- de le croiser dans le noir.
	spawnFood(den + Vector3.new(-2, -3, 1.5), "Poisson", Color3.fromRGB(200, 110, 60), 3, 2)
	spawnFood(den + Vector3.new(2, -3.2, -1.5), "Miette", Color3.fromRGB(210, 180, 140), 3, 1.6)
end

local function spawnCrab()
	local center, size, waterLevel = getPondInfo()
	if not center or not size or not waterLevel then
		return
	end
	local legOffset = 5
	local bottom = waterLevel - POND_DEPTH + legOffset
	local bank = waterLevel + legOffset
	local patrol: { Vector3 } = {
		Vector3.new(center.X - 36, bottom, center.Z - 24),
		Vector3.new(center.X + 36, bottom, center.Z + 18),
		Vector3.new(center.X, bottom, center.Z),
		Vector3.new(center.X + size.X / 2 + 3, bank, center.Z - 30),
		Vector3.new(center.X - size.X / 2 - 3, bank, center.Z + 30),
		Vector3.new(center.X - 40, bank, center.Z + size.Z / 2 + 3),
	}
	if crabDen then
		table.insert(patrol, (crabDen :: Vector3) - Vector3.new(0, 4 - legOffset, 0))
	end
	local info = AnimalData.Crabe
	local model = AnimalModels.BuildCrab(info.MaxHealth)
	model:SetAttribute("FrontInvulnerable", true)
	local crab = register("Crabe", model, CFrame.new(patrol[3]), true, 5, 420, 11, crabUpdate, spawnCrab)
	crab.Data.Patrol = patrol
end

-- ============================================================
-- 5. ÉCUREUIL
-- ============================================================

local dreyCenter: Vector3? = nil
local SQUIRREL_LEG_OFFSET = 9

local function shakeTreeClimbers(landing: Vector3)
	local remote = Remotes.Get("CameraShake")
	for _, player in ipairs(Players:GetPlayers()) do
		local root = getPlayerRoot(player)
		if root then
			local flat = Vector3.new(root.Position.X - TREE_POSITION.X, 0, root.Position.Z - TREE_POSITION.Z)
			local onTree = flat.Magnitude < CANOPY_RADIUS + 10 and root.Position.Y > GROUND_Y + 5
			if onTree then
				remote:FireClient(player, 1.4, 0.9)
				-- Les insectes accrochés près de l'impact sont secoués et tombent.
				if (root.Position - landing).Magnitude < 24 then
					knockback(player, (if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis) * 35 + Vector3.new(0, 15, 0))
					notify(player, "L'écureuil fait trembler la branche !", "warning")
				end
			elseif (root.Position - landing).Magnitude < 40 then
				remote:FireClient(player, 0.6, 0.5)
			end
		end
	end
end

local function startHop(squirrel: Animal, to: Vector3, duration: number, height: number)
	squirrel.Mode = "Hop"
	squirrel.Data.HopFrom = squirrel.Root.Position
	squirrel.Data.HopTo = to
	squirrel.Data.HopDuration = duration
	squirrel.Data.HopHeight = height
	squirrel.Timer = duration
end

local function squirrelUpdate(squirrel: Animal, dt: number)
	squirrel.Timer -= dt
	-- Régénération : on ne tue pas un écureuil, on le fait juste fuir un moment.
	if os.clock() - squirrel.LastDamagedAt > 8 and squirrel.Humanoid.Health < squirrel.Humanoid.MaxHealth then
		squirrel.Humanoid.Health = math.min(squirrel.Humanoid.MaxHealth, squirrel.Humanoid.Health + 25 * dt)
	end
	local tips = squirrel.Data.Tips :: { Vector3 }
	local mode = squirrel.Mode

	if mode == "Idle" or mode == "Perch" then
		squirrel.Mode = "Perch"
		if squirrel.Timer <= 0 then
			local onGround = squirrel.Root.Position.Y < GROUND_Y + 20
			local roll = rng:NextNumber()
			if onGround then
				-- Remonte dans l'arbre.
				startHop(squirrel, tips[rng:NextInteger(1, #tips)] + Vector3.new(0, SQUIRREL_LEG_OFFSET, 0), 2.6, 30)
			elseif roll < 0.25 then
				-- Descend fouiller le sol et cacher des provisions.
				local angle = rng:NextNumber() * math.pi * 2
				local distance = rng:NextNumber(CANOPY_RADIUS * 0.8, CANOPY_RADIUS + 60)
				local spot = groundBelow(TREE_POSITION + Vector3.new(math.cos(angle) * distance, SKY_HEIGHT, math.sin(angle) * distance))
				squirrel.Data.Cache = spot
				startHop(squirrel, spot + Vector3.new(0, SQUIRREL_LEG_OFFSET, 0), 2.8, 20)
			elseif roll < 0.45 then
				-- Casse une noix : pluie de miettes nutritives sous la branche (GDD §6.5).
				local below = groundBelow(squirrel.Root.Position - Vector3.new(0, SQUIRREL_LEG_OFFSET + 2, 0), { getFolder(), squirrel.Model })
				local season = workspace:GetAttribute("CurrentSeason")
				for i = 1, 4 do
					local scatter = Vector3.new(rng:NextNumber(-6, 6), 0.8, rng:NextNumber(-6, 6))
					if season == "Automne" and i == 1 then
						spawnFood(below + scatter + Vector3.new(0, 1.5, 0), "Fruit", Color3.fromRGB(200, 60, 40), 4, 3)
					else
						spawnFood(below + scatter, "Miette", Color3.fromRGB(210, 180, 140), 1, 1.2)
					end
				end
				squirrel.Timer = rng:NextNumber(3, 6)
			else
				local candidates = { dreyCenter or tips[1] }
				for _, tip in ipairs(tips) do
					table.insert(candidates, tip)
				end
				startHop(squirrel, candidates[rng:NextInteger(1, #candidates)] + Vector3.new(0, SQUIRREL_LEG_OFFSET, 0), 1.6, 18)
			end
		end
	elseif mode == "Hop" then
		local duration = squirrel.Data.HopDuration :: number
		local t = 1 - math.clamp(squirrel.Timer / duration, 0, 1)
		local from = squirrel.Data.HopFrom :: Vector3
		local to = squirrel.Data.HopTo :: Vector3
		local position = arcPosition(from, to, squirrel.Data.HopHeight :: number, t)
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local look = if flat.Magnitude > 0.1 then flat.Unit else squirrel.Root.CFrame.LookVector
		squirrel.Model:PivotTo(CFrame.lookAt(position, position + look))
		if squirrel.Timer <= 0 then
			shakeTreeClimbers(to)
			local cache = squirrel.Data.Cache :: Vector3?
			if cache and (to - cache).Magnitude < SQUIRREL_LEG_OFFSET + 3 then
				squirrel.Mode = "Dig"
				squirrel.Timer = 3
			else
				squirrel.Mode = "Perch"
				squirrel.Timer = rng:NextNumber(4, 9)
			end
		end
	elseif mode == "Dig" then
		if squirrel.Timer <= 0 then
			-- Garde-manger souterrain à piller (fourmis, scarabées, termites).
			local cache = squirrel.Data.Cache :: Vector3
			local holeCenter = cache - Vector3.new(0, 2.5, 0)
			if DigService.CarveHole(holeCenter, 4) then
				spawnFood(holeCenter + Vector3.new(-1, -1.5, 0), "Graine", Color3.fromRGB(150, 100, 50), 3, 2.2)
				spawnFood(holeCenter + Vector3.new(1.2, -1.5, 0.5), "Graine", Color3.fromRGB(170, 120, 60), 3, 2.2)
			end
			squirrel.Data.Cache = nil
			squirrel.Mode = "Perch"
			squirrel.Timer = 2
		end
	end
end

local function spawnSquirrel()
	local info = AnimalData.Ecureuil
	local tips = getBranchTips()
	local start = (dreyCenter or tips[#tips]) + Vector3.new(0, SQUIRREL_LEG_OFFSET, 0)
	local model = AnimalModels.BuildSquirrel(info.MaxHealth)
	local squirrel = register("Ecureuil", model, CFrame.new(start), true, 6, 300, 9, squirrelUpdate, spawnSquirrel)
	squirrel.Data.Tips = tips
end

-- ============================================================
-- Nids des grands animaux
-- ============================================================

local function createAnimalNests()
	local tips = getBranchTips()
	local root = workspace:FindFirstChild("GeneratedWorld") or workspace

	-- Nid de l'oiseau sur la plus haute branche : mini-biome chaud (bonus de température en hiver).
	local birdTip = tips[1]
	local birdModel, birdFloor = AnimalModels.BuildBirdNest(birdTip + Vector3.new(0, 1.5, 0))
	birdModel.Parent = root
	CollectionService:AddTag(birdFloor, "Shelter")
	CollectionService:AddTag(birdFloor, "WarmSpot")
	birdFloor:SetAttribute("WarmBonus", 12)
	birdFloor:SetAttribute("WarmRadius", 16)
	birdNestCenter = birdTip + Vector3.new(0, 1.5, 0)

	-- Hotte de l'écureuil sur une autre branche.
	local dreyTip = tips[math.min(3, #tips)]
	local dreyPosition = dreyTip + Vector3.new(0, 9, 0)
	local dreyModel, dreyFloor = AnimalModels.BuildDrey(dreyPosition)
	dreyModel.Parent = root
	CollectionService:AddTag(dreyFloor, "Shelter")
	CollectionService:AddTag(dreyFloor, "WarmSpot")
	dreyFloor:SetAttribute("WarmBonus", 10)
	dreyFloor:SetAttribute("WarmRadius", 12)
	dreyCenter = dreyPosition + Vector3.new(0, -4, 0)
end

-- ============================================================
-- Démarrage
-- ============================================================

function AnimalService.Start()
	createAnimalNests()
	createSpawningPits()
	createCrabBurrow()

	spawnBird()
	spawnChameleon()
	spawnGoldfish()
	spawnCrab()
	spawnSquirrel()
	for _ = 1, FRY_COUNT do
		spawnFry()
	end

	Remotes.Get("RequestGrabEscape").OnServerEvent:Connect(onEscapePress)
	Players.PlayerRemoving:Connect(function(player)
		releaseHold(player, nil)
	end)
	local function watchCharacter(player: Player)
		player.CharacterRemoving:Connect(function()
			releaseHold(player, nil)
		end)
	end
	Players.PlayerAdded:Connect(watchCharacter)
	for _, player in ipairs(Players:GetPlayers()) do
		watchCharacter(player)
	end

	-- Point de rassemblement du banc d'alevins, qui dérive lentement dans la mare.
	task.spawn(function()
		while true do
			local center, size = getPondInfo()
			if center and size then
				AnimalService.SchoolCenter = randomPointInPond(center, size, center.Y, 6)
			end
			task.wait(8)
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < TICK then
			return
		end
		local dt = accumulator
		accumulator = 0
		for i = #animals, 1, -1 do
			local animal = animals[i]
			if animal and animal.Mode ~= "Dead" and animal.Model.Parent then
				-- Une erreur dans une IA ne doit jamais figer toutes les autres.
				local ok, err = pcall(animal.Update, animal, dt)
				if not ok then
					warn("[AnimalService] " .. animal.Id .. " : " .. tostring(err))
					local held = animal.Data.HeldPlayer :: Player?
					if held then
						releaseHold(held, nil)
					end
					destroyTongue(animal)
					animal.Mode = "Idle"
				end
			end
		end
	end)
end

-- Utilisé par CombatService (Autotomie) : libère un joueur tenu par un animal.
function AnimalService.ReleaseHold(player: Player): boolean
	if not holds[player] then
		return false
	end
	releaseHold(player, "Vous sacrifiez une patte pour fuir !")
	return true
end

return AnimalService
