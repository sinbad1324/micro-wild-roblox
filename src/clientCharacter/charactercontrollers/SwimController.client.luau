--!strict
-- SwimController.client.luau
-- Nage libre sous l'eau (CanSwim) ou glisse à la surface (CanWalkOnWater) (StarterCharacterScripts.characterControllers)
--
-- Contrat monde identique à SurvivalService (server) : workspace:GetAttribute("PondWaterLevel")
-- + CollectionService tag "PondZone" (une boîte par bassin : mare + tronçons du ruisseau, test XZ).
-- Tant que ce contrat n'est pas rempli, on reste idle sans erreur.
-- Monter = Saut maintenu ; Descendre = bouton "Bas" (CharacterState) ; ou incliner la caméra.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local SWIM_SPEED_FACTOR = 0.6
local VERTICAL_SPEED_FACTOR = 0.7
local DRAG_SHARPNESS = 6 -- plus haut = la vitesse suit la consigne plus vite (moins de "glisse")
local ENTRY_MOMENTUM = 0.5 -- part de l'élan conservée en entrant dans l'eau (pas d'arrêt net)
local BUOYANCY_RISE = 1.2 -- remontée lente sans commande (studs/s)
local SURFACE_BAND = 3 -- profondeur sous laquelle on se cale doucement à la surface
local SURFACE_REST_DEPTH = 0.4 -- reste sous PondWaterLevel : le test "submergé" (survie, anims) tient
local SURFACE_SPRING = 4
local SURFACE_BOB_AMPLITUDE = 0.35
local SURFACE_BOB_FREQUENCY = 2
local SURFACE_EXIT_MARGIN = 0.6 -- hystérésis : pas d'aller-retour nage/chute à la surface
local SURFACE_DIVE_MARGIN = 0.5 -- pieds à moins de ça au-dessus de l'eau : Ctrl fait plonger
local BREACH_DEPTH = 1 -- Saut maintenu à moins de cette profondeur = on jaillit hors de l'eau
local BREACH_GRACE = 0.4 -- pas de recapture juste après le jaillissement (sinon collé à la berge)
local GLIDE_SPEED_FACTOR = 1.15
local GLIDE_ACCEL_SHARPNESS = 2.5
local GLIDE_DECEL_SHARPNESS = 1.2 -- glisse sur l'eau avant de s'arrêter

-- Un seul Attachment partagé par le VectorForce (annule la gravité en nage) et les LinearVelocity.
local attachment = Instance.new("Attachment")
attachment.Parent = rootPart

local vectorForce = Instance.new("VectorForce")
vectorForce.Attachment0 = attachment
vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
vectorForce.ApplyAtCenterOfMass = true
vectorForce.Enabled = false
vectorForce.Parent = rootPart

local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.Attachment0 = attachment
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.MaxForce = 50000
linearVelocity.Enabled = false
linearVelocity.Parent = rootPart

-- Glisse des marcheurs sur l'eau : plan horizontal seulement, l'axe Y reste libre (saut, chute).
local glideVelocity = Instance.new("LinearVelocity")
glideVelocity.Attachment0 = attachment
glideVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
glideVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
glideVelocity.PrimaryTangentAxis = Vector3.xAxis
glideVelocity.SecondaryTangentAxis = Vector3.zAxis
glideVelocity.MaxForce = 50000
glideVelocity.Enabled = false
glideVelocity.Parent = rootPart

-- Flotteur invisible : les espèces CanWalkOnWater marchent dessus plutôt que de plonger sous l'eau.
local waterFloater = Instance.new("Part")
waterFloater.Name = "WaterSurfaceFloater"
waterFloater.Anchored = true
waterFloater.CanCollide = true
waterFloater.CanQuery = false
waterFloater.CanTouch = false
waterFloater.Transparency = 1
waterFloater.Size = Vector3.new(6, 1, 6)

local swimVelocity = Vector3.zero
local glide = Vector3.zero
local breachUntil = 0

-- Zones en cache (GetTagged alloue une table à chaque appel) ; rafraîchies sur ajout/retrait du tag.
local pondZones: { BasePart } = {}
local function refreshPondZones()
	table.clear(pondZones)
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			table.insert(pondZones, zone)
		end
	end
end
refreshPondZones()
CollectionService:GetInstanceAddedSignal("PondZone"):Connect(refreshPondZones)
CollectionService:GetInstanceRemovedSignal("PondZone"):Connect(refreshPondZones)

local function stopSwimming()
	if not CharacterState.IsSwimming then
		return
	end
	vectorForce.Enabled = false
	linearVelocity.Enabled = false
	swimVelocity = Vector3.zero
	CharacterState.IsSwimming = false
	CharacterState.SetVerticalControls("Swim", false)
end

local function stopWalkingOnWater()
	waterFloater.Parent = nil
	glideVelocity.Enabled = false
	glide = Vector3.zero
end

local function stopAll()
	stopSwimming()
	stopWalkingOnWater()
	CharacterState.SetVerticalControls("SwimSurface", false)
end

local function stageAllowsWater(): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Larve" or stage == "Mue" or stage == "Adulte"
end

-- Mirroir exact de SurvivalService.isInPondZoneXZ (test horizontal en espace local de la zone).
local function isInAnyPondZone(): boolean
	local position = rootPart.Position
	for _, zonePart in ipairs(pondZones) do
		local relative = zonePart.CFrame:PointToObjectSpace(position)
		local halfSize = zonePart.Size * 0.5
		if math.abs(relative.X) <= halfSize.X and math.abs(relative.Z) <= halfSize.Z then
			return true
		end
	end
	return false
end

local function updateWaterWalker(deltaTime: number, waterLevel: number)
	-- Pas de flotteur au-dessus d'un insecte déjà sous l'eau : il resterait coincé dessous.
	local feetY = rootPart.Position.Y - humanoid.HipHeight - rootPart.Size.Y * 0.5
	if feetY < waterLevel - 1 then
		stopWalkingOnWater()
		return
	end
	waterFloater.Position = Vector3.new(rootPart.Position.X, waterLevel - (waterFloater.Size.Y / 2), rootPart.Position.Z)
	waterFloater.Parent = workspace

	local horizontal = CharacterState.GetWorldMove(humanoid)
	-- WalkSpeed serveur : statuts (étourdi, glu, ralenti) déjà inclus par MovementService.
	-- Le vent en surface de la mare fait légèrement dériver les patineurs d'eau (Gerris, Éphémère...).
	local rawWind = workspace:GetAttribute("WindVector")
	local surfaceWind = if typeof(rawWind) == "Vector3" and player:GetAttribute("InShelterOrColony") ~= true
		then Vector3.new(rawWind.X, 0, rawWind.Z) * 0.42
		else Vector3.zero
	local desired = horizontal * humanoid.WalkSpeed * GLIDE_SPEED_FACTOR + surfaceWind
	local sharpness = if horizontal.Magnitude > 0.05 then GLIDE_ACCEL_SHARPNESS else GLIDE_DECEL_SHARPNESS
	if not glideVelocity.Enabled then
		local velocity = rootPart.AssemblyLinearVelocity
		glide = Vector3.new(velocity.X, 0, velocity.Z)
	end
	glide = glide:Lerp(desired, 1 - math.exp(-sharpness * deltaTime))
	glideVelocity.PlaneVelocity = Vector2.new(glide.X, glide.Z)
	glideVelocity.Enabled = true
end

RunService.RenderStepped:Connect(function(deltaTime: number)
	if humanoid.Health <= 0 or CharacterState.IsFlying or not stageAllowsWater() or player:GetAttribute("IsGrabbed") == true then
		stopAll()
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	local canSwim = if species then species.CanSwim else false
	local canWalkOnWater = if species then species.CanWalkOnWater else false
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	-- Monde pas encore généré (waterLevel nil) : idle, pas d'erreur.
	if (not canSwim and not canWalkOnWater) or waterLevel == nil then
		stopAll()
		return
	end

	local isInZone = isInAnyPondZone()

	if canWalkOnWater and isInZone then
		-- Glisse à la surface : on ne plonge pas, le flotteur ancré colle au joueur.
		stopSwimming()
		CharacterState.SetVerticalControls("SwimSurface", false)
		updateWaterWalker(deltaTime, waterLevel)
		return
	end

	stopWalkingOnWater()

	local y = rootPart.Position.Y
	-- Posé / flottant À la surface (le Humanoid garde le corps hors de l'eau) : "Bas" (Ctrl, Q...)
	-- est déjà disponible et fait plonger, sans attendre d'être immergé.
	local feetY = y - humanoid.HipHeight - rootPart.Size.Y * 0.5
	local atSurface = canSwim and isInZone and feetY < waterLevel + SURFACE_DIVE_MARGIN and os.clock() >= breachUntil
	CharacterState.SetVerticalControls("SwimSurface", atSurface and not CharacterState.IsSwimming)
	local diving = atSurface and CharacterState.IsDescendHeld()
	local limit = if CharacterState.IsSwimming then waterLevel + SURFACE_EXIT_MARGIN else waterLevel
	if not (canSwim and isInZone and (y < limit or diving)) or os.clock() < breachUntil then
		stopSwimming()
		return
	end

	if not CharacterState.IsSwimming then
		CharacterState.IsSwimming = true
		-- "Swim" avant de retirer "SwimSurface" : les boutons restent liés, l'appui sur Bas n'est pas perdu.
		CharacterState.SetVerticalControls("Swim", true)
		CharacterState.SetVerticalControls("SwimSurface", false)
		swimVelocity = rootPart.AssemblyLinearVelocity * ENTRY_MOMENTUM
	end

	local swimSpeed = humanoid.WalkSpeed * SWIM_SPEED_FACTOR
	local horizontal, cameraVertical = CharacterState.GetWorldMove(humanoid)
	local jumpHeld = CharacterState.IsJumpHeld(humanoid)
	local buttons = if jumpHeld then 1 elseif CharacterState.IsDescendHeld() then -1 else 0
	local vertical = math.clamp(buttons + cameraVertical, -1, 1)
	local depth = waterLevel - y

	-- Jaillissement : Saut maintenu juste sous la surface => on sort de l'eau d'un coup de patte.
	-- En remontée seulement : à l'entrée (élan de chute), un saut encore maintenu ne rejette pas dehors.
	if jumpHeld and depth < BREACH_DEPTH and swimVelocity.Y > 0 and swimSpeed > 0 then
		local jumpSpeed = if humanoid.UseJumpPower then humanoid.JumpPower else math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
		local velocity = swimVelocity
		stopSwimming()
		rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(velocity.Y, jumpSpeed * 0.9), velocity.Z)
		breachUntil = os.clock() + BREACH_GRACE
		return
	end

	-- Recalculé chaque frame : ApplyStageStats change l'échelle du personnage donc sa masse.
	vectorForce.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)
	vectorForce.Enabled = true

	local desiredY = vertical * swimSpeed * VERTICAL_SPEED_FACTOR
	if vertical == 0 then
		-- Flottabilité : remontée lente, puis calage en douceur juste sous la surface.
		if depth < SURFACE_BAND then
			local restY = waterLevel - SURFACE_REST_DEPTH + math.sin(os.clock() * SURFACE_BOB_FREQUENCY) * SURFACE_BOB_AMPLITUDE * 0.5
			desiredY = math.clamp((restY - y) * SURFACE_SPRING, -BUOYANCY_RISE * 2, BUOYANCY_RISE * 2)
		else
			desiredY = BUOYANCY_RISE
		end
	end
	local desiredVelocity = Vector3.new(horizontal.X * swimSpeed, desiredY, horizontal.Z * swimSpeed)

	-- Impulsion externe (recul, ruée, bond) : reprise dans l'inertie au lieu d'être écrasée.
	if linearVelocity.Enabled and (rootPart.AssemblyLinearVelocity - linearVelocity.VectorVelocity).Magnitude > 25 then
		swimVelocity = rootPart.AssemblyLinearVelocity
	end
	-- Effet de traînée de l'eau : on amortit vers la vitesse voulue au lieu d'un arrêt/départ instantané.
	swimVelocity = swimVelocity:Lerp(desiredVelocity, 1 - math.exp(-DRAG_SHARPNESS * deltaTime))
	linearVelocity.VectorVelocity = swimVelocity
	linearVelocity.Enabled = true
end)

humanoid.Died:Connect(stopAll)

script.Destroying:Connect(stopAll)
