--!strict
-- EvolutionDomain.luau
-- Règles métier d'évolution d'un insecte (Œuf -> Larve -> Cocon/Mue -> Adulte)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local GameConstants = require(ServerScriptService.constant.GameConstants)

local EvolutionDomain = {}

function EvolutionDomain.GetStageForGrowth(speciesId: string, growth: number): string
	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
	if growth < GameConstants.STAGE_THRESHOLDS.LARVE then
		return "Oeuf"
	elseif growth < GameConstants.STAGE_THRESHOLDS.COCON then
		return "Larve"
	elseif growth < GameConstants.STAGE_THRESHOLDS.ADULTE then
		if species.GrowthType == "Metamorphose" then
			return "Cocon"
		else
			return "Larve"
		end
	else
		return "Adulte"
	end
end

function EvolutionDomain.ApplyStageStats(character: Model, speciesId: string, stage: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]

	if stage == "Oeuf" then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		character:ScaleTo(0.25)
	elseif stage == "Larve" then
		humanoid.WalkSpeed = math.max(6, species.WalkSpeed * 0.4)
		humanoid.JumpPower = 15
		character:ScaleTo(0.45)
	elseif stage == "Cocon" then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		character:ScaleTo(0.6)
	elseif stage == "Adulte" then
		humanoid.WalkSpeed = species.WalkSpeed
		humanoid.JumpPower = 50
		character:ScaleTo(1.0)
		humanoid.MaxHealth = species.MaxHealth
		humanoid.Health = species.MaxHealth
	end
end

return EvolutionDomain
