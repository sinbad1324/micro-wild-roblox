--!strict
-- SurvivalService.luau
-- Service gérant la Faim, la Soif, la Température corporelle et l'Oxygène, + le cycle jour/nuit.
--
-- Contrat monde (posé par le futur générateur de monde, Phase A) :
--   workspace:GetAttribute("PondWaterLevel"): number -- hauteur Y de la surface de la mare
--   CollectionService tag "PondZone" sur les parties délimitant la mare (test horizontal)
--   CollectionService tag "Shelter" sur tout abri (galerie creusée, écorce, carcasse en squelette...)
-- Un joueur est "submergé" s'il est sous PondWaterLevel ET à l'intérieur d'une PondZone.
-- Tant que ce contrat n'est pas rempli (avant Phase A), IsSubmerged reste toujours faux : pas de
-- noyade prématurée sur une carte vide.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MathUtils = require(ServerScriptService.utils.MathUtils)
local MovementService = require(ServerScriptService.services.MovementService)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local SurvivalService = {}

local DAY_NIGHT_CYCLE_SECONDS = 600 -- un cycle complet de 24h toutes les 10 minutes réelles
local HYPOTHERMIA_MODIFIER_KEY = "Hypothermia"

local function hasOxygenPassive(speciesId: string): boolean
	local species = InsectData[speciesId]
	if not species then
		return false
	end
	for _, abilityId in ipairs(species.Abilities) do
		local definition = AbilityCatalog[abilityId]
		if definition and definition.Primitive == "Utility" and definition.Range == 0 and definition.Power >= 60 then
			-- BulleOxygene/TubaRespiratoire/BranchiesAquatiques/ClocheDePlongeeToile : toutes
			-- encodées avec un Power élevé représentant une réserve d'air en secondes.
			if string.find(abilityId, "Oxygene") or string.find(abilityId, "Tuba") or string.find(abilityId, "Branchies") or string.find(abilityId, "Cloche") then
				return true
			end
		end
	end
	return false
end

local function isPlayerSheltered(player: Player, rootPart: BasePart): boolean
	local stage = player:GetAttribute("Stage")
	if stage == "Oeuf" or stage == "Cocon" then
		return true -- immobile dans le nid natal, toujours protégé
	end

	local radius = GameConstants.SHELTER_CHECK_RADIUS

	local ownerNestUserId = player:GetAttribute("OwnerNestUserId") :: number?
	if ownerNestUserId then
		local nest = GrowthAndNestService.ActiveNests[ownerNestUserId]
		if nest and (nest.Position - rootPart.Position).Magnitude <= radius then
			return true
		end
	elseif player:GetAttribute("IsMother") == true then
		local nest = GrowthAndNestService.ActiveNests[player.UserId]
		if nest and (nest.Position - rootPart.Position).Magnitude <= radius then
			return true
		end
	end

	for _, shelterInstance in ipairs(CollectionService:GetTagged("Shelter")) do
		local position: Vector3? = nil
		if shelterInstance:IsA("BasePart") then
			position = shelterInstance.Position
		elseif shelterInstance:IsA("Model") and shelterInstance.PrimaryPart then
			position = (shelterInstance :: Model).PrimaryPart.Position
		end
		if position and (position - rootPart.Position).Magnitude <= radius then
			return true
		end
	end

	return false
end

local function isPlayerSubmerged(rootPart: BasePart): boolean
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevel or rootPart.Position.Y >= waterLevel then
		return false
	end
	for _, zonePart in ipairs(CollectionService:GetTagged("PondZone")) do
		if zonePart:IsA("BasePart") then
			local relative = zonePart.CFrame:PointToObjectSpace(rootPart.Position)
			local halfSize = zonePart.Size * 0.5
			if math.abs(relative.X) <= halfSize.X and math.abs(relative.Z) <= halfSize.Z then
				return true
			end
		end
	end
	return false
end

local function advanceDayNightCycle()
	local now = os.clock() % DAY_NIGHT_CYCLE_SECONDS
	Lighting.ClockTime = (now / DAY_NIGHT_CYCLE_SECONDS) * 24
end

function SurvivalService.Start()
	task.spawn(function()
		while true do
			task.wait(GameConstants.SURVIVAL_TICK_INTERVAL)
			advanceDayNightCycle()

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps
			local isNight = Lighting.ClockTime < 6 or Lighting.ClockTime > 19
			local ambientTemp = if isNight then seasonInfo.NightAmbientTemp else seasonInfo.DayAmbientTemp
			workspace:SetAttribute("PondFrozenNow", seasonInfo.PondFrozen)

			for _, player in ipairs(Players:GetPlayers()) do
				local character = player.Character
				local rootPart = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
				local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
				if not humanoid or not rootPart or humanoid.Health <= 0 then
					continue
				end

				local speciesId = (player:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
				local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
				local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"

				local hunger = (player:GetAttribute("Hunger") :: number) or 100
				local thirst = (player:GetAttribute("Thirst") :: number) or 100

				local drainFactor = if stage == "Oeuf" then 0.1 elseif stage == "Cocon" then 0.2 else 1.0
				hunger = math.clamp(hunger - (0.35 * drainFactor), 0, 100)
				thirst = math.clamp(thirst - (0.45 * drainFactor * seasonInfo.ThirstDrainMultiplier), 0, 100)

				local inShelter = isPlayerSheltered(player, rootPart)
				player:SetAttribute("InShelterOrColony", inShelter)
				local targetTemp = if inShelter then GameConstants.SHELTER_TEMPERATURE else ambientTemp
				local bodyTemp = (player:GetAttribute("BodyTemperature") :: number) or 20
				bodyTemp = MathUtils.Lerp(bodyTemp, targetTemp, 0.15)

				if bodyTemp > species.IdealTempMax then
					-- Surchauffe : la soif descend 3x plus vite (GDD section 3).
					thirst = math.clamp(thirst - 0.8, 0, 100)
				end

				local isHypothermic = bodyTemp < species.IdealTempMin
				player:SetAttribute("FlightBlocked", isHypothermic)
				if isHypothermic then
					MovementService.AddModifier(player, HYPOTHERMIA_MODIFIER_KEY, "Multiplier", 0.5)
					humanoid:TakeDamage(1.5)
				else
					MovementService.RemoveModifier(player, HYPOTHERMIA_MODIFIER_KEY)
				end

				-- Oxygène : seules les espèces plongeuses sans passif respiratoire se noient.
				if species.CanSwim and not hasOxygenPassive(speciesId) then
					local submerged = isPlayerSubmerged(rootPart)
					local oxygen = (player:GetAttribute("Oxygen") :: number) or 100
					if submerged then
						oxygen = math.clamp(oxygen - 4, 0, 100)
						if oxygen <= 0 then
							humanoid:TakeDamage(3)
						end
					else
						oxygen = math.clamp(oxygen + 15, 0, 100)
					end
					player:SetAttribute("Oxygen", MathUtils.RoundToDecimal(oxygen, 1))
				end

				if hunger <= 0 then
					humanoid:TakeDamage(2)
				end
				if thirst <= 0 then
					humanoid:TakeDamage(2.5)
				end

				player:SetAttribute("Hunger", MathUtils.RoundToDecimal(hunger, 1))
				player:SetAttribute("Thirst", MathUtils.RoundToDecimal(thirst, 1))
				player:SetAttribute("BodyTemperature", MathUtils.RoundToDecimal(bodyTemp, 1))
			end
		end
	end)
end

return SurvivalService
