--!strict
-- FlightController.client.luau
-- Vol libre en 3D pour les espèces volantes devenues Adulte (StarterCharacterScripts.characterControllers)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local InsectData = require(ReplicatedStorage.shared.InsectData)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local FLIGHT_SPEED_MULTIPLIER = 1.3
local VERTICAL_SPEED_FACTOR = 0.8

local isFlying = false

-- Un seul Attachment partagé par le VectorForce (annule la gravité) et le LinearVelocity (pilotage).
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

-- Lu à chaque frame : Species/Stage/FlightBlocked peuvent changer (mue, hypothermie, repop).
local function canFlyNow(): boolean
	if humanoid.Health <= 0 or CharacterState.IsSwimming then
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
	CharacterState.IsFlying = false
end

-- Décollage : Space, uniquement en chute libre (pas pendant la phase de saut), pas déjà en vol.
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent or input.KeyCode ~= Enum.KeyCode.Space then
		return
	end
	if isFlying or not canFlyNow() then
		return
	end
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		isFlying = true
		CharacterState.IsFlying = true
	end
end)

RunService.RenderStepped:Connect(function()
	if not isFlying then
		return
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
	-- Passifs de vol : "Reine du ciel" (Libellule) et maniabilité de la Guêpe émeraude.
	if species and table.find(species.Abilities, "Vol360Stationnaire") then
		abilityBoost *= 1.25
	elseif species and table.find(species.Abilities, "VolAcrobatique") then
		abilityBoost *= 1.15
	end
	local flightSpeed = (if species then species.WalkSpeed else 16) * FLIGHT_SPEED_MULTIPLIER * seasonBonus * abilityBoost
	-- Statuts serveur : étourdi = plané immobile, glu/ralenti = vol lourd.
	if character:GetAttribute("Status_Stun") == true then
		flightSpeed = 0
	elseif character:GetAttribute("Status_Glue") == true then
		flightSpeed *= 0.25
	elseif character:GetAttribute("Status_Slow") == true then
		flightSpeed *= 0.5
	end

	-- Recalculé chaque frame : ApplyStageStats change l'échelle du personnage donc sa masse.
	vectorForce.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)
	vectorForce.Enabled = true

	local ascend = if UserInputService:IsKeyDown(Enum.KeyCode.Space)
		then 1
		elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then -1
		else 0
	local horizontal = humanoid.MoveDirection * flightSpeed
	-- Vents forts d'automne : poussent les insectes en vol (GDD §4).
	local wind = (workspace:GetAttribute("WindVector") :: Vector3?) or Vector3.zero
	linearVelocity.VectorVelocity = horizontal + wind + Vector3.new(0, ascend * flightSpeed * VERTICAL_SPEED_FACTOR, 0)
	linearVelocity.Enabled = true

	-- Atterrissage naturel : pieds au sol et pas de tentative de montée => on referme le vol.
	if humanoid.FloorMaterial ~= Enum.Material.Air and ascend <= 0 then
		stopFlying()
	end
end)

humanoid.Died:Connect(stopFlying)
