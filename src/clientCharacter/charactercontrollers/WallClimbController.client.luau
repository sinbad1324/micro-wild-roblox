--!strict
-- WallClimbController.client.luau
-- Permet aux insectes grimpeurs de marcher sur les murs, les troncs d'arbres et les plafonds (StarterCharacterScripts.characterControllers)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

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
		CharacterState.IsClimbingWall = false
		return
	end

	local lookResult = workspace:Raycast(rootPart.Position, rootPart.CFrame.LookVector * RAY_DISTANCE, rayParams)
	local downResult = workspace:Raycast(rootPart.Position, -rootPart.CFrame.UpVector * RAY_DISTANCE, rayParams)

	local hitResult = lookResult or downResult
	if hitResult and hitResult.Normal.Y < 0.75 then
		CharacterState.IsClimbingWall = true
		local normal = hitResult.Normal
		local forward = rootPart.CFrame.LookVector
		local right = forward:Cross(normal)
		local newForward = if right.Magnitude > 0.01 then normal:Cross(right).Unit else rootPart.CFrame.LookVector

		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, newForward, normal)
		alignOrientation.Enabled = true

		local moveDir = humanoid.MoveDirection
		if moveDir.Magnitude > 0 then
			local climbVelocity = (newForward * (humanoid.WalkSpeed * CLIMB_SPEED_FACTOR)) - (normal * 4)
			linearVelocity.VectorVelocity = climbVelocity
		else
			linearVelocity.VectorVelocity = -normal * 2
		end
		linearVelocity.Enabled = true
	else
		CharacterState.IsClimbingWall = false
		alignOrientation.Enabled = false
		linearVelocity.Enabled = false
	end
end)
