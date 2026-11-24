--!strict
-- AbilityController.luau
-- Entrées de combat (GDD §8.3) : Clic gauche = morsure, E / R = pouvoirs, F = agripper,
-- C = creuser (maintenir). Boutons tactiles via ContextActionService sur mobile.
-- Le client n'envoie que l'intention ; il applique seulement les MOUVEMENTS demandés par le
-- serveur (charge, bond, recul) car c'est lui qui possède la physique de son personnage.
--
-- Réactivité : la morsure (petite ruée + jauge de recharge) et la charge sont PRÉDITES localement
-- dès l'appui ; le serveur reste seul juge des dégâts et du vrai cooldown. Un appui juste avant
-- la fin d'une recharge est mis en tampon et rejoué. La cible que la morsure toucherait est
-- surlignée (aide à la visée, purement visuelle).

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local AimUtil = require(ReplicatedStorage.shared.AimUtil)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)

local AbilityController = {}

-- (slot: string, cooldownSeconds: number) : écouté par AbilityHotbarView pour les jauges.
AbilityController.CooldownStarted = Instance.new("BindableEvent")
-- () : morsure locale prédite, émise à l'appui (avant la réponse du serveur) pour l'animation.
AbilityController.LocalBite = Instance.new("BindableEvent")

-- Creusement : petites demandes rapprochées (galerie continue), force 1..3 choisie avec V.
local DIG_REPEAT_SECONDS = 0.12
local DIG_REACH = 8 -- doit rester sous MAX_REACH (DigService)
local DIG_STRENGTH_COUNT = 3
local MAX_MOTION_SPEED = 140
-- Doivent rester alignés sur GameConstants.BITE_RANGE / BITE_COOLDOWN (serveur, non répliqué).
local BITE_RANGE = 7
local BITE_COOLDOWN = 0.8
local BITE_CONE_COS = math.cos(math.rad(60))
local BITE_NUDGE_SPEED = 16
local BUFFER_WINDOW = 0.35 -- un appui fait moins de 0.35 s avant la fin de la recharge est rejoué
local LUNGE_PREDICT_WINDOW = 0.6
local TARGET_REFRESH_SECONDS = 0.1

-- Primitives qui s'exécutent toujours côté serveur (pas besoin de cible) : jauge prédite sans risque.
local PREDICTED_PRIMITIVES: { [string]: boolean } = {
	Projectile = true,
	ConeBurst = true,
	LungeCharge = true,
	Leap = true,
	Camouflage = true,
	ArmorBuff = true,
	SupportAura = true,
	Light = true,
}

local player = Players.LocalPlayer
local started = false
local digging = false
local digStrength = 2
-- Visée du creusement : uniquement le Terrain (ni l'insecte, ni les plantes, ni les autres joueurs).
local digRayParams = RaycastParams.new()
digRayParams.FilterType = Enum.RaycastFilterType.Include
digRayParams.FilterDescendantsInstances = { workspace.Terrain }
-- Visée des pouvoirs (tirs de toile...) : tout le décor, sauf les personnages.
local AIM_DISTANCE = 300
local abilityAimParams = RaycastParams.new()
abilityAimParams.FilterType = Enum.RaycastFilterType.Exclude
abilityAimParams.RespectCanCollide = true

local function abilityAim(root: BasePart): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ignore: { Instance } = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	abilityAimParams.FilterDescendantsInstances = ignore
	return (AimUtil.Point(camera, root.Position, AIM_DISTANCE, abilityAimParams))
end

local cooldownEnds: { [string]: number } = {} -- par slot, horloge locale
local buffered: { [string]: boolean } = {}
local lungePredictedAt = 0
local targetHighlight: Highlight? = nil

local function getRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Personnage vivant, ni étourdi ni agrippé : mêmes refus que CombatService (qui reste juge).
local function getActingCharacter(): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil
	end
	if character:GetAttribute("Status_Stun") == true or player:GetAttribute("IsGrabbed") == true then
		return nil, nil
	end
	return character, root
end

local function canBite(): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Adulte" or stage == "Larve" or stage == "Mue"
end

local function abilityForSlot(slot: string): AbilityCatalog.AbilityDefinition?
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	if not species then
		return nil
	end
	for _, id in ipairs(species.Abilities) do
		local definition = AbilityCatalog[id]
		if definition and definition.Slot == slot then
			return definition
		end
	end
	return nil
end

local function applyVelocity(velocity: Vector3)
	local root = getRoot()
	if not root or velocity.Magnitude ~= velocity.Magnitude then
		return -- NaN : on ignore plutôt que d'envoyer le personnage hors de la carte
	end
	if velocity.Magnitude > MAX_MOTION_SPEED then
		velocity = velocity.Unit * MAX_MOTION_SPEED
	end
	root.AssemblyLinearVelocity = velocity
	-- Fenêtre d'impulsion : Flight/Swim/WallClimb coupent leur LinearVelocity tant qu'elle dure,
	-- sinon la contrainte réécrite chaque frame annule le recul/la charge (horloge locale, même client).
	local character = player.Character
	if character then
		character:SetAttribute("ImpulseUntil", os.clock() + 0.25)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and velocity.Y > 0 then
			-- Au sol seulement (pas en vol/nage/escalade) : le Humanoid freinerait l'impulsion en quelques frames.
			local state = humanoid:GetState()
			if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics or state == Enum.HumanoidStateType.Landed then
				humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
			end
		end
	end
end

local function applyLunge(direction: Vector3, range: number)
	applyVelocity(direction * math.max(range * 3.5, 45) + Vector3.new(0, 8, 0))
end

local function startLocalCooldown(slot: string, seconds: number)
	cooldownEnds[slot] = os.clock() + seconds
	AbilityController.CooldownStarted:Fire(slot, seconds)
end

-- Tampon d'entrée : rejoue l'action à la fin de la recharge si l'appui est arrivé juste avant.
local function bufferInput(slot: string, remaining: number, action: () -> ())
	if remaining > BUFFER_WINDOW or buffered[slot] then
		return
	end
	buffered[slot] = true
	task.delay(remaining + 0.02, function()
		buffered[slot] = nil
		action()
	end)
end

-- Miroir de CombatService.findTargets pour la morsure : la cible la plus proche dans le cône
-- avant. Les cibles camouflées sont ignorées pour ne pas les révéler.
local function findBiteTarget(root: BasePart, scale: number): (Model?, BasePart?, number)
	local origin = root.Position
	local look = root.CFrame.LookVector
	local range = BITE_RANGE * math.max(scale, 0.5)
	local familyId = player:GetAttribute("FamilyId")
	local bestModel: Model? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = math.huge

	local function consider(model: Model, targetRoot: BasePart, radius: number)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or model:GetAttribute("Camouflaged") ~= nil then
			return
		end
		local offset = targetRoot.Position - origin
		local distance = offset.Magnitude - radius
		if distance > range or distance >= bestDistance then
			return
		end
		-- Au contact, l'angle n'a plus de sens (même règle que le serveur).
		if distance > 1.5 and offset.Magnitude > 0.01 and offset.Unit:Dot(look) < BITE_CONE_COS then
			return
		end
		bestModel, bestRoot, bestDistance = model, targetRoot, distance
	end

	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		if other ~= player and character and not (familyId ~= nil and other:GetAttribute("FamilyId") == familyId) then
			local otherRoot = character:FindFirstChild("HumanoidRootPart")
			if otherRoot and otherRoot:IsA("BasePart") then
				consider(character, otherRoot, 1)
			end
		end
	end
	for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
		if animal:IsA("Model") and animal.PrimaryPart then
			consider(animal, animal.PrimaryPart, (animal:GetAttribute("HitRadius") :: number?) or 4)
		end
	end
	for _, wild in ipairs(CollectionService:GetTagged("WildInsect")) do
		if wild:IsA("Model") and wild.PrimaryPart then
			consider(wild, wild.PrimaryPart, (wild:GetAttribute("HitRadius") :: number?) or 2)
		end
	end
	-- Mamans PNJ (comme le serveur) : sauf celle de sa propre famille.
	for _, mother in ipairs(CollectionService:GetTagged("NpcMother")) do
		if mother:IsA("Model") and mother.PrimaryPart and (familyId == nil or mother:GetAttribute("FamilyId") ~= familyId) then
			consider(mother, mother.PrimaryPart, (mother:GetAttribute("HitRadius") :: number?) or 2)
		end
	end
	return bestModel, bestRoot, bestDistance
end

local function biteCooldown(): number
	local special = abilityForSlot("LeftClick")
	return if special then math.max(BITE_COOLDOWN, special.Cooldown * 0.5) else BITE_COOLDOWN
end

local function bite()
	local character, root = getActingCharacter()
	if not character or not root or not canBite() then
		return -- le serveur refuserait aussi : on ne prédit rien
	end
	local remaining = (cooldownEnds.LeftClick or 0) - os.clock()
	if remaining > 0 then
		bufferInput("LeftClick", remaining, bite)
		return
	end
	startLocalCooldown("LeftClick", biteCooldown())

	-- Petite ruée immédiate vers la cible (ou droit devant) : la morsure "part" à l'appui.
	local scale = character:GetScale()
	local _, targetRoot, distance = findBiteTarget(root, scale)
	if distance > 1.5 then
		local direction = root.CFrame.LookVector
		if targetRoot then
			local offset = targetRoot.Position - root.Position
			if offset.Magnitude > 0.01 then
				direction = offset.Unit
			end
		end
		applyVelocity(root.AssemblyLinearVelocity + direction * BITE_NUDGE_SPEED * math.clamp(scale, 0.5, 1.5))
	end

	AbilityController.LocalBite:Fire()
	Remotes.Get("RequestLeftClickBite"):FireServer()
end

local function useAbility(slot: string)
	if slot == "F" then
		-- F relâche aussi une prise en cours : jamais filtré ni mis en tampon localement.
		Remotes.Get("RequestGrab"):FireServer()
		return
	end
	local remaining = (cooldownEnds[slot] or 0) - os.clock()
	if remaining > 0 then
		bufferInput(slot, remaining, function()
			useAbility(slot)
		end)
		return
	end
	local character, root = getActingCharacter()
	local definition = abilityForSlot(slot)
	if character and root and definition and player:GetAttribute("Stage") == "Adulte" and PREDICTED_PRIMITIVES[definition.Primitive] then
		startLocalCooldown(slot, definition.Cooldown)
		if definition.Primitive == "LungeCharge" then
			-- Même formule que CombatService.executeLunge : la charge part sans attendre l'aller-retour.
			lungePredictedAt = os.clock()
			applyLunge(root.CFrame.LookVector, definition.Range * math.max(character:GetScale(), 0.6))
		end
	end
	-- Point visé envoyé avec la demande (tirs de toile...) ; le serveur le borne à la portée.
	Remotes.Get("RequestUseAbility"):FireServer(slot, if root then abilityAim(root) else nil)
end

-- Surligne la cible que la morsure toucherait (aide à la visée).
local function refreshTargetHighlight()
	local target: Model? = nil
	local character, root = getActingCharacter()
	if character and root and canBite() then
		target = findBiteTarget(root, character:GetScale())
	end
	local highlight = targetHighlight
	if not highlight or not highlight.Parent then
		if not target then
			return
		end
		local created = Instance.new("Highlight")
		created.Name = "BiteTargetHighlight"
		created.FillTransparency = 1
		created.OutlineColor = Color3.fromRGB(255, 235, 150)
		created.OutlineTransparency = 0.15
		created.DepthMode = Enum.HighlightDepthMode.Occluded
		created.Parent = workspace
		targetHighlight = created
		highlight = created
	end
	if highlight.Adornee ~= target then
		highlight.Adornee = target
	end
	highlight.Enabled = target ~= nil
end

local function digOnce()
	local root = getRoot()
	local camera = workspace.CurrentCamera
	if not root or not camera then
		return
	end
	-- On creuse là où vise la souris (centre de l'écran en manette / sur mobile) : point exact du Terrain.
	local start, direction = AimUtil.Ray(camera, root.Position)
	local hit = workspace:Raycast(start, direction * (DIG_REACH * 1.5), digRayParams)
	local target = if hit and (hit.Position - root.Position).Magnitude <= DIG_REACH
		then hit.Position
		else root.Position + direction * (DIG_REACH * 0.5)
	Remotes.Get("RequestDig"):FireServer(target, digStrength)
end

local function cycleDigStrength()
	digStrength = digStrength % DIG_STRENGTH_COUNT + 1
	-- Attribut local (non répliqué) : lu par le hotbar pour afficher la force.
	player:SetAttribute("DigStrength", digStrength)
end

local function startDigging()
	if digging then
		return
	end
	digging = true
	task.spawn(function()
		while digging do
			digOnce()
			task.wait(DIG_REPEAT_SECONDS)
		end
	end)
end

-- Mouvements commandés par le serveur (voir CombatService).
local function onAbilityCast(slot: unknown, primitive: unknown, cooldown: unknown, range: unknown, extra: unknown)
	if primitive == "Knockback" then
		if typeof(extra) == "Vector3" then
			applyVelocity(extra :: Vector3)
		end
		return
	end
	if typeof(slot) ~= "string" or typeof(cooldown) ~= "number" or typeof(range) ~= "number" then
		return
	end
	local root = getRoot()
	if root then
		if primitive == "Lunge" and typeof(extra) == "Vector3" then
			-- Charge déjà lancée par la prédiction locale : on ne la rejoue pas.
			if os.clock() - lungePredictedAt > LUNGE_PREDICT_WINDOW then
				applyLunge((extra :: Vector3).Unit, range :: number)
			end
		elseif primitive == "Leap" and typeof(extra) == "Vector3" then
			-- Trajectoire balistique qui atterrit sur la cible en ~0.6 s.
			local flightTime = 0.6
			local delta = (extra :: Vector3) - root.Position
			local gravity = workspace.Gravity
			local velocity = Vector3.new(delta.X / flightTime, delta.Y / flightTime + 0.5 * gravity * flightTime, delta.Z / flightTime)
			applyVelocity(velocity)
		end
	end
	if (cooldown :: number) > 0 then
		-- Le cooldown confirmé (un aller-retour après l'appui) fait foi pour le tampon d'entrée.
		-- La jauge déjà lancée par la prédiction n'est pas relancée : pas de saut visuel.
		local confirmedEnd = os.clock() + (cooldown :: number)
		local predictedEnd = cooldownEnds[slot :: string] or 0
		cooldownEnds[slot :: string] = confirmedEnd
		if math.abs(confirmedEnd - predictedEnd) > 0.5 then
			AbilityController.CooldownStarted:Fire(slot, cooldown)
		end
	end
end

local function handleAction(actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if actionName == "MW_Boost" then
		-- Boost maintenu : envoyé seulement au début et à la fin de l'appui.
		if inputState == Enum.UserInputState.Begin then
			Remotes.Get("RequestBoost"):FireServer(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			Remotes.Get("RequestBoost"):FireServer(false)
		end
		return Enum.ContextActionResult.Sink
	end
	if actionName == "MW_DigStrength" then
		if inputState == Enum.UserInputState.Begin then
			cycleDigStrength()
		end
		return Enum.ContextActionResult.Sink
	end
	if actionName == "MW_Dig" then
		if inputState == Enum.UserInputState.Begin then
			startDigging()
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			digging = false
		end
		return Enum.ContextActionResult.Sink
	end
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if actionName == "MW_Bite" then
		if player:GetAttribute("BuildMode") ~= true then
			bite()
		end
	elseif actionName == "MW_E" then
		useAbility("E")
	elseif actionName == "MW_R" then
		useAbility("R")
	elseif actionName == "MW_F" then
		useAbility("F")
	end
	return Enum.ContextActionResult.Sink
end

local function bindTouchFriendly(name: string, title: string, keys: { Enum.KeyCode | Enum.UserInputType }, position: UDim2)
	ContextActionService:BindAction(name, handleAction, true, table.unpack(keys))
	ContextActionService:SetTitle(name, title)
	ContextActionService:SetPosition(name, position)
end

function AbilityController.Start()
	if started then
		return
	end
	started = true

	-- Le clic gauche passe par UserInputService (pas CAS) pour ne pas voler le clic aux GUI.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		-- Mode construction du nid : le clic pose une pièce, il ne mord pas.
		if input.UserInputType == Enum.UserInputType.MouseButton1 and player:GetAttribute("BuildMode") ~= true then
			bite()
		end
	end)

	bindTouchFriendly("MW_Bite", "Mordre", { Enum.KeyCode.ButtonR2 }, UDim2.new(1, -170, 1, -170))
	bindTouchFriendly("MW_E", "E", { Enum.KeyCode.E, Enum.KeyCode.ButtonX }, UDim2.new(1, -230, 1, -110))
	bindTouchFriendly("MW_R", "R", { Enum.KeyCode.R, Enum.KeyCode.ButtonY }, UDim2.new(1, -230, 1, -230))
	bindTouchFriendly("MW_F", "F", { Enum.KeyCode.F, Enum.KeyCode.ButtonB }, UDim2.new(1, -110, 1, -230))
	bindTouchFriendly("MW_Dig", "C", { Enum.KeyCode.C, Enum.KeyCode.ButtonL2 }, UDim2.new(1, -290, 1, -170))
	-- DPadUp / (1,-350,1,-170) sont pris par "monter" (CharacterState, nage / vol).
	-- Shift : le shift lock est désactivé (default.project.json), la touche sert au boost.
	bindTouchFriendly("MW_Boost", "Boost", { Enum.KeyCode.LeftShift, Enum.KeyCode.DPadLeft }, UDim2.new(1, -350, 1, -230))
	bindTouchFriendly("MW_DigStrength", "Force", { Enum.KeyCode.V, Enum.KeyCode.DPadRight }, UDim2.new(1, -290, 1, -230))
	player:SetAttribute("DigStrength", digStrength)

	Remotes.Get("AbilityCast").OnClientEvent:Connect(onAbilityCast)
	player.CharacterRemoving:Connect(function()
		digging = false
	end)
	-- Nouvelle espèce = nouveaux pouvoirs : les recharges locales de l'ancienne ne valent plus.
	player:GetAttributeChangedSignal("Species"):Connect(function()
		table.clear(cooldownEnds)
	end)
	task.spawn(function()
		while true do
			task.wait(TARGET_REFRESH_SECONDS)
			refreshTargetHighlight()
		end
	end)
end

return AbilityController
