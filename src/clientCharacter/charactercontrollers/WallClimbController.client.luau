--!strict
-- WallClimbController.client.luau
-- Permet aux insectes grimpeurs de marcher sur les murs, les troncs d'arbres et les plafonds (StarterCharacterScripts.characterControllers)
--
-- Principe : plusieurs rayons (bas, avant, diagonales, "enroulement" d'arête) donnent une normale
-- moyenne pondérée, lissée dans le temps. Pendant l'escalade le Humanoid est en PlatformStand :
-- AlignOrientation + LinearVelocity pilotent seuls le corps (plus de lutte avec l'auto-redressement).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local CLIMB_SPEED_FACTOR = 0.85
local ENGAGE_MAX_UP_Y = 0.7 -- surface plus raide que ça => on s'y accroche
local RELEASE_MIN_UP_Y = 0.8 -- hystérésis : on rend la main au Humanoid au-delà (sol)
local MIN_CLIMB_TIME = 0.3 -- pas de retour au sol dans la foulée de l'accroche
local LOST_SURFACE_GRACE = 0.25 -- plus aucun contact pendant ce temps => chute
local JUMP_COOLDOWN = 0.4 -- après un saut mural, pas de ré-accroche immédiate
local NORMAL_SHARPNESS = 10 -- lissage de la normale (plus haut = plus vif)
local VELOCITY_SHARPNESS = 14 -- lissage de la vitesse (anti-saccade)
local HOVER_GAIN = 8 -- rappel vers la distance de "pattes" au mur

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }
rayParams.IgnoreWater = true
-- Les zones invisibles (PondZone, déclencheurs) ne sont pas des murs.
rayParams.RespectCanCollide = true

local attachment = Instance.new("Attachment")
attachment.Parent = rootPart

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Attachment0 = attachment
alignOrientation.Responsiveness = 40
alignOrientation.MaxTorque = math.huge
alignOrientation.Enabled = false
alignOrientation.Parent = rootPart

local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.Attachment0 = attachment
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.MaxForce = 50000
linearVelocity.Enabled = false
linearVelocity.Parent = rootPart

local climbing = false
local engagedAt = 0
local lostTime = 0
local jumpCooldownUntil = 0
local jumpWasHeld = false
local smoothedUp = Vector3.yAxis
local climbVelocity = Vector3.zero

-- Accumulateurs du sondage multi-rayons (pas de table allouée par frame).
local accNormal = Vector3.zero
local hitCount = 0
local minGap = math.huge
local nearestNormal = Vector3.yAxis

local function canPlayerClimb(): boolean
	-- Allowlist (pas blocklist) : un Stage pas encore répliqué (nil) ne doit pas autoriser l'escalade.
	local stage = player:GetAttribute("Stage")
	if stage ~= "Larve" and stage ~= "Mue" and stage ~= "Adulte" then
		return false
	end
	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	return if species then species.CanClimbWalls else false
end

-- Distance centre -> surface quand on est "posé sur ses pattes". Relu chaque frame : ScaleTo
-- (changement de stade) agrandit le root et la HipHeight.
local function getBodyReach(): number
	return humanoid.HipHeight + rootPart.Size.Y * 0.5
end

local function projectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - normal * v:Dot(normal)
end

local function probe(origin: Vector3, direction: Vector3, length: number): RaycastResult?
	local result = workspace:Raycast(origin, direction * length, rayParams)
	-- Distance ~0 : rayon parti de l'intérieur d'un volume (rayon d'arête dans le Terrain), normale non fiable.
	if result and result.Distance > 0.01 then
		-- Le plus proche domine, mais chaque contact compte un peu : transitions progressives.
		local closeness = 1 - result.Distance / length
		accNormal += result.Normal * (0.15 + closeness * closeness)
		hitCount += 1
		local gap = (rootPart.Position - result.Position):Dot(result.Normal)
		if gap < minGap then
			minGap = gap
			nearestNormal = result.Normal
		end
	end
	return result
end

local function stopClimbing(landedOnFloor: boolean)
	if not climbing then
		return
	end
	climbing = false
	CharacterState.IsClimbingWall = false
	alignOrientation.Enabled = false
	linearVelocity.Enabled = false
	humanoid.PlatformStand = false
	if humanoid.Health <= 0 then
		return
	end
	if landedOnFloor then
		-- Redressement net : la normale lissée est déjà presque verticale, le saut est invisible.
		local position = rootPart.Position
		local flat = projectOnPlane(rootPart.CFrame.LookVector, Vector3.yAxis)
		if flat.Magnitude > 0.05 then
			rootPart.CFrame = CFrame.lookAt(position, position + flat)
		end
	else
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

local function startClimbing()
	climbing = true
	engagedAt = os.clock()
	lostTime = 0
	-- Part de l'orientation actuelle : la normale lissée tourne ensuite vers le mur.
	smoothedUp = rootPart.CFrame.UpVector
	climbVelocity = rootPart.AssemblyLinearVelocity
	CharacterState.IsClimbingWall = true
	humanoid.PlatformStand = true
	alignOrientation.CFrame = rootPart.CFrame.Rotation
	alignOrientation.Enabled = true
	linearVelocity.VectorVelocity = climbVelocity
	linearVelocity.Enabled = true
end

-- Direction voulue sur la surface, relative à la caméra : "avancer" = s'éloigner de la caméra ;
-- face à un mur, la part de l'élan qui rentrerait dans le mur devient "monter".
local function getSurfaceMove(up: Vector3): Vector3
	local input = CharacterState.GetMoveVector(humanoid)
	local camera = workspace.CurrentCamera
	if input.Magnitude < 0.05 or not camera then
		return Vector3.zero
	end
	local camCFrame = camera.CFrame
	local heading = projectOnPlane(camCFrame.LookVector, Vector3.yAxis)
	if heading.Magnitude < 0.05 then
		heading = projectOnPlane(camCFrame.UpVector, Vector3.yAxis) -- caméra à la verticale
	end
	heading = heading.Unit
	local forward = projectOnPlane(heading, up) + projectOnPlane(Vector3.yAxis, up) * -heading:Dot(up)
	if forward.Magnitude < 0.01 then
		return Vector3.zero
	end
	forward = forward.Unit
	-- La droite caméra reste juste au sol et au plafond (vu d'en dessous) ; mur latéral => repli.
	local right = projectOnPlane(camCFrame.RightVector, up)
	right += forward:Cross(up) * math.max(0, 1 - right.Magnitude)
	if right.Magnitude > 0.01 then
		right = right.Unit
	end
	local move = projectOnPlane(right * input.X - forward * input.Z, up)
	return if move.Magnitude > 1 then move.Unit else move
end

local function getJumpSpeed(): number
	if humanoid.UseJumpPower then
		return humanoid.JumpPower
	end
	return math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
end

-- Hors escalade : on ne sonde que si le joueur avance, dans sa direction de marche.
local function tryEngage(bodyReach: number)
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 or os.clock() < jumpCooldownUntil then
		return
	end
	local direction = moveDirection.Unit
	local result = workspace:Raycast(rootPart.Position, direction * (bodyReach * 1.2 + rootPart.Size.Z * 0.5), rayParams)
	if result and result.Normal.Y < ENGAGE_MAX_UP_Y and direction:Dot(-result.Normal) > 0.35 then
		startClimbing()
	end
end

local function updateClimb(deltaTime: number, bodyReach: number)
	local up = smoothedUp
	local position = rootPart.Position
	local probeLength = bodyReach * 1.6 + 0.5
	local surfaceMove = getSurfaceMove(up)

	local probeForward = if surfaceMove.Magnitude > 0.1
		then surfaceMove.Unit
		else projectOnPlane(rootPart.CFrame.LookVector, up)
	if probeForward.Magnitude < 0.05 then
		-- LookVector quasi colinéaire à la normale => UpVector (orthogonal) est forcément dans le plan.
		probeForward = projectOnPlane(rootPart.CFrame.UpVector, up)
	end
	probeForward = probeForward.Unit

	accNormal = Vector3.zero
	hitCount = 0
	minGap = math.huge
	nearestNormal = up
	local downHit = probe(position, -up, probeLength)
	probe(position, probeForward, probeLength * 0.9) -- coin rentrant devant (mur -> plafond)
	local frontDiagonal = probe(position, (probeForward - up).Unit, probeLength * 1.2)
	probe(position, (-probeForward - up).Unit, probeLength * 1.2)
	if not downHit or not frontDiagonal then
		-- Arête saillante (haut d'un mur) : on vise, depuis un point au-delà de l'arête, la face d'après.
		probe(position + probeForward * bodyReach - up * (bodyReach * 1.5), -probeForward, bodyReach * 2)
	end

	local speed = humanoid.WalkSpeed * CLIMB_SPEED_FACTOR
	local desired: Vector3
	if hitCount == 0 then
		lostTime += deltaTime
		if lostTime > LOST_SURFACE_GRACE then
			stopClimbing(false)
			return
		end
		desired = projectOnPlane(climbVelocity, up) - up * 4 -- garde l'élan et cherche la surface
	else
		lostTime = 0
		local targetUp = if accNormal.Magnitude > 0.01 then accNormal.Unit else up
		-- Demi-tour complet (rare) : on passe par l'avant pour que l'interpolation ne s'annule pas.
		if smoothedUp:Dot(targetUp) < -0.9 then
			targetUp = (targetUp + probeForward).Unit
		end
		smoothedUp = smoothedUp:Lerp(targetUp, 1 - math.exp(-NORMAL_SHARPNESS * deltaTime)).Unit
		up = smoothedUp

		if
			os.clock() - engagedAt > MIN_CLIMB_TIME
			-- Attend que la normale lissée ait rejoint le sol : le redressement final reste invisible.
			and up:Dot(targetUp) > 0.99
			and targetUp.Y >= RELEASE_MIN_UP_Y
			and downHit
			and downHit.Normal.Y >= RELEASE_MIN_UP_Y
		then
			stopClimbing(true)
			return
		end

		local hover = math.clamp((bodyReach - minGap) * HOVER_GAIN, -speed, speed)
		desired = projectOnPlane(surfaceMove, up) * speed + nearestNormal * hover
	end

	climbVelocity = climbVelocity:Lerp(desired, 1 - math.exp(-VELOCITY_SHARPNESS * deltaTime))
	linearVelocity.VectorVelocity = climbVelocity
	-- Suit la masse : ScaleTo l'augmente, il faut toujours vaincre la gravité.
	linearVelocity.MaxForce = math.max(50000, rootPart.AssemblyMass * workspace.Gravity * 4)

	local facing = projectOnPlane(if surfaceMove.Magnitude > 0.1 then surfaceMove else rootPart.CFrame.LookVector, up)
	if facing.Magnitude < 0.05 then
		facing = probeForward
	end
	alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, facing.Unit, up)
end

local connection: RBXScriptConnection? = nil
connection = RunService.RenderStepped:Connect(function(deltaTime: number)
	local jumpHeld = CharacterState.IsJumpHeld(humanoid)
	local jumpPressed = jumpHeld and not jumpWasHeld
	jumpWasHeld = jumpHeld

	-- Cède la main à Flight/Swim : sinon leurs LinearVelocity/AlignOrientation respectifs se battent.
	-- Saisi par un prédateur : le serveur déplace la victime, on ne lutte pas contre lui.
	if
		not canPlayerClimb()
		or humanoid.Health <= 0
		or CharacterState.IsFlying
		or CharacterState.IsSwimming
		or player:GetAttribute("IsGrabbed") == true
	then
		stopClimbing(false)
		return
	end

	local bodyReach = getBodyReach()
	if not climbing then
		tryEngage(bodyReach)
		return
	end

	if jumpPressed then
		-- Saut mural : on se détache le long de la normale, avec un peu de hauteur.
		local jumpNormal = smoothedUp
		local jumpSpeed = getJumpSpeed()
		jumpCooldownUntil = os.clock() + JUMP_COOLDOWN
		stopClimbing(false)
		rootPart.AssemblyLinearVelocity = jumpNormal * jumpSpeed + Vector3.yAxis * (jumpSpeed * 0.4)
		return
	end

	-- Impulsion externe (recul serveur, secousse du Grand Chêne, ruée) : on lâche prise au lieu de l'écraser.
	if (rootPart.AssemblyLinearVelocity - linearVelocity.VectorVelocity).Magnitude > 35 then
		jumpCooldownUntil = os.clock() + JUMP_COOLDOWN
		stopClimbing(false)
		return
	end

	updateClimb(deltaTime, bodyReach)
end)

local function cleanup()
	stopClimbing(false)
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

humanoid.Died:Connect(cleanup)
script.Destroying:Connect(cleanup)
