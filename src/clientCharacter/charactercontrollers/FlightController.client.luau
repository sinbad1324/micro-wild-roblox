--!strict
-- FlightController.client.luau
-- Vol libre en 3D pour les espèces volantes devenues Adulte (StarterCharacterScripts.characterControllers)
--
-- Vol à poussée limitée : les ailes ne fournissent qu'une accélération max (plus faible en travers
-- qu'en ligne droite) -> élan réel, virages en courbe à pleine vitesse, freinage progressif.
-- Le corps s'incline selon l'ACCÉLÉRATION (nez en bas pour accélérer, roulis vers l'intérieur du
-- virage, cabré pour freiner / se poser), vol stationnaire qui dérive et vibre comme un vrai insecte.
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
local ACCEL_SHARPNESS = 4 -- réactivité vers la consigne (bornée par la poussée)
local DECEL_SHARPNESS = 2 -- sans input : on plane un peu avant de s'arrêter
local THRUST = 3.2 -- accélération max = vitesse de vol * ceci (studs/s²)
local LATERAL_THRUST = 0.65 -- fraction de la poussée disponible en travers : virages en courbe
local TAKEOFF_LIFT = 10 -- coup d'aile vers le haut au décollage (studs/s)
-- Vol stationnaire : dérive lente (bruit de Perlin) + petite vibration rapide (battements).
local HOVER_DRIFT = 1.1
local HOVER_DRIFT_RATE = 0.55
local HOVER_BUZZ = 0.35
local HOVER_BUZZ_RATE = 9
local TURN_SHARPNESS = 6
local HEADING_MIN_SPEED = 1.5 -- sous cette vitesse horizontale on garde le cap actuel
local TILT_SHARPNESS = 7
-- cos(bank) * cos(pitch) doit rester > 0.8 : InsectAnimationController ne bat des ailes que si UpVector.Y > 0.8.
local MAX_BANK = math.rad(25)
local MAX_PITCH = math.rad(20)
local TILT_GRAVITY = 0.3 -- "g" de référence de l'inclinaison (fraction de la gravité) : plus bas = plus penché
local CRUISE_LEAN = math.rad(6) -- nez légèrement en bas en vol rapide
local FLARE = math.rad(14) -- cabré avant de se poser
local FLARE_HEIGHT = 3
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
local hoverSeed = (player.UserId % 997) + 0.5 -- chaque insecte dérive différemment

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

-- ============================================================
-- VFX de vent de vitesse en vol (sillage de bout d'ailes + tunnel de filets d'air à haute vitesse)
-- ============================================================

local function createWingTrail(side: number): (Attachment, Attachment, Trail)
	local att0 = Instance.new("Attachment")
	att0.Name = if side < 0 then "LeftWingTrail0" else "RightWingTrail0"
	att0.Parent = rootPart
	local att1 = Instance.new("Attachment")
	att1.Name = if side < 0 then "LeftWingTrail1" else "RightWingTrail1"
	att1.Parent = rootPart

	local trail = Instance.new("Trail")
	trail.Name = if side < 0 then "LeftWingSlipstream" else "RightWingSlipstream"
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.FaceCamera = true
	trail.Lifetime = 0.28
	trail.MinLength = 0.05
	trail.LightEmission = 0.65
	trail.LightInfluence = 0.35
	trail.Color = ColorSequence.new(Color3.fromRGB(242, 255, 255), Color3.fromRGB(185, 238, 255))
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.25, 1),
		NumberSequenceKeypoint.new(0.75, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.15, 0.22),
		NumberSequenceKeypoint.new(0.7, 0.42),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Enabled = false
	trail.Parent = rootPart
	return att0, att1, trail
end

local leftAtt0, leftAtt1, leftWingTrail = createWingTrail(-1)
local rightAtt0, rightAtt1, rightWingTrail = createWingTrail(1)

local slipstreamBox = Instance.new("Part")
slipstreamBox.Name = "FlightSlipstreamBox"
slipstreamBox.Size = Vector3.new(9, 6, 4.5)
slipstreamBox.Anchored = true
slipstreamBox.CanCollide = false
slipstreamBox.CanQuery = false
slipstreamBox.CanTouch = false
slipstreamBox.CastShadow = false
slipstreamBox.Transparency = 1
slipstreamBox.Parent = workspace.CurrentCamera or workspace

local slipstreamEmitter = Instance.new("ParticleEmitter")
slipstreamEmitter.Name = "FlightSpeedLines"
slipstreamEmitter.Shape = Enum.ParticleEmitterShape.Box
slipstreamEmitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
slipstreamEmitter.EmissionDirection = Enum.NormalId.Front
slipstreamEmitter.Orientation = Enum.ParticleOrientation.VelocityParallel
slipstreamEmitter.LockedToPart = false
slipstreamEmitter.Lifetime = NumberRange.new(0.26, 0.48)
slipstreamEmitter.Speed = NumberRange.new(24, 38)
slipstreamEmitter.SpreadAngle = Vector2.new(7, 5)
slipstreamEmitter.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.08),
	NumberSequenceKeypoint.new(0.45, 0.28),
	NumberSequenceKeypoint.new(1, 0.06),
})
slipstreamEmitter.Squash = NumberSequence.new(-3.6)
slipstreamEmitter.Color = ColorSequence.new(Color3.fromRGB(245, 255, 255), Color3.fromRGB(195, 242, 255))
slipstreamEmitter.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.2, 0.24),
	NumberSequenceKeypoint.new(0.8, 0.34),
	NumberSequenceKeypoint.new(1, 1),
})
slipstreamEmitter.LightEmission = 0.6
slipstreamEmitter.LightInfluence = 0.4
slipstreamEmitter.Rate = 0
slipstreamEmitter.Enabled = false
slipstreamEmitter.Parent = slipstreamBox

local lastQuantizedFlightWind = -1

local function disableFlightWindFx()
	leftWingTrail.Enabled = false
	rightWingTrail.Enabled = false
	slipstreamEmitter.Enabled = false
	slipstreamEmitter.Rate = 0
end

local function updateFlightWindFx(vel: Vector3, baseCruiseSpeed: number)
	local speed = vel.Magnitude
	-- Se déclenche quand on approche/dépasse la pleine vitesse de croisière, et monte au maximum en boost (Shift), piqué ou bourrasque.
	local startSpeed = baseCruiseSpeed * 0.78
	local maxFastSpeed = baseCruiseSpeed * 1.52
	local relativeLevel = math.clamp((speed - startSpeed) / math.max(maxFastSpeed - startSpeed, 4), 0, 1)
	local absoluteLevel = math.clamp((speed - 18) / 28, 0, 1)
	local level = math.clamp(math.max(relativeLevel, absoluteLevel * 0.85), 0, 1)

	if level <= 0.04 or speed < 4 then
		disableFlightWindFx()
		return
	end

	local spanX = math.max(0.85, rootPart.Size.X * 0.72)
	local offsetY = rootPart.Size.Y * 0.12
	local offsetZ = rootPart.Size.Z * 0.1
	local halfWidth = 0.04 + level * 0.18

	leftAtt0.Position = Vector3.new(-spanX, offsetY + halfWidth, offsetZ)
	leftAtt1.Position = Vector3.new(-spanX, offsetY - halfWidth, offsetZ)
	rightAtt0.Position = Vector3.new(spanX, offsetY + halfWidth, offsetZ)
	rightAtt1.Position = Vector3.new(spanX, offsetY - halfWidth, offsetZ)

	local trailLife = 0.14 + level * 0.32
	leftWingTrail.Lifetime = trailLife
	rightWingTrail.Lifetime = trailLife
	leftWingTrail.Enabled = true
	rightWingTrail.Enabled = true

	local velDir = vel / speed
	local boxCenter = rootPart.Position + velDir * (rootPart.Size.Z * 0.6 + 4.8)
	slipstreamBox.CFrame = CFrame.lookAt(boxCenter, boxCenter - velDir)

	local quantized = math.floor(level * 15 + 0.5)
	if quantized ~= lastQuantizedFlightWind then
		lastQuantizedFlightWind = quantized
		local qLvl = quantized / 15
		local peakSize = 0.14 + qLvl * 0.28
		local minAlpha = math.clamp(0.58 - qLvl * 0.40, 0.16, 0.60)
		slipstreamEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, peakSize * 0.35),
			NumberSequenceKeypoint.new(0.45, peakSize),
			NumberSequenceKeypoint.new(1, peakSize * 0.25),
		})
		slipstreamEmitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, minAlpha),
			NumberSequenceKeypoint.new(0.8, math.min(0.95, minAlpha + 0.12)),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	local targetRate = 6 + level * 32 + level * level * 72
	if math.abs(slipstreamEmitter.Rate - targetRate) > 1.5 then
		slipstreamEmitter.Rate = targetRate
	end
	local streakSpd = math.max(18, speed * (1.15 + level * 0.45))
	slipstreamEmitter.Speed = NumberRange.new(streakSpd * 0.85, streakSpd * 1.25)
	slipstreamEmitter.Enabled = true
end

character.AncestryChanged:Connect(function(_, parent)
	if not parent then
		slipstreamBox:Destroy()
	end
end)

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
	disableFlightWindFx()
end

local function startFlying()
	isFlying = true
	CharacterState.IsFlying = true
	CharacterState.SetVerticalControls("Flight", true)
	humanoid.AutoRotate = false
	-- On part de l'élan actuel (pas d'arrêt net en l'air), avec un petit coup d'aile vers le haut.
	local velocity = rootPart.AssemblyLinearVelocity
	flightVelocity = Vector3.new(velocity.X, math.max(velocity.Y + TAKEOFF_LIFT * 0.5, TAKEOFF_LIFT), velocity.Z)
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
			and not CharacterState.IsSwinging
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
	local desired = Vector3.new(horizontal.X * flightSpeed, desiredY, horizontal.Z * flightSpeed)
	if not hasInput then
		-- Vol stationnaire : jamais un point figé, l'insecte dérive lentement et vibre.
		local t = os.clock()
		desired = Vector3.new(
			math.noise(t * HOVER_DRIFT_RATE, hoverSeed) * HOVER_DRIFT,
			math.noise(hoverSeed, t * HOVER_DRIFT_RATE) * HOVER_DRIFT + math.sin(t * HOVER_BUZZ_RATE) * HOVER_BUZZ,
			math.noise(t * HOVER_DRIFT_RATE, -hoverSeed) * HOVER_DRIFT
		)
	end

	-- Vent dynamique (modulé par l'abri, le poids de l'espèce et les rafales) : dévie et emporte l'insecte en vol.
	local wind = CharacterState.GetEffectiveWind(rootPart, rayParams) * (0.95 / math.sqrt(agility))
	-- Impulsion externe (recul, ruée, bond d'AbilityController) : reprise dans l'inertie au lieu d'être écrasée.
	if linearVelocity.Enabled and (rootPart.AssemblyLinearVelocity - linearVelocity.VectorVelocity).Magnitude > 25 then
		flightVelocity = rootPart.AssemblyLinearVelocity - wind
	end
	-- Poussée limitée (indépendant du framerate pour l'approche, borné en accélération) : on garde
	-- l'élan, on tourne en courbe, on freine progressivement.
	local sharpness = (if hasInput then ACCEL_SHARPNESS else DECEL_SHARPNESS) * agility
	local accel = (desired - flightVelocity) * (1 - math.exp(-sharpness * dt)) / dt
	local maxAccel = math.max(flightSpeed, 4) * THRUST * agility
	local speed = flightVelocity.Magnitude
	if speed > 1 then
		-- Composante en travers de la trajectoire : moins de poussée disponible (virage large à pleine vitesse).
		local along = flightVelocity / speed
		local forwardPart = along * accel:Dot(along)
		local lateralPart = accel - forwardPart
		local lateralMax = maxAccel * LATERAL_THRUST
		if lateralPart.Magnitude > lateralMax then
			lateralPart = lateralPart.Unit * lateralMax
		end
		accel = forwardPart + lateralPart
	end
	if accel.Magnitude > maxAccel then
		accel = accel.Unit * maxAccel
	end
	flightVelocity += accel * dt

	-- Atterrissage amorti : près du sol, la vitesse de descente diminue avec la hauteur restante.
	local feetOffset = humanoid.HipHeight + rootPart.Size.Y * 0.5
	local flare = 0
	if vertical <= 0 and flightVelocity.Y < 0 then
		local ground = workspace:Raycast(rootPart.Position, Vector3.new(0, -(feetOffset + LANDING_PROBE), 0), rayParams)
		if ground then
			local clearance = math.max(0, rootPart.Position.Y - ground.Position.Y - feetOffset)
			local minY = -(LANDING_MIN_SPEED + clearance * LANDING_SHARPNESS)
			if flightVelocity.Y < minY then
				flightVelocity = Vector3.new(flightVelocity.X, minY, flightVelocity.Z)
			end
			-- Cabré juste avant de toucher : les ailes freinent la descente.
			flare = math.clamp(1 - clearance / FLARE_HEIGHT, 0, 1) * FLARE
		end
	end

	linearVelocity.VectorVelocity = flightVelocity + wind
	linearVelocity.Enabled = true

	-- Cap : suit la vitesse horizontale.
	local horizontalSpeed = math.sqrt(flightVelocity.X * flightVelocity.X + flightVelocity.Z * flightVelocity.Z)
	local turn = 0
	if horizontalSpeed > HEADING_MIN_SPEED then
		local targetYaw = math.atan2(-flightVelocity.X, -flightVelocity.Z)
		local delta = (targetYaw - yaw + math.pi) % TWO_PI - math.pi
		turn = delta * (1 - math.exp(-TURN_SHARPNESS * agility * dt))
		yaw = (yaw + turn) % TWO_PI
	end
	-- Inclinaison = accélération + poussée latérale du vent vues dans le repère du cap : roulis vers
	-- l'intérieur du virage et sous les rafales, nez en bas pour accélérer / en haut pour freiner.
	local heading = CFrame.fromEulerAnglesYXZ(0, yaw, 0)
	local referenceG = workspace.Gravity * TILT_GRAVITY
	local accelRight = accel:Dot(heading.RightVector) + wind:Dot(heading.RightVector) * 0.45
	local accelForward = accel:Dot(heading.LookVector) - wind:Dot(heading.LookVector) * 0.25
	local tiltAlpha = 1 - math.exp(-TILT_SHARPNESS * dt)
	local targetBank = math.clamp(-math.atan(accelRight / referenceG), -MAX_BANK, MAX_BANK)
	local climb = math.clamp(flightVelocity.Y / math.max(flightSpeed, 1), -1, 1) * MAX_PITCH * 0.6
	local cruise = math.clamp(horizontalSpeed / math.max(flightSpeed, 1), 0, 1) * CRUISE_LEAN
	local targetPitch = math.clamp(climb - math.atan(accelForward / referenceG) * 0.6 - cruise + flare, -MAX_PITCH, MAX_PITCH)
	bank += (targetBank - bank) * tiltAlpha
	pitch += (targetPitch - pitch) * tiltAlpha
	alignOrientation.CFrame = CFrame.fromEulerAnglesYXZ(pitch, yaw, bank)
	alignOrientation.Enabled = true

	-- Effet de vent de vitesse (sillage de bout d'ailes + filets d'air frontaux) quand on vole vite.
	local baseWalkSpeed = if species then species.WalkSpeed else 16
	updateFlightWindFx(flightVelocity, baseWalkSpeed * FLIGHT_SPEED_MULTIPLIER)

	-- Atterrissage naturel : pieds au sol et pas de tentative de montée => on referme le vol.
	if humanoid.FloorMaterial ~= Enum.Material.Air and vertical <= 0 then
		stopFlying()
	end
end)

humanoid.Died:Connect(stopFlying)
