--!strict
-- WallClimbController.client.luau
-- "Spider-walk" (GDD §8.1) : les insectes grimpeurs marchent sur les murs, troncs, dessous des
-- branches et plafonds, avec des transitions continues (StarterCharacterScripts.characterControllers).
--
-- Principe (cinématique, pas de forces lissées qui traînent) : à chaque frame on calcule OÙ
-- l'insecte doit être sur la surface et AVEC QUELLE orientation, puis :
--   * la vitesse du root = (cible - position) / dt  -> la physique l'y amène exactement, les
--     collisions restent gérées, et la vitesse réelle anime les pattes / sons ;
--   * la rotation du root suit la normale lissée (posée directement, sans AlignOrientation) ;
--   * une VectorForce annule la gravité tant qu'on grimpe.
-- Coin rentrant (sol -> mur, mur -> plafond) : un rayon devant détecte la nouvelle face, on pivote.
-- Arête saillante (haut d'un mur, bout de branche) : le rayon sous les pattes ne touche plus, un
-- rayon "d'enroulement" retrouve la face d'après, on s'enroule autour.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local CLIMB_SPEED_FACTOR = 0.9
local WALL_MAX_UP_DOT = 0.7 -- une face dont la normale s'écarte autant de "up" est une nouvelle face
local FLOOR_MIN_Y = 0.85 -- normale assez verticale pour rendre la main au Humanoid (sol)
local MIN_CLIMB_TIME = 0.35
local LOST_SURFACE_GRACE = 0.2
local JUMP_COOLDOWN = 0.4
local UP_SHARPNESS = 14 -- vitesse de bascule de l'orientation (plus haut = plus vif)
local SNAP_SHARPNESS = 22 -- vitesse de recollage à la bonne distance de la surface
local TURN_SHARPNESS = 16 -- vitesse de rotation du corps vers la direction de marche
local MAX_CORRECTION_SPEED = 60
-- Coins : la bascule démarre un peu AVANT le contact (fraction de la portée des pattes) et l'insecte
-- continue d'avancer pendant qu'il tourne (fraction de sa vitesse) au lieu de s'arrêter net.
local PIVOT_LOOKAHEAD = 0.6
local CORNER_SPEED = 0.7

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true -- zones invisibles (PondZone, déclencheurs) ignorées

local attachment = Instance.new("Attachment")
attachment.Name = "ClimbAttachment"
attachment.Parent = rootPart

local antiGravity = Instance.new("VectorForce")
antiGravity.Name = "ClimbAntiGravity"
antiGravity.Attachment0 = attachment
antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
antiGravity.ApplyAtCenterOfMass = true
antiGravity.Enabled = false
antiGravity.Parent = rootPart

local climbing = false
local engagedAt = 0
local lostTime = 0
local floorTime = 0 -- temps passé d'affilée sur une face de sol (retour au Humanoid)
local FLOOR_CONFIRM_TIME = 0.15
local jumpCooldownUntil = 0
local jumpWasHeld = false
local up = Vector3.yAxis -- normale lissée de la surface sous les pattes
local facing = Vector3.new(0, 0, -1) -- direction du regard, dans le plan de la surface
local pivotUp: Vector3? = nil -- coin rentrant en cours : face visée (gardée jusqu'à la fin du pivot)
local pivotFrom = Vector3.yAxis -- face quittée pendant le pivot
-- Collision du root coupée UNIQUEMENT pendant une bascule (coin rentrant / arête) : la boîte englobe
-- tout le corps (tête, mâchoires) et se coinçait contre le mur / le plafond en tournant. Le reste du
-- temps elle reste active : sans elle, l'insecte traversait le sol et tombait dans le vide.
local rootCollided = rootPart.CanCollide

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = { character }
overlapParams.RespectCanCollide = true

local function overlapsWorld(): boolean
	return #workspace:GetPartsInPart(rootPart, overlapParams) > 0
end

local function canPlayerClimb(): boolean
	-- Allowlist : un Stage pas encore répliqué (nil) ne doit pas autoriser l'escalade.
	local stage = player:GetAttribute("Stage")
	if stage ~= "Larve" and stage ~= "Mue" and stage ~= "Adulte" then
		return false
	end
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	return species ~= nil and species.CanClimbWalls
end

-- Distance centre -> surface quand l'insecte est posé sur ses pattes (relue chaque frame :
-- ScaleTo et l'ajustement du root au corps la changent).
local function getBodyReach(): number
	return humanoid.HipHeight + rootPart.Size.Y * 0.5
end

-- Demi-épaisseur de la boîte du root le long de "dir" (le root est allongé : corps de l'insecte).
local function bodyExtent(dir: Vector3): number
	local l = rootPart.CFrame:VectorToObjectSpace(dir)
	local h = rootPart.Size * 0.5
	return math.abs(l.X) * h.X + math.abs(l.Y) * h.Y + math.abs(l.Z) * h.Z
end

local function projectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - normal * v:Dot(normal)
end

local function ray(origin: Vector3, direction: Vector3, length: number): RaycastResult?
	local result = workspace:Raycast(origin, direction * length, rayParams)
	-- Distance ~0 : rayon parti de l'intérieur d'un volume, normale non fiable.
	if result and result.Distance > 0.01 then
		return result
	end
	return nil
end

-- Interpolation de direction qui ne s'annule jamais (demi-tour complet : passe par "pivot").
local function turnToward(from: Vector3, to: Vector3, alpha: number, pivot: Vector3): Vector3
	if from:Dot(to) < -0.95 then
		to = (to + pivot * 0.5).Unit
	end
	local mixed = from:Lerp(to, alpha)
	return if mixed.Magnitude > 1e-3 then mixed.Unit else to
end

-- Direction voulue sur la surface, relative à la caméra : "avancer" = s'éloigner de la caméra ;
-- face à un mur, la part de l'élan qui rentrerait dans le mur devient "monter".
local function getSurfaceMove(surfaceUp: Vector3): Vector3
	local input = CharacterState.GetMoveVector(humanoid)
	local camera = workspace.CurrentCamera
	if input.Magnitude < 0.05 or not camera then
		return Vector3.zero
	end
	local camCFrame = camera.CFrame
	local heading = projectOnPlane(camCFrame.LookVector, Vector3.yAxis)
	if heading.Magnitude < 0.05 then
		heading = projectOnPlane(camCFrame.UpVector, Vector3.yAxis)
	end
	heading = heading.Unit
	local forward = projectOnPlane(heading, surfaceUp) + projectOnPlane(Vector3.yAxis, surfaceUp) * -heading:Dot(surfaceUp)
	if forward.Magnitude < 0.01 then
		return Vector3.zero
	end
	forward = forward.Unit
	local right = projectOnPlane(camCFrame.RightVector, surfaceUp)
	right += forward:Cross(surfaceUp) * math.max(0, 1 - right.Magnitude)
	if right.Magnitude > 0.01 then
		right = right.Unit
	end
	local move = projectOnPlane(right * input.X - forward * input.Z, surfaceUp)
	return if move.Magnitude > 1 then move.Unit else move
end

local function getJumpSpeed(): number
	if humanoid.UseJumpPower then
		return humanoid.JumpPower
	end
	return math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
end

local function stopClimbing(landedOnFloor: boolean)
	if not climbing then
		return
	end
	climbing = false
	pivotUp = nil
	CharacterState.IsClimbingWall = false
	antiGravity.Enabled = false
	humanoid.PlatformStand = false
	rootPart.AssemblyAngularVelocity = Vector3.zero
	-- Collision rendue TOUT DE SUITE (jamais de chute sans collision) ; la dernière normale sert à
	-- dégager la boîte si elle mord dans le décor après le redressement.
	local lastUp = up
	rootPart.CanCollide = rootCollided
	if humanoid.Health <= 0 then
		return
	end
	-- Redressement (aussi en chute : un root resté à 90/180° ferait trébucher le Humanoid).
	-- Retour au sol : l'orientation lissée est déjà quasi droite, le raccord est invisible.
	local flat = projectOnPlane(facing, Vector3.yAxis)
	if flat.Magnitude < 0.05 then
		flat = projectOnPlane(rootPart.CFrame.LookVector, Vector3.yAxis)
	end
	if flat.Magnitude > 0.05 then
		local position = rootPart.Position
		rootPart.CFrame = CFrame.lookAt(position, position + flat)
	end
	-- Petits pas le long de la normale quittée tant que la boîte chevauche une part (pas d'éjection).
	local push = math.max(0.05, rootPart.Size.Y * 0.25)
	for _ = 1, 8 do
		if not overlapsWorld() then
			break
		end
		rootPart.CFrame += lastUp * push
	end
	if landedOnFloor then
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	else
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
end

local function startClimbing()
	climbing = true
	engagedAt = os.clock()
	lostTime = 0
	floorTime = 0
	pivotUp = nil
	up = rootPart.CFrame.UpVector
	facing = projectOnPlane(rootPart.CFrame.LookVector, up)
	if facing.Magnitude < 0.05 then
		facing = Vector3.new(0, 0, -1)
	end
	facing = facing.Unit
	CharacterState.IsClimbingWall = true
	humanoid.PlatformStand = true
	rootCollided = rootPart.CanCollide
	antiGravity.Enabled = true
end

-- Hors escalade : on s'accroche dès que l'insecte avance contre une face trop raide pour marcher.
local function tryEngage(reach: number)
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.1 or os.clock() < jumpCooldownUntil then
		return
	end
	local direction = moveDirection.Unit
	-- Même portée que le rayon de coin rentrant : on ne s'accroche que si le pivot verra la face.
	local result = ray(rootPart.Position, direction, math.max(reach, bodyExtent(direction)) + 0.3)
	if result and result.Normal.Y < WALL_MAX_UP_DOT and direction:Dot(-result.Normal) > 0.3 then
		-- Petite marche (facette de rocher, caillou) : StepAssistController la franchit d'un bond.
		-- On ne s'accroche qu'aux vrais murs, sinon l'escalade s'allume et s'éteint à chaque facette.
		-- (au sol seulement : en l'air, on agrippe le mur comme avant)
		if humanoid.FloorMaterial ~= Enum.Material.Air and CharacterState.StepHeight(rootPart, humanoid, direction, rayParams) then
			return
		end
		startClimbing()
	end
end

-- Distance centre -> face à tenir : les pattes (reach), ou plus si la boîte inclinée dépasse.
local function surfaceGap(normal: Vector3, reach: number): number
	return math.max(reach, bodyExtent(normal))
end

-- Décalage qui place le centre à la bonne distance d'une face (absolu : ne s'accumule pas).
-- `pushOnly` : ne fait que repousser (face quittée : on a le droit de s'en éloigner en grimpant).
local function clearanceFrom(position: Vector3, normal: Vector3, reach: number, pushOnly: boolean): Vector3
	local gap = surfaceGap(normal, reach)
	local hit = ray(position, -normal, gap + reach + 0.5)
	if not hit then
		return Vector3.zero
	end
	local amount = surfaceGap(hit.Normal, reach) - (position - hit.Position):Dot(hit.Normal)
	return hit.Normal * (if pushOnly then math.max(0, amount) else amount)
end

local function updateClimb(deltaTime: number, reach: number)
	local position = rootPart.Position
	local speed = humanoid.WalkSpeed * CLIMB_SPEED_FACTOR
	local move = getSurfaceMove(up)
	local moving = move.Magnitude > 0.05
	local moveDir = if moving then move.Unit else facing
	-- Légère déviation tangentielle par le vent lorsqu'on grimpe sur une paroi ou branche exposée.
	local wind = CharacterState.GetEffectiveWind(rootPart, rayParams)
	local surfaceWind = projectOnPlane(wind, up)
	local windStep = if moving then surfaceWind * (0.22 * deltaTime) elseif surfaceWind.Magnitude > 14 then surfaceWind * (0.12 * deltaTime) else Vector3.zero
	local step = move * speed * deltaTime + windStep

	local targetUp = up
	local targetPos = position + step
	local surfaceFound = false
	local wrapping = false

	-- 1) Coin rentrant : une autre face juste devant (mur quand on marche au sol, plafond en haut
	--    d'un mur...). On n'avance pas dedans, on pivote dessus jusqu'au bout (hystérésis).
	if moving and not pivotUp then
		local ahead = ray(position, moveDir, surfaceGap(moveDir, reach) + step.Magnitude + reach * PIVOT_LOOKAHEAD + 0.15)
		if ahead and ahead.Normal:Dot(up) < WALL_MAX_UP_DOT then
			pivotUp = ahead.Normal
			pivotFrom = up
		end
	end
	local pivot = pivotUp
	if pivot and up:Dot(pivot) < 0.95 then
		-- On tourne en continuant d'avancer SUR la nouvelle face (l'élan qui rentrait dans le mur
		-- devient "s'éloigner de l'ancienne face"), à bonne distance de la nouvelle face.
		if moving then
			local along = projectOnPlane(moveDir, pivot)
			local away = projectOnPlane(pivotFrom, pivot)
			if away.Magnitude > 1e-3 then
				along += away.Unit * math.max(0, moveDir:Dot(-pivot))
			end
			step = if along.Magnitude > 1e-3 then along.Unit * (speed * CORNER_SPEED * deltaTime) else Vector3.zero
		else
			step = Vector3.zero
		end
		targetUp = pivot
		local ahead = position + step
		targetPos = ahead + clearanceFrom(ahead, pivotFrom, reach, true) + clearanceFrom(ahead, pivot, reach, false)
		surfaceFound = true
	else
		pivotUp = nil
	end

	-- 2) Surface sous les pattes, au point visé : on s'y recolle à la bonne distance.
	if not surfaceFound then
		local below = ray(targetPos + up * (reach * 0.5), -up, reach * 2.6)
		if below then
			-- Deuxième échantillon un peu devant : la normale anticipe les courbes (tronc, branche).
			local front = ray(targetPos + moveDir * (reach * 0.8) + up * (reach * 0.5), -up, reach * 2.6)
			local normal = below.Normal
			if front then
				normal += front.Normal
			end
			-- Échantillons à gauche / à droite : sur une surface à facettes (rocher), la normale moyenne
			-- ne saute plus d'une facette à l'autre (corps stable au lieu de tressauter).
			local side = up:Cross(moveDir)
			if side.Magnitude > 1e-3 then
				side = side.Unit * (reach * 0.6)
				local left = ray(targetPos - side + up * (reach * 0.5), -up, reach * 2.6)
				local right = ray(targetPos + side + up * (reach * 0.5), -up, reach * 2.6)
				if left then
					normal += left.Normal
				end
				if right then
					normal += right.Normal
				end
			end
			normal = if normal.Magnitude > 1e-3 then normal.Unit else below.Normal
			targetUp = normal
			-- below.Position inclut déjà le pas (rayon parti de position + step).
			targetPos = below.Position + below.Normal * surfaceGap(below.Normal, reach)
			surfaceFound = true
		end
	end

	-- 3) Arête saillante : plus rien sous les pattes, on cherche la face qui suit l'arête. Le rayon
	--    part juste sous le plan quitté (marche aussi sur une feuille ou une planche fine).
	if not surfaceFound then
		local wrapOrigin = targetPos + moveDir * (reach * 0.5) - up * (reach + 0.05)
		local wrap = ray(wrapOrigin, -moveDir, reach * 2 + step.Magnitude)
		if wrap and wrap.Normal:Dot(up) < 0.95 then
			-- Le pas pointe hors de l'arête : on le redirige le long de la face d'après (on s'enroule sans s'arrêter).
			local around = projectOnPlane(-up, wrap.Normal)
			local edge = up:Cross(wrap.Normal)
			step = Vector3.zero
			if moving and around.Magnitude > 1e-3 then
				-- Seule la part de l'input qui sort par-dessus l'arête s'enroule ; le reste longe l'arête.
				step = around.Unit * (speed * CORNER_SPEED * deltaTime * math.max(0, moveDir:Dot(wrap.Normal)))
				if edge.Magnitude > 1e-3 then
					edge = edge.Unit
					step += edge * (moveDir:Dot(edge) * speed * deltaTime)
				end
			end
			targetUp = wrap.Normal
			targetPos = wrap.Position + wrap.Normal * surfaceGap(wrap.Normal, reach) + step
			surfaceFound = true
			wrapping = true
		end
	end

	if surfaceFound then
		lostTime = 0
	else
		lostTime += deltaTime
		if lostTime > LOST_SURFACE_GRACE then
			stopClimbing(false)
			return
		end
	end

	-- Orientation : la normale suit la surface en douceur, le regard suit la marche.
	local oldUp = up
	up = turnToward(up, targetUp, 1 - math.exp(-UP_SHARPNESS * deltaTime), moveDir)
	-- Le regard tourne avec la normale (transport) : il reste toujours dans le plan, jamais // à up.
	local axis = oldUp:Cross(up)
	if axis.Magnitude > 1e-4 then
		facing = CFrame.fromAxisAngle(axis.Unit, math.atan2(axis.Magnitude, oldUp:Dot(up))) * facing
	end
	local flatFacing = projectOnPlane(facing, up)
	if flatFacing.Magnitude > 1e-3 then
		facing = flatFacing.Unit
	end
	local desiredFacing = projectOnPlane(moveDir, up)
	if desiredFacing.Magnitude > 0.05 then
		-- Pivot dans le plan : un demi-tour pivote sur place au lieu de cabrer le corps.
		facing = turnToward(facing, desiredFacing.Unit, 1 - math.exp(-TURN_SHARPNESS * deltaTime), up:Cross(facing))
	end

	-- Retour au sol : surface sous les pattes quasi horizontale et orientation déjà alignée dessus.
	-- Confirmé sur FLOOR_CONFIRM_TIME : une facette plate isolée ne coupe pas l'escalade.
	if surfaceFound and targetUp.Y >= FLOOR_MIN_Y and up:Dot(targetUp) >= 0.985 then
		floorTime += deltaTime
	else
		floorTime = 0
	end
	if os.clock() - engagedAt > MIN_CLIMB_TIME and floorTime >= FLOOR_CONFIRM_TIME then
		stopClimbing(true)
		return
	end

	-- Position : la physique rejoint exactement la cible (collisions conservées), recollage lissé.
	local snapAlpha = 1 - math.exp(-SNAP_SHARPNESS * deltaTime)
	local wanted = position:Lerp(targetPos, snapAlpha) + step * (1 - snapAlpha)
	local velocity = (wanted - position) / math.max(deltaTime, 1 / 240)
	if velocity.Magnitude > MAX_CORRECTION_SPEED then
		velocity = velocity.Unit * MAX_CORRECTION_SPEED
	end
	-- Collision coupée pendant une bascule seulement ; rendue dès qu'on est de nouveau à plat sur une
	-- face et que la boîte ne mord plus dans le décor (les rayons nous tiennent sur la surface entre-temps).
	if pivotUp ~= nil or wrapping then
		rootPart.CanCollide = false
	elseif not rootPart.CanCollide and rootCollided and not overlapsWorld() then
		rootPart.CanCollide = true
	end
	-- Rotation d'abord, vitesse ensuite (affecter le CFrame ne doit pas écraser la vitesse posée).
	rootPart.CFrame = CFrame.lookAt(position, position + facing, up)
	rootPart.AssemblyLinearVelocity = velocity
	rootPart.AssemblyAngularVelocity = Vector3.zero
	-- Suit la masse (ScaleTo) : la gravité est toujours exactement compensée.
	antiGravity.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)
end

local connection: RBXScriptConnection? = nil
connection = RunService.RenderStepped:Connect(function(deltaTime: number)
	local jumpHeld = CharacterState.IsJumpHeld(humanoid)
	local jumpPressed = jumpHeld and not jumpWasHeld
	jumpWasHeld = jumpHeld

	-- Cède la main au vol / à la nage ; saisi par un prédateur : le serveur déplace la victime.
	if
		not canPlayerClimb()
		or humanoid.Health <= 0
		or CharacterState.IsFlying
		or CharacterState.IsSwimming
		or CharacterState.IsSwinging
		or player:GetAttribute("IsGrabbed") == true
	then
		stopClimbing(false)
		return
	end

	local reach = getBodyReach()
	if not climbing then
		tryEngage(reach)
		if not climbing then
			return
		end
	end

	if jumpPressed then
		CharacterState.WallJumpUntil = os.clock() + 0.3
		-- Saut mural : on se détache le long de la normale, avec un peu de hauteur.
		local jumpNormal = up
		local jumpSpeed = getJumpSpeed()
		jumpCooldownUntil = os.clock() + JUMP_COOLDOWN
		stopClimbing(false)
		rootPart.AssemblyLinearVelocity = jumpNormal * jumpSpeed + Vector3.yAxis * (jumpSpeed * 0.4)
		return
	end

	-- Impulsion externe (recul serveur, secousse du Grand Chêne) posée par AbilityController.
	if ((character:GetAttribute("ImpulseUntil") :: number?) or 0) > os.clock() then
		jumpCooldownUntil = os.clock() + JUMP_COOLDOWN
		stopClimbing(false)
		return
	end

	updateClimb(math.min(deltaTime, 1 / 20), reach)
end)

local function cleanup()
	stopClimbing(false)
	rootPart.CanCollide = rootCollided
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

humanoid.Died:Connect(cleanup)
script.Destroying:Connect(cleanup)
