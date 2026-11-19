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
local NEAR_DISTANCE_SQ = 40 * 40
local FAR_DISTANCE_SQ = 100 * 100
-- Mamans PNJ : plus grosses (MOTHER_SCALE) et peu nombreuses -> visibles de plus loin.
local NPC_TAG = "NpcMother"
local NPC_NEAR_DISTANCE_SQ = 60 * 60
local NPC_FAR_DISTANCE_SQ = 150 * 150
local MAX_SPEED = 150 -- au-delà : téléportation / réapparition, on ignore la mesure
local BITE_DURATION = 0.3
local ZONE_REFRESH_PERIOD = 2
local TWO_PI = math.pi * 2

-- IK des pattes
local IK_RANGE_SQ = 60 * 60 -- au-delà : pattes au repos (pas de raycast)
local STEP_IDLE = 0.22 -- à l'arrêt : petits pas de recalage (fraction de la longueur de patte)
local STEP_MIN_DURATION = 0.05
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

-- Tables de travail réutilisées par rebuild (clé = Side * 10 + Index).
local scratchSpread: { [number]: number } = {}
local scratchBias: { [number]: number } = {}
local scratchLegs: { [number]: IKLeg } = {}

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
	table.clear(rec.legs)
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

		-- Patte à IK : rangée dans sa structure de patte, pas dans le cache générique.
		local segment = child:GetAttribute("LegSeg")
		if code == K_LEG and (segment == "Upper" or segment == "Lower") then
			maxLegIndex = math.max(maxLegIndex, index)
			local key = side * 10 + index
			local leg = scratchLegs[key]
			if not leg then
				leg = {
					group = (index + (if side > 0 then 1 else 0)) % 2,
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
end

-- IK à 2 os (hanche -> genou -> pied) puis écriture des Welds : C0 = M * repos, où M est la
-- transformation rigide du segment dans le repère du root.
local function solveLeg(leg: IKLeg, footLocal: Vector3)
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
	local upper = CFrame.new(hip) * legFrame(knee - hip, normal) * leg.upperBasis * CFrame.new(-hip)
	local lower = CFrame.new(knee) * legFrame(foot - knee, normal) * leg.lowerBasis * CFrame.new(-(hip + leg.knee))
	for i, weld in ipairs(leg.upperWelds) do
		weld.C0 = upper * leg.upperRests[i]
	end
	for i, weld in ipairs(leg.lowerWelds) do
		weld.C0 = lower * leg.lowerRests[i]
	end
end

-- Appui sous `from` à portée de la hanche, ou nil (vide, bord, trop bas pour la patte).
local function groundBelow(rec: Record, from: Vector3, hip: Vector3, up: Vector3, reach: number): Vector3?
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
	if position and (position - hip).Magnitude <= reach * REACH_OK then
		return position
	end
	return nil
end

-- Pas planté / pas en arc pour chaque patte, puis IK. `grounded` = corps posé (sol, mur, plafond).
local function updateLegs(rec: Record, root: BasePart, dt: number, air: number, swim: number)
	local legs = rec.legs
	if #legs == 0 then
		return
	end
	if rec.distSq > IK_RANGE_SQ then
		-- Loin : pattes remises au repos une seule fois, aucun raycast.
		for _, leg in ipairs(legs) do
			if leg.foot ~= nil then
				leg.foot = nil
				leg.stepping = false
				leg.planted = false
				for i, weld in ipairs(leg.upperWelds) do
					weld.C0 = leg.upperRests[i]
				end
				for i, weld in ipairs(leg.lowerWelds) do
					weld.C0 = leg.lowerRests[i]
				end
			end
		end
		return
	end

	local rootCFrame = root.CFrame
	local rootPosition = rootCFrame.Position
	local up = rootCFrame.UpVector
	local back = -rootCFrame.LookVector
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
		local hipWorld = rootCFrame * leg.hip
		local homeWorld = rootCFrame * (leg.hip + leg.toe)
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
			local ground = groundBelow(rec, homeWorld, hipWorld, up, reach)
				or groundBelow(rec, homeWorld:Lerp(hipWorld, 0.5), hipWorld, up, reach)
			local foot = leg.foot
			if not ground then
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
						local homeVelocity = velocity + omega:Cross(homeWorld - rootPosition)
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
						local stretch = (foot - hipWorld).Magnitude
						local otherBusy = if leg.group == 0 then busy1 else busy0
						if (late or stretch > reach * REACH_STRETCH or math.abs(along) > reach * 0.6) and otherBusy == 0 then
							-- Le pied se pose une demi-foulée DEVANT l'endroit où sera la hanche à l'atterrissage.
							duration = if moving
								then math.clamp(stride / homeSpeed, STEP_MIN_DURATION, STEP_MAX_DURATION)
								else 0.16
							local aim = homeWorld + homeVelocity * duration + heading * stepDistance
							local target = groundBelow(rec, aim, hipWorld, up, reach) or ground
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
		solveLeg(leg, rootCFrame:PointToObjectSpace(current))
	end
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
	updateLegs(rec, root, dt, air, swim)
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
