--!strict
-- JumpController.client.luau
-- Bond réaliste (StarterCharacterScripts.characterControllers) : les sauteurs (JumpProfiles
-- "Catapulte" / "Bond") ne sautent pas à la verticale comme un humain mais partent en arc vers
-- l'avant (direction de marche, sinon là où regarde l'insecte). La hauteur vient du JumpPower
-- posé par le serveur ; ici on n'ajoute que l'élan horizontal au décollage.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local JumpProfiles = require(ReplicatedStorage.shared.JumpProfiles)

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local NYMPH_FORWARD_FACTOR = 0.5

local function forwardFor(): number
	local speciesId = player:GetAttribute("Species")
	local profile = JumpProfiles.For(if type(speciesId) == "string" then speciesId else "")
	local stage = player:GetAttribute("Stage")
	if stage == "Adulte" then
		return profile.Forward
	end
	-- Nymphe de sauterelle : petits bonds ; une chenille ne bondit pas (JumpPower minuscule).
	if stage == "Larve" or stage == "Mue" then
		return profile.Forward * NYMPH_FORWARD_FACTOR
	end
	return 0
end

humanoid.StateChanged:Connect(function(_, new)
	if new ~= Enum.HumanoidStateType.Jumping then
		return
	end
	local forward = forwardFor()
	if
		forward <= 0
		or CharacterState.IsFlying
		or CharacterState.IsSwimming
		or CharacterState.IsClimbingWall
		or CharacterState.IsSwinging
		or player:GetAttribute("IsGrabbed") == true
	then
		return
	end
	-- Après le pas physique : le Humanoid a posé la vitesse verticale du saut, on ajoute l'élan.
	RunService.Heartbeat:Once(function()
		local flat = Vector3.new(humanoid.MoveDirection.X, 0, humanoid.MoveDirection.Z)
		if flat.Magnitude < 0.1 then
			local look = rootPart.CFrame.LookVector
			flat = Vector3.new(look.X, 0, look.Z)
		end
		if flat.Magnitude < 0.01 then
			return
		end
		local velocity = rootPart.AssemblyLinearVelocity
		local vertical = math.max(velocity.Y, 0)
		rootPart.AssemblyLinearVelocity = Vector3.new(0, vertical, 0) + flat.Unit * (forward + humanoid.WalkSpeed * 0.5)
		-- Pas de vent ni de contraintes de vol/nage pendant la phase balistique du bond.
		local airTime = 2 * vertical / math.max(workspace.Gravity, 1)
		character:SetAttribute("ImpulseUntil", os.clock() + math.clamp(airTime, 0.2, 1.2))
	end)
end)
