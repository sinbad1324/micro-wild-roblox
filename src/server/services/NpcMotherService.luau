--!strict
-- NpcMotherService.luau
-- Mamans PNJ (GDD §2 "Maman joueuse ou IA", §8.2 Colonie & Maman).
-- Au démarrage, ~10 nids PNJ sont posés dans les biomes qui conviennent à leur espèce ; chacun est
-- enregistré dans GrowthAndNestService.ActiveNests (id = GameConstants.NPC_NEST_ID_BASE - n,
-- FamilyId "NpcNest_<n>") : il apparaît dans le menu de spawn et un oeuf peut y naître.
--
-- Chaque Maman PNJ est un insecte adulte visible (mannequin + InsectVisualService), tagué "NpcMother",
-- déplacé côté serveur (Root ancrée) comme les animaux. Machine à états :
--   Idle (autour du nid) -> Forage (noeud "FoodNode" proche) -> Return (dépôt dans StoredFood)
--   -> Feed (pause au nid ; FoodService.nestTick nourrit les bébés avec la réserve)
--   Defend : mord un joueur hors famille qui attaque la Maman ou un bébé de la famille près du nid
--   Flee   : se réfugie au nid quand un animal géant approche
-- Morte : carcasse + réapparition après NPC_MOTHER_RESPAWN_SECONDS ; le nid et la famille restent.
-- Sommeil/LOD : sans joueur à NPC_MOTHER_ACTIVE_RANGE, IA à 1 Hz sans raycast ; sinon décisions à
-- 10 Hz, sol à 5 Hz et CFrame interpolé à chaque frame (les Roots ancrées ne sont pas interpolées
-- par les clients).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local FoodData = require(ReplicatedStorage.shared.FoodData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local ServerTypes = require(ServerScriptService.types.ServerTypes)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local FoodService = require(ServerScriptService.services.FoodService)
local DamageService = require(ServerScriptService.services.DamageService)
local CarcassService = require(ServerScriptService.services.CarcassService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local NpcMotherService = {}

local MOTHER_SCALE = 1.3 -- une reine est un peu plus grosse qu'un adulte joueur
local MOTHER_HEALTH_MULTIPLIER = 2.5
local THINK_SECONDS = 0.1 -- décisions à 10 Hz près des joueurs
local GROUND_RAY_SECONDS = 0.2 -- suivi du sol à 5 Hz
local FAR_TICK_SECONDS = 1 -- IA endormie
local PRESENCE_SECONDS = 1 -- réévaluation joueurs proches / animaux géants
local NEAR_EXIT_FACTOR = 1.2 -- hystérésis : on ne s'endort qu'un peu au-delà de la portée d'éveil
local FORAGE_RADIUS = 90
local FORAGE_TIMEOUT = 45
local FORAGE_COOLDOWN_WITH_BABIES = 15
local FORAGE_COOLDOWN_ALONE = 50
local STOCK_TARGET_WITH_BABIES = 250
local STOCK_TARGET_ALONE = 80
local NEST_STOCK_CAP = 500 -- même plafond que FoodService.nestTick
local CARRY_MULTIPLIER = 2 -- une reine rapporte une grosse charge
local FLEE_RANGE = 55
local FLEE_CLEAR_RANGE = 85
local DEFEND_RANGE = GameConstants.NEST_RADIUS * 2.5
local DEFEND_LEASH = GameConstants.NEST_RADIUS * 3.5
local DEFEND_MAX_SECONDS = 15
local AGGRESSION_MEMORY = 3 -- un coup reçu il y a moins de 3 s déclenche la défense
local BITE_RANGE = 4.5
local BITE_COOLDOWN = 1.5
local BITE_DAMAGE_FACTOR = 0.6
local MIN_SITE_SPACING = 40
local MAX_STEP_HEIGHT = 6 -- au-delà, le "sol" trouvé est un obstacle (personnage, rocher...)

type Mode = "Idle" | "Forage" | "Return" | "Feed" | "Defend" | "Flee" | "Dead"

type Mother = {
	Index: number,
	NestId: number,
	Nest: ServerTypes.NestData,
	SpeciesId: string,
	DisplayName: string,
	Aquatic: boolean,
	Model: Model?,
	Root: BasePart?,
	Humanoid: Humanoid?,
	HalfHeight: number,
	Position: Vector3, -- pieds de la Maman (position logique au sol)
	GroundY: number,
	Heading: Vector3, -- direction de regard horizontale (unitaire)
	Goal: Vector3?,
	Speed: number,
	Mode: Mode,
	ModeSince: number,
	Timer: number,
	NextForageAt: number,
	FoodNode: BasePart?,
	Carrying: number,
	Target: Player?,
	DefendFrom: Vector3, -- origine de la laisse du combat (nid, ou lieu de l'attaque si la Maman est visée)
	NotifiedAt: number,
	DryPosition: Vector3, -- dernier point au sol hors de l'eau (recul d'une Maman terrestre)
	NextBiteAt: number,
	Near: boolean,
	ThinkAcc: number,
	RayAcc: number,
	FarAcc: number,
}

type Site = { Species: string, Center: Vector3, MinRadius: number, MaxRadius: number, Angle: number, Aquatic: boolean }

-- Biomes adaptés à chaque espèce (WorldLayout) : fourmis/termites à la Souche, abeilles/frelons
-- autour du Chêne (hors canopée), araignée/mante dans la Prairie, scorpion/scarabée aux Rochers,
-- aquatiques au fond de la Mare (berge nord : la nurserie IA occupe la berge sud).
local SITES: { Site } = {
	{ Species = "FourmiRousse", Center = WorldLayout.STUMP_CENTER, MinRadius = 60, MaxRadius = 125, Angle = 0.6, Aquatic = false },
	{ Species = "TermiteSoldat", Center = WorldLayout.STUMP_CENTER, MinRadius = 60, MaxRadius = 125, Angle = 3.6, Aquatic = false },
	{ Species = "AbeilleMellifere", Center = WorldLayout.OAK_CENTER, MinRadius = 108, MaxRadius = 128, Angle = 0.4, Aquatic = false },
	{ Species = "FrelonAsiatique", Center = WorldLayout.OAK_CENTER, MinRadius = 108, MaxRadius = 128, Angle = 2.6, Aquatic = false },
	{ Species = "VeuveNoire", Center = WorldLayout.PRAIRIE_CENTER, MinRadius = 50, MaxRadius = 150, Angle = 1.0, Aquatic = false },
	{ Species = "ManteReligieuse", Center = WorldLayout.PRAIRIE_CENTER, MinRadius = 50, MaxRadius = 150, Angle = 4.2, Aquatic = false },
	{ Species = "ScorpionEmpereur", Center = WorldLayout.ROCKS_CENTER, MinRadius = 50, MaxRadius = 140, Angle = 2.0, Aquatic = false },
	{ Species = "ScarabeeHercule", Center = WorldLayout.ROCKS_CENTER, MinRadius = 50, MaxRadius = 140, Angle = 5.2, Aquatic = false },
	{ Species = "Argyronete", Center = WorldLayout.POND_CENTER, MinRadius = 0, MaxRadius = 0, Angle = -55, Aquatic = true },
	{ Species = "DytiqueBorde", Center = WorldLayout.POND_CENTER, MinRadius = 0, MaxRadius = 0, Angle = 55, Aquatic = true },
}

local mothers: { Mother } = {}
local motherFolder: Folder? = nil
-- Caches réévalués à PRESENCE_SECONDS (aucune allocation dans la boucle par frame).
local playerRoots: { BasePart } = {}
local giantRoots: { BasePart } = {}
-- Tag "Animal" suivi par signaux (pas de GetTagged à chaque seconde).
local animalModels: { [Model]: boolean } = {}
-- Filtres de raycast reconstruits seulement quand personnages/dossiers changent.
local rayFiltersDirty = true
-- UserId -> NestId -> os.clock() de la dernière récompense pour avoir tué cette Maman.
local lastKillReward: { [number]: { [number]: number } } = {}

local landRayParams = RaycastParams.new()
landRayParams.FilterType = Enum.RaycastFilterType.Exclude
landRayParams.IgnoreWater = false -- une Maman terrestre n'entre pas dans l'eau
local waterRayParams = RaycastParams.new()
waterRayParams.FilterType = Enum.RaycastFilterType.Exclude
waterRayParams.IgnoreWater = true -- une Maman aquatique marche au fond

local function getFolder(): Folder
	if motherFolder and motherFolder.Parent then
		return motherFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "NpcMothers"
	folder.Parent = workspace
	motherFolder = folder
	return folder
end

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function getAliveCharacterRoot(player: Player): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil
	end
	return character, root
end

local function setMode(m: Mother, mode: Mode, now: number)
	m.Mode = mode
	m.ModeSince = now
end

-- ============================================================
-- Placement des nids
-- ============================================================

local function rebuildRayFilters()
	local ignore: { Instance } = { getFolder() }
	local nests = workspace:FindFirstChild("Nests")
	if nests then
		table.insert(ignore, nests)
	end
	local carcasses = workspace:FindFirstChild("Carcasses")
	if carcasses then
		table.insert(ignore, carcasses)
	end
	-- Corps des animaux et boules de nourriture : ne sont pas du sol (sinon la Maman monte dessus).
	local animals = workspace:FindFirstChild("Animals")
	if animals then
		table.insert(ignore, animals)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	landRayParams.FilterDescendantsInstances = ignore
	waterRayParams.FilterDescendantsInstances = ignore
end

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

-- Vrai si un objet solide (rocher, racine, souche...) occupe déjà l'emplacement du nid.
local function isObstructed(groundPosition: Vector3): boolean
	overlapParams.FilterDescendantsInstances = landRayParams.FilterDescendantsInstances
	local parts = workspace:GetPartBoundsInBox(CFrame.new(groundPosition + Vector3.new(0, 5, 0)), Vector3.new(14, 8, 14), overlapParams)
	for _, part in ipairs(parts) do
		if part.CanCollide and not part:IsA("Terrain") then
			return true
		end
	end
	return false
end

local function farFromOthers(position: Vector3, taken: { Vector3 }): boolean
	for _, other in ipairs(taken) do
		if flatDistance(position, other) < MIN_SITE_SPACING then
			return false
		end
	end
	return true
end

local function findLandSite(site: Site, taken: { Vector3 }): Vector3?
	local limit = WorldLayout.MAP_HALF - 20
	for attempt = 0, 15 do
		local angle = site.Angle + attempt * 0.55
		local radius = site.MinRadius + (site.MaxRadius - site.MinRadius) * ((attempt * 0.37) % 1)
		local x = math.clamp(site.Center.X + math.cos(angle) * radius, -limit, limit)
		local z = math.clamp(site.Center.Z + math.sin(angle) * radius, -limit, limit)
		local origin = Vector3.new(x, WorldLayout.GROUND_TOP_Y + 60, z)
		local result = workspace:Raycast(origin, Vector3.new(0, -120, 0), landRayParams)
		if
			result
			and result.Material ~= Enum.Material.Water
			and math.abs(result.Position.Y - WorldLayout.GROUND_TOP_Y) <= MAX_STEP_HEIGHT
			and farFromOthers(result.Position, taken)
			and not isObstructed(result.Position)
		then
			return result.Position
		end
	end
	return nil
end

local function findAquaticSite(site: Site, taken: { Vector3 }): Vector3?
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	local pondZone: BasePart? = nil
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") and zone.Name == "PondZone_Mare" then
			pondZone = zone
		end
	end
	if not waterLevel or not pondZone then
		return nil
	end
	-- Site.Angle sert ici de décalage X le long de la berge nord.
	local x = pondZone.Position.X + site.Angle
	local z = pondZone.Position.Z - pondZone.Size.Z * 0.3
	local result = workspace:Raycast(Vector3.new(x, waterLevel, z), Vector3.new(0, -(WorldLayout.POND_DEPTH + 10), 0), waterRayParams)
	local position = if result then result.Position else Vector3.new(x, waterLevel - WorldLayout.POND_DEPTH, z)
	if not farFromOthers(position, taken) then
		return nil
	end
	return position
end

-- ============================================================
-- Corps de la Maman
-- ============================================================

local function render(m: Mother)
	local root = m.Root
	if not root then
		return
	end
	local center = m.Position + Vector3.new(0, m.HalfHeight, 0)
	-- Tête de l'insecte vers -Z : CFrame.lookAt oriente justement -Z vers la cible.
	root.CFrame = CFrame.lookAt(center, center + m.Heading)
end

local onDeath: (m: Mother, model: Model) -> ()

local function spawnMotherBody(m: Mother)
	local species = InsectData[m.SpeciesId]
	local model = Instance.new("Model")
	model.Name = m.DisplayName
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = CFrame.new(m.Nest.Position)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayName = m.DisplayName
	humanoid.HipHeight = 0
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth = (if species then species.MaxHealth else 100) * MOTHER_HEALTH_MULTIPLIER
	humanoid.Health = humanoid.MaxHealth
	humanoid.Parent = model

	model:SetAttribute("FamilyId", m.Nest.FamilyId)
	model:SetAttribute("SpeciesId", m.SpeciesId)
	model:SetAttribute("NestId", m.NestId)
	model:SetAttribute("HitRadius", 2 * MOTHER_SCALE)
	model.Parent = getFolder()
	model:ScaleTo(MOTHER_SCALE)

	m.Model = model
	m.Root = root
	m.Humanoid = humanoid
	m.HalfHeight = root.Size.Y / 2
	m.Position = m.Nest.Position - Vector3.new(0, 2, 0) -- Nest.Position = sol + 2
	m.GroundY = m.Position.Y
	m.DryPosition = m.Position
	m.Heading = Vector3.new(0, 0, -1)
	m.Goal = nil
	m.Speed = 0
	m.Carrying = 0
	m.FoodNode = nil
	m.Target = nil
	setMode(m, "Idle", os.clock())
	m.Timer = 0
	render(m)
	InsectVisualService.ApplyVisual(model, m.SpeciesId, "Adulte", nil)
	-- Tag posé après le corps : CombatService ne vise qu'une Maman complète.
	CollectionService:AddTag(model, "NpcMother")

	humanoid.Died:Connect(function()
		onDeath(m, model)
	end)

	m.Nest.MotherAlive = true
	GrowthAndNestService.RefreshNestDisplay(m.NestId)
end

local function notifyFamily(m: Mother, message: string)
	for _, child in ipairs(m.Nest.Children) do
		if child.Parent then
			notify(child, message, "warning")
		end
	end
end

onDeath = function(m: Mother, model: Model)
	if m.Model ~= model or m.Mode == "Dead" then
		return
	end
	setMode(m, "Dead", os.clock())
	local root = m.Root
	local ok, err = pcall(function()
		local template = InsectVisualService.BuildCarcassTemplate(model)
		CarcassService.SpawnCarcassFor(if root then root.Position else m.Position, m.DisplayName, false, model:GetScale(), template)
	end)
	if not ok then
		warn("[NpcMotherService] carcasse : " .. tostring(err))
	end
	-- Le tueur gagne des PE comme pour un insecte-joueur.
	local killerId = model:GetAttribute("LastAttackerUserId") :: number?
	local killer = if killerId then Players:GetPlayerByUserId(killerId) else nil
	if killer then
		-- Anti-farm : une même Maman ne rapporte des PE à un même tueur qu'une fois par 3 réapparitions.
		local now = os.clock()
		local perNest = lastKillReward[killer.UserId]
		if not perNest then
			perNest = {}
			lastKillReward[killer.UserId] = perNest
		end
		local last = perNest[m.NestId]
		if not last or now - last >= GameConstants.NPC_MOTHER_RESPAWN_SECONDS * 3 then
			perNest[m.NestId] = now
			ProgressionService.AddEvolutionPoints(killer, GameConstants.KILL_EVOLUTION_POINTS)
		end
	end
	m.Model = nil
	m.Root = nil
	m.Humanoid = nil
	model:Destroy()

	-- Le nid et la famille persistent, sans mère, jusqu'à la réapparition.
	m.Nest.MotherAlive = false
	GrowthAndNestService.RefreshNestDisplay(m.NestId)
	notifyFamily(m, m.DisplayName .. " est morte ! Le nid tient bon jusqu'à son retour.")
	task.delay(GameConstants.NPC_MOTHER_RESPAWN_SECONDS, function()
		if GrowthAndNestService.ActiveNests[m.NestId] ~= m.Nest then
			return
		end
		local spawned, spawnErr = pcall(spawnMotherBody, m)
		if not spawned then
			warn("[NpcMotherService] réapparition : " .. tostring(spawnErr))
			return
		end
		notifyFamily(m, m.DisplayName .. " est de retour au nid.")
	end)
end

-- ============================================================
-- Comportement
-- ============================================================

local function walkSpeed(m: Mother): number
	local species = InsectData[m.SpeciesId]
	return if species then species.WalkSpeed else 16
end

local function needsFood(m: Mother): boolean
	local target = if #m.Nest.Children > 0 then STOCK_TARGET_WITH_BABIES else STOCK_TARGET_ALONE
	return m.Nest.StoredFood < target
end

local function findFoodNode(m: Mother): BasePart?
	local species = InsectData[m.SpeciesId]
	local diet: FoodData.DietType = if species then species.Diet else "Omnivore"
	local nestPosition = m.Nest.Position
	local waterLevel = (workspace:GetAttribute("PondWaterLevel") :: number?) or WorldLayout.POND_WATER_LEVEL
	local best: BasePart? = nil
	local bestDistance = FORAGE_RADIUS
	for _, instance in ipairs(CollectionService:GetTagged("FoodNode")) do
		if not instance:IsA("BasePart") or instance:GetAttribute("Depleted") == true then
			continue
		end
		local node = instance :: BasePart
		local position = node.Position
		-- Aquatique : sous l'eau seulement ; terrestre : au niveau du nid (pas de fruit dans la canopée,
		-- ni de galerie souterraine, ni de fond de mare).
		local reachable = if m.Aquatic
			then position.Y < waterLevel
			else math.abs(position.Y - nestPosition.Y) <= 8 and position.Y > waterLevel + 1
		if not reachable then
			continue
		end
		local distance = flatDistance(position, nestPosition)
		if distance < bestDistance then
			local foodType = node:GetAttribute("FoodType") :: string?
			-- Régime vérifié ici pour ne pas marcher vers un noeud immangeable (FoodService revérifie).
			if foodType and FoodData.CanEat(diet, foodType) then
				best = node
				bestDistance = distance
			end
		end
	end
	return best
end

local function isFamily(m: Mother, player: Player): boolean
	return player:GetAttribute("FamilyId") == m.Nest.FamilyId
end

-- Niveau module (pas de closure à 10 Hz). La Maman se défend partout (laisse mesurée depuis sa
-- position) ; un bébé n'est défendu que près du nid.
local function checkVictim(m: Mother, victim: Instance, victimPosition: Vector3, now: number, isMother: boolean): Player?
	local at = victim:GetAttribute("LastAttackAt") :: number?
	local attackerId = victim:GetAttribute("LastAttackerUserId") :: number?
	if not at or not attackerId or now - at > AGGRESSION_MEMORY then
		return nil
	end
	if not isMother and flatDistance(victimPosition, m.Nest.Position) > DEFEND_RANGE then
		return nil
	end
	local attacker = Players:GetPlayerByUserId(attackerId)
	if not attacker or isFamily(m, attacker) then
		return nil
	end
	local _, attackerRoot = getAliveCharacterRoot(attacker)
	local leashFrom = if isMother then m.Position else m.Nest.Position
	if not attackerRoot or flatDistance(attackerRoot.Position, leashFrom) > DEFEND_LEASH then
		return nil
	end
	return attacker
end

-- Un joueur hors famille qui vient de frapper la Maman ou un bébé de la famille près du nid.
-- Renvoie aussi l'origine de la laisse du combat.
local function findAggressor(m: Mother, now: number): (Player?, Vector3)
	local model = m.Model
	if model then
		local found = checkVictim(m, model, m.Position, now, true)
		if found then
			return found, m.Position
		end
	end
	for _, child in ipairs(m.Nest.Children) do
		local character, root = getAliveCharacterRoot(child)
		if character and root then
			local found = checkVictim(m, character, root.Position, now, false)
			if found then
				return found, m.Nest.Position
			end
		end
	end
	return nil, m.Nest.Position
end

local function nearestGiantDistance(position: Vector3): number
	local best = math.huge
	for _, root in ipairs(giantRoots) do
		if root.Parent then
			local distance = (root.Position - position).Magnitude
			if distance < best then
				best = distance
			end
		end
	end
	return best
end

local function deposit(m: Mother)
	if m.Carrying <= 0 then
		return
	end
	m.Nest.StoredFood = math.min(m.Nest.StoredFood + m.Carrying, NEST_STOCK_CAP)
	m.Carrying = 0
	GrowthAndNestService.RefreshNestDisplay(m.NestId)
end

local function think(m: Mother, now: number)
	local humanoid = m.Humanoid
	if not humanoid or humanoid.Health <= 0 or m.Mode == "Dead" then
		return
	end
	local nestPosition = m.Nest.Position - Vector3.new(0, 2, 0)
	local baseSpeed = walkSpeed(m)

	-- 1. Défense de la famille (prioritaire sur la fuite : GDD §8.2).
	if m.Mode ~= "Defend" then
		local aggressor, leashFrom = findAggressor(m, now)
		if aggressor then
			setMode(m, "Defend", now)
			-- Toast seulement pour un nouvel agresseur ou après 5 s (pas de spam en ré-entrée).
			if m.Target ~= aggressor or now - m.NotifiedAt > 5 then
				notify(aggressor, m.DisplayName .. " défend sa famille !", "warning")
				m.NotifiedAt = now
			end
			m.Target = aggressor
			m.DefendFrom = leashFrom
			m.FoodNode = nil
		end
	end

	-- 2. Fuite : un animal géant approche. Le nid sert d'abri : y arriver met fin à la fuite
	-- (sinon les Mamans de la mare, frôlées en continu par le poisson et le crabe, ne sortiraient jamais).
	local giantDistance = nearestGiantDistance(m.Position)
	-- Tout le disque du nid abrite : la petite ronde Idle ne relance pas la fuite.
	local atNest = flatDistance(m.Position, nestPosition) <= GameConstants.NEST_RADIUS
	if m.Mode == "Flee" then
		if giantDistance > FLEE_CLEAR_RANGE or atNest then
			setMode(m, "Idle", now)
			m.Timer = now + 2
		else
			m.Goal = nestPosition
			m.Speed = baseSpeed * 1.2
			return
		end
	elseif m.Mode ~= "Defend" and giantDistance <= FLEE_RANGE and not atNest then
		setMode(m, "Flee", now)
		m.FoodNode = nil
		m.Target = nil
		m.Goal = nestPosition
		m.Speed = baseSpeed * 1.2
		return
	end

	-- 3. Comportement courant.
	if m.Mode == "Defend" then
		local target = m.Target
		local character: Model?, targetRoot: BasePart? = nil, nil
		if target and target.Parent then
			character, targetRoot = getAliveCharacterRoot(target)
		end
		if
			not target
			or not character
			or not targetRoot
			or isFamily(m, target)
			or now - m.ModeSince > DEFEND_MAX_SECONDS
			or flatDistance(targetRoot.Position, m.DefendFrom) > DEFEND_LEASH
		then
			setMode(m, "Return", now)
			return
		end
		m.Goal = targetRoot.Position
		m.Speed = baseSpeed * 1.15
		local reach = BITE_RANGE * MOTHER_SCALE
		if (targetRoot.Position - (m.Position + Vector3.new(0, m.HalfHeight, 0))).Magnitude <= reach and now >= m.NextBiteAt then
			m.NextBiteAt = now + BITE_COOLDOWN
			local species = InsectData[m.SpeciesId]
			-- Morsure datée sur la Maman : les clients l'animent (pas de joueur attaquant à résoudre).
			local model = m.Model
			if model then
				model:SetAttribute("BiteAt", now)
			end
			DamageService.ApplyDamage(character, (if species then species.Damage else 10) * BITE_DAMAGE_FACTOR)
		end
	elseif m.Mode == "Forage" then
		local node = m.FoodNode
		if not node or not node.Parent or node:GetAttribute("Depleted") == true or now - m.ModeSince > FORAGE_TIMEOUT then
			m.FoodNode = nil
			setMode(m, "Return", now)
			return
		end
		m.Goal = node.Position
		m.Speed = baseSpeed * 0.8
		if flatDistance(node.Position, m.Position) <= 3 + math.max(node.Size.X, node.Size.Z) / 2 then
			local species = InsectData[m.SpeciesId]
			local nutrition = FoodService.ConsumeNode(node, if species then species.Diet else "Omnivore")
			m.FoodNode = nil
			if nutrition then
				m.Carrying += nutrition * CARRY_MULTIPLIER
			end
			setMode(m, "Return", now)
		end
	elseif m.Mode == "Return" then
		m.Goal = nestPosition
		m.Speed = baseSpeed * 0.8
		if flatDistance(m.Position, nestPosition) <= 4 then
			deposit(m)
			setMode(m, "Feed", now)
			m.Timer = now + 3
		end
	elseif m.Mode == "Feed" then
		-- Pause au coeur du nid : FoodService.nestTick distribue la réserve aux bébés présents.
		m.Goal = nestPosition
		m.Speed = baseSpeed * 0.4
		if now >= m.Timer then
			setMode(m, "Idle", now)
			m.Timer = 0
		end
	else -- Idle
		if now >= m.NextForageAt and giantDistance > FLEE_CLEAR_RANGE and needsFood(m) then
			m.NextForageAt = now + (if #m.Nest.Children > 0 then FORAGE_COOLDOWN_WITH_BABIES else FORAGE_COOLDOWN_ALONE)
			local node = findFoodNode(m)
			if node then
				m.FoodNode = node
				setMode(m, "Forage", now)
				return
			end
		end
		if now >= m.Timer then
			-- Petite ronde autour du nid.
			local angle = math.random() * math.pi * 2
			local radius = 4 + math.random() * (GameConstants.NEST_RADIUS - 6)
			m.Goal = nestPosition + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			m.Speed = baseSpeed * 0.35
			m.Timer = now + 3 + math.random() * 5
		end
	end
end

-- Suivi du sol (5 Hz près des joueurs, 1 Hz endormie). Une Maman terrestre qui atteint l'eau fait demi-tour.
local function sampleGround(m: Mother, now: number)
	local origin = Vector3.new(m.Position.X, m.Position.Y + MAX_STEP_HEIGHT, m.Position.Z)
	local params = if m.Aquatic then waterRayParams else landRayParams
	local result = workspace:Raycast(origin, Vector3.new(0, -(MAX_STEP_HEIGHT + 14), 0), params)
	if not result then
		return
	end
	if result.Material == Enum.Material.Water and not m.Aquatic then
		m.FoodNode = nil
		-- Recul au dernier point sec : elle s'arrête au bord de l'eau, même en combat.
		m.Position = Vector3.new(m.DryPosition.X, m.Position.Y, m.DryPosition.Z)
		if m.Mode == "Defend" then
			-- Sans abandonner le combat (évite l'oscillation Defend/Return et ses toasts).
			m.Goal = nil
		elseif m.Mode ~= "Return" and m.Mode ~= "Flee" then
			setMode(m, "Return", now)
		end
		return
	end
	m.GroundY = result.Position.Y
	m.DryPosition = m.Position
end

local function step(m: Mother, dt: number)
	local goal = m.Goal
	if goal then
		local delta = flat(goal - m.Position)
		local distance = delta.Magnitude
		if distance > 0.5 then
			local direction = delta / distance
			local move = math.min(m.Speed * dt, distance)
			m.Position += direction * move
			-- Virage adouci (évite les demi-tours instantanés).
			local blended = m.Heading:Lerp(direction, math.min(1, dt * 6))
			if blended.Magnitude > 0.01 then
				m.Heading = blended.Unit
			end
		end
	end
	local y = m.Position.Y + (m.GroundY - m.Position.Y) * math.min(1, dt * 8)
	m.Position = Vector3.new(m.Position.X, y, m.Position.Z)
end

local function refreshPresence()
	table.clear(playerRoots)
	for _, player in ipairs(Players:GetPlayers()) do
		local _, root = getAliveCharacterRoot(player)
		if root then
			table.insert(playerRoots, root)
		end
	end
	table.clear(giantRoots)
	for animal in pairs(animalModels) do
		-- Seuls les alevins sont "Grabbable" : tout le reste est un animal géant.
		local primary = animal.PrimaryPart
		if primary and animal:GetAttribute("Grabbable") ~= true then
			table.insert(giantRoots, primary)
		end
	end
	local range = GameConstants.NPC_MOTHER_ACTIVE_RANGE
	for _, m in ipairs(mothers) do
		-- Une Maman éveillée reste éveillée jusqu'à range * NEAR_EXIT_FACTOR (pas de clignotement LOD).
		local limit = if m.Near then range * NEAR_EXIT_FACTOR else range
		local near = false
		for _, root in ipairs(playerRoots) do
			if (root.Position - m.Position).Magnitude <= limit then
				near = true
				break
			end
		end
		m.Near = near
	end
	if rayFiltersDirty then
		rayFiltersDirty = false
		rebuildRayFilters()
	end
end

-- Pas de closure par frame : pcall(updateMother, m, dt, now).
local function updateMother(m: Mother, dt: number, now: number)
	if m.Near then
		-- Modulo (et non remise à 0) : chaque Maman garde son décalage de phase, les raycasts et
		-- décisions restent répartis sur des frames différentes.
		m.ThinkAcc += dt
		if m.ThinkAcc >= THINK_SECONDS then
			m.ThinkAcc %= THINK_SECONDS
			think(m, now)
		end
		m.RayAcc += dt
		if m.RayAcc >= GROUND_RAY_SECONDS then
			m.RayAcc %= GROUND_RAY_SECONDS
			sampleGround(m, now)
		end
		step(m, dt)
		render(m)
	else
		m.FarAcc += dt
		if m.FarAcc >= FAR_TICK_SECONDS then
			local elapsed = math.min(m.FarAcc, FAR_TICK_SECONDS * 2)
			m.FarAcc %= FAR_TICK_SECONDS
			-- 1 raycast/s : même endormie, une Maman terrestre ne traverse pas la mare et suit le relief.
			sampleGround(m, now)
			think(m, now)
			step(m, elapsed)
			render(m)
		end
	end
end

local function onHeartbeat(dt: number)
	local now = os.clock()
	for _, m in ipairs(mothers) do
		if m.Mode == "Dead" or not m.Model then
			continue
		end
		local ok, err = pcall(updateMother, m, dt, now)
		if not ok then
			warn("[NpcMotherService] " .. m.DisplayName .. " : " .. tostring(err))
			m.Goal = nil
			setMode(m, "Idle", now)
		end
	end
end

-- ============================================================
-- API
-- ============================================================

-- Mamans PNJ actives (lecture seule) : { NestId, SpeciesId, DisplayName, Mode, alive }.
function NpcMotherService.GetMothers(): { { NestId: number, SpeciesId: string, DisplayName: string, Mode: string, Alive: boolean } }
	local list = {}
	for _, m in ipairs(mothers) do
		table.insert(list, { NestId = m.NestId, SpeciesId = m.SpeciesId, DisplayName = m.DisplayName, Mode = m.Mode :: string, Alive = m.Model ~= nil })
	end
	return list
end

function NpcMotherService.Start()
	-- Caches tenus par signaux : animaux tagués, filtres de raycast.
	for _, instance in ipairs(CollectionService:GetTagged("Animal")) do
		if instance:IsA("Model") then
			animalModels[instance] = true
		end
	end
	CollectionService:GetInstanceAddedSignal("Animal"):Connect(function(instance)
		if instance:IsA("Model") then
			animalModels[instance] = true
		end
	end)
	CollectionService:GetInstanceRemovedSignal("Animal"):Connect(function(instance)
		animalModels[instance :: Model] = nil
	end)
	local function markDirty()
		rayFiltersDirty = true
	end
	local function watchPlayer(player: Player)
		player.CharacterAdded:Connect(markDirty)
		markDirty()
	end
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	-- lastKillReward n'est pas vidé au départ : un rejoin ne doit pas remettre le compteur à zéro.
	Players.PlayerRemoving:Connect(markDirty)
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "Nests" or child.Name == "Carcasses" or child.Name == "NpcMothers" or child.Name == "Animals" then
			markDirty()
		end
	end)
	rebuildRayFilters()
	local taken: { Vector3 } = { WorldLayout.SPAWN_POSITION }
	for _, aiNest in ipairs(CollectionService:GetTagged("AINest")) do
		if aiNest:IsA("BasePart") then
			table.insert(taken, aiNest.Position)
		end
	end

	-- Nids enregistrés de façon synchrone : la première diffusion du menu de spawn les contient.
	for index, site in ipairs(SITES) do
		local species = InsectData[site.Species]
		if not species then
			continue
		end
		local ok, err = pcall(function()
			local ground = if site.Aquatic then findAquaticSite(site, taken) else findLandSite(site, taken)
			if not ground then
				warn("[NpcMotherService] aucun emplacement pour " .. site.Species)
				return
			end
			table.insert(taken, ground)
			local displayName = "Reine " .. species.Name .. " (PNJ)"
			local nestId, nest = GrowthAndNestService.RegisterNpcNest(index, site.Species, ground, displayName)
			local m: Mother = {
				Index = index,
				NestId = nestId,
				Nest = nest,
				SpeciesId = site.Species,
				DisplayName = displayName,
				Aquatic = site.Aquatic,
				Model = nil,
				Root = nil,
				Humanoid = nil,
				HalfHeight = 1,
				Position = ground,
				GroundY = ground.Y,
				Heading = Vector3.new(0, 0, -1),
				Goal = nil,
				Speed = 0,
				Mode = "Idle",
				ModeSince = 0,
				Timer = 0,
				-- Départs étalés : les Mamans ne partent pas toutes chercher à manger en même temps.
				NextForageAt = os.clock() + 5 + index * 3,
				FoodNode = nil,
				Carrying = 0,
				Target = nil,
				DefendFrom = ground,
				NotifiedAt = 0,
				DryPosition = ground,
				NextBiteAt = 0,
				Near = false,
				-- Phases étalées par index (nombre d'or) : les Mamans ne tiquent pas toutes sur la même frame.
				ThinkAcc = ((index * 0.618) % 1) * THINK_SECONDS,
				RayAcc = ((index * 0.382) % 1) * GROUND_RAY_SECONDS,
				FarAcc = ((index * 0.618) % 1) * FAR_TICK_SECONDS,
			}
			table.insert(mothers, m)
			spawnMotherBody(m)
		end)
		if not ok then
			warn("[NpcMotherService] " .. site.Species .. " : " .. tostring(err))
		end
	end

	task.spawn(function()
		while true do
			task.wait(PRESENCE_SECONDS)
			local ok, err = pcall(refreshPresence)
			if not ok then
				warn("[NpcMotherService] présence : " .. tostring(err))
			end
		end
	end)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return NpcMotherService
