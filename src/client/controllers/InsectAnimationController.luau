--!strict
-- InsectAnimationController.luau
-- Animation procédurale locale des insectes de TOUS les joueurs visibles (StarterPlayerScripts.controllers).
-- Le serveur construit le conteneur "InsectVisual" (voir la CONVENTION D'ANIMATION en tête de
-- InsectVisualService) ; ici chaque client écrit Weld.C0 = RestC0 * rotation, toujours à partir du
-- repos (jamais d'accumulation). Rien n'est répliqué : c'est purement cosmétique.
--
-- Mouvements : marche en tripodes alternés (vitesse), respiration + balancement des antennes,
-- battement d'ailes en l'air (repliées au sol), élytres ouverts en vol, brasses sous l'eau,
-- ondulation des larves, léger bercement de l'oeuf/du cocon, coup de mâchoires/pinces/queue
-- quand un joueur mord (remote AbilityCast pour soi, attribut LastAttackAt de la victime pour les autres).
--
-- Perf : aucun tableau alloué par frame, rien au-delà de FAR_DISTANCE, une frame sur deux au-delà
-- de NEAR_DISTANCE, une seule rotation calculée par membre (toutes ses parts la partagent).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local Remotes = require(ReplicatedStorage.shared.Remotes)

local InsectAnimationController = {}

local CONTAINER_NAME = "InsectVisual"
-- Repos des parts NON étiquetées (oeuf/cocon), mémorisé côté client pour ne jamais relire un C0 déjà animé.
local LOCAL_REST_ATTRIBUTE = "AnimRestC0"
local NEAR_DISTANCE_SQ = 40 * 40
local FAR_DISTANCE_SQ = 100 * 100
local BITE_DURATION = 0.3
local ZONE_REFRESH_PERIOD = 2
local TWO_PI = math.pi * 2

local K_LEG = 1
local K_WING = 2
local K_ELYTRON = 3
local K_ANTENNA = 4
local K_ABDOMEN = 5
local K_TAIL = 6
local K_JAW = 7
local K_CLAW = 8
local K_SEGMENT = 9
local K_WHOLE = 10

local KIND_CODES: { [string]: number } = {
	Leg = K_LEG,
	Wing = K_WING,
	Elytron = K_ELYTRON,
	Antenna = K_ANTENNA,
	Abdomen = K_ABDOMEN,
	Tail = K_TAIL,
	Jaw = K_JAW,
	Claw = K_CLAW,
	Segment = K_SEGMENT,
}

local FREEFALL = Enum.HumanoidStateType.Freefall
local JUMPING = Enum.HumanoidStateType.Jumping

type Record = {
	player: Player,
	character: Model,
	root: BasePart?,
	humanoid: Humanoid?,
	container: Instance?,
	charConn: RBXScriptConnection?,
	containerConn: RBXScriptConnection?,
	attackConn: RBXScriptConnection?,
	dirty: boolean,
	whole: boolean, -- oeuf/cocon : tout le visuel se berce d'un bloc
	-- Cache en tableaux parallèles (une entrée par part animée).
	count: number,
	welds: { Weld },
	rests: { CFrame },
	kinds: { number },
	sides: { number },
	indices: { number },
	spreads: { number }, -- ailes : angle Y (signé) pour les déployer sur le côté
	biases: { number }, -- ailes : centre du battement
	-- État d'animation.
	seed: number,
	last: number,
	odd: boolean,
	gait: number,
	wingPhase: number,
	move: number,
	air: number,
	swim: number,
	biteAt: number,
	scale: number,
	manyLegs: boolean,
	scorpion: boolean,
	wingRate: number,
	wingIdle: number,
}

local records: { [Player]: Record } = {}
local started = false

local pondZones: { Instance } = {}
local nextZoneRefresh = 0
local frameWaterLevel: number? = nil

-- Tables de travail réutilisées par rebuild (clé = Side * 10 + Index).
local scratchSpread: { [number]: number } = {}
local scratchBias: { [number]: number } = {}

local function isInPondZone(position: Vector3): boolean
	for _, zone in ipairs(pondZones) do
		if zone:IsA("BasePart") then
			local relative = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size * 0.5
			if math.abs(relative.X) <= half.X and math.abs(relative.Z) <= half.Z then
				return true
			end
		end
	end
	return false
end

local function clearCache(rec: Record)
	rec.count = 0
	table.clear(rec.welds)
	table.clear(rec.rests)
	table.clear(rec.kinds)
	table.clear(rec.sides)
	table.clear(rec.indices)
	table.clear(rec.spreads)
	table.clear(rec.biases)
end

-- Reconstruit le cache depuis le conteneur (appelé seulement quand il change : jamais par frame).
local function rebuild(rec: Record, whole: boolean)
	-- Remet d'abord au repos ce qu'on animait : une part qui sort du cache ne reste pas tordue.
	for i = 1, rec.count do
		rec.welds[i].C0 = rec.rests[i]
	end
	clearCache(rec)
	rec.dirty = false
	rec.whole = whole

	local container = rec.container
	if not container then
		return
	end

	local species = rec.player:GetAttribute("Species")
	local plan = InsectBodyPlans.Get(if type(species) == "string" then species else "")
	local wings = plan.Wings
	rec.scorpion = plan.Tail == "ScorpionTail"
	rec.wingRate = if wings == "Butterfly" then 14 elseif wings == "Mayfly" then 28 elseif wings == "Dragonfly" then 45 else 65
	rec.wingIdle = if wings == "Butterfly" then 0.3 else 0
	-- ScaleTo (transition de stade) met à l'échelle C0/C1 des Welds mais PAS l'attribut RestC0 :
	-- on ramène donc les repos de l'échelle de construction ("AnimScale") à l'échelle actuelle.
	local scale = rec.character:GetScale()
	local authored = container:GetAttribute("AnimScale")
	local authorScale: number = if type(authored) == "number" and authored > 0 then authored else scale
	local ratio = scale / authorScale
	rec.scale = scale

	table.clear(scratchSpread)
	table.clear(scratchBias)
	local maxLegIndex = 0
	local count = 0
	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("BasePart") then
			continue
		end
		-- Ancrages au sol (feuille, fils de soie, crémaster) : gardent leur C0 serveur.
		if whole and (child.Name == "EggPad" or child.Name == "SilkThread" or child.Name == "Cremaster") then
			continue
		end
		local weld = child:FindFirstChild("Weld")
		if not weld or not weld:IsA("Weld") then
			continue
		end
		local anim = child:GetAttribute("Anim")
		local rest = child:GetAttribute("RestC0")
		local code = 0
		local restCf: CFrame? = nil
		if type(anim) == "string" and typeof(rest) == "CFrame" then
			code = KIND_CODES[anim] or 0
			restCf = rest
		end
		if whole then
			code = K_WHOLE
			if not restCf then
				local saved = child:GetAttribute(LOCAL_REST_ATTRIBUTE)
				if typeof(saved) == "CFrame" then
					restCf = saved
				else
					-- Mémorisé à l'échelle de construction, comme RestC0.
					local c0 = weld.C0
					restCf = c0.Rotation + c0.Position / ratio
					child:SetAttribute(LOCAL_REST_ATTRIBUTE, restCf)
				end
			end
		end
		if code == 0 or not restCf then
			continue
		end
		if ratio ~= 1 then
			restCf = restCf.Rotation + restCf.Position * ratio
		end

		local sideValue = child:GetAttribute("Side")
		local indexValue = child:GetAttribute("Index")
		local side: number = if type(sideValue) == "number" then sideValue else 0
		local index: number = if type(indexValue) == "number" then indexValue else 0
		local spread = 0
		local bias = 0.15
		if code == K_LEG then
			maxLegIndex = math.max(maxLegIndex, index)
		elseif code == K_WING then
			-- Toutes les parts d'une même aile doivent partager exactement le même angle.
			local key = side * 10 + index
			local known = scratchSpread[key]
			if known then
				spread = known
				bias = scratchBias[key]
			else
				-- Direction de l'aile au repos (racine -> centre de la part), dans le repère du root.
				local dir = (restCf * weld.C1:Inverse()).Position - restCf.Position
				local theta = side * 1.3 - math.atan2(dir.X, dir.Z)
				if theta > math.pi then
					theta -= TWO_PI
				elseif theta < -math.pi then
					theta += TWO_PI
				end
				-- On ne fait qu'OUVRIR vers l'extérieur : une aile déjà étalée (libellule, papillon) reste telle quelle.
				spread = if side * theta > 0 then theta else 0
				-- Aile dressée à la verticale (éphémère) : elle bat vers l'extérieur, pas vers le haut.
				if dir.Y > math.sqrt(dir.X * dir.X + dir.Z * dir.Z) then
					bias = -0.75
				end
				scratchSpread[key] = spread
				scratchBias[key] = bias
			end
		end

		count += 1
		rec.welds[count] = weld
		rec.rests[count] = restCf
		rec.kinds[count] = code
		rec.sides[count] = side
		rec.indices[count] = index
		rec.spreads[count] = spread
		rec.biases[count] = bias
	end
	rec.count = count
	rec.manyLegs = maxLegIndex > 4 -- scolopendre : vague le long du corps plutôt que tripodes
end

local function animate(rec: Record, root: BasePart, humanoid: Humanoid, now: number)
	local dt = math.clamp(now - rec.last, 0, 0.1)
	rec.last = now
	local t = now + rec.seed
	local count = rec.count
	local welds = rec.welds
	local rests = rec.rests

	if rec.whole then
		-- Oeuf / cocon : quelque chose vit là-dedans.
		local rock = CFrame.Angles(math.sin(t * 1.3) * 0.025, 0, math.sin(t * 0.9) * 0.02)
			+ Vector3.new(0, math.sin(t * 2.2) * 0.015 * rec.scale, 0)
		for i = 1, count do
			welds[i].C0 = rock * rests[i]
		end
		return
	end

	local speed = root.AssemblyLinearVelocity.Magnitude
	local position = root.Position
	local waterLevel = frameWaterLevel
	local swimming = waterLevel ~= nil and position.Y < waterLevel and isInPondZone(position)
	local airborne = false
	if not swimming then
		local state = humanoid:GetState()
		-- UpVector : un grimpeur collé à un mur est aussi en "Freefall", mais penché ; en vol on reste droit.
		airborne = (state == FREEFALL or state == JUMPING) and root.CFrame.UpVector.Y > 0.8
	end

	local alpha = math.min(1, dt * 10)
	rec.air += ((if airborne then 1 else 0) - rec.air) * alpha
	rec.swim += ((if swimming then 1 else 0) - rec.swim) * alpha
	rec.move += ((if airborne then 0 else math.min(1, speed / 3)) - rec.move) * alpha
	local air, swim, move = rec.air, rec.swim, rec.move

	local gaitRate = if swimming then 4 + speed * 0.5 else math.min(6 + speed * 0.8, 22)
	rec.gait = (rec.gait + dt * gaitRate) % TWO_PI
	-- Pas de phase plafonné : évite le repliement (battement stroboscopique) à bas FPS.
	rec.wingPhase = (rec.wingPhase + math.min(dt * rec.wingRate, 1.2)) % TWO_PI
	local gait, wingPhase = rec.gait, rec.wingPhase

	-- Morsure : les mâchoires s'ouvrent (> 0) puis claquent au-delà du repos (< 0) et reviennent.
	local jawOpen = 0
	local u = (now - rec.biteAt) / BITE_DURATION
	if u >= 0 and u < 1 then
		if u < 0.4 then
			jawOpen = 0.6 * u / 0.4
		elseif u < 0.55 then
			jawOpen = 0.6 - 0.85 * (u - 0.4) / 0.15
		else
			jawOpen = -0.25 * (1 - (u - 0.55) / 0.45)
		end
	end

	local kinds = rec.kinds
	local sides = rec.sides
	local indices = rec.indices
	local manyLegs = rec.manyLegs
	local lastKind, lastSide, lastIndex = 0, 0, 0
	local rot = CFrame.identity
	for i = 1, count do
		local kind, side, index = kinds[i], sides[i], indices[i]
		-- Les parts d'un même membre se suivent : la rotation n'est recalculée qu'au changement de membre.
		if kind ~= lastKind or side ~= lastSide or index ~= lastIndex then
			lastKind, lastSide, lastIndex = kind, side, index
			if kind == K_LEG then
				local phase: number
				if manyLegs then
					phase = gait + index * 0.8 + (if side > 0 then math.pi else 0)
				else
					phase = gait + (if (index + (if side > 0 then 1 else 0)) % 2 == 0 then 0 else math.pi)
				end
				-- Pied en avant quand swing > 0 ; levé pendant qu'il avance, posé pendant qu'il pousse.
				local swing = 0.4 * math.sin(phase) * move
				local lift = 0.28 * math.max(0, math.cos(phase)) * move
				if swim > 0.01 then
					-- Brasse : gauche et droite rament ensemble, les paires se décalent.
					swing = swing * (1 - swim) + (math.sin(gait + index * 1.1) * 0.55 - 0.15) * swim
					lift *= 1 - swim
				end
				-- En vol : pattes pendantes, traînées vers l'arrière.
				swing -= 0.3 * air
				lift -= 0.2 * air
				rot = CFrame.Angles(0, side * swing, side * lift)
			elseif kind == K_WING then
				local flap = air * (rec.biases[i] + 0.7 * math.sin(wingPhase + index * 0.7))
					+ (1 - air) * rec.wingIdle * math.sin(t * 1.5)
				-- Déploiement (Y) appliqué AVANT le battement (Z) : d'où le produit dans cet ordre.
				rot = CFrame.Angles(0, 0, side * flap) * CFrame.Angles(0, rec.spreads[i] * air, 0)
			elseif kind == K_ELYTRON then
				rot = CFrame.Angles(0, 0, side * air * (0.45 + 0.04 * math.sin(wingPhase)))
					* CFrame.Angles(0, side * 0.75 * air, 0)
			elseif kind == K_ANTENNA then
				rot = CFrame.Angles(
					math.sin(t * 2.1 + side) * 0.08 + math.sin(gait * 2) * 0.08 * move + 0.2 * air,
					side * math.sin(t * 1.4 + index) * 0.1,
					0
				)
			elseif kind == K_ABDOMEN then
				rot = CFrame.Angles(
					math.sin(t * 2.4) * 0.035 + math.sin(gait * 2) * 0.05 * move + 0.18 * air + math.sin(gait) * 0.1 * swim,
					math.sin(gait) * 0.04 * move,
					0
				)
			elseif kind == K_TAIL then
				local rx = math.sin(t * 1.6) * 0.05
				if rec.scorpion then
					-- La queue se recourbe en marchant et fouette vers l'avant avec la morsure.
					rx -= 0.08 * move + 0.7 * math.abs(jawOpen)
				end
				rot = CFrame.Angles(rx, math.sin(t * 1.1 + side * 1.3) * 0.06 + math.sin(gait) * 0.2 * swim, 0)
			elseif kind == K_JAW then
				rot = CFrame.Angles(0, -side * (0.04 + 0.04 * math.sin(t * 3.1) + jawOpen), 0)
			elseif kind == K_CLAW then
				rot = CFrame.Angles(math.sin(t * 1.3 + side) * 0.04 + 0.7 * jawOpen, 0, 0)
			elseif kind == K_SEGMENT then
				local wave = gait - index * 0.9
				local drive = move + swim
				rot = CFrame.Angles(
					math.sin(t * 2 - index * 0.5) * 0.03,
					math.sin(wave) * (0.2 * move + 0.3 * swim) + math.sin(t * 1.2 - index * 0.7) * 0.04,
					0
				) + Vector3.new(math.cos(wave) * 0.05 * rec.scale * math.min(1, drive), 0, 0)
			else
				rot = CFrame.identity
			end
		end
		welds[i].C0 = rests[i] * rot
	end
end

local function bindContainer(rec: Record, container: Instance?)
	local conn = rec.containerConn
	if conn then
		conn:Disconnect()
		rec.containerConn = nil
	end
	clearCache(rec) -- l'ancien conteneur est détruit : inutile de le remettre au repos
	rec.container = container
	rec.dirty = true
	if container then
		-- Les parts (et leurs Welds) arrivent par vagues à la réplication.
		rec.containerConn = container.DescendantAdded:Connect(function()
			rec.dirty = true
		end)
	end
end

local function untrack(player: Player)
	local rec = records[player]
	if not rec then
		return
	end
	records[player] = nil
	if rec.charConn then
		rec.charConn:Disconnect()
	end
	if rec.containerConn then
		rec.containerConn:Disconnect()
	end
	if rec.attackConn then
		rec.attackConn:Disconnect()
	end
	clearCache(rec)
end

local function track(player: Player, character: Model)
	untrack(player)
	local rec: Record = {
		player = player,
		character = character,
		root = nil,
		humanoid = nil,
		container = nil,
		charConn = nil,
		containerConn = nil,
		attackConn = nil,
		dirty = true,
		whole = false,
		count = 0,
		welds = {},
		rests = {},
		kinds = {},
		sides = {},
		indices = {},
		spreads = {},
		biases = {},
		seed = math.random() * 10,
		last = os.clock(),
		odd = false,
		gait = 0,
		wingPhase = 0,
		move = 0,
		air = 0,
		swim = 0,
		biteAt = -10,
		scale = 1,
		manyLegs = false,
		scorpion = false,
		wingRate = 65,
		wingIdle = 0,
	}
	records[player] = rec
	-- Changement de stade : le serveur détruit le conteneur et en crée un nouveau.
	rec.charConn = character.ChildAdded:Connect(function(child)
		if child.Name == CONTAINER_NAME then
			bindContainer(rec, child)
		end
	end)
	-- Morsure des AUTRES joueurs : DamageService date chaque coup sur la victime (attributs répliqués).
	-- shortcut: seuls les coups qui touchent un joueur sont visibles ; un attribut posé par
	-- CombatService sur l'attaquant couvrirait aussi les morsures dans le vide ou sur un animal.
	rec.attackConn = character:GetAttributeChangedSignal("LastAttackAt"):Connect(function()
		local attackerId = character:GetAttribute("LastAttackerUserId")
		if type(attackerId) ~= "number" then
			return
		end
		local attacker = Players:GetPlayerByUserId(attackerId)
		if attacker and attacker ~= Players.LocalPlayer then
			local attackerRec = records[attacker]
			if attackerRec then
				attackerRec.biteAt = os.clock()
			end
		end
	end)
	bindContainer(rec, character:FindFirstChild(CONTAINER_NAME))
end

local function onHeartbeat()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()

	local waterLevel = workspace:GetAttribute("PondWaterLevel")
	frameWaterLevel = if type(waterLevel) == "number" then waterLevel else nil
	if now >= nextZoneRefresh then
		nextZoneRefresh = now + ZONE_REFRESH_PERIOD
		pondZones = CollectionService:GetTagged("PondZone")
	end

	for player, rec in records do
		local character = rec.character
		local root = rec.root
		if not root or root.Parent ~= character then
			local found = character:FindFirstChild("HumanoidRootPart")
			root = if found and found:IsA("BasePart") then found else nil
			rec.root = root
		end
		local humanoid = rec.humanoid
		if not humanoid or humanoid.Parent ~= character then
			humanoid = character:FindFirstChildOfClass("Humanoid")
			rec.humanoid = humanoid
		end
		local container = rec.container
		if container and container.Parent ~= character then
			bindContainer(rec, nil)
			container = nil
		end
		-- Mort : on fige la pose (le serveur clone la carcasse de son côté).
		if not root or not humanoid or not container or humanoid.Health <= 0 then
			continue
		end

		local offset = root.Position - cameraPosition
		local distanceSq = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
		if distanceSq > FAR_DISTANCE_SQ then
			continue
		end
		rec.odd = not rec.odd
		if distanceSq > NEAR_DISTANCE_SQ and rec.odd then
			continue
		end

		local stage = container:GetAttribute("Stage")
		local whole = stage == "Oeuf" or stage == "Cocon"
		if rec.dirty or whole ~= rec.whole or character:GetScale() ~= rec.scale then
			rebuild(rec, whole)
		end
		if rec.count > 0 then
			animate(rec, root, humanoid, now)
		end
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		track(player, character)
	end)
	player.CharacterRemoving:Connect(function(character)
		local rec = records[player]
		if rec and rec.character == character then
			untrack(player)
		end
	end)
	local character = player.Character
	if character then
		track(player, character)
	end
end

function InsectAnimationController.Start()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(untrack)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	RunService.Heartbeat:Connect(onHeartbeat)

	-- AbilityCast n'est envoyé qu'au joueur qui mord : il anime l'insecte local (même dans le vide).
	task.spawn(function()
		Remotes.Get("AbilityCast").OnClientEvent:Connect(function(_slot: unknown, primitive: unknown)
			if primitive == "Bite" or primitive == "Lunge" then
				local rec = records[Players.LocalPlayer]
				if rec then
					rec.biteAt = os.clock()
				end
			end
		end)
	end)
end

return InsectAnimationController
