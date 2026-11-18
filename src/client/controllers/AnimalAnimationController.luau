--!strict
-- AnimalAnimationController.luau
-- Animation procédurale locale des grands animaux (tag "Animal") et des statues de la galerie
-- (workspace.Galerie3D.Animaux), côté client (StarterPlayerScripts.controllers).
-- Convention : voir l'en-tête de AnimalModels. Chaque part animable est soudée à "Root" par un Weld
-- "AnimWeld" (enfant de Root) ; on écrit weld.C0 = RestC0 * rotation, toujours depuis le repos
-- (jamais d'accumulation). Un membre porté (oeil du caméléon, doigt de pince) suit son parent :
--   C0 = parentRest * parentDelta * parentRest:Inverse() * RestC0 * delta.
-- Rien n'est répliqué : purement cosmétique.
--
-- Mouvements : battement d'ailes de l'oiseau (lié à la vitesse et à la montée/descente, ailes
-- repliées au perchoir), cycles de marche (diagonale pour le caméléon, bonds pour l'écureuil,
-- sautillement de l'oiseau, tétrapodes du crabe), balancement des queues, ondulation du poisson et
-- de ses nageoires, claquements de pinces du crabe, yeux du caméléon pivotant chacun de leur côté,
-- respiration (tête) et coups d'oeil.
--
-- Vitesse : la Root est ancrée et déplacée par PivotTo (AssemblyLinearVelocity = 0), on la déduit
-- donc du déplacement de la Root entre deux mises à jour, lissé (la réplication arrive par à-coups).
-- Perf : aucun tableau alloué par frame, rien au-delà de FAR_DISTANCE, une frame sur deux au-delà
-- de NEAR_DISTANCE, une seule rotation calculée par membre (toutes ses parts la partagent).

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local AnimalAnimationController = {}

local TAG = "Animal"
local GALLERY_FOLDER = "Galerie3D"
local GALLERY_ANIMALS = "Animaux"
local WELD_NAME = "AnimWeld"
local NEAR_DISTANCE_SQ = 120 * 120
local FAR_DISTANCE_SQ = 350 * 350
local FRY_FAR_DISTANCE_SQ = 150 * 150 -- alevins : petits et nombreux
local MAX_SPEED = 150 -- au-delà : téléportation / respawn, on ignore la mesure
local SNAP_DURATION = 0.45
local TWO_PI = math.pi * 2

local K_LEG = 1
local K_WING = 2
local K_TAIL = 3
local K_FIN = 4
local K_CLAW = 5
local K_HEAD = 6
local K_EYE = 7

local KIND_CODES: { [string]: number } = {
	Leg = K_LEG,
	Wing = K_WING,
	Tail = K_TAIL,
	Fin = K_FIN,
	Claw = K_CLAW,
	Head = K_HEAD,
	Eye = K_EYE,
}

local S_OTHER = 0
local S_BIRD = 1
local S_CHAMELEON = 2
local S_FISH = 3
local S_CRAB = 4
local S_SQUIRREL = 5

-- Clé = Model.Name posé par AnimalModels (identique pour les animaux vivants et les statues).
local SPECIES_CODES: { [string]: number } = {
	Oiseau = S_BIRD,
	Cameleon = S_CHAMELEON,
	PoissonRouge = S_FISH,
	Alevin = S_FISH,
	Crabe = S_CRAB,
	Ecureuil = S_SQUIRREL,
}

type Record = {
	model: Model,
	root: BasePart?,
	humanoid: Humanoid?,
	addConn: RBXScriptConnection?,
	dirty: boolean,
	species: number,
	fry: boolean,
	-- Cache en tableaux parallèles (une entrée par part animée).
	count: number,
	welds: { Weld },
	rests: { CFrame }, -- membre porté : parentRest:Inverse() * RestC0
	kinds: { number },
	sides: { number },
	indices: { number },
	parents: { number }, -- indice de l'entrée parente (0 = aucune) ; toujours < à l'indice courant
	deltas: { CFrame }, -- rotation appliquée cette frame (lue par les membres portés)
	-- Réglages par espèce (posés au rebuild).
	walkRef: number,
	gaitBase: number,
	gaitGain: number,
	gaitMax: number,
	breathRate: number,
	headRange: number,
	headPause: number,
	headSnap: number,
	-- État d'animation.
	seed: number,
	last: number,
	odd: boolean,
	lastPos: Vector3?,
	speed: number,
	climb: number,
	move: number,
	air: number,
	gait: number,
	wingPhase: number,
	headYaw: number,
	headTarget: number,
	nextHead: number,
	eyeYaw: { number }, -- [1] = gauche, [2] = droite
	eyePitch: { number },
	eyeTargetYaw: { number },
	eyeTargetPitch: { number },
	eyeNext: { number },
	snapAt: number,
	snapSide: number,
	nextSnap: number,
}

local records: { [Instance]: Record } = {}
local started = false

-- Welds de membres portés, ajoutés après leurs parents (réutilisé par rebuild).
local scratchChildren: { Weld } = {}

local function clearCache(rec: Record)
	rec.count = 0
	table.clear(rec.welds)
	table.clear(rec.rests)
	table.clear(rec.kinds)
	table.clear(rec.sides)
	table.clear(rec.indices)
	table.clear(rec.parents)
	table.clear(rec.deltas)
end

local function numberAttribute(part: BasePart, name: string): number
	local value = part:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

local function addEntry(rec: Record, weld: Weld, rest: CFrame, kind: number, side: number, index: number, parent: number)
	local count = rec.count + 1
	rec.count = count
	rec.welds[count] = weld
	rec.rests[count] = rest
	rec.kinds[count] = kind
	rec.sides[count] = side
	rec.indices[count] = index
	rec.parents[count] = parent
	rec.deltas[count] = CFrame.identity
end

local function applySpecies(rec: Record)
	local species = rec.species
	-- walkRef = vitesse (studs/s) pour un pas d'amplitude pleine ; cadence = base + gain * vitesse.
	if species == S_BIRD then
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 10, 6, 0.6, 14
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = 2.2, 1, 0.4, 18
	elseif species == S_CHAMELEON then
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 4, 2, 0.8, 8
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = 0.9, 0.3, 1.5, 2
	elseif species == S_FISH then
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 10, 3, 0.35, 12
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = (if rec.fry then 3 else 1.5), 0, 1, 1
	elseif species == S_CRAB then
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 8, 5, 0.8, 18
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = 1.2, 0, 1, 1
	elseif species == S_SQUIRREL then
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 12, 6, 0.5, 16
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = 2.6, 0.7, 0.5, 14
	else
		rec.walkRef, rec.gaitBase, rec.gaitGain, rec.gaitMax = 8, 4, 0.6, 16
		rec.breathRate, rec.headRange, rec.headPause, rec.headSnap = 1.5, 0.3, 1, 4
	end
end

-- Reconstruit le cache depuis les welds de la Root (seulement quand le modèle change, jamais par frame).
local function rebuild(rec: Record)
	-- Remet au repos ce qu'on animait : une part qui sort du cache ne reste pas tordue.
	for i = 1, rec.count do
		local p = rec.parents[i]
		rec.welds[i].C0 = if p > 0 then rec.rests[p] * rec.rests[i] else rec.rests[i]
	end
	clearCache(rec)
	rec.dirty = false

	local model = rec.model
	rec.species = SPECIES_CODES[model.Name] or S_OTHER
	rec.fry = model.Name == "Alevin"
	applySpecies(rec)
	rec.humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model.PrimaryPart -- = "Root" (posée par AnimalModels.newBuilder)
	rec.root = root
	if not root then
		return
	end

	table.clear(scratchChildren)
	for _, instance in ipairs(root:GetChildren()) do
		if instance.Name ~= WELD_NAME or not instance:IsA("Weld") then
			continue
		end
		local child = instance :: Weld
		local part = child.Part1
		if not part then
			continue
		end
		local anim = part:GetAttribute("Anim")
		local rest = part:GetAttribute("RestC0")
		if type(anim) ~= "string" or typeof(rest) ~= "CFrame" then
			continue
		end
		local kind = KIND_CODES[anim]
		if not kind then
			continue
		end
		if part:GetAttribute("ParentAnim") ~= nil then
			table.insert(scratchChildren, child)
			continue
		end
		addEntry(rec, child, rest, kind, numberAttribute(part, "Side"), numberAttribute(part, "Index"), 0)
	end

	for _, weld in ipairs(scratchChildren) do
		local part = weld.Part1
		if not part then
			continue
		end
		local anim = part:GetAttribute("Anim")
		local rest = part:GetAttribute("RestC0")
		local parentAnim = part:GetAttribute("ParentAnim")
		if type(anim) ~= "string" or typeof(rest) ~= "CFrame" or type(parentAnim) ~= "string" then
			continue
		end
		local kind = KIND_CODES[anim]
		local parentKind = KIND_CODES[parentAnim]
		if not kind or not parentKind then
			continue
		end
		local parentSide = numberAttribute(part, "ParentSide")
		local parentIndex = numberAttribute(part, "ParentIndex")
		local parent = 0
		for j = 1, rec.count do
			if rec.parents[j] == 0 and rec.kinds[j] == parentKind and rec.sides[j] == parentSide and rec.indices[j] == parentIndex then
				parent = j
				break
			end
		end
		-- Parent pas encore répliqué : DescendantAdded relancera un rebuild à son arrivée.
		if parent > 0 then
			addEntry(rec, weld, rec.rests[parent]:Inverse() * rest, kind, numberAttribute(part, "Side"), numberAttribute(part, "Index"), parent)
		end
	end
	table.clear(scratchChildren)
end

local function animate(rec: Record, root: BasePart, now: number)
	local elapsed = now - rec.last
	rec.last = now
	local dt = math.min(elapsed, 0.1)
	local t = now + rec.seed
	local species = rec.species

	-- Vitesse mesurée sur la Root (3D : grimper un tronc ou nager compte comme avancer).
	local position = root.Position
	local lastPos = rec.lastPos
	rec.lastPos = position
	if lastPos and elapsed > 0 and elapsed < 0.5 then
		local delta = position - lastPos
		local speed = delta.Magnitude / elapsed
		local climb = delta.Y / elapsed
		if speed < MAX_SPEED then
			local a = math.min(1, dt * 5)
			rec.speed += (speed - rec.speed) * a
			rec.climb += (climb - rec.climb) * a
		end
	end
	local speed, climb = rec.speed, rec.climb

	local alpha = math.min(1, dt * 6)
	-- Oiseau : au-delà d'une marche rapide, il vole (perché / picorant = immobile).
	local airborne = species == S_BIRD and speed > 8
	rec.air += ((if airborne then 1 else 0) - rec.air) * alpha
	local air = rec.air
	rec.move += ((if airborne then 0 else math.min(1, speed / rec.walkRef)) - rec.move) * alpha
	local move = rec.move

	rec.gait = (rec.gait + dt * math.min(rec.gaitBase + speed * rec.gaitGain, rec.gaitMax)) % TWO_PI
	local gait = rec.gait
	local breath = math.sin(t * rec.breathRate)

	-- Ailes : bat plus vite en montée ; en descente / piqué, il plane (amplitude réduite).
	local flapAmp = 0.8
	if species == S_BIRD then
		local wingRate = math.min(9 + speed * 0.12 + math.max(climb, 0) * 0.4, 22)
		rec.wingPhase = (rec.wingPhase + dt * wingRate) % TWO_PI
		flapAmp = 0.8 - 0.55 * math.clamp(-climb / 15, 0, 1)
	elseif species == S_FISH then
		rec.wingPhase = (rec.wingPhase + dt * (5 + speed * 0.3)) % TWO_PI -- battement des pectorales
	end
	local wingPhase = rec.wingPhase

	-- Coups d'oeil : la tête se tourne par à-coups (moins en marchant).
	if rec.headRange > 0 then
		if now >= rec.nextHead then
			rec.headTarget = (math.random() - 0.5) * rec.headRange * (1 - 0.7 * move) * (1 - air)
			rec.nextHead = now + rec.headPause + math.random() * 2
		end
		rec.headYaw += (rec.headTarget - rec.headYaw) * math.min(1, dt * rec.headSnap)
	end
	local headYaw = rec.headYaw

	-- Caméléon : chaque oeil vise sa propre cible (saccades indépendantes).
	if species == S_CHAMELEON then
		local eyeAlpha = math.min(1, dt * 8)
		for slot = 1, 2 do
			if now >= rec.eyeNext[slot] then
				rec.eyeTargetYaw[slot] = (math.random() - 0.5) * 1.4
				rec.eyeTargetPitch[slot] = (math.random() - 0.5) * 0.8
				rec.eyeNext[slot] = now + 0.6 + math.random() * 1.8
			end
			rec.eyeYaw[slot] += (rec.eyeTargetYaw[slot] - rec.eyeYaw[slot]) * eyeAlpha
			rec.eyePitch[slot] += (rec.eyeTargetPitch[slot] - rec.eyePitch[slot]) * eyeAlpha
		end
	end

	-- Crabe : claquement d'une pince à la fois, plus fréquent quand il se déplace (chasse).
	local snapOpen = 0
	local snapSide = rec.snapSide
	if species == S_CRAB then
		if now >= rec.nextSnap then
			rec.snapAt = now
			rec.snapSide = -rec.snapSide
			snapSide = rec.snapSide
			rec.nextSnap = now + (if move > 0.3 then 0.8 else 2) + math.random() * 2.5
		end
		local u = (now - rec.snapAt) / SNAP_DURATION
		if u >= 0 and u < 1 then
			-- S'ouvre, claque au-delà du repos, revient.
			if u < 0.55 then
				snapOpen = 0.55 * u / 0.55
			elseif u < 0.7 then
				snapOpen = 0.55 - 0.65 * (u - 0.55) / 0.15
			else
				snapOpen = -0.1 * (1 - (u - 0.7) / 0.3)
			end
		end
	end

	-- Poisson : vague du corps (queue, tête en contre-phase, nageoires impaires en retard).
	local tailAmp = 0.18 + 0.3 * math.min(1, speed / 12)
	local wave = math.sin(gait)

	local count = rec.count
	local welds = rec.welds
	local rests = rec.rests
	local kinds = rec.kinds
	local sides = rec.sides
	local indices = rec.indices
	local parents = rec.parents
	local deltas = rec.deltas
	local lastKind, lastSide, lastIndex = 0, 0, 0
	local rot = CFrame.identity
	for i = 1, count do
		local kind, side, index = kinds[i], sides[i], indices[i]
		-- Les parts d'un même membre se suivent : rotation recalculée seulement au changement de membre.
		if kind ~= lastKind or side ~= lastSide or index ~= lastIndex then
			lastKind, lastSide, lastIndex = kind, side, index
			if kind == K_LEG then
				if species == S_CRAB then
					-- Tétrapodes alternés ; patte vers l'extérieur : balayage Y, levée Z.
					local phase = gait + (if (index + (if side > 0 then 1 else 0)) % 2 == 0 then 0 else math.pi)
					rot = CFrame.Angles(0, side * 0.3 * math.sin(phase) * move, side * (0.3 * math.max(0, math.cos(phase)) * move + 0.02 * breath))
				elseif species == S_BIRD then
					-- Sautille pieds joints au sol ; en vol, pattes repliées vers l'arrière.
					local hop = 0.35 * math.sin(gait) * move
					rot = CFrame.Angles(hop - 0.9 * air, 0, side * 0.1 * air)
				elseif species == S_SQUIRREL then
					-- Bonds : avant puis arrière, les deux côtés ensemble.
					local phase = gait + (if index == 2 then math.pi else 0)
					rot = CFrame.Angles(0.55 * math.sin(phase) * move, 0, side * 0.12 * math.max(0, math.cos(phase)) * move)
				else
					-- Diagonale (caméléon) : avant-gauche avec arrière-droite.
					local phase = gait + (if side > 0 then math.pi else 0) + (if index == 2 then math.pi else 0)
					rot = CFrame.Angles(0.35 * math.sin(phase) * move, 0, side * 0.2 * math.max(0, math.cos(phase)) * move)
				end
			elseif kind == K_WING then
				-- Déploiement (Y, vers l'extérieur) appliqué AVANT le battement (Z) ; replié au perchoir.
				local flap = air * (0.2 + flapAmp * math.sin(wingPhase)) + (1 - air) * 0.03 * breath
				rot = CFrame.Angles(0, 0, side * flap) * CFrame.Angles(0, side * 1.35 * air, 0)
			elseif kind == K_TAIL then
				if species == S_FISH then
					rot = CFrame.Angles(0, wave * tailAmp, 0)
				elseif species == S_BIRD then
					rot = CFrame.Angles(math.sin(t * 2) * 0.06 - 0.15 * air + 0.12 * math.sin(gait) * move, math.sin(t * 1.1) * 0.04, 0)
				elseif species == S_SQUIRREL then
					rot = CFrame.Angles(math.sin(t * 1.3) * 0.08 + 0.25 * math.sin(gait) * move, math.sin(t * 0.9) * 0.12, 0)
				else
					rot = CFrame.Angles(math.sin(t * 0.7) * 0.08, math.sin(t * 0.5) * 0.05 + math.sin(gait) * 0.08 * move, 0)
				end
			elseif kind == K_FIN then
				if index == 1 then
					rot = CFrame.Angles(0, side * (0.15 + 0.2 * math.sin(wingPhase)), side * 0.15 * math.sin(wingPhase + 1))
				elseif index == 2 then
					rot = CFrame.Angles(0, side * 0.1 * math.sin(wingPhase + 2), side * 0.08 * math.sin(wingPhase))
				else
					rot = CFrame.Angles(0, 0, math.sin(gait - 1) * 0.15)
				end
			elseif kind == K_CLAW then
				local open = if side == snapSide then snapOpen else 0
				if index == 1 then
					-- Bras : se lève avec le claquement, léger bercement au repos.
					rot = CFrame.Angles(math.sin(t * 1.2 + side) * 0.06 + 0.35 * math.max(open, 0) + 0.04 * breath, side * 0.05 * math.sin(gait) * move, 0)
				else
					-- Doigt mobile : s'ouvre vers le haut puis claque.
					rot = CFrame.Angles(0.06 + 0.03 * math.sin(t * 2.1 + side) + open, 0, 0)
				end
			elseif kind == K_HEAD then
				if species == S_FISH then
					rot = CFrame.Angles(0.03 * breath, -wave * tailAmp * 0.25, 0)
				else
					rot = CFrame.Angles(0.04 * breath + 0.05 * math.sin(gait * 2) * move, headYaw, 0)
				end
			elseif kind == K_EYE then
				if species == S_CHAMELEON then
					local slot = if side > 0 then 2 else 1
					rot = CFrame.Angles(rec.eyePitch[slot], rec.eyeYaw[slot], 0)
				else
					-- Pédoncules du crabe.
					rot = CFrame.Angles(math.sin(t * 1.7 + side) * 0.1, side * math.sin(t * 1.1 + side) * 0.1, 0)
				end
			else
				rot = CFrame.identity
			end
		end
		deltas[i] = rot
		local p = parents[i]
		if p > 0 then
			welds[i].C0 = rests[p] * deltas[p] * rests[i] * rot
		else
			welds[i].C0 = rests[i] * rot
		end
	end
end

local function untrack(instance: Instance)
	local rec = records[instance]
	if not rec then
		return
	end
	records[instance] = nil
	if rec.addConn then
		rec.addConn:Disconnect()
	end
	clearCache(rec)
end

local function track(instance: Instance)
	if records[instance] or not instance:IsA("Model") then
		return
	end
	local rec: Record = {
		model = instance :: Model,
		root = nil,
		humanoid = nil,
		addConn = nil,
		dirty = true,
		species = S_OTHER,
		fry = false,
		count = 0,
		welds = {},
		rests = {},
		kinds = {},
		sides = {},
		indices = {},
		parents = {},
		deltas = {},
		walkRef = 8,
		gaitBase = 4,
		gaitGain = 0.6,
		gaitMax = 16,
		breathRate = 1.5,
		headRange = 0,
		headPause = 1,
		headSnap = 1,
		seed = math.random() * 10,
		last = os.clock(),
		odd = math.random() < 0.5,
		lastPos = nil,
		speed = 0,
		climb = 0,
		move = 0,
		air = 0,
		gait = math.random() * TWO_PI,
		wingPhase = 0,
		headYaw = 0,
		headTarget = 0,
		nextHead = 0,
		eyeYaw = { 0, 0 },
		eyePitch = { 0, 0 },
		eyeTargetYaw = { 0, 0 },
		eyeTargetPitch = { 0, 0 },
		eyeNext = { 0, 0 },
		snapAt = -10,
		snapSide = 1,
		nextSnap = os.clock() + math.random() * 3,
	}
	records[instance] = rec
	-- Les parts et leurs Welds arrivent par vagues à la réplication (et au streaming).
	rec.addConn = instance.DescendantAdded:Connect(function()
		rec.dirty = true
	end)
end

local function onHeartbeat()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local now = os.clock()

	for instance, rec in records do
		local model = rec.model
		if not model.Parent then
			untrack(instance) -- statue retirée (les animaux tagués passent par le signal de tag)
			continue
		end
		local root = rec.root
		if not root or root.Parent ~= model then
			root = model.PrimaryPart
			rec.root = root
			rec.dirty = true
		end
		if not root then
			continue
		end
		local humanoid = rec.humanoid
		-- Mort : on fige la pose (le serveur détruit le modèle et pose la carcasse).
		if humanoid and humanoid.Parent == model and humanoid.Health <= 0 then
			continue
		end

		local offset = root.Position - cameraPosition
		local distanceSq = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
		if distanceSq > (if rec.fry then FRY_FAR_DISTANCE_SQ else FAR_DISTANCE_SQ) then
			rec.lastPos = nil -- pas de pic de vitesse au retour dans le champ
			continue
		end
		rec.odd = not rec.odd
		if distanceSq > NEAR_DISTANCE_SQ and rec.odd then
			continue
		end

		if rec.dirty then
			rebuild(rec)
		end
		if rec.count > 0 then
			animate(rec, root, now)
		end
	end
end

-- Statues de la galerie : pas de tag "Animal" (pas d'IA), mêmes modèles -> mêmes animations au repos.
local function watchGallery()
	local gallery = workspace:WaitForChild(GALLERY_FOLDER, 120)
	if not gallery then
		return
	end
	local animals = gallery:WaitForChild(GALLERY_ANIMALS, 60)
	if not animals then
		return
	end
	animals.ChildAdded:Connect(track)
	animals.ChildRemoved:Connect(untrack)
	for _, child in ipairs(animals:GetChildren()) do
		track(child)
	end
end

function AnimalAnimationController.Start()
	if started then
		return
	end
	started = true

	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
	for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
		track(instance)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
	task.spawn(watchGallery)
end

return AnimalAnimationController
