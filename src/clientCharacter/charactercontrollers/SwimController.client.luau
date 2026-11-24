--!strict
-- SwimController.client.luau
-- Nage libre sous l'eau (CanSwim) ou glisse à la surface (CanWalkOnWater) (StarterCharacterScripts.characterControllers)
--
-- Contrat monde identique à SurvivalService (server) : workspace:GetAttribute("PondWaterLevel")
-- + CollectionService tag "PondZone" (une boîte par bassin : mare + tronçons du ruisseau, test XZ).
-- Tant que ce contrat n'est pas rempli, on reste idle sans erreur.
-- Monter = Saut maintenu ; Descendre = bouton "Bas" (CharacterState) ; ou incliner la caméra.
-- Propulsion propre à l'espèce (SwimProfiles) : coups de rames par à-coups (dytique, notonecte),
-- jet (larve de libellule), tortillement (larves), marche sur le fond (nèpe, crabe), glisse (poisson).
-- Le gerris rame à la surface (à-coups des pattes médianes) au lieu de glisser en continu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SwimProfiles = require(ReplicatedStorage.shared.SwimProfiles)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local SWIM_SPEED_FACTOR = 0.6
local VERTICAL_SPEED_FACTOR = 0.7
local WIGGLE_FREQUENCY = 12 -- tortillement des larves (rad/s)
local BOTTOM_CRAWL_FACTOR = 0.5 -- marcheurs du fond : vitesse de marche sous l'eau
local ROW_PERIOD = 0.3 -- gerris : un coup de pattes médianes toutes les 0.3 s
local ROW_IMPULSE = 0.8
local ROW_DRAG = 1.6
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
local strokeTimer = 0
local rowTimer = 0
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
	if not glideVelocity.Enabled then
		local velocity = rootPart.AssemblyLinearVelocity
		glide = Vector3.new(velocity.X, 0, velocity.Z)
	end
	if player:GetAttribute("Species") == "Gerris" then
		-- Rame : poussée par à-coups puis longue glisse sur le film d'eau.
		rowTimer -= deltaTime
		if horizontal.Magnitude > 0.05 and rowTimer <= 0 then
			rowTimer = ROW_PERIOD
			glide += horizontal.Unit * humanoid.WalkSpeed * ROW_IMPULSE
		end
		glide *= math.exp(-ROW_DRAG * deltaTime)
		local cap = humanoid.WalkSpeed * GLIDE_SPEED_FACTOR * 1.4
		if glide.Magnitude > cap then
			glide = glide.Unit * cap
		end
		glide += surfaceWind * deltaTime
	else
		local desired = horizontal * humanoid.WalkSpeed * GLIDE_SPEED_FACTOR + surfaceWind
		local sharpness = if horizontal.Magnitude > 0.05 then GLIDE_ACCEL_SHARPNESS else GLIDE_DECEL_SHARPNESS
		glide = glide:Lerp(desired, 1 - math.exp(-sharpness * deltaTime))
	end
	glideVelocity.PlaneVelocity = Vector2.new(glide.X, glide.Z)
	glideVelocity.Enabled = true
end

local connection: RBXScriptConnection? = nil
connection = RunService.RenderStepped:Connect(function(deltaTime: number)
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

	-- Impulsion externe (recul, ruée, bond) : reprise dans l'inertie au lieu d'être écrasée.
	if linearVelocity.Enabled and (rootPart.AssemblyLinearVelocity - linearVelocity.VectorVelocity).Magnitude > 25 then
		swimVelocity = rootPart.AssemblyLinearVelocity
	end

	local profile = SwimProfiles.For(speciesId)
	local input = Vector3.new(horizontal.X, vertical * VERTICAL_SPEED_FACTOR, horizontal.Z)
	local hasInput = input.Magnitude > 0.05
	local direction = if hasInput then input.Unit else Vector3.zero
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

	if profile.Style == "Fond" and grounded and vertical <= 0 then
		-- Marcheur du fond (nèpe, phrygane, crabe) : il marche lentement sur le fond, il ne nage pas.
		local crawl = humanoid.WalkSpeed * BOTTOM_CRAWL_FACTOR
		swimVelocity = Vector3.new(horizontal.X * crawl, math.min(swimVelocity.Y, 0), horizontal.Z * crawl)
	elseif profile.StrokePeriod > 0 then
		-- Coups de pattes / jets : poussée par à-coups, puis glisse freinée par l'eau.
		strokeTimer -= deltaTime
		if hasInput and strokeTimer <= 0 then
			strokeTimer = profile.StrokePeriod
			swimVelocity += direction * swimSpeed * profile.StrokeImpulse
		elseif not hasInput then
			strokeTimer = math.min(strokeTimer, 0.05) -- le prochain appui part tout de suite
		end
		swimVelocity *= math.exp(-profile.Drag * deltaTime)
	else
		-- Poussée continue (poisson) ou tortillement en zigzag (larves).
		local target = direction * swimSpeed * profile.StrokeImpulse
		if profile.Wiggle > 0 and hasInput then
			local side = Vector3.yAxis:Cross(direction)
			if side.Magnitude > 0.01 then
				target += side.Unit * math.sin(os.clock() * WIGGLE_FREQUENCY) * swimSpeed * profile.Wiggle
			end
		end
		swimVelocity = swimVelocity:Lerp(target, 1 - math.exp(-profile.Drag * deltaTime))
	end

	-- Flottabilité : les rameurs (pleins d'air) remontent, les marcheurs du fond coulent.
	if vertical == 0 and profile.Buoyancy > 0 and depth < SURFACE_BAND then
		-- Calage en douceur juste sous la surface (respiration), petit tangage.
		local restY = waterLevel - SURFACE_REST_DEPTH + math.sin(os.clock() * SURFACE_BOB_FREQUENCY) * SURFACE_BOB_AMPLITUDE * 0.5
		local springY = math.clamp((restY - y) * SURFACE_SPRING, -BUOYANCY_RISE * 2, BUOYANCY_RISE * 2)
		swimVelocity = Vector3.new(swimVelocity.X, springY, swimVelocity.Z)
	else
		swimVelocity += Vector3.new(0, profile.Buoyancy * deltaTime, 0)
	end
	local cap = swimSpeed * profile.MaxSpeed
	if swimVelocity.Magnitude > cap and cap > 0 then
		swimVelocity = swimVelocity.Unit * cap
	end
	linearVelocity.VectorVelocity = swimVelocity
	linearVelocity.Enabled = true
end)

local function cleanup()
	-- Une seule fois (Died puis Destroying) : stopAll toucherait le Parent du flotteur détruit.
	if not connection then
		return
	end
	stopAll()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	waterFloater:Destroy()
end

humanoid.Died:Connect(cleanup)
script.Destroying:Connect(cleanup)
