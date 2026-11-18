--!strict
-- CombatService.luau
-- Chasse & PvP (GDD §8.3) : morsure (clic gauche), pouvoirs d'espèce (E / R), agrippement (F) +
-- QTE d'évasion (Espace). Chaque pouvoir est exécuté via sa "primitive" (shared/AbilityCatalog),
-- donc ~11 mécaniques couvrent les 75 pouvoirs. Le client n'envoie qu'une INTENTION (le slot) :
-- la cible, la portée, les dégâts et le cooldown sont tous résolus ici.
--
-- Les cibles sont trouvées par distance + angle par rapport au HumanoidRootPart (les parts
-- visuelles ont CanQuery=false, un raycast ne les verrait pas). Les animaux sont des Models
-- tagués "Animal" (Humanoid + PrimaryPart + attribut HitRadius), voir AnimalService.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local DamageService = require(ServerScriptService.services.DamageService)
local MovementService = require(ServerScriptService.services.MovementService)
local StatusEffectService = require(ServerScriptService.services.StatusEffectService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)

local CombatService = {}

type Target = {
	Model: Model,
	Root: BasePart,
	Radius: number,
	Player: Player?,
	Distance: number,
}

type GrabState = {
	Grabber: Player,
	VictimModel: Model,
	VictimPlayer: Player?,
	DamagePerSecond: number,
	EscapePresses: number,
	EscapeNeeded: number,
	ExpiresAt: number,
	ThrowOnRelease: boolean,
	Anchor: Vector3, -- position du prédateur au moment de la prise (anti-téléportation)
	LastGrabberPosition: Vector3,
}

local GRAB_DURATION = 5
local GRAB_ESCAPE_PRESSES = 12
local GRAB_ESCAPE_PRESSES_STRONG = 20
local MAX_ESCAPE_PRESSES_PER_SECOND = 14
local PROJECTILE_SPEED = 90
local GRAB_FOLLOW_RATE = 18 -- 1/s : la proie rejoint les mandibules en douceur (pas de téléportation)
local GRAB_FACE_GRABBER = CFrame.Angles(0, math.pi, 0)
local LUNGE_WINDUP = 0.25 -- délai entre le télégraphe de charge et le coup
local LEAP_AIRTIME = 0.6 -- durée du bond côté client (anneau d'atterrissage)
local MAX_WEBS_PER_PLAYER = 2

local cooldowns: { [Player]: { [string]: number } } = {}
local grabsByGrabber: { [Player]: GrabState } = {}
local grabsByVictim: { [Model]: GrabState } = {}
local escapePressTimes: { [Player]: { number } } = {}
local webs: { [Player]: { BasePart } } = {}
local stillSince: { [Player]: number } = {}

-- ============================================================
-- Utilitaires
-- ============================================================

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function feedback(player: Player, success: boolean, reason: string?)
	Remotes.Get("AbilityFeedback"):FireClient(player, success, reason)
end

local function getSpecies(player: Player): InsectData.InsectInfo
	local speciesId = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	return InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
end

local function getAliveRoot(player: Player): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil
	end
	return character, root
end

local function isOnCooldown(player: Player, key: string): boolean
	local playerCooldowns = cooldowns[player]
	return playerCooldowns ~= nil and (playerCooldowns[key] or 0) > os.clock()
end

local function startCooldown(player: Player, key: string, seconds: number)
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		playerCooldowns = {}
		cooldowns[player] = playerCooldowns
	end
	playerCooldowns[key] = os.clock() + seconds
end

-- Multiplicateur de puissance selon le stade (une larve mord faiblement, un oeuf pas du tout).
local function stagePowerFactor(player: Player): number
	local stage = player:GetAttribute("Stage")
	if stage == "Adulte" then
		return 1
	elseif stage == "Larve" then
		return 0.4
	elseif stage == "Mue" then
		return 0.3
	end
	return 0
end

local function sameFamily(a: Player, b: Player?): boolean
	if not b then
		return false
	end
	local familyA = a:GetAttribute("FamilyId")
	return familyA ~= nil and familyA == b:GetAttribute("FamilyId")
end

-- Toutes les cibles vivantes (joueurs + animaux) dans un cône devant l'attaquant, triées par distance.
local function findTargets(attacker: Player, attackerRoot: BasePart, range: number, coneDegrees: number, includeFamily: boolean?): { Target }
	local results: { Target } = {}
	local origin = attackerRoot.Position
	local look = attackerRoot.CFrame.LookVector
	local cosLimit = math.cos(math.rad(coneDegrees))

	local function consider(model: Model, root: BasePart, radius: number, player: Player?)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		if player and not includeFamily and sameFamily(attacker, player) then
			return
		end
		local offset = root.Position - origin
		local distance = offset.Magnitude - radius
		if distance > range then
			return
		end
		local direction = if offset.Magnitude > 0.01 then offset.Unit else look
		-- Au contact, l'angle n'a plus de sens (cible "dans" l'attaquant) : on l'accepte.
		if distance > 1.5 and direction:Dot(look) < cosLimit then
			return
		end
		table.insert(results, { Model = model, Root = root, Radius = radius, Player = player, Distance = distance })
	end

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= attacker then
			local character, root = getAliveRoot(other)
			if character and root then
				consider(character, root, 1, other)
			end
		end
	end
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal:IsA("Model") and animal.PrimaryPart then
			consider(animal, animal.PrimaryPart, (animal:GetAttribute("HitRadius") :: number?) or 4, nil)
		end
	end
	-- Mamans PNJ (NpcMotherService) : ses propres enfants ne la mordent pas.
	local attackerFamily = attacker:GetAttribute("FamilyId")
	for _, mother in ipairs(CollectionService:GetTagged("NpcMother")) do
		if mother:IsA("Model") and mother.PrimaryPart and (includeFamily or attackerFamily == nil or mother:GetAttribute("FamilyId") ~= attackerFamily) then
			consider(mother, mother.PrimaryPart, (mother:GetAttribute("HitRadius") :: number?) or 2, nil)
		end
	end

	table.sort(results, function(a, b)
		return a.Distance < b.Distance
	end)
	return results
end

local function isBehind(target: Target, attackerRoot: BasePart): boolean
	local toAttacker = attackerRoot.Position - target.Root.Position
	if toAttacker.Magnitude < 0.01 then
		return false
	end
	return target.Root.CFrame.LookVector:Dot(toAttacker.Unit) < -0.25
end

-- Envoie une poussée au client propriétaire de la physique de la victime.
local function knockback(target: Target, direction: Vector3, strength: number)
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, 1) -- cible "dans" l'attaquant : évite un .Unit NaN
	end
	if target.Player then
		Remotes.Get("AbilityCast"):FireClient(target.Player, "Knockback", "Knockback", 0, 0, direction.Unit * strength + Vector3.new(0, strength * 0.4, 0))
	end
end

-- Inflige des dégâts en appliquant les passifs défensifs de la victime (esquive, ailes toxiques).
local function strike(attacker: Player, target: Target, amount: number, attackerRoot: BasePart, isMelee: boolean): boolean
	if target.Player then
		local victimSpecies = getSpecies(target.Player)
		for _, abilityId in ipairs(victimSpecies.Abilities) do
			local definition = AbilityCatalog[abilityId]
			if not definition or definition.Slot ~= "Passive" then
				continue
			end
			if abilityId == "ReflexeEsquive" and math.random() < definition.Power then
				notify(target.Player, "Esquive réflexe !", "info")
				feedback(attacker, false, "La cible a esquivé !")
				return false
			end
			if abilityId == "AilesToxiques" and isMelee and attacker.Character and definition.Status then
				StatusEffectService.Apply(attacker.Character, definition.Status, definition.StatusDuration or 4, definition.StatusMagnitude, target.Player.UserId)
			end
		end
	end
	return DamageService.ApplyDamage(target.Model, amount, {
		AttackerUserId = attacker.UserId,
		FromBehind = isBehind(target, attackerRoot),
	})
end

local function applyStatusFromDefinition(attacker: Player, target: Target, definition: AbilityCatalog.AbilityDefinition)
	if definition.Status then
		StatusEffectService.Apply(target.Model, definition.Status, definition.StatusDuration or 3, definition.StatusMagnitude, attacker.UserId)
	end
end

-- Les VFX sont rendus par chaque client (CombatFxController) : le serveur ne diffuse que des
-- arguments compacts (voir shared/Remotes "CombatFx"), il ne crée ni n'anime aucune part.
local fxRemote: RemoteEvent? = nil
local function fx(kind: string, a: any, b: any, c: any, d: any)
	if not fxRemote then
		fxRemote = Remotes.Get("CombatFx")
	end
	(fxRemote :: RemoteEvent):FireAllClients(kind, a, b, c, d)
end

-- Éclat de couleur d'un effet de zone. L'éclat d'un coup qui blesse est déjà émis par
-- DamageService ("Hit").
local function flash(position: Vector3, color: Color3, size: number)
	fx("Flash", position, color, size, nil)
end

local function cameraShake(players: { Player }, intensity: number, duration: number)
	local remote = Remotes.Get("CameraShake")
	for _, player in ipairs(players) do
		remote:FireClient(player, intensity, duration)
	end
end

local function breakCamouflage(player: Player)
	stillSince[player] = os.clock() -- le camouflage passif ne revient qu'après 1.5 s d'immobilité
	local character = player.Character
	if character and character:GetAttribute("CamouflageLevel") ~= nil then
		InsectVisualService.SetCamouflage(character, 0)
		character:SetAttribute("Camouflaged", nil)
	end
end

-- ============================================================
-- Agrippement (F) + QTE
-- ============================================================

local function releaseGrab(state: GrabState, reason: string?)
	if grabsByGrabber[state.Grabber] ~= state then
		return
	end
	grabsByGrabber[state.Grabber] = nil
	grabsByVictim[state.VictimModel] = nil
	MovementService.RemoveModifier(state.Grabber, "Grabbing")
	state.Grabber:SetAttribute("IsGrabbing", nil)

	local victimRoot = state.VictimModel.PrimaryPart or state.VictimModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	state.VictimModel:SetAttribute("GrabbedBy", nil)
	if state.VictimPlayer then
		local victim = state.VictimPlayer
		victim:SetAttribute("IsGrabbed", false)
		MovementService.RemoveModifier(victim, "Grabbed")
		if victimRoot and state.VictimModel == victim.Character then
			victimRoot.Anchored = false
			pcall(function()
				(victimRoot :: BasePart):SetNetworkOwner(victim)
			end)
		end
		Remotes.Get("GrabStateChanged"):FireClient(victim, false, nil)
		if reason then
			notify(victim, reason, "info")
		end
		if state.ThrowOnRelease then
			local grabberRoot = state.Grabber.Character and state.Grabber.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if grabberRoot then
				Remotes.Get("AbilityCast"):FireClient(victim, "Knockback", "Knockback", 0, 0, grabberRoot.CFrame.LookVector * 70 + Vector3.new(0, 45, 0))
			end
		end
	end
end

local function canBeGrabbedBy(grabber: Player, target: Target): boolean
	if grabsByVictim[target.Model] then
		return false
	end
	if target.Player then
		-- Déjà tenue (par un autre prédateur ou par la langue du caméléon).
		if target.Player:GetAttribute("IsGrabbed") == true then
			return false
		end
		-- "Proie plus petite" : comparaison PV max x échelle (un adulte ne saisit pas un plus gros).
		local grabberHumanoid = grabber.Character and grabber.Character:FindFirstChildOfClass("Humanoid")
		local victimHumanoid = target.Model:FindFirstChildOfClass("Humanoid")
		if not grabberHumanoid or not victimHumanoid then
			return false
		end
		local grabberSize = grabberHumanoid.MaxHealth * (grabber.Character :: Model):GetScale()
		local victimSize = victimHumanoid.MaxHealth * target.Model:GetScale()
		return victimSize <= grabberSize * 1.15
	end
	-- Animaux : seuls les petits (alevins) peuvent être agrippés.
	return target.Model:GetAttribute("Grabbable") == true
end

local function startGrab(grabber: Player, grabberRoot: BasePart, definition: AbilityCatalog.AbilityDefinition, abilityId: string): boolean
	local range = math.max(definition.Range, 4) * math.max((grabber.Character :: Model):GetScale(), 0.5)
	local targets = findTargets(grabber, grabberRoot, range, 55)
	local target: Target? = nil
	for _, candidate in ipairs(targets) do
		if canBeGrabbedBy(grabber, candidate) then
			target = candidate
			break
		end
	end
	if not target then
		feedback(grabber, false, "Aucune proie assez petite à portée.")
		return false -- useAbility pose un court cooldown anti-spam
	end

	local species = getSpecies(grabber)
	local strongGrip = table.find(species.Abilities, "SaisieGeante") ~= nil
	local damagePerSecond = if definition.Power > 0 then definition.Power * 0.5 else species.Damage * 0.4

	local state: GrabState = {
		Grabber = grabber,
		VictimModel = target.Model,
		VictimPlayer = target.Player,
		DamagePerSecond = damagePerSecond,
		EscapePresses = 0,
		EscapeNeeded = if strongGrip then GRAB_ESCAPE_PRESSES_STRONG else GRAB_ESCAPE_PRESSES,
		ExpiresAt = os.clock() + GRAB_DURATION,
		ThrowOnRelease = abilityId == "ProjectionMandibules",
		Anchor = grabberRoot.Position,
		LastGrabberPosition = grabberRoot.Position,
	}
	grabsByGrabber[grabber] = state
	grabsByVictim[target.Model] = state
	target.Model:SetAttribute("GrabbedBy", grabber.UserId)
	MovementService.AddModifier(grabber, "Grabbing", "Override", 0, GRAB_DURATION)
	-- Lu par FlightController : un prédateur volant fait du surplace pendant la prise.
	grabber:SetAttribute("IsGrabbing", true)

	if target.Player then
		local victim = target.Player
		victim:SetAttribute("IsGrabbed", true)
		MovementService.AddModifier(victim, "Grabbed", "Override", 0, GRAB_DURATION)
		-- Ancrée : grabFollow l'amène ensuite en douceur devant les mandibules du prédateur.
		target.Root.Anchored = true
		Remotes.Get("GrabStateChanged"):FireClient(victim, true, grabber.Name, state.EscapeNeeded)
		escapePressTimes[victim] = {}
	end

	if definition.Status then
		applyStatusFromDefinition(grabber, target, definition)
	end
	notify(grabber, "Proie agrippée !", "info")
	return true
end

local function onGrabEscape(player: Player)
	local character = player.Character
	local state = character and grabsByVictim[character]
	if not state then
		return
	end
	-- Plafond de cadence : un auto-clicker ne libère pas plus vite qu'un humain très rapide.
	local now = os.clock()
	local presses = escapePressTimes[player] or {}
	escapePressTimes[player] = presses
	while #presses > 0 and now - presses[1] > 1 do
		table.remove(presses, 1)
	end
	-- Écart minimal entre deux appuis comptés : 12 appels dans la même frame ne valent qu'un appui.
	if #presses >= MAX_ESCAPE_PRESSES_PER_SECOND or (#presses > 0 and now - presses[#presses] < 1 / MAX_ESCAPE_PRESSES_PER_SECOND) then
		return
	end
	table.insert(presses, now)

	state.EscapePresses += 1
	if state.EscapePresses >= state.EscapeNeeded then
		state.ThrowOnRelease = false -- une évasion réussie n'est pas une projection
		releaseGrab(state, "Libéré !")
		notify(state.Grabber, "Votre proie s'est échappée !", "warning")
	end
end

local GRAB_MAX_DRIFT = 15 -- le prédateur ne peut pas emporter sa proie (vol, téléportation)
local GRAB_MAX_STEP = 10

local function grabTick(deltaTime: number)
	local now = os.clock()
	for grabber, state in pairs(grabsByGrabber) do
		local _, grabberRoot = getAliveRoot(grabber)
		local victimHumanoid = state.VictimModel:FindFirstChildOfClass("Humanoid")
		if not grabberRoot or not victimHumanoid or victimHumanoid.Health <= 0 or now >= state.ExpiresAt or not state.VictimModel.Parent then
			releaseGrab(state, nil)
			continue
		end
		if StatusEffectService.Has(grabber.Character :: Model, "Stun") then
			releaseGrab(state, "Le prédateur a lâché prise !")
			continue
		end
		-- Position du prédateur fournie par son client : on refuse qu'il "emporte" la proie.
		local position = grabberRoot.Position
		if (position - state.Anchor).Magnitude > GRAB_MAX_DRIFT or (position - state.LastGrabberPosition).Magnitude > GRAB_MAX_STEP then
			releaseGrab(state, "La proie glisse hors des mandibules !")
			continue
		end
		state.LastGrabberPosition = position
		DamageService.ApplyDamage(state.VictimModel, state.DamagePerSecond * deltaTime, { AttackerUserId = grabber.UserId, Quiet = true })
	end
end

-- Placement de la proie à chaque frame (fluide), séparé des dégâts (4 Hz).
local function grabFollow(deltaTime: number)
	-- Lissage exponentiel : la position du prédateur arrive par à-coups (réseau), la proie suit sans saccade.
	local alpha = 1 - math.exp(-GRAB_FOLLOW_RATE * deltaTime)
	for grabber, state in pairs(grabsByGrabber) do
		local character = grabber.Character
		local grabberRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		-- Devant les mandibules, tournée vers le prédateur (CFrame = valeur, aucune allocation de table).
		local hold = CFrame.new(0, 0, -2.5 * (if character then character:GetScale() else 1)) * GRAB_FACE_GRABBER
		if character and grabberRoot then
			if state.VictimPlayer then
				local victimRoot = state.VictimModel:FindFirstChild("HumanoidRootPart") :: BasePart?
				if victimRoot then
					victimRoot.CFrame = victimRoot.CFrame:Lerp(grabberRoot.CFrame * hold, alpha)
				end
			else
				-- Petit animal (alevin) : emporté dans les mandibules.
				state.VictimModel:PivotTo(state.VictimModel:GetPivot():Lerp(grabberRoot.CFrame * hold, alpha))
			end
		end
	end
end

-- ============================================================
-- Primitives de pouvoirs
-- ============================================================

local function executeProjectile(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number, color: Color3)
	local range = definition.Range * math.max(scale, 0.6)
	local targets = findTargets(player, root, range, 20)
	local target = targets[1]
	local startPosition = root.Position + root.CFrame.LookVector * 1.5
	local endPosition = if target then target.Root.Position else startPosition + root.CFrame.LookVector * range
	local travelTime = (endPosition - startPosition).Magnitude / PROJECTILE_SPEED

	fx("Proj", startPosition, endPosition, color, travelTime)

	if target then
		task.delay(travelTime, function()
			-- La cible a pu esquiver en s'éloignant pendant le vol.
			if (target.Root.Position - endPosition).Magnitude <= 6 + target.Radius then
				if strike(player, target, definition.Power * stagePowerFactor(player), root, false) then
					applyStatusFromDefinition(player, target, definition)
				end
			end
		end)
	end
end

local function executeConeBurst(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number, color: Color3)
	local range = definition.Range * math.max(scale, 0.6)
	local targets = findTargets(player, root, range, 70)
	local shaken: { Player } = {}
	for _, target in ipairs(targets) do
		if strike(player, target, definition.Power * stagePowerFactor(player), root, false) then
			applyStatusFromDefinition(player, target, definition)
			knockback(target, target.Root.Position - root.Position, 25)
			if target.Player then
				table.insert(shaken, target.Player)
			end
		end
	end
	fx("Cone", root.Position, root.CFrame.LookVector * range, color, nil)
	if definition.Status == "Stun" then
		cameraShake(shaken, 0.8, 1.2)
	end
end

local function executeLunge(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number, slot: string)
	local range = definition.Range * math.max(scale, 0.6)
	Remotes.Get("AbilityCast"):FireClient(player, slot, "Lunge", definition.Cooldown, range, root.CFrame.LookVector)
	fx("Tele", player.Character, "Lunge", root.CFrame.LookVector * range, LUNGE_WINDUP) -- traînée d'avertissement
	task.delay(LUNGE_WINDUP, function()
		local _, currentRoot = getAliveRoot(player)
		if not currentRoot then
			return
		end
		local targets = findTargets(player, currentRoot, math.max(GameConstants.BITE_RANGE, range * 0.5), 45)
		local target = targets[1]
		if target then
			if strike(player, target, definition.Power * stagePowerFactor(player), currentRoot, true) then
				applyStatusFromDefinition(player, target, definition)
				knockback(target, target.Root.Position - currentRoot.Position, 55)
			end
		end
	end)
end

local function executeLeap(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number, slot: string)
	local range = definition.Range * math.max(scale, 0.6)
	local targets = findTargets(player, root, range, 50)
	local target = targets[1]
	local landing = if target then target.Root.Position else root.Position + root.CFrame.LookVector * range
	Remotes.Get("AbilityCast"):FireClient(player, slot, "Leap", definition.Cooldown, range, landing)
	fx("Tele", player.Character, "Leap", landing, LEAP_AIRTIME) -- anneau d'atterrissage visible par la proie
	if not target or definition.Power <= 0 then
		return
	end
	-- Le bond dure ~0.6 s côté client + latence : on teste l'atterrissage jusqu'à 1.1 s.
	task.spawn(function()
		local startedAt = os.clock()
		while os.clock() - startedAt < 1.1 do
			task.wait(0.1)
			local _, currentRoot = getAliveRoot(player)
			if not currentRoot then
				return
			end
			if (currentRoot.Position - target.Root.Position).Magnitude <= GameConstants.BITE_RANGE + target.Radius + 3 then
				if strike(player, target, definition.Power * stagePowerFactor(player), currentRoot, true) then
					applyStatusFromDefinition(player, target, definition)
				end
				return
			end
		end
	end)
end

local function executeStatusBite(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number, abilityId: string): boolean
	local range = math.max(definition.Range, GameConstants.BITE_RANGE) * math.max(scale, 0.5)
	local targets = findTargets(player, root, range, 60)
	local target = targets[1]
	if not target then
		feedback(player, false, "Aucune cible à portée.")
		return false
	end
	if strike(player, target, definition.Power * stagePowerFactor(player), root, true) then
		applyStatusFromDefinition(player, target, definition)
		if abilityId == "SuccionDeSangXP" then
			-- Boire le sang d'un géant rapporte gros (GDD : boost d'XP).
			-- Une Maman PNJ n'est pas un géant : pas de farm de PE sur elle.
			local bonus = if target.Player or CollectionService:HasTag(target.Model, "NpcMother") then 15 else 60
			player:SetAttribute("Hunger", math.min(100, ((player:GetAttribute("Hunger") :: number?) or 0) + 15))
			CombatService.EvolutionPointsHook(player, bonus)
		end
	end
	if abilityId == "PiqureUltime" then
		-- Piqûre kamikaze : l'abeille s'arrache le dard et en souffre gravement.
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(humanoid.MaxHealth * 0.35)
		end
	end
	return true
end

local function executeCamouflage(player: Player, definition: AbilityCatalog.AbilityDefinition)
	local character = player.Character
	if not character then
		return
	end
	InsectVisualService.SetCamouflage(character, 0.85)
	character:SetAttribute("Camouflaged", true)
	local token = ((character:GetAttribute("CamouflageToken") :: number?) or 0) + 1
	character:SetAttribute("CamouflageToken", token)
	notify(player, "Camouflé ! (courir ou attaquer vous révèle)", "info")
	task.delay(math.max(definition.Duration, 3), function()
		if character.Parent and character:GetAttribute("Camouflaged") == true and character:GetAttribute("CamouflageToken") == token then
			InsectVisualService.SetCamouflage(character, 0)
			character:SetAttribute("Camouflaged", nil)
		end
	end)
end

local function executeArmorBuff(player: Player, definition: AbilityCatalog.AbilityDefinition)
	local character = player.Character
	if not character then
		return
	end
	character:SetAttribute("ActiveArmor", definition.Power)
	MovementService.AddModifier(player, "ArmorTurtle", "Override", 0, definition.Duration)
	task.delay(definition.Duration, function()
		if character.Parent then
			character:SetAttribute("ActiveArmor", nil)
		end
	end)
end

local function familyInRange(player: Player, origin: Vector3, range: number): { Player }
	local members: { Player } = { player }
	local familyId = player:GetAttribute("FamilyId")
	if not familyId then
		return members
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other:GetAttribute("FamilyId") == familyId then
			local _, otherRoot = getAliveRoot(other)
			if otherRoot and (otherRoot.Position - origin).Magnitude <= range then
				table.insert(members, other)
			end
		end
	end
	return members
end

local function executeSupportAura(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, abilityId: string)
	local members = familyInRange(player, root.Position, definition.Range)
	if abilityId == "PheromonesColonie" then
		for _, member in ipairs(members) do
			MovementService.AddModifier(member, "Pheromones", "Multiplier", 1 + definition.Power, definition.Duration)
			if member ~= player then
				notify(member, player.Name .. " lance une alerte phéromone !", "info")
			end
		end
	else
		-- RecoltePollenMiel : soigne toute la ruche à portée.
		for _, member in ipairs(members) do
			local humanoid = member.Character and member.Character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + definition.Power)
			end
		end
	end
	flash(root.Position, Color3.fromRGB(255, 220, 90), definition.Range * 0.3)
end

local function executeLight(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, scale: number)
	local range = math.max(definition.Range, 6) * math.max(scale, 0.6)
	for _, target in ipairs(findTargets(player, root, range, 80)) do
		applyStatusFromDefinition(player, target, definition)
	end
	flash(root.Position + root.CFrame.LookVector * 2, Color3.fromRGB(255, 255, 200), range * 0.6)
end

local function spawnWeb(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition)
	local list = webs[player] or {}
	webs[player] = list
	while #list >= MAX_WEBS_PER_PLAYER do
		local oldest = table.remove(list, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end

	local web = Instance.new("Part")
	web.Name = "ToilePiege"
	web.Size = Vector3.new(10, 0.2, 10)
	web.CFrame = root.CFrame * CFrame.new(0, -1.5 * (player.Character :: Model):GetScale(), -6)
	web.Anchored = true
	web.CanCollide = false
	web.CanQuery = false
	web.Material = Enum.Material.Fabric
	web.Color = Color3.fromRGB(235, 235, 240)
	web.Transparency = 0.55
	web:SetAttribute("OwnerUserId", player.UserId)
	web.Parent = workspace
	local decal = Instance.new("SelectionBox")
	decal.Adornee = web
	decal.LineThickness = 0.03
	decal.Color3 = Color3.fromRGB(250, 250, 250)
	decal.Transparency = 0.5
	decal.Parent = web
	table.insert(list, web)
	Debris:AddItem(web, definition.Duration)
	fx("Web", web, nil, nil, nil) -- apparition animée côté client

	local caught: { [Model]: number } = {}
	web.Touched:Connect(function(hit)
		local model = hit:FindFirstAncestorOfClass("Model")
		local victim = model and Players:GetPlayerFromCharacter(model)
		if not model or not victim or victim == player or sameFamily(player, victim) then
			return
		end
		if caught[model] and os.clock() - caught[model] < 4 then
			return
		end
		caught[model] = os.clock()
		StatusEffectService.Apply(model, definition.Status or "Stun", definition.StatusDuration or 2, definition.StatusMagnitude, player.UserId)
		StatusEffectService.Apply(model, "Glue", 4, 0.7, player.UserId)
		notify(victim, "Pris dans une toile d'araignée !", "warning")
		notify(player, victim.Name .. " est pris dans votre toile !", "info")
	end)
end

local function executeUtility(player: Player, root: BasePart, definition: AbilityCatalog.AbilityDefinition, abilityId: string, scale: number): boolean
	if abilityId == "TisserToilePiege" then
		spawnWeb(player, root, definition)
		return true
	elseif abilityId == "MarquagePheromoneCible" then
		local target = findTargets(player, root, definition.Range * math.max(scale, 0.6), 35)[1]
		if not target then
			feedback(player, false, "Aucune cible à marquer.")
			return false
		end
		-- Jeton (comme CamouflageToken) : un re-marquage prolonge la marque au lieu d'être effacé par l'ancien délai.
		local token = ((target.Model:GetAttribute("MarkToken") :: number?) or 0) + 1
		target.Model:SetAttribute("MarkToken", token)
		target.Model:SetAttribute("Marked", true)
		local highlight = target.Model:FindFirstChild("PheromoneMark") :: Highlight?
		if not highlight then
			local newHighlight = Instance.new("Highlight")
			newHighlight.Name = "PheromoneMark"
			newHighlight.FillColor = Color3.fromRGB(255, 120, 30)
			newHighlight.FillTransparency = 0.6
			newHighlight.OutlineColor = Color3.fromRGB(255, 60, 0)
			newHighlight.Parent = target.Model
			highlight = newHighlight
		end
		task.delay(definition.Duration, function()
			if target.Model.Parent and target.Model:GetAttribute("MarkToken") == token then
				target.Model:SetAttribute("Marked", nil)
				if highlight then
					highlight:Destroy()
				end
			end
		end)
		for _, member in ipairs(familyInRange(player, root.Position, 200)) do
			notify(member, "Cible marquée par l'essaim ! (+25% dégâts)", "info")
		end
		return true
	elseif abilityId == "CourantAscendant" then
		player:SetAttribute("FlightBoost", definition.Power)
		task.delay(definition.Duration, function()
			player:SetAttribute("FlightBoost", nil)
		end)
		return true
	elseif abilityId == "AutotomieFuite" then
		local state = player.Character and grabsByVictim[player.Character]
		if state then
			state.ThrowOnRelease = false
			releaseGrab(state, "Vous sacrifiez une patte pour fuir !")
		elseif not CombatService.ReleaseAnimalHoldHook(player) then
			feedback(player, false, "Personne ne vous tient.")
			return false
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(humanoid.MaxHealth * 0.1)
		end
		MovementService.AddModifier(player, "AutotomieSprint", "Multiplier", 1.5, 3)
		return true
	end
	feedback(player, false, "Ce pouvoir est passif.")
	return false
end

local ABILITY_COLORS: { [string]: Color3 } = {
	JetAcideFormique = Color3.fromRGB(230, 220, 60),
	CanonAGlu = Color3.fromRGB(245, 240, 200),
	SprayChimiqueBouillant = Color3.fromRGB(255, 140, 40),
	SaignementReflexeToxique = Color3.fromRGB(255, 215, 40),
	CriSoniqueEtourdissant = Color3.fromRGB(150, 200, 255),
}

-- Résout et exécute le pouvoir du slot demandé pour l'espèce du joueur.
local function useAbility(player: Player, slot: string)
	local character, root = getAliveRoot(player)
	if not character or not root then
		return
	end
	-- Anti-spam : chaque refus pose ce court cooldown avant de renvoyer un toast.
	if isOnCooldown(player, "NoAbility_" .. slot) then
		return
	end
	if StatusEffectService.Has(character, "Stun") then
		startCooldown(player, "NoAbility_" .. slot, 0.5)
		feedback(player, false, "Étourdi !")
		return
	end
	if player:GetAttribute("Stage") ~= "Adulte" then
		startCooldown(player, "NoAbility_" .. slot, 0.5)
		feedback(player, false, "Les pouvoirs se débloquent à l'âge adulte.")
		return
	end

	local species = getSpecies(player)
	local abilityId: string? = nil
	local definition: AbilityCatalog.AbilityDefinition? = nil
	for _, id in ipairs(species.Abilities) do
		local candidate = AbilityCatalog[id]
		if candidate and candidate.Slot == slot then
			abilityId = id
			definition = candidate
			break
		end
	end
	if not abilityId or not definition then
		feedback(player, false, "Aucun pouvoir sur cette touche.")
		startCooldown(player, "NoAbility_" .. slot, 0.5)
		return
	end
	-- Agrippé : seule l'autotomie (sacrifier une patte) reste possible.
	if player:GetAttribute("IsGrabbed") == true and abilityId ~= "AutotomieFuite" then
		return
	end
	if isOnCooldown(player, abilityId) then
		return
	end

	local scale = character:GetScale()
	local primitive = definition.Primitive
	local executed = true
	if primitive ~= "Camouflage" then
		breakCamouflage(player)
	end

	if primitive == "Projectile" then
		executeProjectile(player, root, definition, scale, ABILITY_COLORS[abilityId] or Color3.fromRGB(200, 255, 120))
	elseif primitive == "ConeBurst" then
		executeConeBurst(player, root, definition, scale, ABILITY_COLORS[abilityId] or Color3.fromRGB(255, 255, 255))
	elseif primitive == "LungeCharge" then
		executeLunge(player, root, definition, scale, slot)
	elseif primitive == "Leap" then
		executeLeap(player, root, definition, scale, slot)
	elseif primitive == "Grab" then
		executed = startGrab(player, root, definition, abilityId)
	elseif primitive == "StatusBite" then
		executed = executeStatusBite(player, root, definition, scale, abilityId)
	elseif primitive == "Camouflage" then
		executeCamouflage(player, definition)
	elseif primitive == "ArmorBuff" then
		executeArmorBuff(player, definition)
	elseif primitive == "SupportAura" then
		executeSupportAura(player, root, definition, abilityId)
	elseif primitive == "Light" then
		executeLight(player, root, definition, scale)
	else
		executed = executeUtility(player, root, definition, abilityId, scale)
	end

	if not executed then
		startCooldown(player, abilityId, 0.6) -- anti-spam d'un pouvoir qui échoue (pas de cible...)
	else
		startCooldown(player, abilityId, definition.Cooldown)
		if primitive ~= "LungeCharge" and primitive ~= "Leap" then
			Remotes.Get("AbilityCast"):FireClient(player, slot, primitive, definition.Cooldown, definition.Range, nil)
		end
	end
end

-- ============================================================
-- Morsure (clic gauche)
-- ============================================================

local function onBite(player: Player)
	local character, root = getAliveRoot(player)
	if not character or not root or player:GetAttribute("IsGrabbed") == true then
		return
	end
	local factor = stagePowerFactor(player)
	if factor <= 0 or StatusEffectService.Has(character, "Stun") then
		return
	end
	if isOnCooldown(player, "Bite") then
		return
	end

	local species = getSpecies(player)
	-- Certaines espèces ont une morsure spéciale sur le clic gauche (venin, mâchoires de requin...).
	local special: AbilityCatalog.AbilityDefinition? = nil
	for _, id in ipairs(species.Abilities) do
		local candidate = AbilityCatalog[id]
		if candidate and candidate.Slot == "LeftClick" then
			special = candidate
			break
		end
	end
	local cooldown = if special then math.max(GameConstants.BITE_COOLDOWN, special.Cooldown * 0.5) else GameConstants.BITE_COOLDOWN
	startCooldown(player, "Bite", cooldown)
	breakCamouflage(player)

	local range = GameConstants.BITE_RANGE * math.max(character:GetScale(), 0.5)
	local target = findTargets(player, root, range, 60)[1]
	Remotes.Get("AbilityCast"):FireClient(player, "LeftClick", "Bite", cooldown, range, nil)
	if not target then
		return
	end
	local damage = (if special then special.Power else species.Damage) * factor
	if strike(player, target, damage, root, true) then
		if special and special.Status and player:GetAttribute("Stage") == "Adulte" then
			applyStatusFromDefinition(player, target, special)
		end
	end
end

-- ============================================================
-- Camouflage passif (Phasme, Nèpe) : actif tant que l'insecte reste immobile.
-- ============================================================

local PASSIVE_CAMOUFLAGE_LEVEL: { [string]: number } = {
	MimetismeBrindille = 0.95,
	CamouflageFeuilleMorte = 0.8,
}

local function passiveCamouflageTick()
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		local character, root = getAliveRoot(player)
		if not character or not root or player:GetAttribute("Stage") ~= "Adulte" then
			stillSince[player] = nil
			continue
		end
		-- Camouflage actif (E/R) : courir le rompt.
		if character:GetAttribute("Camouflaged") == true and root.AssemblyLinearVelocity.Magnitude > 8 then
			InsectVisualService.SetCamouflage(character, 0)
			character:SetAttribute("Camouflaged", nil)
		end
		local level: number? = nil
		for _, id in ipairs(getSpecies(player).Abilities) do
			if PASSIVE_CAMOUFLAGE_LEVEL[id] then
				level = PASSIVE_CAMOUFLAGE_LEVEL[id]
			end
		end
		if not level then
			continue
		end
		local moving = root.AssemblyLinearVelocity.Magnitude > 0.6
		if moving then
			stillSince[player] = nil
			if character:GetAttribute("Camouflaged") == "Passive" then
				InsectVisualService.SetCamouflage(character, 0)
				character:SetAttribute("Camouflaged", nil)
			end
		else
			stillSince[player] = stillSince[player] or now
			if now - (stillSince[player] :: number) >= 1.5 and character:GetAttribute("Camouflaged") == nil then
				InsectVisualService.SetCamouflage(character, level)
				character:SetAttribute("Camouflaged", "Passive")
			end
		end
	end
end

-- Remplacé par ProgressionService au démarrage (évite un require circulaire).
function CombatService.EvolutionPointsHook(_player: Player, _amount: number) end

-- Remplacé par AnimalService au démarrage : libère une proie tenue par un animal (langue du
-- caméléon). Retourne vrai si le joueur était tenu.
function CombatService.ReleaseAnimalHoldHook(_player: Player): boolean
	return false
end

function CombatService.IsGrabbed(model: Model): boolean
	return grabsByVictim[model] ~= nil
end

function CombatService.Start()
	Remotes.Get("RequestLeftClickBite").OnServerEvent:Connect(onBite)
	Remotes.Get("RequestUseAbility").OnServerEvent:Connect(function(player, slot: unknown)
		if slot == "E" or slot == "R" then
			useAbility(player, slot :: string)
		end
	end)
	Remotes.Get("RequestGrab").OnServerEvent:Connect(function(player)
		if grabsByGrabber[player] then
			releaseGrab(grabsByGrabber[player], "Le prédateur vous relâche.")
			return
		end
		useAbility(player, "F")
	end)
	Remotes.Get("RequestGrabEscape").OnServerEvent:Connect(onGrabEscape)

	Players.PlayerRemoving:Connect(function(player)
		local state = grabsByGrabber[player]
		if state then
			releaseGrab(state, nil)
		end
		local character = player.Character
		local victimState = character and grabsByVictim[character]
		if victimState then
			releaseGrab(victimState, nil)
		end
		cooldowns[player] = nil
		escapePressTimes[player] = nil
		stillSince[player] = nil
		for _, web in ipairs(webs[player] or {}) do
			web:Destroy()
		end
		webs[player] = nil
	end)

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(0.25)
			local now = os.clock()
			-- Une erreur ne doit jamais figer les prises (victimes ancrées pour toujours).
			local ok, err = pcall(grabTick, now - last)
			if not ok then
				warn("[CombatService] grabTick : " .. tostring(err))
			end
			last = now
		end
	end)
	game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
		local ok, err = pcall(grabFollow, deltaTime)
		if not ok then
			warn("[CombatService] grabFollow : " .. tostring(err))
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			local ok, err = pcall(passiveCamouflageTick)
			if not ok then
				warn("[CombatService] camouflage : " .. tostring(err))
			end
		end
	end)
end

return CombatService
