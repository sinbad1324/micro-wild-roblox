--!strict
-- SwimController.client.luau
-- Nage libre sous l'eau (CanSwim) ou marche à la surface (CanWalkOnWater) (StarterCharacterScripts.characterControllers)
--
-- Contrat monde identique à SurvivalService (server) : workspace:GetAttribute("PondWaterLevel")
-- + CollectionService tag "PondZone". Tant que ce contrat n'est pas rempli, on reste idle sans erreur.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local SWIM_SPEED_FACTOR = 0.6
local VERTICAL_SPEED_FACTOR = 0.7
local DRAG_SHARPNESS = 6 -- plus haut = la vitesse suit la consigne plus vite (moins de "glisse")

-- Un seul Attachment partagé par le VectorForce (annule la gravité en nage) et le LinearVelocity.
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

local function destroyFloater()
	waterFloater.Parent = nil
end

local function stopSwimming()
	vectorForce.Enabled = false
	linearVelocity.Enabled = false
	swimVelocity = Vector3.zero
	CharacterState.IsSwimming = false
end

local function stageAllowsWater(): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Larve" or stage == "Mue" or stage == "Adulte"
end

-- Mirroir exact de SurvivalService.isPlayerSubmerged (test horizontal en espace local de la zone).
local function findContainingPondZone(): BasePart?
	for _, zonePart in ipairs(CollectionService:GetTagged("PondZone")) do
		if zonePart:IsA("BasePart") then
			local relative = zonePart.CFrame:PointToObjectSpace(rootPart.Position)
			local halfSize = zonePart.Size * 0.5
			if math.abs(relative.X) <= halfSize.X and math.abs(relative.Z) <= halfSize.Z then
				return zonePart
			end
		end
	end
	return nil
end

RunService.RenderStepped:Connect(function(deltaTime: number)
	if humanoid.Health <= 0 or CharacterState.IsFlying or not stageAllowsWater() then
		stopSwimming()
		destroyFloater()
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	local canSwim = if species then species.CanSwim else false
	local canWalkOnWater = if species then species.CanWalkOnWater else false
	if not canSwim and not canWalkOnWater then
		stopSwimming()
		destroyFloater()
		return
	end

	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if waterLevel == nil then
		-- Monde pas encore généré : idle, pas d'erreur.
		stopSwimming()
		destroyFloater()
		return
	end

	local zonePart = findContainingPondZone()
	local isInZone = zonePart ~= nil

	if canWalkOnWater and isInZone then
		-- Flotte à la surface : on ne dive pas sous l'eau, le flotteur ancré colle au joueur.
		stopSwimming()
		waterFloater.Position = Vector3.new(rootPart.Position.X, waterLevel - (waterFloater.Size.Y / 2), rootPart.Position.Z)
		waterFloater.Parent = workspace
		return
	end

	destroyFloater()

	local isBelowSurface = rootPart.Position.Y < waterLevel
	if not (canSwim and isInZone and isBelowSurface) then
		stopSwimming()
		return
	end

	CharacterState.IsSwimming = true

	-- Recalculé chaque frame : ApplyStageStats change l'échelle du personnage donc sa masse.
	vectorForce.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)
	vectorForce.Enabled = true

	local swimSpeed = (if species then species.WalkSpeed else 16) * SWIM_SPEED_FACTOR
	if character:GetAttribute("Status_Stun") == true or player:GetAttribute("IsGrabbed") == true then
		swimSpeed = 0
	elseif character:GetAttribute("Status_Glue") == true then
		swimSpeed *= 0.25
	elseif character:GetAttribute("Status_Slow") == true then
		swimSpeed *= 0.5
	end
	local ascend = if UserInputService:IsKeyDown(Enum.KeyCode.Space)
		then 1
		elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then -1
		else 0
	local desiredVelocity = (humanoid.MoveDirection * swimSpeed) + Vector3.new(0, ascend * swimSpeed * VERTICAL_SPEED_FACTOR, 0)

	-- Effet de traînée de l'eau : on amortit vers la vitesse voulue au lieu d'un arrêt/départ instantané.
	local lerpAlpha = 1 - math.exp(-DRAG_SHARPNESS * deltaTime)
	swimVelocity = swimVelocity:Lerp(desiredVelocity, lerpAlpha)
	linearVelocity.VectorVelocity = swimVelocity
	linearVelocity.Enabled = true
end)

humanoid.Died:Connect(function()
	stopSwimming()
	destroyFloater()
end)

script.Destroying:Connect(destroyFloater)
