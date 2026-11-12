--!strict
-- EvolutionDomain.luau
-- Règles métier d'évolution d'un insecte (Œuf -> Larve -> Mue/Cocon -> Adulte), conforme au GDD
-- section 2 (Oeuf 0-10%, Larve 10-50%, Métamorphose/Mue 50-75%, Adulte 75-100%+).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MovementService = require(ServerScriptService.services.MovementService)
local ServerTypes = require(ServerScriptService.types.ServerTypes)

local EvolutionDomain = {}

-- Stade "stable" dérivé uniquement de la croissance (ignore la fenêtre transitoire "Mue",
-- qui est gérée à part par GrowthAndNestService car elle dépend du TEMPS, pas que de la
-- croissance : voir EvolutionDomain.ShouldTriggerMolt).
function EvolutionDomain.GetStageForGrowth(speciesId: string, growth: number): ServerTypes.StageType
	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
	local thresholds = GameConstants.STAGE_THRESHOLDS

	if growth < thresholds.LARVE then
		return "Oeuf"
	elseif growth < thresholds.COCON then
		return "Larve"
	elseif growth < thresholds.ADULTE then
		if species.GrowthType == "Metamorphose" then
			return "Cocon"
		else
			return "Larve"
		end
	else
		return "Adulte"
	end
end

-- Vrai si la croissance vient de franchir un palier de mue (espèces Hémimétaboles/Arachnides
-- uniquement) entre l'ancienne et la nouvelle valeur de croissance.
function EvolutionDomain.ShouldTriggerMolt(speciesId: string, previousGrowth: number, newGrowth: number): boolean
	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
	if species.GrowthType ~= "Mue" then
		return false
	end
	for _, step in ipairs(GameConstants.MOLT_GROWTH_STEPS) do
		if previousGrowth < step and newGrowth >= step then
			return true
		end
	end
	return false
end

function EvolutionDomain.ApplyStageStats(player: Player, character: Model, speciesId: string, stage: ServerTypes.StageType)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]

	if stage == "Oeuf" then
		MovementService.SetBaseWalkSpeed(player, 0)
		MovementService.SetBaseJumpPower(player, 0)
		character:ScaleTo(0.25)
	elseif stage == "Larve" then
		MovementService.SetBaseWalkSpeed(player, math.max(6, species.WalkSpeed * 0.4))
		MovementService.SetBaseJumpPower(player, 15)
		character:ScaleTo(0.45)
	elseif stage == "Mue" then
		-- Carapace molle qui vient de muer : un peu plus rapide qu'une larve, mais toujours
		-- très vulnérable (voir DamageService.MOLT_DAMAGE_MULTIPLIER).
		MovementService.SetBaseWalkSpeed(player, math.max(6, species.WalkSpeed * 0.5))
		MovementService.SetBaseJumpPower(player, 10)
		character:ScaleTo(0.55)
	elseif stage == "Cocon" then
		MovementService.SetBaseWalkSpeed(player, 0)
		MovementService.SetBaseJumpPower(player, 0)
		character:ScaleTo(0.6)
	elseif stage == "Adulte" then
		MovementService.SetBaseWalkSpeed(player, species.WalkSpeed)
		MovementService.SetBaseJumpPower(player, 50)
		character:ScaleTo(1.0)
		humanoid.MaxHealth = species.MaxHealth
		humanoid.Health = species.MaxHealth
	end
end

return EvolutionDomain
