--!strict
-- StepAssistController.client.luau
-- 1) Aide à franchir les petites marches au sol (StarterCharacterScripts.characterControllers).
-- 2) Dérive et poussée du vent au sol et en l'air (saut / chute libre) :
--    * En l'air (saut, chute depuis une branche) : le vent courbe la trajectoire horizontale
--    * Au sol en marche : le vent dévie légèrement la trajectoire (vent de travers), pousse dans le
--      dos ou freine de face
--    * Au sol à l'arrêt sous une forte rafale : les insectes exposés glissent légèrement sous la
--      bourrasque (les pattes à IK font alors de petits pas de recalage)
-- Exécuté sur Stepped (après le calcul interne du Humanoid et juste avant le solveur physique) pour
-- que la dérive du vent soit intégrée par la physique en respectant toutes les collisions.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local HOP_MARGIN = 0.15
local HOP_COOLDOWN = 0.12

-- Coefficients de dérive au vent (le vecteur reçu de GetEffectiveWind inclut déjà l'abri et le poids de l'espèce).
local GROUND_WALK_WIND_FACTOR = 0.30 -- déviation en marchant
local GROUND_IDLE_GUST_THRESHOLD = 9.0 -- vitesse de vent ressenti au-delà de laquelle une rafale pousse à l'arrêt
local GROUND_IDLE_WIND_FACTOR = 0.25 -- glissement sous une forte rafale à l'arrêt
local AIR_WIND_ACCEL = 1.65 -- accélération horizontale du vent pendant un saut / une chute
local AIR_WIND_MAX_CARRY = 0.75 -- vitesse max ajoutée par le vent en l'air (fraction du vent)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

local GROUNDED: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

local nextHopAt = 0

local connection = RunService.Stepped:Connect(function(_time: number, dt: number)
	if
		humanoid.Health <= 0
		or humanoid.PlatformStand
		or CharacterState.IsClimbingWall
		or CharacterState.IsFlying
		or CharacterState.IsSwimming
		or CharacterState.IsSwinging
		or player:GetAttribute("IsGrabbed") == true
		or ((character:GetAttribute("ImpulseUntil") :: number?) or 0) > os.clock()
	then
		return
	end

	local state = humanoid:GetState()
	local isGrounded = GROUNDED[state] == true and humanoid.FloorMaterial ~= Enum.Material.Air
	local velocity = rootPart.AssemblyLinearVelocity
	local direction = humanoid.MoveDirection
	local isMoving = direction.Magnitude >= 0.1

	-- ---------- 1) Dérive & poussée du vent (en l'air et au sol) ----------
	local wind = CharacterState.GetEffectiveWind(rootPart, rayParams)
	local flatWind = Vector3.new(wind.X, 0, wind.Z)
	local windSpeed = flatWind.Magnitude
	if windSpeed > 0.4 then
		local windDir = flatWind / windSpeed
		if not isGrounded then
			-- En saut ou en chute libre : l'insecte n'a plus d'appui au sol et dérive dans le courant d'air.
			local horizVel = Vector3.new(velocity.X, 0, velocity.Z)
			local alongWind = horizVel:Dot(windDir)
			local maxAlong = humanoid.WalkSpeed + windSpeed * AIR_WIND_MAX_CARRY
			if alongWind < maxAlong then
				local push = flatWind * (AIR_WIND_ACCEL * math.min(dt, 1 / 20))
				velocity += push
				rootPart.AssemblyLinearVelocity = velocity
			end
		elseif humanoid.WalkSpeed > 0 then
			-- Au sol : déviation de la marche + léger recul/glissement à l'arrêt lors des fortes bourrasques.
			local baseWalkVel = Vector3.new(direction.X, 0, direction.Z) * humanoid.WalkSpeed
			local drift = Vector3.zero
			if isMoving then
				drift = flatWind * GROUND_WALK_WIND_FACTOR
			elseif windSpeed > GROUND_IDLE_GUST_THRESHOLD then
				drift = windDir * ((windSpeed - GROUND_IDLE_GUST_THRESHOLD) * GROUND_IDLE_WIND_FACTOR)
			end
			if drift.Magnitude > 0.15 then
				local targetHoriz = baseWalkVel + drift
				velocity = Vector3.new(targetHoriz.X, velocity.Y, targetHoriz.Z)
				rootPart.AssemblyLinearVelocity = velocity
			end
		end
	end

	-- ---------- 2) Franchissement automatique des petites marches ----------
	if not isGrounded or not isMoving or humanoid.WalkSpeed <= 0 then
		return
	end
	local now = os.clock()
	if now < nextHopAt then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z).Unit
	if Vector3.new(velocity.X, 0, velocity.Z):Dot(flat) > humanoid.WalkSpeed * 0.5 then
		return
	end
	local rise = CharacterState.StepHeight(rootPart, humanoid, direction, rayParams)
	if not rise then
		return
	end
	local needed = math.sqrt(2 * workspace.Gravity * (rise + HOP_MARGIN))
	if velocity.Y < needed then
		nextHopAt = now + HOP_COOLDOWN
		CharacterState.WallJumpUntil = now + needed / workspace.Gravity
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, needed, velocity.Z) + flat * 2
	end
end)

humanoid.Died:Connect(function()
	connection:Disconnect()
end)
script.Destroying:Connect(function()
	connection:Disconnect()
end)
