--!strict
-- InsectAnimationController.luau
-- Animation procédurale locale des insectes de TOUS les joueurs visibles et des Mamans PNJ (tag
-- "NpcMother", NpcMotherService) (StarterPlayerScripts.controllers).
-- Le serveur construit le conteneur "InsectVisual" (voir la CONVENTION D'ANIMATION en tête de
-- InsectVisualService) ; ici chaque client écrit Weld.C0 = RestC0 * rotation, toujours à partir du
-- repos (jamais d'accumulation). Rien n'est répliqué : c'est purement cosmétique.
--
-- Pattes : CINÉMATIQUE INVERSE (IK) procédurale. Chaque patte cherche son appui par raycast dans
-- le repère du corps (marche aussi au mur/plafond), reste plantée pendant que le corps avance, puis
-- fait un pas en arc (tripodes alternés) ; une IK à 2 os place le genou pour que le pied touche
-- exactement le sol, qu'il soit plus haut (marche, caillou) ou plus bas (creux, bord).
-- Mouvements : marche en tripodes alternés (vitesse), respiration + balancement des antennes,
-- battement d'ailes en l'air (repliées au sol), élytres ouverts en vol, brasses sous l'eau,
-- ondulation des larves, léger bercement de l'oeuf/du cocon, coup de mâchoires/pinces/queue
-- quand un joueur mord (remote AbilityCast pour soi, attribut LastAttackAt de la victime pour les autres).
--
-- Perf : aucun tableau alloué par frame, rien au-delà de FAR_DISTANCE, une frame sur deux au-delà
-- de NEAR_DISTANCE, une seule rotation calculée par membre (toutes ses parts la partagent).
-- Mamans PNJ : Root ancrée déplacée par CFrame (vitesse nulle), on déduit donc la vitesse du
-- déplacement de la Root entre deux mises à jour, lissé ; elles marchent toujours (jamais en vol).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)

local InsectAnimationController = {}

local CONTAINER_NAME = "InsectVisual"
-- Repos des parts NON étiquetées (oeuf/cocon), mémorisé côté client pour ne jamais relire un C0 déjà animé.
local LOCAL_REST_ATTRIBUTE = "AnimRestC0"
local NEAR_DISTANCE_SQ = 60 * 60 -- au-delà : une frame sur deux
local FAR_DISTANCE_SQ = 150 * 150 -- au-delà : plus animé du tout
-- Mamans PNJ : plus grosses (MOTHER_SCALE) et peu nombreuses -> visibles de plus loin.
local NPC_TAG = "NpcMother"
local WILD_TAG = "WildInsect" -- insectes sauvages PNJ (WildInsectService), animés comme les Mamans
local NPC_NEAR_DISTANCE_SQ = 60 * 60
local NPC_FAR_DISTANCE_SQ = 150 * 150
local MAX_SPEED = 150 -- au-delà : téléportation / réapparition, on ignore la mesure
local BITE_DURATION = 0.3
local BITE_LUNGE = 0.25 -- avancée du corps au claquement (fraction de l'échelle)
local BITE_DIP = 0.1 -- rad : la tête plonge vers la proie
local ZONE_REFRESH_PERIOD = 2
local TWO_PI = math.pi * 2

-- IK des pattes
local IK_RANGE_SQ = 60 * 60 -- au-delà : pattes au repos (pas de raycast)
local STEP_IDLE = 0.22 -- à l'arrêt : petits pas de recalage (fraction de la longueur de patte)
local STEP_MIN_DURATION = 0.03
-- Durée d'un pas = STRIDE_TIME * foulée / vitesse : un cycle (2 tripodes) laisse le corps avancer d'une
-- foulée pendant qu'un pied peut en rattraper ~1.5 -> les pattes ne prennent jamais de retard.
local STRIDE_TIME = 0.5
-- Ordre à respecter : appui accepté (REACH_OK) < pas d'urgence (REACH_STRETCH) < 1 (pied bloqué par l'IK).
local REACH_OK = 0.95
local REACH_STRETCH = 0.98
local STEP_MAX_DURATION = 0.2

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
local K_STATIC = 11 -- part sans articulation (thorax, tête...) : ne suit que la pose du corps / de la tête

-- Corps : suit le plan des pieds posés (pente, marche) et se tasse un peu à chaque pas.
-- Raide = petits angles plafonnés + lissage rapide (pas de ballottement).
local BODY_TILT = 0.7 -- fraction de la pente des pieds reprise par le corps
local BODY_MAX_TILT = 0.3 -- rad
local BODY_STIFFNESS = 10
-- Tête du joueur local : suit un peu la caméra (fraction de l'angle, plafonnée).
local HEAD_FOLLOW = 0.45
local HEAD_MAX_YAW = 0.5
local HEAD_MAX_PITCH = 0.3
local HEAD_RATE = 8
-- Scolopendre : pliage max entre deux anneaux voisins (rad). Plus petit = corps plus raide.
local SEGMENT_MAX_BEND = 0.28
-- Parts non étiquetées qui appartiennent à la tête (les antennes / mâchoires le sont par leur Anim).
local HEAD_NAMES: { [string]: boolean } = {
	Head = true,
	LarvaHead = true,
	NymphHead = true,
	GrubHead = true,
	CaterpillarHead = true,
	Muzzle = true,
	Clypeus = true,
	Ocellus = true,
	Eye = true,
	EyeMain = true,
	EyeSide = true,
	EyeShine = true,
	HeadHorn = true,
	HornTooth = true,
	Proboscis = true,
	Rostrum = true,
	GlueNozzle = true,
	GlueDrop = true,
	Pedipalp = true,
	Mask = true,
	MouthBrush = true,
}

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

type IKLeg = {
	group: number, -- 0 / 1 : tripodes alternés
	side: number,
	index: number, -- n° de paire (= n° d'anneau chez la scolopendre)
	neighbors: { IKLeg }, -- corps segmenté : pattes qui ne doivent pas lever en même temps (vague)
	lastHome: Vector3?, -- point d'appui de repos au frame précédent (vitesse mesurée)
	homeVel: Vector3,
	upperWelds: { Weld },
	upperRests: { CFrame },
	lowerWelds: { Weld },
	lowerRests: { CFrame },
	hip: Vector3, -- articulation de la hanche (repère du root, échelle actuelle)
	knee: Vector3, -- offset hanche -> genou au repos
	toe: Vector3, -- offset hanche -> pointe du pied au repos
	pole: Vector3, -- direction de pliage du genou (perpendiculaire à hanche -> pied au repos)
	a: number, -- longueur hanche -> genou
	b: number, -- longueur genou -> pied
	foot: Vector3?, -- position monde du pied (planté ou en vol)
	stepping: boolean,
	stepT: number,
	stepDuration: number,
	stepFrom: Vector3,
	stepTo: Vector3,
	stepArc: number,
	planted: boolean, -- false après un vol / une nage / un vide : un pas d'atterrissage le replante
	upperBasis: CFrame, -- inverse du repère (corde, normale du plan de patte) au repos
	lowerBasis: CFrame,
}

type Record = {
	player: Player?, -- nil pour une Maman PNJ
	character: Model,
	nearSq: number,
	farSq: number,
	lastPos: Vector3?, -- PNJ : vitesse mesurée sur la Root ancrée
	speed: number,
	root: BasePart?,
	humanoid: Humanoid?,
	container: Instance?,
	charConn: RBXScriptConnection?,
	containerConn: RBXScriptConnection?,
	attackConn: RBXScriptConnection?,
	dirty: boolean,
	whole: boolean, -- oeuf/cocon : tout le visuel se berce d'un bloc
	wantWhole: boolean, -- stade du conteneur lié (fixe : un nouveau stade = un nouveau conteneur)
	-- Cache en tableaux parallèles (une entrée par part animée).
	count: number,
	welds: { Weld },
	rests: { CFrame },
	kinds: { number },
	sides: { number },
	indices: { number },
	spreads: { number }, -- ailes : angle Y (signé) pour les déployer sur le côté
	biases: { number }, -- ailes : centre du battement
	heads: { boolean }, -- part portée par la tête (tourne avec le cou)
	neck: Vector3?, -- pivot du cou (repère du root), nil = pas de tête animable
	bodyHeight: number,
	bodyPitch: number,
	bodyRoll: number,
	headYaw: number,
	headPitch: number,
	drawnBody: Vector3?, -- dernière pose écrite sur les parts fixes (nil = à réécrire)
	drawnHead: Vector3,
	-- Corps segmenté (scolopendre) : chaque anneau suit le chemin de la tête (follow-the-leader).
	segmented: boolean,
	segCount: number,
	segLeader: Vector3, -- centre de l'anneau 1 au repos (repère du root), rigide avec le root
	segDist: { number }, -- distance de chaque anneau derrière l'anneau 1, le long du chemin
	segOf: { number }, -- anneau qui porte la part (0 = aucun)
	segFrames: { CFrame }, -- transformation de chaque anneau dans le repère du root
	trailPos: { Vector3 }, -- chemin de la tête (le plus récent en premier)
	trailUp: { Vector3 },
	trailSpacing: number,
	trailCap: number,
	segRoot: CFrame?, -- root au dernier calcul des anneaux (immobile => rien à recalculer)
	segMoved: boolean,
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
	legs: { IKLeg },
	walkOnWater: boolean, -- gerris : les pattes prennent appui sur la surface de l'étang
	distSq: number,
	velocity: Vector3,
	lastRot: CFrame?,
	omega: Vector3, -- vitesse angulaire mesurée (la Root d'un grimpeur / d'une PNJ n'en a pas)
}

-- Clé = Player pour un joueur, Model pour une Maman PNJ.
local records: { [Instance]: Record } = {}
local started = false

local pondZones: { Instance } = {}
local nextZoneRefresh = 0
local frameWaterLevel: number? = nil
local frameWind = Vector3.zero

-- Tables de travail réutilisées par rebuild (clé = Side * 10 + Index).
local scratchSpread: { [number]: number } = {}
local scratchBias: { [number]: number } = {}
local scratchLegs: { [number]: IKLeg } = {}
local scratchSegments: { [number]: Vector3 } = {}

-- Rayons des pieds : ignorent TOUS les personnages animés (sinon un pied se pose sur la Root d'un voisin).
local legRayParams = RaycastParams.new()
legRayParams.FilterType = Enum.RaycastFilterType.Exclude
legRayParams.IgnoreWater = true
legRayParams.RespectCanCollide = true
local rayFilter: { Instance } = {}

-- Repère d'un segment de patte : X = corde, Z = normale du plan de la patte (sans roulis parasite).
local function legFrame(chord: Vector3, normal: Vector3): CFrame
	local x = chord.Unit
	local n = (normal - x * normal:Dot(x)).Unit
	return CFrame.fromMatrix(Vector3.zero, x, n:Cross(x), n)
end

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
	table.clear(rec.heads)
	table.clear(rec.legs)
	rec.neck = nil
	rec.drawnBody = nil
	table.clear(rec.segDist)
	table.clear(rec.segOf)
	table.clear(rec.segFrames)
	table.clear(rec.trailPos)
	table.clear(rec.trailUp)
	rec.segmented = false
	rec.segCount = 0
	rec.segRoot = nil
	rec.segMoved = true
end

-- Reconstruit le cache depuis le conteneur (appelé seulement quand il change : jamais par frame).
local function rebuild(rec: Record, whole: boolean)
	-- Remet d'abord au repos ce qu'on animait : une part qui sort du cache ne reste pas tordue.
	for i = 1, rec.count do
		rec.welds[i].C0 = rec.rests[i]
	end
	for _, leg in ipairs(rec.legs) do
		for i, weld in ipairs(leg.upperWelds) do
			weld.C0 = leg.upperRests[i]
		end
		for i, weld in ipairs(leg.lowerWelds) do
			weld.C0 = leg.lowerRests[i]
		end
	end
	clearCache(rec)
	rec.dirty = false
	rec.whole = whole

	local container = rec.container
	if not container then
		return
	end

	local player = rec.player
	local species = if player then player:GetAttribute("Species") else rec.character:GetAttribute("SpeciesId")
	local plan = InsectBodyPlans.Get(if type(species) == "string" then species else "")
	local wings = plan.Wings
	rec.scorpion = plan.Tail == "ScorpionTail"
	rec.wingRate = if wings == "Butterfly" then 14 elseif wings == "Mayfly" then 28 elseif wings == "Dragonfly" then 45 else 65
	rec.wingIdle = if wings == "Butterfly" then 0.3 else 0
	local info = InsectData[if type(species) == "string" then species else ""]
	rec.walkOnWater = info ~= nil and info.CanWalkOnWater
	-- ScaleTo (transition de stade) met à l'échelle C0/C1 des Welds mais PAS l'attribut RestC0 :
	-- on ramène donc les repos de l'échelle de construction ("AnimScale") à l'échelle actuelle.
	local scale = rec.character:GetScale()
	local authored = container:GetAttribute("AnimScale")
	local authorScale: number = if type(authored) == "number" and authored > 0 then authored else scale
	local ratio = scale / authorScale
	rec.scale = scale

	table.clear(scratchSpread)
	table.clear(scratchBias)
	table.clear(scratchLegs)
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
		-- Mue : la vieille peau reste posée au sol à côté, elle ne suit pas le corps.
		if child.Name == "Exuviae" then
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
		if code == 0 then
			restCf = nil -- étiquette inconnue : traitée comme une part fixe (C0 = offset complet)
		end
		if whole or code == 0 then
			code = if whole then K_WHOLE else K_STATIC
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

		-- Patte à IK : rangée dans sa structure de patte, pas dans le cache générique.
		local segment = child:GetAttribute("LegSeg")
		if code == K_LEG and (segment == "Upper" or segment == "Lower") then
			maxLegIndex = math.max(maxLegIndex, index)
			local key = side * 10 + index
			local leg = scratchLegs[key]
			if not leg then
				leg = {
					group = (index + (if side > 0 then 1 else 0)) % 2,
					side = side,
					index = index,
					neighbors = {},
					lastHome = nil,
					homeVel = Vector3.zero,
					upperWelds = {},
					upperRests = {},
					lowerWelds = {},
					lowerRests = {},
					hip = restCf.Position,
					knee = Vector3.zero,
					toe = Vector3.zero,
					pole = Vector3.yAxis,
					a = 0,
					b = 0,
					foot = nil,
					stepping = false,
					stepT = 0,
					stepDuration = STEP_MAX_DURATION,
					stepFrom = Vector3.zero,
					stepTo = Vector3.zero,
					stepArc = 0,
					planted = false,
					upperBasis = CFrame.identity,
					lowerBasis = CFrame.identity,
				}
				scratchLegs[key] = leg
			end
			local ikLeg = leg :: IKLeg
			if segment == "Upper" then
				table.insert(ikLeg.upperWelds, weld)
				table.insert(ikLeg.upperRests, restCf)
			else
				table.insert(ikLeg.lowerWelds, weld)
				table.insert(ikLeg.lowerRests, restCf)
			end
			local kneeOffset = child:GetAttribute("IKKnee")
			local toeOffset = child:GetAttribute("IKToe")
			if typeof(kneeOffset) == "Vector3" and typeof(toeOffset) == "Vector3" then
				ikLeg.knee = kneeOffset * ratio
				ikLeg.toe = toeOffset * ratio
			end
			continue
		end
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
		if code == K_SEGMENT and not scratchSegments[index] then
			scratchSegments[index] = restCf.Position
		end
		local onHead = HEAD_NAMES[child.Name] == true or code == K_ANTENNA or code == K_JAW
		rec.heads[count] = onHead
		if onHead and code == K_STATIC and not rec.neck and string.sub(child.Name, -4) == "Head" then
			-- Cou : arrière de la tête (l'avant regarde -Z).
			rec.neck = restCf.Position + Vector3.new(0, 0, child.Size.Z * 0.4)
		end
	end
	rec.count = count
	for _, leg in pairs(scratchLegs) do
		local a = leg.knee.Magnitude
		local b = (leg.toe - leg.knee).Magnitude
		-- > 0.01 : sinon le min de math.clamp dans solveLeg dépasse son max (erreur à chaque frame).
		if a > 0.01 and b > 0.01 and leg.toe.Magnitude > 1e-3 then
			leg.a = a
			leg.b = b
			local restDir = leg.toe.Unit
			local pole = leg.knee - restDir * leg.knee:Dot(restDir)
			-- Patte droite au repos : n'importe quelle perpendiculaire (le pôle doit rester ⟂ à la corde).
			leg.pole = if pole.Magnitude > 1e-3
				then pole.Unit
				else restDir:Cross(if math.abs(restDir.X) < 0.9 then Vector3.xAxis else Vector3.yAxis).Unit
			local normal = leg.pole:Cross(restDir)
			leg.upperBasis = legFrame(leg.knee, normal):Inverse()
			leg.lowerBasis = legFrame(leg.toe - leg.knee, normal):Inverse()
			table.insert(rec.legs, leg)
		end
	end
	table.clear(scratchLegs)
	rec.manyLegs = maxLegIndex > 4 -- scolopendre : vague le long du corps plutôt que tripodes

	-- Corps segmenté (anneaux 1..n consécutifs + pattes à IK) : chaque anneau suivra le chemin de la tête.
	local segCount = 0
	while scratchSegments[segCount + 1] do
		segCount += 1
	end
	rec.segmented = segCount >= 3 and #rec.legs > 0
	if rec.segmented then
		local leader = scratchSegments[1]
		rec.segLeader = leader
		rec.segCount = segCount
		for k = 1, segCount do
			rec.segDist[k] = math.max(0, scratchSegments[k].Z - leader.Z)
			rec.segFrames[k] = CFrame.identity
		end
		local length = rec.segDist[segCount]
		rec.trailSpacing = math.max(0.02, length / (segCount - 1) * 0.5)
		rec.trailCap = math.ceil(length / rec.trailSpacing) + 6
		-- Pattes voisines (vis-à-vis + même côté, anneaux ±1) : jamais levées ensemble -> vague.
		local byKey: { [number]: IKLeg } = {}
		for _, leg in ipairs(rec.legs) do
			byKey[leg.index * 2 + (if leg.side > 0 then 1 else 0)] = leg
		end
		for _, leg in ipairs(rec.legs) do
			local own = if leg.side > 0 then 1 else 0
			for _, key in ipairs({ leg.index * 2 + 1 - own, (leg.index - 1) * 2 + own, (leg.index + 1) * 2 + own }) do
				local other = byKey[key]
				if other then
					table.insert(leg.neighbors, other)
				end
			end
		end
	end
	for i = 1, count do
		local kind, index = rec.kinds[i], rec.indices[i]
		rec.segOf[i] = if not rec.segmented
			then 0
			elseif kind == K_TAIL then segCount
			elseif (kind == K_SEGMENT or kind == K_LEG) and index >= 1 and index <= segCount then index
			else 0
	end
	table.clear(scratchSegments)
end

-- IK à 2 os (hanche -> genou -> pied) puis écriture des Welds : C0 = M * repos, où M est la
-- transformation rigide du segment dans le repère du root.
local function solveLeg(leg: IKLeg, footLocal: Vector3, body: CFrame)
	local hip, a, b = leg.hip, leg.a, leg.b
	local toHip = footLocal - hip
	local distance = toHip.Magnitude
	local direction = if distance > 1e-4 then toHip / distance else leg.toe.Unit
	distance = math.clamp(distance, math.abs(a - b) + 0.01, a + b - 0.001)
	-- Genou plié du même côté qu'au repos (vers le haut / l'extérieur).
	local pole = leg.pole - direction * leg.pole:Dot(direction)
	if pole.Magnitude < 1e-3 then
		pole = Vector3.yAxis - direction * direction.Y
	end
	pole = if pole.Magnitude > 1e-4 then pole.Unit else Vector3.xAxis
	local cosine = math.clamp((a * a + distance * distance - b * b) / (2 * a * distance), -1, 1)
	local sine = math.sqrt(1 - cosine * cosine)
	local knee = hip + direction * (a * cosine) + pole * (a * sine)
	local foot = hip + direction * distance

	-- Rotation de chaque segment = repère résolu * inverse du repère de repos (corde + plan de la patte).
	local normal = pole:Cross(direction)
	local upper = body * CFrame.new(hip) * legFrame(knee - hip, normal) * leg.upperBasis * CFrame.new(-hip)
	local lower = body * CFrame.new(knee) * legFrame(foot - knee, normal) * leg.lowerBasis * CFrame.new(-(hip + leg.knee))
	for i, weld in ipairs(leg.upperWelds) do
		weld.C0 = upper * leg.upperRests[i]
	end
	for i, weld in ipairs(leg.lowerWelds) do
		weld.C0 = lower * leg.lowerRests[i]
	end
end

-- Appui sous `from` à portée de `anchor` (la hanche, ou sa position prévue à l'atterrissage du pas),
-- ou nil (vide, bord, trop bas pour la patte).
local function groundBelow(rec: Record, from: Vector3, hip: Vector3, anchor: Vector3, up: Vector3, reach: number): Vector3?
	-- Le rayon part de la hanche vers le haut du pied : sous une feuille / un surplomb, il ne passe pas au-dessus.
	local start = from + up * (reach * 0.9)
	local rise = start - hip
	if rise.Magnitude > 1e-3 then
		local block = workspace:Raycast(hip, rise, legRayParams)
		if block then
			start = block.Position - rise.Unit * 0.05
		end
	end
	local direction = up * (-reach * 1.9)
	local hit = workspace:Raycast(start, direction, legRayParams)
	local position = if hit then hit.Position else nil
	-- Gerris : la surface de l'étang porte (le flotteur de SwimController n'existe que chez son propriétaire).
	local level = frameWaterLevel
	if rec.walkOnWater and level and up.Y > 0.8 then
		local t = (level - start.Y) / direction.Y
		if t >= 0 and t <= 1 and (position == nil or position.Y < level) and isInPondZone(start) then
			position = start + direction * t
		end
	end
	if position and (position - anchor).Magnitude <= reach * REACH_OK then
		return position
	end
	return nil
end

-- Pas planté / pas en arc pour chaque patte, puis IK. `grounded` = corps posé (sol, mur, plafond).
local function updateLegs(rec: Record, root: BasePart, dt: number, elapsed: number, air: number, swim: number, body: CFrame)
	local legs = rec.legs
	if #legs == 0 then
		return
	end
	local segmented = rec.segmented
	local segFrames = rec.segFrames
	if rec.distSq > IK_RANGE_SQ then
		-- Loin : pattes au repos, aucun raycast (une seule écriture, sauf anneaux qui bougent encore).
		for _, leg in ipairs(legs) do
			if leg.foot ~= nil or (segmented and rec.segMoved) then
				leg.foot = nil
				leg.stepping = false
				leg.planted = false
				leg.lastHome = nil
				local frame = if segmented then segFrames[leg.index] or CFrame.identity else CFrame.identity
				for i, weld in ipairs(leg.upperWelds) do
					weld.C0 = frame * leg.upperRests[i]
				end
				for i, weld in ipairs(leg.lowerWelds) do
					weld.C0 = frame * leg.lowerRests[i]
				end
			end
		end
		return
	end

	-- Hanches dans le repère du CORPS (incliné / tassé) ; sondes du sol selon le vrai haut du root.
	local rootCFrame = root.CFrame * body
	local rootPosition = rootCFrame.Position
	local rootUp = root.CFrame.UpVector
	local rootBack = -root.CFrame.LookVector
	local grounded = air < 0.5 and swim < 0.5
	local velocity = rec.velocity
	local omega = rec.omega
	local busy0, busy1 = 0, 0
	for _, leg in ipairs(legs) do
		if leg.stepping then
			if leg.group == 0 then
				busy0 += 1
			else
				busy1 += 1
			end
		end
	end

	for _, leg in ipairs(legs) do
		local reach = leg.a + leg.b
		-- Corps segmenté : la patte suit SON anneau (repère, haut et vitesse propres).
		local legBody = if segmented then segFrames[leg.index] or body else body
		local frame = if segmented then root.CFrame * legBody else rootCFrame
		local up = if segmented then frame.UpVector else rootUp
		local back = if segmented then -frame.LookVector else rootBack
		local hipWorld = frame * leg.hip
		local homeWorld = frame * (leg.hip + leg.toe)
		local lastHome = leg.lastHome
		leg.lastHome = homeWorld
		if lastHome and elapsed > 0 and elapsed < 0.5 and (homeWorld - lastHome).Magnitude < reach * 6 then
			-- PNJ : Root ancrée répliquée par à-coups -> lissage lent, comme rec.velocity.
			local rate = if rec.player then 12 else 5
			leg.homeVel = leg.homeVel:Lerp((homeWorld - lastHome) / elapsed, math.min(1, dt * rate))
		else
			leg.homeVel = Vector3.zero
		end
		local current: Vector3

		if not grounded then
			-- En vol : pattes pendantes, traînées vers l'arrière. À la nage : les tripodes rament en alternance.
			local stroke = if swim > 0.01 then math.sin(rec.gait + leg.group * math.pi) * reach * 0.4 * swim else 0
			local tucked = homeWorld:Lerp(hipWorld, 0.3) - up * (reach * 0.35 * air) + back * (reach * 0.25 * air + stroke)
			current = (leg.foot or tucked):Lerp(tucked, math.min(1, dt * 12))
			leg.stepping = false
			leg.planted = false
		elseif leg.stepping then
			leg.stepT += dt / leg.stepDuration
			local t = math.min(1, leg.stepT)
			local ease = t * t * (3 - 2 * t)
			current = leg.stepFrom:Lerp(leg.stepTo, ease) + up * (math.sin(math.pi * t) * leg.stepArc)
			if t >= 1 then
				leg.stepping = false
				leg.planted = true
				current = leg.stepTo
				if leg.group == 0 then
					busy0 -= 1
				else
					busy1 -= 1
				end
			end
		else
			-- Bord / trou : la patte agrippe la lèvre plus près du corps.
			local ground = groundBelow(rec, homeWorld, hipWorld, hipWorld, up, reach)
				or groundBelow(rec, homeWorld:Lerp(hipWorld, 0.5), hipWorld, hipWorld, up, reach)
			local foot = leg.foot
			if not ground and foot and leg.planted and (foot - hipWorld).Magnitude <= reach then
				-- Sonde ratée (relief, bord) mais pied encore à portée : il reste planté au lieu de flotter.
				current = foot
			elseif not ground then
				-- Rien à portée : la patte pend dans le vide.
				local hang = homeWorld:Lerp(hipWorld, 0.3) - up * (reach * 0.3)
				current = (foot or hang):Lerp(hang, math.min(1, dt * 8))
				leg.planted = false
			elseif not foot then
				current = ground
				leg.planted = true
			else
				current = foot
				local stepTarget: Vector3? = nil
				local duration, arc = 0, 0
				if not leg.planted then
					-- Atterrissage (après un saut, la nage ou un vide) : pas immédiat, hors cadence des tripodes.
					stepTarget, duration, arc = ground, 0.08, reach * 0.1
				else
					local offset = ground - foot
					local along = offset:Dot(up)
					local planar = offset - up * along
					local drift = planar.Magnitude
					if drift > reach * 6 then
						current = ground -- téléportation / réapparition : on replante directement
					else
						-- Vitesse du point d'attache : translation + rotation du corps (virage sur place).
						local homeVelocity = if segmented
							then leg.homeVel
							else velocity + omega:Cross(homeWorld - rootPosition)
						homeVelocity -= up * homeVelocity:Dot(up)
						local homeSpeed = homeVelocity.Magnitude
						local moving = homeSpeed > 0.4
						local stride = if moving
							then math.clamp(homeSpeed * 0.11, reach * 0.5, reach)
							else reach * STEP_IDLE * 2
						local stepDistance = stride * 0.5
						local heading = if moving then homeVelocity / homeSpeed else Vector3.zero
						-- En marche, seul le retard compte : un pied posé devant attend que le corps le dépasse.
						local late = if moving
							then planar:Dot(heading) > stepDistance or drift > stride
							else drift > stepDistance
						-- Patte trop tendue : elle part tout de suite, sans attendre l'autre tripode (sinon elle traîne).
						local overstretched = (foot - hipWorld).Magnitude > reach * REACH_STRETCH
						-- Tripodes : l'autre groupe doit être posé. Corps segmenté : seulement les voisines (vague).
						local free = (if leg.group == 0 then busy1 else busy0) == 0
						if segmented then
							free = true
							for _, other in ipairs(leg.neighbors) do
								if other.stepping then
									free = false
									break
								end
							end
						end
						if overstretched or ((late or math.abs(along) > reach * 0.6) and free) then
							-- Le pied se pose une demi-foulée DEVANT l'endroit où sera la hanche à l'atterrissage.
							duration = if moving
								then math.clamp(stride * STRIDE_TIME / homeSpeed, STEP_MIN_DURATION, STEP_MAX_DURATION)
								else 0.16
							local travel = homeVelocity * duration
							local landingHip = hipWorld + travel
							local landingHome = homeWorld + travel
							local aim = landingHome + heading * stepDistance
							-- Portée jugée depuis la hanche À L'ATTERRISSAGE ; repli progressif vers le repos prévu,
							-- jamais directement sous la hanche actuelle (le pied retomberait déjà en retard).
							local target = groundBelow(rec, aim, hipWorld, landingHip, up, reach)
								or groundBelow(rec, aim:Lerp(landingHome, 0.5), hipWorld, landingHip, up, reach)
								or groundBelow(rec, landingHome, hipWorld, landingHip, up, reach)
								or ground
							if (target - foot).Magnitude > reach * 0.08 then
								stepTarget = target
								arc = math.clamp(drift * 0.45, reach * 0.12, reach * 0.45)
									+ math.max(0, (target - foot):Dot(up))
							end
						end
					end
				end
				if stepTarget then
					leg.stepFrom = foot
					leg.stepTo = stepTarget
					leg.stepT = 0
					leg.stepDuration = duration
					leg.stepArc = arc
					leg.stepping = true
					if leg.group == 0 then
						busy0 += 1
					else
						busy1 += 1
					end
				end
			end
		end
		leg.foot = current
		solveLeg(leg, frame:PointToObjectSpace(current), legBody)
	end
end

-- Point (et normale) à la distance `d` derrière le meneur, le long du chemin de la tête.
local function trailPoint(rec: Record, leader: Vector3, up: Vector3, d: number): (Vector3, Vector3)
	local prev, prevUp = leader, up
	local trail, ups = rec.trailPos, rec.trailUp
	for k = 1, #trail do
		local point, pointUp = trail[k], ups[k]
		local len = (point - prev).Magnitude
		if d <= len then
			local t = if len > 1e-6 then d / len else 0
			return prev:Lerp(point, t), prevUp:Lerp(pointUp, t)
		end
		d -= len
		prev, prevUp = point, pointUp
	end
	-- Au-delà du chemin mémorisé : prolongé tout droit.
	local before = if #trail >= 2 then trail[#trail - 1] else leader
	local direction = prev - before
	return (if direction.Magnitude > 1e-6 then prev + direction.Unit * d else prev), prevUp
end

-- Follow-the-leader : l'anneau 1 est rigide avec le root (la tête mène), chaque anneau suivant se
-- place là où est passée la tête, orienté le long du chemin (il prend les coins mur/sol un par un).
local function updateSegments(rec: Record, root: BasePart, fresh: boolean)
	local rootCFrame = root.CFrame
	local leaderRest = rec.segLeader
	local leader = rootCFrame * leaderRest
	local up = rootCFrame.UpVector
	local trail, ups = rec.trailPos, rec.trailUp
	local spacing = rec.trailSpacing
	local count = rec.segCount
	local dist = rec.segDist
	local length = dist[count]
	local lastRoot = rec.segRoot
	rec.segRoot = rootCFrame
	rec.segMoved = fresh or lastRoot == nil or not rootCFrame:FuzzyEq(lastRoot, 1e-4)
	if not rec.segMoved then
		return -- immobile : anneaux inchangés
	end
	if fresh or #trail == 0 or (leader - trail[1]).Magnitude > length then
		for _, leg in ipairs(rec.legs) do
			leg.lastHome = nil -- pas de pic de vitesse mesurée au recalage
		end
		-- Apparition / retour dans le champ / téléportation : corps droit derrière la tête.
		table.clear(trail)
		table.clear(ups)
		local back = -rootCFrame.LookVector
		for k = 1, rec.trailCap do
			trail[k] = leader + back * (k * spacing)
			ups[k] = up
		end
	else
		-- Marche arrière : la tête recule sur son propre chemin -> on le raccourcit devant et on le
		-- prolonge derrière (le corps est repoussé le long du chemin au lieu de se replier).
		while #trail >= 2 and (leader - trail[1]):Dot(trail[1] - trail[2]) < 0 do
			table.remove(trail, 1)
			table.remove(ups, 1)
			local last = trail[#trail]
			local before = if #trail >= 2 then trail[#trail - 1] else leader
			local direction = last - before
			trail[#trail + 1] = if direction.Magnitude > 1e-6 then last + direction.Unit * spacing else last
			ups[#ups + 1] = ups[#ups]
		end
	end
	if (leader - trail[1]).Magnitude >= spacing then
		table.insert(trail, 1, leader)
		table.insert(ups, 1, up)
		if #trail > rec.trailCap then
			trail[#trail] = nil
			ups[#ups] = nil
		end
	end
	local inverse = rootCFrame:Inverse()
	local frames = rec.segFrames
	frames[1] = CFrame.identity
	-- Chaîne RIGIDE : chaque anneau vise le chemin de la tête, mais reste à distance fixe du
	-- précédent et ne plie pas plus de SEGMENT_MAX_BEND par articulation (corps de scolopendre raide).
	local previousUp = up
	local previousPos = leader
	local previousDir = rootCFrame.LookVector
	for k = 2, count do
		local d = dist[k]
		local position, pointUp = trailPoint(rec, leader, up, d)
		local toPrevious = previousPos - position
		local tangent = if toPrevious.Magnitude > 1e-5 then toPrevious.Unit else previousDir
		local bend = math.acos(math.clamp(previousDir:Dot(tangent), -1, 1))
		if bend > SEGMENT_MAX_BEND then
			local axis = previousDir:Cross(tangent)
			tangent = if axis.Magnitude > 1e-5
				then CFrame.fromAxisAngle(axis.Unit, SEGMENT_MAX_BEND) * previousDir
				else previousDir
		end
		position = previousPos - tangent * (d - dist[k - 1])
		previousPos, previousDir = position, tangent
		-- Normale rendue ⟂ au corps (sinon lookAt vrille sur une arête mur/sol).
		local ortho = pointUp - tangent * pointUp:Dot(tangent)
		pointUp = if ortho.Magnitude > 1e-3 then ortho.Unit else previousUp
		previousUp = pointUp
		local world = CFrame.lookAt(position, position + tangent, pointUp)
		frames[k] = inverse * world * CFrame.new(-(leaderRest + Vector3.new(0, 0, d)))
	end
end

-- Pose du corps (repère du root) : hauteur + tangage + roulis repris du plan des pieds posés.
local function updateBody(rec: Record, root: BasePart, dt: number): CFrame
	local targetHeight, targetPitch, targetRoll = 0, 0, 0
	local legs = rec.legs
	if #legs > 0 and not rec.segmented and rec.distSq <= IK_RANGE_SQ and rec.air < 0.5 and rec.swim < 0.5 then
		local rootCFrame = root.CFrame
		local n, stepping, reachSum = 0, 0, 0
		local sx, sz, sy, sxx, szz, sxz, sxy, szy = 0, 0, 0, 0, 0, 0, 0, 0
		for _, leg in ipairs(legs) do
			local foot = leg.foot
			if leg.stepping then
				stepping += 1
			elseif foot and leg.planted then
				-- Écart vertical du pied par rapport à son appui de repos (positif = sol plus haut).
				local home = leg.hip + leg.toe
				local dy = rootCFrame:PointToObjectSpace(foot).Y - home.Y
				n += 1
				reachSum += leg.a + leg.b
				sx += home.X
				sz += home.Z
				sy += dy
				sxx += home.X * home.X
				szz += home.Z * home.Z
				sxz += home.X * home.Z
				sxy += home.X * dy
				szy += home.Z * dy
			end
		end
		if n >= 3 then
			-- Plan des moindres carrés dy = a + slopeX*x + slopeZ*z (ajustement conjoint : sans faux roulis
			-- quand un seul tripode est posé et que x et z de ses pieds sont corrélés).
			local reach = reachSum / n
			local mx, mz, my = sx / n, sz / n, sy / n
			local cxx, czz, cxz = sxx / n - mx * mx, szz / n - mz * mz, sxz / n - mx * mz
			local cxy, czy = sxy / n - mx * my, szy / n - mz * my
			local det = cxx * czz - cxz * cxz
			local slopeX, slopeZ = 0, 0
			if math.abs(det) > 1e-6 then
				slopeX = (czz * cxy - cxz * czy) / det
				slopeZ = (cxx * czy - cxz * cxy) / det
			else
				slopeX = if cxx > 1e-4 then cxy / cxx else 0
				slopeZ = if czz > 1e-4 then czy / czz else 0
			end
			targetRoll = math.clamp(math.atan(slopeX) * BODY_TILT, -BODY_MAX_TILT, BODY_MAX_TILT)
			targetPitch = math.clamp(-math.atan(slopeZ) * BODY_TILT, -BODY_MAX_TILT, BODY_MAX_TILT)
			-- Moitié de l'écart moyen des pieds + léger tassement quand des pattes sont levées.
			targetHeight = math.clamp(my * 0.5 - reach * 0.06 * stepping / #legs, -reach * 0.2, reach * 0.2)
		end
	end
	-- Hors portée IK : les pattes reviennent au repos d'un coup, le corps aussi (sinon ils se décollent).
	local alpha = if rec.distSq > IK_RANGE_SQ then 1 else math.min(1, dt * BODY_STIFFNESS)
	rec.bodyHeight += (targetHeight - rec.bodyHeight) * alpha
	rec.bodyPitch += (targetPitch - rec.bodyPitch) * alpha
	rec.bodyRoll += (targetRoll - rec.bodyRoll) * alpha
	return CFrame.new(0, rec.bodyHeight, 0) * CFrame.Angles(rec.bodyPitch, 0, rec.bodyRoll)
end

-- Rotation du cou (repère du corps). Joueur local seulement : la caméra des autres n'est pas connue ici.
local function updateHead(rec: Record, root: BasePart, body: CFrame, dt: number): CFrame
	local neck = rec.neck
	if not neck then
		return CFrame.identity
	end
	local targetYaw, targetPitch = 0, 0
	local camera = workspace.CurrentCamera
	if camera and rec.player ~= nil and rec.player == Players.LocalPlayer then
		local look = (root.CFrame * body):VectorToObjectSpace(camera.CFrame.LookVector)
		local yaw = math.atan2(-look.X, -look.Z)
		-- Caméra face à l'insecte (|yaw| -> pi) : la tête revient droite au lieu de basculer d'un côté à l'autre.
		local horizontal = math.sqrt(look.X * look.X + look.Z * look.Z)
		-- Caméra quasi alignée sur le haut du corps (mur, vue du dessus) : lacet indéfini, la tête reste droite.
		local fade = math.clamp((2.6 - math.abs(yaw)) / 0.8, 0, 1) * math.clamp((horizontal - 0.2) / 0.3, 0, 1)
		local pitch = math.atan2(look.Y, horizontal)
		targetYaw = math.clamp(yaw * HEAD_FOLLOW, -HEAD_MAX_YAW, HEAD_MAX_YAW) * fade
		targetPitch = math.clamp(pitch * HEAD_FOLLOW, -HEAD_MAX_PITCH, HEAD_MAX_PITCH) * fade
	end
	local alpha = math.min(1, dt * HEAD_RATE)
	rec.headYaw += (targetYaw - rec.headYaw) * alpha
	rec.headPitch += (targetPitch - rec.headPitch) * alpha
	return CFrame.new(neck) * CFrame.fromEulerAnglesYXZ(rec.headPitch, rec.headYaw, 0) * CFrame.new(-neck)
end

local function animate(rec: Record, root: BasePart, humanoid: Humanoid, now: number)
	local elapsed = now - rec.last
	local dt = math.clamp(elapsed, 0, 0.1)
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

	local position = root.Position
	local speed: number
	if rec.player then
		rec.velocity = root.AssemblyLinearVelocity
		speed = rec.velocity.Magnitude
	else
		-- Root ancrée : vitesse = déplacement lissé (la réplication arrive par à-coups).
		local lastPos = rec.lastPos
		rec.lastPos = position
		if lastPos and elapsed > 0 and elapsed < 0.5 then
			local delta = (position - lastPos) / elapsed
			local measured = delta.Magnitude
			if measured < MAX_SPEED then
				rec.speed += (measured - rec.speed) * math.min(1, dt * 5)
				rec.velocity = rec.velocity:Lerp(delta, math.min(1, dt * 5))
			end
		end
		speed = rec.speed
	end
	-- Vitesse angulaire déduite de la rotation (un grimpeur a AssemblyAngularVelocity = 0, une PNJ est ancrée).
	local rotation = root.CFrame.Rotation
	local lastRot = rec.lastRot
	local fresh = lastRot == nil -- premier frame ou retour dans le champ
	rec.lastRot = rotation
	if lastRot and elapsed > 0 and elapsed < 0.5 then
		local axis, angle = (lastRot:Inverse() * rotation):ToAxisAngle()
		local rate = angle / elapsed
		if rate < 30 then
			local measured = if angle > 1e-5 then lastRot:VectorToWorldSpace(axis) * rate else Vector3.zero
			rec.omega = rec.omega:Lerp(measured, math.min(1, dt * 10))
		end
	end
	local waterLevel = frameWaterLevel
	local swimming = waterLevel ~= nil and position.Y < waterLevel and isInPondZone(position)
	local airborne = false
	if not swimming and rec.player then
		local state = humanoid:GetState()
		-- UpVector : un grimpeur collé à un mur est aussi en "Freefall", mais penché ; en vol on reste droit.
		airborne = (state == FREEFALL or state == JUMPING) and root.CFrame.UpVector.Y > 0.8
	elseif not swimming and rec.character:GetAttribute("Flying") == true then
		airborne = true -- PNJ volant (WildInsectService) : ailes battantes, pattes pendantes
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
	-- Le corps recule un peu (armé) puis se détend vers l'avant au claquement et revient.
	local jawOpen = 0
	local lunge = 0
	local u = (now - rec.biteAt) / BITE_DURATION
	if u >= 0 and u < 1 then
		if u < 0.4 then
			jawOpen = 0.6 * u / 0.4
			lunge = -0.3 * u / 0.4
		elseif u < 0.55 then
			jawOpen = 0.6 - 0.85 * (u - 0.4) / 0.15
			lunge = -0.3 + 1.3 * (u - 0.4) / 0.15
		else
			jawOpen = -0.25 * (1 - (u - 0.55) / 0.45)
			lunge = 1 - (u - 0.55) / 0.45
		end
	end

	local body = updateBody(rec, root, dt)
	local segmented = rec.segmented
	-- Pas de bond pour un corps segmenté : les anneaux suivent le chemin, la tête s'en décollerait.
	local lungeZ, lungePitch = 0, 0
	if lunge ~= 0 and not segmented then
		lungeZ = -lunge * BITE_LUNGE * rec.scale
		lungePitch = -lunge * BITE_DIP
		body = CFrame.new(0, 0, lungeZ) * body * CFrame.Angles(lungePitch, 0, 0)
	end
	if segmented then
		updateSegments(rec, root, fresh)
	end
	local segOf, segFrames = rec.segOf, rec.segFrames
	local headCf = body * updateHead(rec, root, body, dt)
	-- Parts fixes : réécrites seulement quand la pose bouge (sinon des centaines de C0 par frame et par insecte).
	local bodySig = Vector3.new(rec.bodyHeight + lungeZ, rec.bodyPitch + lungePitch, rec.bodyRoll)
	local headSig = Vector3.new(rec.headYaw, rec.headPitch, 0)
	local drawn = rec.drawnBody
	-- Seuil ~0.1° / 2 millièmes de studs : le lissage ne réécrit pas tout pour des écarts invisibles.
	local bodyPosed = drawn == nil or (bodySig - drawn).Magnitude > 2e-3
	local headPosed = bodyPosed or (headSig - rec.drawnHead).Magnitude > 2e-3
	if bodyPosed then
		rec.drawnBody = bodySig
	end
	if headPosed then
		rec.drawnHead = headSig
	end
	local heads = rec.heads

	local kinds = rec.kinds
	local sides = rec.sides
	local indices = rec.indices
	local manyLegs = rec.manyLegs
	local localWind = if not swimming and frameWind.Magnitude > 0.5 then root.CFrame:VectorToObjectSpace(frameWind) else Vector3.zero
	local windStrength = math.clamp(localWind.Magnitude / 26, 0, 1)
	local windFlutter = math.sin(t * (7 + windStrength * 8)) * 0.09 * windStrength
	local windPitch = math.clamp(localWind.Z * 0.015, -0.32, 0.32)
	local windYaw = math.clamp(-localWind.X * 0.014, -0.28, 0.28)
	local lastKind, lastSide, lastIndex = 0, 0, 0
	local rot = CFrame.identity
	for i = 1, count do
		local kind, side, index = kinds[i], sides[i], indices[i]
		local seg = segOf[i]
		if kind == K_STATIC and seg == 0 and not (if heads[i] then headPosed else bodyPosed) then
			continue
		end
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
					+ (1 - air) * (rec.wingIdle * math.sin(t * 1.5) + windFlutter * 0.45)
				-- Déploiement (Y) appliqué AVANT le battement (Z) : d'où le produit dans cet ordre.
				rot = CFrame.Angles(0, 0, side * flap) * CFrame.Angles(0, rec.spreads[i] * air, 0)
			elseif kind == K_ELYTRON then
				rot = CFrame.Angles(0, 0, side * air * (0.45 + 0.04 * math.sin(wingPhase)))
					* CFrame.Angles(0, side * 0.75 * air, 0)
			elseif kind == K_ANTENNA then
				rot = CFrame.Angles(
					math.sin(t * 2.1 + side) * 0.08 + math.sin(gait * 2) * 0.08 * move + 0.2 * air + windPitch + windFlutter,
					side * math.sin(t * 1.4 + index) * 0.1 + windYaw,
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
			elseif kind == K_SEGMENT and segmented then
				rot = CFrame.identity -- la courbure vient du chemin de la tête
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
		welds[i].C0 = (if seg > 0 then segFrames[seg] elseif heads[i] then headCf else body) * rests[i] * rot
	end
	updateLegs(rec, root, dt, elapsed, air, swim, body)
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
	local stage = if container then container:GetAttribute("Stage") else nil
	rec.wantWhole = stage == "Oeuf" or stage == "Cocon"
	if container then
		-- Les parts (et leurs Welds) arrivent par vagues à la réplication.
		rec.containerConn = container.DescendantAdded:Connect(function()
			rec.dirty = true
		end)
	end
end

-- FilterDescendantsInstances est copié à l'affectation : on le réaffecte à chaque changement.
local function refreshRayFilter()
	table.clear(rayFilter)
	for _, rec in records do
		table.insert(rayFilter, rec.character)
	end
	legRayParams.FilterDescendantsInstances = rayFilter
end

local function untrack(key: Instance)
	local rec = records[key]
	if not rec then
		return
	end
	records[key] = nil
	refreshRayFilter()
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

local function track(key: Instance, player: Player?, character: Model)
	untrack(key)
	local rec: Record = {
		player = player,
		character = character,
		nearSq = if player then NEAR_DISTANCE_SQ else NPC_NEAR_DISTANCE_SQ,
		farSq = if player then FAR_DISTANCE_SQ else NPC_FAR_DISTANCE_SQ,
		lastPos = nil,
		speed = 0,
		root = nil,
		humanoid = nil,
		container = nil,
		charConn = nil,
		containerConn = nil,
		attackConn = nil,
		dirty = true,
		whole = false,
		wantWhole = false,
		count = 0,
		welds = {},
		rests = {},
		kinds = {},
		sides = {},
		indices = {},
		spreads = {},
		biases = {},
		heads = {},
		neck = nil,
		bodyHeight = 0,
		bodyPitch = 0,
		bodyRoll = 0,
		headYaw = 0,
		headPitch = 0,
		drawnBody = nil,
		drawnHead = Vector3.zero,
		segmented = false,
		segCount = 0,
		segLeader = Vector3.zero,
		segDist = {},
		segOf = {},
		segFrames = {},
		trailPos = {},
		trailUp = {},
		trailSpacing = 0.1,
		trailCap = 0,
		segRoot = nil,
		segMoved = true,
		seed = math.random() * 10,
		last = os.clock(),
		odd = math.random() < 0.5, -- étale les mises à mi-cadence sur les deux frames
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
		legs = {},
		walkOnWater = false,
		distSq = 0,
		velocity = Vector3.zero,
		lastRot = nil,
		omega = Vector3.zero,
	}
	records[key] = rec
	refreshRayFilter()
	-- Changement de stade : le serveur détruit le conteneur et en crée un nouveau.
	rec.charConn = character.ChildAdded:Connect(function(child)
		if child.Name == CONTAINER_NAME then
			bindContainer(rec, child)
		end
	end)
	-- Morsure des AUTRES joueurs : DamageService date chaque coup sur la victime (attributs répliqués).
	-- shortcut: seuls les coups qui touchent un joueur sont visibles ; un attribut posé par
	-- CombatService sur l'attaquant couvrirait aussi les morsures dans le vide ou sur un animal.
	-- Une Maman PNJ date sa propre morsure (attribut "BiteAt") : une seule connexion pour les deux.
	rec.attackConn = character.AttributeChanged:Connect(function(name: string)
		if name == "BiteAt" then
			if player == nil then
				rec.biteAt = os.clock()
			end
			return
		elseif name ~= "LastAttackAt" then
			return
		end
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
	local windAttr = workspace:GetAttribute("WindVector")
	frameWind = if typeof(windAttr) == "Vector3" then windAttr else Vector3.zero
	if now >= nextZoneRefresh then
		nextZoneRefresh = now + ZONE_REFRESH_PERIOD
		pondZones = CollectionService:GetTagged("PondZone")
	end

	for _, rec in records do
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
		if distanceSq > rec.farSq then
			rec.lastPos = nil -- pas de pic de vitesse au retour dans le champ
			rec.lastRot = nil
			continue
		end
		rec.odd = not rec.odd
		if distanceSq > rec.nearSq and rec.odd then
			continue
		end

		local whole = rec.wantWhole
		if rec.dirty or whole ~= rec.whole or character:GetScale() ~= rec.scale then
			rebuild(rec, whole)
		end
		rec.distSq = distanceSq
		if rec.count > 0 or #rec.legs > 0 then
			animate(rec, root, humanoid, now)
		end
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		track(player, player, character)
	end)
	player.CharacterRemoving:Connect(function(character)
		local rec = records[player]
		if rec and rec.character == character then
			untrack(player)
		end
	end)
	local character = player.Character
	if character then
		track(player, player, character)
	end
end

local function onNpcAdded(instance: Instance)
	if instance:IsA("Model") then
		track(instance, nil, instance)
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

	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(onNpcAdded)
	CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(untrack)
	for _, instance in ipairs(CollectionService:GetTagged(NPC_TAG)) do
		onNpcAdded(instance)
	end
	CollectionService:GetInstanceAddedSignal(WILD_TAG):Connect(onNpcAdded)
	CollectionService:GetInstanceRemovedSignal(WILD_TAG):Connect(untrack)
	for _, instance in ipairs(CollectionService:GetTagged(WILD_TAG)) do
		onNpcAdded(instance)
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
