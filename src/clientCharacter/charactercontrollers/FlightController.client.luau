--!strict
-- FlightController.client.luau
-- Vol libre en 3D pour les espèces volantes devenues Adulte (StarterCharacterScripts.characterControllers)
--
-- Vol avec inertie (accélération / décélération), inclinaison en virage, piqué/cabré selon la
-- vitesse verticale, vol stationnaire légèrement ondulant et atterrissage amorti.
-- Décollage : nouvel appui sur Saut en chute libre (clavier, manette, bouton tactile).
-- Monter = Saut maintenu ; Descendre = bouton "Bas" (CharacterState) ; ou incliner la caméra.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local FLIGHT_SPEED_MULTIPLIER = 1.3
local VERTICAL_SPEED_FACTOR = 0.8
local DIVE_SPEED_FACTOR = 1.35 -- un piqué va plus vite qu'une montée
local ACCEL_SHARPNESS = 3 -- plus haut = la vitesse rejoint la consigne plus vite
local DECEL_SHARPNESS = 1.6 -- plus bas que l'accélération : on glisse un peu avant de s'arrêter
local TAKEOFF_LIFT = 6 -- petite impulsion vers le haut au décollage (studs/s)
local HOVER_BOB_AMPLITUDE = 0.8
local HOVER_BOB_FREQUENCY = 2.4
local TURN_SHARPNESS = 6
local HEADING_MIN_SPEED = 1.5 -- sous cette vitesse horizontale on garde le cap actuel
local TILT_SHARPNESS = 5
-- cos(bank) * cos(pitch) doit rester > 0.8 : InsectAnimationController ne bat des ailes que si UpVector.Y > 0.8.
local MAX_BANK = math.rad(25)
local MAX_PITCH = math.rad(20)
local BANK_PER_YAW_RATE = 0.18
local LANDING_PROBE = 10 -- distance au sol (sous les pieds) où commence l'amorti
local LANDING_SHARPNESS = 1.5 -- vitesse de descente max = clearance * ceci + minimum
local LANDING_MIN_SPEED = 2
local TWO_PI = math.pi * 2

local isFlying = false
local lastJumpHeld = false
local flightVelocity = Vector3.zero
local yaw = 0
local bank = 0
local pitch = 0

-- Un seul Attachment partagé par le VectorForce (annule la gravité), le LinearVelocity (pilotage)
-- et l'AlignOrientation (cap, inclinaison).
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

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Attachment0 = attachment
alignOrientation.Responsiveness = 18
alignOrientation.MaxTorque = 1e6
alignOrientation.Enabled = false
alignOrientation.Parent = rootPart

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }
-- Les zones invisibles (PondZone, déclencheurs) ne sont pas un sol : pas de freinage en plein air.
rayParams.RespectCanCollide = true

-- Lu à chaque frame : Species/Stage/FlightBlocked peuvent changer (mue, hypothermie, repop).
local function canFlyNow(): boolean
	if humanoid.Health <= 0 or CharacterState.IsSwimming then
		return false
	end
	-- Plongé dans l'eau (Terrain Water) : on referme le vol, SwimController prend le relais.
	if humanoid:GetState() == Enum.HumanoidStateType.Swimming then
		return false
	end
	if player:GetAttribute("FlightBlocked") == true or player:GetAttribute("IsGrabbed") == true then
		return false
	end
	if player:GetAttribute("Stage") ~= "Adulte" then
		return false -- le vol ne se débloque qu'à l'âge adulte (GDD), jamais en Larve/Mue
	end
	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	return if species then species.CanFly else false
end

local function stopFlying()
	if not isFlying then
		return
	end
	isFlying = false
	vectorForce.Enabled = false
	linearVelocity.Enabled = false
	alignOrientation.Enabled = false
	humanoid.AutoRotate = true
	CharacterState.IsFlying = false
	CharacterState.SetVerticalControls("Flight", false)
end

local function startFlying()
	isFlying = true
	CharacterState.IsFlying = true
	CharacterState.SetVerticalControls("Flight", true)
	humanoid.AutoRotate = false
	-- On part de l'élan actuel (pas d'arrêt net en l'air), avec un petit coup d'aile vers le haut.
	local velocity = rootPart.AssemblyLinearVelocity
	flightVelocity = Vector3.new(velocity.X, math.max(velocity.Y, TAKEOFF_LIFT), velocity.Z)
	local look = rootPart.CFrame.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	bank = 0
	pitch = 0
end

RunService.RenderStepped:Connect(function(deltaTime: number)
	local dt = math.max(deltaTime, 1 / 240)
	-- Front montant lu chaque frame (même au sol) : le saut initial ne déclenche pas le vol.
	local jumpHeld = CharacterState.IsJumpHeld(humanoid)
	local jumpPressed = jumpHeld and not lastJumpHeld
	lastJumpHeld = jumpHeld

	if not isFlying then
		if
			jumpPressed
			and not CharacterState.IsClimbingWall
			and os.clock() >= CharacterState.WallJumpUntil
			and humanoid:GetState() == Enum.HumanoidStateType.Freefall
			and canFlyNow()
		then
			startFlying()
		else
			return
		end
	end
	if not canFlyNow() then
		stopFlying()
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	-- Bonus d'été (endurance des volants) et "Courant ascendant" du Papillon (pouvoir R).
	local seasonBonus = (workspace:GetAttribute("FlightSeasonBonus") :: number?) or 1
	local abilityBoost = (player:GetAttribute("FlightBoost") :: number?) or 1
	local agility = 1
	-- Passifs de vol : "Reine du ciel" (Libellule) et maniabilité de la Guêpe émeraude.
	if species and table.find(species.Abilities, "Vol360Stationnaire") then
		abilityBoost *= 1.25
		agility = 1.6 -- s'arrête net et repart sur place
	elseif species and table.find(species.Abilities, "VolAcrobatique") then
		abilityBoost *= 1.15
		agility = 1.35
	end
	-- WalkSpeed serveur (MovementService) : inclut déjà soif, statuts, carapace, saisie...
	local flightSpeed = humanoid.WalkSpeed * FLIGHT_SPEED_MULTIPLIER * seasonBonus * abilityBoost

	-- Recalculé chaque frame : ApplyStageStats change l'échelle du personnage donc sa masse.
	vectorForce.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)
	vectorForce.Enabled = true

	local horizontal, cameraVertical = CharacterState.GetWorldMove(humanoid)
	local buttons = if jumpHeld then 1 elseif CharacterState.IsDescendHeld() then -1 else 0
	local vertical = math.clamp(buttons + cameraVertical, -1, 1)
	local verticalFactor = if vertical < 0 then DIVE_SPEED_FACTOR else VERTICAL_SPEED_FACTOR
	local desiredY = vertical * flightSpeed * verticalFactor
	local hasInput = vertical ~= 0 or horizontal.Magnitude > 0.05
	if not hasInput then
		-- Vol stationnaire : légère ondulation plutôt qu'un point figé.
		desiredY = math.sin(os.clock() * HOVER_BOB_FREQUENCY) * HOVER_BOB_AMPLITUDE
	end
	local desired = Vector3.new(horizontal.X * flightSpeed, desiredY, horizontal.Z * flightSpeed)

	-- Inertie : la vitesse rejoint la consigne exponentiellement (indépendant du framerate).
	local sharpness = (if hasInput then ACCEL_SHARPNESS else DECEL_SHARPNESS) * agility
	-- Vents forts d'automne : poussent les insectes en vol (GDD §4).
	local wind = (workspace:GetAttribute("WindVector") :: Vector3?) or Vector3.zero
	-- Impulsion externe (recul, ruée, bond d'AbilityController) : reprise dans l'inertie au lieu d'être écrasée.
	if linearVelocity.Enabled and (rootPart.AssemblyLinearVelocity - linearVelocity.VectorVelocity).Magnitude > 25 then
		flightVelocity = rootPart.AssemblyLinearVelocity - wind
	end
	flightVelocity = flightVelocity:Lerp(desired, 1 - math.exp(-sharpness * dt))

	-- Atterrissage amorti : près du sol, la vitesse de descente diminue avec la hauteur restante.
	local feetOffset = humanoid.HipHeight + rootPart.Size.Y * 0.5
	if vertical <= 0 and flightVelocity.Y < 0 then
		local ground = workspace:Raycast(rootPart.Position, Vector3.new(0, -(feetOffset + LANDING_PROBE), 0), rayParams)
		if ground then
			local clearance = math.max(0, rootPart.Position.Y - ground.Position.Y - feetOffset)
			local minY = -(LANDING_MIN_SPEED + clearance * LANDING_SHARPNESS)
			if flightVelocity.Y < minY then
				flightVelocity = Vector3.new(flightVelocity.X, minY, flightVelocity.Z)
			end
		end
	end

	linearVelocity.VectorVelocity = flightVelocity + wind
	linearVelocity.Enabled = true

	-- Cap : suit la vitesse horizontale ; inclinaison = vitesse de virage, tangage = vitesse verticale.
	local horizontalSpeed = math.sqrt(flightVelocity.X * flightVelocity.X + flightVelocity.Z * flightVelocity.Z)
	local turn = 0
	if horizontalSpeed > HEADING_MIN_SPEED then
		local targetYaw = math.atan2(-flightVelocity.X, -flightVelocity.Z)
		local delta = (targetYaw - yaw + math.pi) % TWO_PI - math.pi
		turn = delta * (1 - math.exp(-TURN_SHARPNESS * agility * dt))
		yaw = (yaw + turn) % TWO_PI
	end
	local tiltAlpha = 1 - math.exp(-TILT_SHARPNESS * dt)
	local targetBank = math.clamp(turn / dt * BANK_PER_YAW_RATE, -MAX_BANK, MAX_BANK)
	local targetPitch = math.clamp(flightVelocity.Y / math.max(flightSpeed, 1), -1, 1) * MAX_PITCH
	bank += (targetBank - bank) * tiltAlpha
	pitch += (targetPitch - pitch) * tiltAlpha
	alignOrientation.CFrame = CFrame.fromEulerAnglesYXZ(pitch, yaw, bank)
	alignOrientation.Enabled = true

	-- Atterrissage naturel : pieds au sol et pas de tentative de montée => on referme le vol.
	if humanoid.FloorMaterial ~= Enum.Material.Air and vertical <= 0 then
		stopFlying()
	end
end)

humanoid.Died:Connect(stopFlying)
