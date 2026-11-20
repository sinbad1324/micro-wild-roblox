--!strict
-- EvolutionDomain.luau
-- Règles métier d'évolution d'un insecte (Œuf -> Larve -> Mue/Cocon -> Adulte), conforme au GDD
-- section 2 (Oeuf 0-10%, Larve 10-50%, Métamorphose/Mue 50-75%, Adulte 75-100%+).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MovementService = require(ServerScriptService.services.MovementService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)
local ServerTypes = require(ServerScriptService.types.ServerTypes)

local EvolutionDomain = {}

-- Niveaux d'XP (ProgressionService.AddExperience) : par niveau au-delà du 1er, l'insecte grandit
-- un peu et gagne vie, force et vitesse. Remis au niveau 1 à chaque nouvelle vie.
EvolutionDomain.MAX_LEVEL = 20
local LEVEL_SCALE_STEP = 0.012 -- +1.2 % de taille par niveau (jusqu'à ~+23 %)
local LEVEL_HEALTH_STEP = 0.04
local LEVEL_SPEED_STEP = 0.01
EvolutionDomain.LEVEL_DAMAGE_STEP = 0.03

function EvolutionDomain.GetLevel(player: Player): number
	local level = player:GetAttribute("Level")
	return if type(level) == "number" then math.clamp(math.floor(level), 1, EvolutionDomain.MAX_LEVEL) else 1
end

function EvolutionDomain.GetLevelScale(player: Player): number
	return 1 + LEVEL_SCALE_STEP * (EvolutionDomain.GetLevel(player) - 1)
end

local function levelHealthFactor(player: Player): number
	return 1 + LEVEL_HEALTH_STEP * (EvolutionDomain.GetLevel(player) - 1)
end

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

-- Transition de stade : l'échelle est interpolée par paliers (pas de tween par frame côté serveur),
-- l'ancien corps grossit/rétrécit puis le nouveau corps est construit à la fin.
local STAGE_TWEEN_SECONDS = 0.9
local STAGE_TWEEN_STEPS = 4
local STAGE_TOKEN_ATTRIBUTE = "StageToken" -- sur le personnage : invalide une transition remplacée

-- Échelle du personnage pour un stade. Une larve grossit avec sa croissance : les espèces à mues
-- grandissent ainsi visiblement à chaque mue au lieu de passer d'un coup de 0.45 à 1.
function EvolutionDomain.GetStageScale(stage: ServerTypes.StageType, growth: number): number
	if stage == "Oeuf" then
		return 0.25
	elseif stage == "Cocon" then
		return 0.6
	elseif stage == "Adulte" then
		return 1.0
	end
	local thresholds = GameConstants.STAGE_THRESHOLDS
	local alpha = math.clamp((growth - thresholds.LARVE) / (thresholds.ADULTE - thresholds.LARVE), 0, 1)
	return 0.45 + 0.25 * alpha
end

-- Vitesse, saut et vie du stade (sans toucher à l'échelle).
local function applyStats(player: Player, humanoid: Humanoid, speciesId: string, stage: ServerTypes.StageType)
	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]

	if stage == "Oeuf" then
		MovementService.SetBaseWalkSpeed(player, 0)
		MovementService.SetBaseJumpPower(player, 0)
	elseif stage == "Larve" then
		MovementService.SetBaseWalkSpeed(player, math.max(6, species.WalkSpeed * 0.4))
		MovementService.SetBaseJumpPower(player, 15)
	elseif stage == "Mue" then
		-- Carapace molle qui vient de muer : un peu plus rapide qu'une larve, mais toujours
		-- très vulnérable (voir DamageService.MOLT_DAMAGE_MULTIPLIER).
		MovementService.SetBaseWalkSpeed(player, math.max(6, species.WalkSpeed * 0.5))
		MovementService.SetBaseJumpPower(player, 10)
	elseif stage == "Cocon" then
		MovementService.SetBaseWalkSpeed(player, 0)
		MovementService.SetBaseJumpPower(player, 0)
	elseif stage == "Adulte" then
		-- Passif "Sprint ondulant" : vitesse de base augmentée (ex: Scolopendre).
		local sprint = if table.find(species.Abilities, "SprintOndulant") then 1.3 else 1
		MovementService.SetBaseWalkSpeed(player, species.WalkSpeed * sprint)
		MovementService.SetBaseJumpPower(player, 50)
		humanoid.MaxHealth = species.MaxHealth * levelHealthFactor(player)
		humanoid.Health = humanoid.MaxHealth
	end
end

-- Stats + échelle appliquées d'un coup (API historique ; SetStage gère la transition douce).
function EvolutionDomain.ApplyStageStats(player: Player, character: Model, speciesId: string, stage: ServerTypes.StageType)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	applyStats(player, humanoid, speciesId, stage)
	character:ScaleTo(EvolutionDomain.GetStageScale(stage, (player:GetAttribute("Growth") :: number?) or 0) * EvolutionDomain.GetLevelScale(player))
end

-- Point d'entrée UNIQUE pour changer de stade : attribut + stats + corps 3D. Sans le visuel, un
-- joueur resterait un oeuf à l'écran pour toujours (ApplyVisual ne tournait qu'au spawn).
-- Cède ~1 s pendant la transition d'échelle (appeler via task.spawn dans une boucle) ; `instant`
-- = vrai pour un corps neuf (apparition, choix d'espèce) : pas de transition, pas d'attente.
function EvolutionDomain.SetStage(player: Player, speciesId: string, stage: ServerTypes.StageType, instant: boolean?)
	player:SetAttribute("Stage", stage)
	local character = player.Character
	if not character then
		return
	end
	-- Un nouvel appel (mue qui se termine, mutation tirée...) remplace la transition en cours.
	local token = ((character:GetAttribute(STAGE_TOKEN_ATTRIBUTE) :: number?) or 0) + 1
	character:SetAttribute(STAGE_TOKEN_ATTRIBUTE, token)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		applyStats(player, humanoid, speciesId, stage)
	end

	local targetScale = EvolutionDomain.GetStageScale(stage, (player:GetAttribute("Growth") :: number?) or 0)
		* EvolutionDomain.GetLevelScale(player)
	local startScale = character:GetScale()
	if not instant and character:FindFirstChild("InsectVisual") and math.abs(targetScale - startScale) > 0.02 then
		for step = 1, STAGE_TWEEN_STEPS - 1 do
			local remaining = 1 - step / STAGE_TWEEN_STEPS
			character:ScaleTo(startScale + (targetScale - startScale) * (1 - remaining * remaining))
			task.wait(STAGE_TWEEN_SECONDS / STAGE_TWEEN_STEPS)
			if character.Parent == nil or character:GetAttribute(STAGE_TOKEN_ATTRIBUTE) ~= token then
				return
			end
		end
	end

	-- Détruit l'ancien corps AVANT le ScaleTo final (une passe de redimensionnement en moins).
	local oldVisual = character:FindFirstChild("InsectVisual")
	if oldVisual then
		oldVisual:Destroy()
	end
	character:ScaleTo(targetScale)
	InsectVisualService.ApplyVisual(character, speciesId, stage, player:GetAttribute("Mutation") :: string?)
end

-- Nouveau niveau : vitesse, vie (même proportion + petit soin) et taille, sans reconstruire le corps.
function EvolutionDomain.ApplyLevel(player: Player)
	local level = EvolutionDomain.GetLevel(player)
	if level > 1 then
		MovementService.AddModifier(player, "Level", "Multiplier", 1 + LEVEL_SPEED_STEP * (level - 1))
	else
		MovementService.RemoveModifier(player, "Level")
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	local stage = player:GetAttribute("Stage")
	if stage == "Adulte" then
		local species = InsectData[(player:GetAttribute("Species") :: string?) or ""] or InsectData[GameConstants.DEFAULT_SPECIES]
		local ratio = humanoid.Health / math.max(humanoid.MaxHealth, 1)
		humanoid.MaxHealth = species.MaxHealth * levelHealthFactor(player)
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.MaxHealth * (ratio + 0.25))
	end
	if type(stage) == "string" and character:FindFirstChild("InsectVisual") then
		character:ScaleTo(EvolutionDomain.GetStageScale(stage :: any, (player:GetAttribute("Growth") :: number?) or 0) * EvolutionDomain.GetLevelScale(player))
	end
end

return EvolutionDomain
