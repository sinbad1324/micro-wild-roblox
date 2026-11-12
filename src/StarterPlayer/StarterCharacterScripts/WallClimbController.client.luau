--!strict
-- WallClimbController.client.luau
-- Permet aux insectes qui grimpent dans la vraie vie de marcher sur les murs, les troncs d'arbres et les plafonds

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = script.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InsectData = require(Shared:WaitForChild("InsectData"))

local RAY_DISTANCE = 4.5
local CLIMB_SPEED_FACTOR = 0.85

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { character }

local alignOrientation = Instance.new("AlignOrientation")
alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
alignOrientation.Responsiveness = 25
alignOrientation.Enabled = false

local linearVelocity = Instance.new("LinearVelocity")
linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
linearVelocity.MaxForce = 50000
linearVelocity.Enabled = false

local attachment = Instance.new("Attachment")
attachment.Parent = rootPart
alignOrientation.Attachment0 = attachment
linearVelocity.Attachment0 = attachment
alignOrientation.Parent = rootPart
linearVelocity.Parent = rootPart

local function canPlayerClimb(): boolean
	local stage = player:GetAttribute("Stage")
	if stage == "Oeuf" or stage == "Cocon" then
		return false
	end
	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId]
	return if species then species.CanClimbWalls else false
end

RunService.RenderStepped:Connect(function()
	if not canPlayerClimb() or humanoid.Health <= 0 then
		alignOrientation.Enabled = false
		linearVelocity.Enabled = false
		humanoid.PlatformStand = false
		return
	end

	-- Raycast devant et sous l'insecte pour détecter un mur, un tronc d'arbre ou une feuille
	local lookResult = workspace:Raycast(rootPart.Position, rootPart.CFrame.LookVector * RAY_DISTANCE, rayParams)
	local downResult = workspace:Raycast(rootPart.Position, -rootPart.CFrame.UpVector * RAY_DISTANCE, rayParams)

	local hitResult = lookResult or downResult
	if hitResult and hitResult.Normal.Y < 0.75 then
		-- Surface inclinée, verticale (arbre/mur) ou plafond (dessous de feuille)
		local normal = hitResult.Normal
		local forward = rootPart.CFrame.LookVector
		local right = forward:Cross(normal)
		local newForward = if right.Magnitude > 0.01 then normal:Cross(right).Unit else rootPart.CFrame.LookVector

		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, newForward, normal)
		alignOrientation.Enabled = true

		local moveDir = humanoid.MoveDirection
		if moveDir.Magnitude > 0 then
			-- Projette le mouvement le long de la paroi et plaque légèrement l'insecte contre l'arbre/mur
			local climbVelocity = (newForward * (humanoid.WalkSpeed * CLIMB_SPEED_FACTOR)) - (normal * 4)
			linearVelocity.VectorVelocity = climbVelocity
		else
			-- Maintient l'insecte collé à la paroi quand il s'arrête
			linearVelocity.VectorVelocity = -normal * 2
		end
		linearVelocity.Enabled = true
	else
		alignOrientation.Enabled = false
		linearVelocity.Enabled = false
	end
end)
