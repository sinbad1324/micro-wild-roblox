--!strict
-- WildInsectService.luau
-- Insectes sauvages PNJ : peuplent la carte avec TOUTES les espèces d'insectes (InsectData, hors
-- animaux jouables), chacune dans un biome qui lui convient. Corps = mannequin adulte construit par
-- InsectVisualService (même rendu et même animation que les joueurs, tag "WildInsect").
--
-- Comportement (machine à états simple, selon le régime) :
--   Wander : flâne autour de son point d'attache, pauses ; les volants planent et ondulent en l'air,
--            les aquatiques restent au fond de l'eau.
--   Chase  : un carnivore attaque un joueur qui passe trop près (laisse autour de son territoire) ;
--            tout insecte mordu riposte contre son agresseur.
--   Flee   : un herbivore fuit un joueur proche (et tout insecte fuit quand il est très blessé).
-- Mort : carcasse (nourriture) + PE au tueur (anti-farm), réapparition ailleurs après un délai.
-- LOD : sans joueur proche, IA à 1 Hz sans raycast ; sinon décisions à 5 Hz et CFrame chaque frame
-- (Root ancrée : les clients ne l'interpolent pas).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local DamageService = require(ServerScriptService.services.DamageService)
local CarcassService = require(ServerScriptService.services.CarcassService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)
local StatusEffectService = require(ServerScriptService.services.StatusEffectService)

local WildInsectService = {}

local TAG = "WildInsect"
local WILD_TOTAL = 42 -- toutes les espèces au moins une fois, puis des doublons
local THINK_SECONDS = 0.2
local GROUND_SECONDS = 0.2
local FAR_TICK_SECONDS = 1
local PRESENCE_SECONDS = 1
local ACTIVE_RANGE = 220
local WANDER_RADIUS = 28
local IDLE_MIN, IDLE_MAX = 1.5, 6
local AGGRO_RANGE = 14
local FLEE_RANGE = 12
local LEASH = 55
local CHASE_MAX_SECONDS = 12
local AGGRESSION_MEMORY = 4
local BITE_RANGE = 3.5
local BITE_COOLDOWN = 1.6
local BITE_DAMAGE_FACTOR = 0.5
local RESPAWN_SECONDS = 60
local KILL_POINTS = math.floor(GameConstants.KILL_EVOLUTION_POINTS * 0.5)
local KILL_REWARD_COOLDOWN = 120 -- même PNJ, même tueur
local MAX_STEP_HEIGHT = 8
local FLY_HEIGHT_MIN, FLY_HEIGHT_MAX = 5, 11

type Mode = "Wander" | "Idle" | "Chase" | "Flee" | "Dead"

type Wild = {
	Index: number,
	SpeciesId: string,
	Name: string,
	Diet: string,
	Flyer: boolean,
	Aquatic: boolean,
	Home: Vector3,
	Model: Model?,
	Root: BasePart?,
	Humanoid: Humanoid?,
	HalfHeight: number,
	Position: Vector3, -- pieds au sol (ou au fond de l'eau)
	GroundY: number,
	FlyHeight: number,
	Heading: Vector3,
	Goal: Vector3?,
	Speed: number,
	Mode: Mode,
	ModeSince: number,
	Timer: number,
	Target: Player?,
	NextBiteAt: number,
	Near: boolean,
	ThinkAcc: number,
	GroundAcc: number,
	FarAcc: number,
	Seed: number,
}

local wilds: { Wild } = {}
local folder: Folder? = nil
local playerRoots: { [Player]: BasePart } = {}
local lastKillReward: { [number]: { [number]: number } } = {}

local landParams = RaycastParams.new()
landParams.FilterType = Enum.RaycastFilterType.Exclude
landParams.IgnoreWater = false -- un insecte terrestre s'arrête au bord de l'eau
local waterParams = RaycastParams.new()
waterParams.FilterType = Enum.RaycastFilterType.Exclude
waterParams.IgnoreWater = true -- un aquatique marche au fond

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "WildInsects"
	created.Parent = workspace
	folder = created
	landParams.FilterDescendantsInstances = { created }
	waterParams.FilterDescendantsInstances = { created }
	return created
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- ============================================================
-- Placement
-- ============================================================

local LAND_BIOMES = { WorldLayout.STUMP_CENTER, WorldLayout.PRAIRIE_CENTER, WorldLayout.ROCKS_CENTER, WorldLayout.OAK_CENTER }
local AIR_BIOMES = { WorldLayout.OAK_CENTER, WorldLayout.PRAIRIE_CENTER, WorldLayout.POND_CENTER, WorldLayout.STUMP_CENTER }

local function pondZones(): { BasePart }
	local zones: { BasePart } = {}
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			table.insert(zones, zone)
		end
	end
	return zones
end

-- Point au sol (terrestre/volant) ou au fond d'une mare (aquatique), ou nil si rien de valable.
local function findSpot(aquatic: boolean, flyer: boolean, rng: Random): Vector3?
	local limit = WorldLayout.MAP_HALF - 30
	if aquatic then
		local zones = pondZones()
		local level = workspace:GetAttribute("PondWaterLevel")
		if #zones == 0 or type(level) ~= "number" then
			return nil
		end
		for _ = 1, 8 do
			local zone = zones[rng:NextInteger(1, #zones)]
			local local_ = Vector3.new(rng:NextNumber(-0.4, 0.4) * zone.Size.X, 0, rng:NextNumber(-0.4, 0.4) * zone.Size.Z)
			local point = zone.CFrame * local_
			local hit = workspace:Raycast(Vector3.new(point.X, level, point.Z), Vector3.new(0, -60, 0), waterParams)
			if hit and hit.Position.Y < level - 1 then
				return hit.Position
			end
		end
		return nil
	end
	local biomes = if flyer then AIR_BIOMES else LAND_BIOMES
	for _ = 1, 12 do
		local center = biomes[rng:NextInteger(1, #biomes)]
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(30, 190)
		local x = math.clamp(center.X + math.cos(angle) * radius, -limit, limit)
		local z = math.clamp(center.Z + math.sin(angle) * radius, -limit, limit)
		local hit = workspace:Raycast(Vector3.new(x, WorldLayout.GROUND_TOP_Y + 120, z), Vector3.new(0, -260, 0), landParams)
		if hit and hit.Material ~= Enum.Material.Water then
			return hit.Position
		end
	end
	return nil
end

-- ============================================================
-- Corps
-- ============================================================

local function render(w: Wild, now: number)
	local root = w.Root
	if not root then
		return
	end
	local lift = 0
	if w.Flyer then
		-- Vol : altitude propre + ondulation lente, plus bas quand il attaque.
		local height = if w.Mode == "Chase" then 2.5 else w.FlyHeight
		lift = height + math.sin(now * 1.7 + w.Seed) * 0.8
	end
	local center = w.Position + Vector3.new(0, w.HalfHeight + lift, 0)
	root.CFrame = CFrame.lookAt(center, center + w.Heading)
end

local onDeath: (w: Wild, model: Model) -> ()

local function spawnBody(w: Wild)
	local species = InsectData[w.SpeciesId]
	local model = Instance.new("Model")
	model.Name = w.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = CFrame.new(w.Home)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayName = w.Name
	humanoid.HipHeight = 0
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.NameDisplayDistance = 45
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	humanoid.MaxHealth = if species then species.MaxHealth else 100
	humanoid.Health = humanoid.MaxHealth
	humanoid.Parent = model

	model:SetAttribute("SpeciesId", w.SpeciesId)
	model:SetAttribute("HitRadius", 2)
	model:SetAttribute("Flying", if w.Flyer then true else nil) -- lu par InsectAnimationController
	model.Parent = getFolder()

	w.Model = model
	w.Root = root
	w.Humanoid = humanoid
	w.HalfHeight = root.Size.Y / 2
	w.Position = w.Home
	w.GroundY = w.Home.Y
	w.Heading = Vector3.new(0, 0, -1)
	w.Goal = nil
	w.Speed = 0
	w.Target = nil
	w.Mode = "Idle"
	w.ModeSince = os.clock()
	w.Timer = os.clock() + 2
	render(w, os.clock())
	InsectVisualService.ApplyVisual(model, w.SpeciesId, "Adulte", nil)
	-- Tag posé après le corps : combat et animation ne voient qu'un insecte complet.
	CollectionService:AddTag(model, TAG)

	humanoid.Died:Connect(function()
		onDeath(w, model)
	end)
end

onDeath = function(w: Wild, model: Model)
	if w.Model ~= model or w.Mode == "Dead" then
		return
	end
	w.Mode = "Dead"
	local root = w.Root
	local ok, err = pcall(function()
		local template = InsectVisualService.BuildCarcassTemplate(model)
		CarcassService.SpawnCarcassFor(if root then root.Position else w.Position, w.Name, false, model:GetScale(), template)
	end)
	if not ok then
		warn("[WildInsectService] carcasse : " .. tostring(err))
	end
	local killerId = model:GetAttribute("LastAttackerUserId")
	local killer = if type(killerId) == "number" then Players:GetPlayerByUserId(killerId) else nil
	if killer then
		local now = os.clock()
		local perWild = lastKillReward[killer.UserId] or {}
		lastKillReward[killer.UserId] = perWild
		local last = perWild[w.Index]
		if not last or now - last >= KILL_REWARD_COOLDOWN then
			perWild[w.Index] = now
			ProgressionService.AddEvolutionPoints(killer, KILL_POINTS)
			ProgressionService.AddExperience(killer, 30)
		end
	end
	w.Model = nil
	w.Root = nil
	w.Humanoid = nil
	model:Destroy()
	task.delay(RESPAWN_SECONDS, function()
		local spot = findSpot(w.Aquatic, w.Flyer, Random.new())
		if spot then
			w.Home = spot
		end
		local spawned, spawnErr = pcall(spawnBody, w)
		if not spawned then
			warn("[WildInsectService] réapparition : " .. tostring(spawnErr))
		end
	end)
end

-- ============================================================
-- Comportement
-- ============================================================

local function setMode(w: Wild, mode: Mode, now: number)
	if w.Mode ~= mode then
		w.Mode = mode
		w.ModeSince = now
	end
end

local function nearestPlayer(w: Wild, range: number): (Player?, BasePart?, number)
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = range
	for player, root in pairs(playerRoots) do
		local distance = (root.Position - w.Position).Magnitude
		if distance < bestDistance then
			best, bestRoot, bestDistance = player, root, distance
		end
	end
	return best, bestRoot, bestDistance
end

local function think(w: Wild, now: number)
	local model = w.Model
	local humanoid = w.Humanoid
	if not model or not humanoid then
		return
	end
	local species = InsectData[w.SpeciesId]
	-- Glu / ralentissement / étourdissement (StatusEffectService) appliqués à la vitesse de l'IA.
	local baseSpeed = (if species then species.WalkSpeed else 14) * StatusEffectService.GetSpeedFactor(model)
	if w.Flyer then
		baseSpeed *= 1.2
	end

	-- Riposte : un insecte mordu poursuit son agresseur (s'il est assez en forme).
	local lastHit = model:GetAttribute("LastAttackAt")
	local attackerId = model:GetAttribute("LastAttackerUserId")
	local hitRecently = type(lastHit) == "number" and now - lastHit < AGGRESSION_MEMORY
	local hurt = humanoid.Health < humanoid.MaxHealth * 0.3
	if hitRecently and type(attackerId) == "number" and w.Mode ~= "Chase" and w.Mode ~= "Flee" then
		local attacker = Players:GetPlayerByUserId(attackerId)
		if attacker and playerRoots[attacker] then
			if hurt or w.Diet == "Herbivore" then
				w.Target = attacker
				setMode(w, "Flee", now)
			else
				w.Target = attacker
				setMode(w, "Chase", now)
			end
		end
	end

	if w.Mode == "Chase" then
		local target = w.Target
		local targetRoot = target and playerRoots[target]
		if not target or not targetRoot or now - w.ModeSince > CHASE_MAX_SECONDS or flat(w.Position - w.Home).Magnitude > LEASH then
			w.Target = nil
			setMode(w, "Wander", now)
			w.Goal = w.Home
			w.Speed = baseSpeed * 0.8
			return
		end
		w.Goal = targetRoot.Position
		w.Speed = baseSpeed * 1.1
		local center = w.Position + Vector3.new(0, w.HalfHeight, 0)
		if (targetRoot.Position - center).Magnitude <= BITE_RANGE + (if w.Flyer then 3 else 0) and now >= w.NextBiteAt then
			w.NextBiteAt = now + BITE_COOLDOWN
			model:SetAttribute("BiteAt", now) -- animé par les clients (mâchoires)
			local character = targetRoot.Parent
			if character and character:IsA("Model") then
				-- Une mort par morsure revient au PNJ, pas au dernier joueur ayant touché la cible.
				character:SetAttribute("LastAttackerUserId", nil)
				DamageService.ApplyDamage(character, (if species then species.Damage else 10) * BITE_DAMAGE_FACTOR)
			end
		end
		return
	end

	if w.Mode == "Flee" then
		local target = w.Target
		local targetRoot = target and playerRoots[target]
		if not targetRoot or now - w.ModeSince > 6 then
			w.Target = nil
			setMode(w, "Wander", now)
			return
		end
		local away = flat(w.Position - targetRoot.Position)
		away = if away.Magnitude > 0.1 then away.Unit else w.Heading
		w.Goal = w.Position + away * 20
		w.Speed = baseSpeed * 1.25
		return
	end

	-- Réactions de base : carnivore attaque, herbivore fuit, quand un joueur passe trop près.
	if w.Diet == "Carnivore" then
		local player, _, distance = nearestPlayer(w, AGGRO_RANGE)
		if player and distance < AGGRO_RANGE then
			w.Target = player
			setMode(w, "Chase", now)
			return
		end
	elseif w.Diet == "Herbivore" then
		local player = nearestPlayer(w, FLEE_RANGE)
		if player then
			w.Target = player
			setMode(w, "Flee", now)
			return
		end
	end

	if w.Mode == "Idle" then
		w.Goal = nil
		if now >= w.Timer then
			-- Nouvelle destination autour du point d'attache.
			local angle = math.random() * math.pi * 2
			local radius = math.random() * WANDER_RADIUS
			w.Goal = w.Home + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			w.Speed = baseSpeed * (0.35 + math.random() * 0.3)
			setMode(w, "Wander", now)
		end
	else -- Wander
		local goal = w.Goal
		if not goal or flat(goal - w.Position).Magnitude < 1.5 then
			w.Goal = nil
			w.Timer = now + IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN)
			setMode(w, "Idle", now)
		end
	end
end

local function sampleGround(w: Wild)
	local origin = Vector3.new(w.Position.X, w.Position.Y + MAX_STEP_HEIGHT, w.Position.Z)
	local params = if w.Aquatic then waterParams else landParams
	local hit = workspace:Raycast(origin, Vector3.new(0, -(MAX_STEP_HEIGHT + 20), 0), params)
	if not hit then
		return
	end
	if hit.Material == Enum.Material.Water and not w.Aquatic and not w.Flyer then
		-- Bord de l'eau : demi-tour vers le point d'attache.
		w.Goal = w.Home
		return
	end
	w.GroundY = hit.Position.Y
end

local function step(w: Wild, dt: number)
	local goal = w.Goal
	if goal then
		local delta = flat(goal - w.Position)
		local distance = delta.Magnitude
		if distance > 0.3 then
			local direction = delta / distance
			w.Position += direction * math.min(w.Speed * dt, distance)
			local blended = w.Heading:Lerp(direction, math.min(1, dt * 6))
			if blended.Magnitude > 0.01 then
				w.Heading = blended.Unit
			end
		end
	end
	local y = w.Position.Y + (w.GroundY - w.Position.Y) * math.min(1, dt * 8)
	w.Position = Vector3.new(w.Position.X, y, w.Position.Z)
end

local function update(w: Wild, dt: number, now: number)
	if w.Near then
		w.ThinkAcc += dt
		if w.ThinkAcc >= THINK_SECONDS then
			w.ThinkAcc %= THINK_SECONDS
			think(w, now)
		end
		w.GroundAcc += dt
		if w.GroundAcc >= GROUND_SECONDS then
			w.GroundAcc %= GROUND_SECONDS
			sampleGround(w)
		end
		step(w, dt)
		render(w, now)
	else
		w.FarAcc += dt
		if w.FarAcc >= FAR_TICK_SECONDS then
			local elapsed = math.min(w.FarAcc, FAR_TICK_SECONDS * 2)
			w.FarAcc %= FAR_TICK_SECONDS
			sampleGround(w)
			think(w, now)
			step(w, elapsed)
			render(w, now)
		end
	end
end

local function refreshPresence()
	table.clear(playerRoots)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			playerRoots[player] = root
		end
	end
	for _, w in ipairs(wilds) do
		local limit = if w.Near then ACTIVE_RANGE * 1.2 else ACTIVE_RANGE
		local near = false
		for _, root in pairs(playerRoots) do
			if (root.Position - w.Position).Magnitude <= limit then
				near = true
				break
			end
		end
		w.Near = near
	end
end

function WildInsectService.Start()
	getFolder()
	-- Espèces d'insectes (pas les animaux jouables), ordre stable pour des index stables.
	local species: { string } = {}
	for id, info in pairs(InsectData) do
		if info.Category ~= "Animal" then
			table.insert(species, id)
		end
	end
	table.sort(species)
	if #species == 0 then
		return
	end

	-- Le monde (terrain, mares) est généré avant : on place après un court délai de sécurité.
	task.delay(3, function()
		local rng = Random.new(20261120)
		for index = 1, WILD_TOTAL do
			local id = species[(index - 1) % #species + 1]
			local info = InsectData[id]
			local aquatic = info.Category == "Aquatique"
			local flyer = info.Category == "Volant" and info.CanFly
			local home = findSpot(aquatic, flyer, rng)
			if not home then
				continue
			end
			local w: Wild = {
				Index = index,
				SpeciesId = id,
				Name = info.Name,
				Diet = info.Diet,
				Flyer = flyer,
				Aquatic = aquatic,
				Home = home,
				Model = nil,
				Root = nil,
				Humanoid = nil,
				HalfHeight = 1,
				Position = home,
				GroundY = home.Y,
				FlyHeight = rng:NextNumber(FLY_HEIGHT_MIN, FLY_HEIGHT_MAX),
				Heading = Vector3.new(0, 0, -1),
				Goal = nil,
				Speed = 0,
				Mode = "Idle",
				ModeSince = 0,
				Timer = 0,
				Target = nil,
				NextBiteAt = 0,
				Near = false,
				-- Phases étalées : tous les PNJ ne tiquent pas sur la même frame.
				ThinkAcc = ((index * 0.618) % 1) * THINK_SECONDS,
				GroundAcc = ((index * 0.382) % 1) * GROUND_SECONDS,
				FarAcc = ((index * 0.618) % 1) * FAR_TICK_SECONDS,
				Seed = index * 1.7,
			}
			local ok, err = pcall(spawnBody, w)
			if ok then
				table.insert(wilds, w)
			else
				warn("[WildInsectService] " .. id .. " : " .. tostring(err))
			end
		end
	end)

	local presenceAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		presenceAcc += dt
		if presenceAcc >= PRESENCE_SECONDS then
			presenceAcc = 0
			refreshPresence()
		end
		local now = os.clock()
		for _, w in ipairs(wilds) do
			if w.Mode == "Dead" or not w.Model then
				continue
			end
			local ok, err = pcall(update, w, dt, now)
			if not ok then
				warn("[WildInsectService] " .. w.Name .. " : " .. tostring(err))
				w.Goal = nil
				setMode(w, "Idle", now)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		playerRoots[player] = nil
	end)
end

return WildInsectService
