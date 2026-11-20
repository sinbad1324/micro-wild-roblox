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
local RunService = game:GetService("RunService")
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
-- Le serveur démarre à 8h du matin : un nouveau joueur ne naît pas en pleine nuit froide.
local DAY_START_OFFSET_SECONDS = DAY_NIGHT_CYCLE_SECONDS * 8 / 24
-- Horloge déterministe basée sur GetServerTimeNow : le client (WorldFxController) recalcule la même
-- heure à chaque image pour un soleil parfaitement fluide ; le serveur ne l'écrit qu'à ~2 Hz
-- (gameplay jour/nuit + clients sans contrôleur), ce qui limite la réplication.
local DAY_NIGHT_WRITE_SECONDS = 0.5
local HYPOTHERMIA_MODIFIER_KEY = "Hypothermia"

-- Tick fin (1 s max) : les jauges descendent en douceur au lieu de marches toutes les 2 s.
-- Tous les taux ci-dessous sont PAR SECONDE et multipliés par TICK_SECONDS.
local TICK_SECONDS = math.min(GameConstants.SURVIVAL_TICK_INTERVAL, 1)
-- Équilibrage carte 1500x1500 : ~14 min de 100 à 0 en Faim, ~11 min en Soif (7 min en été).
local HUNGER_PER_SECOND = 0.12
local THIRST_PER_SECOND = 0.15
local OVERHEAT_THIRST_PER_SECOND = 0.25
local STARVE_DAMAGE_PER_SECOND = 1
local DEHYDRATION_DAMAGE_PER_SECOND = 1.25
-- Le corps se refroidit/réchauffe lentement dehors (≈20-35 s d'exploration en hiver avant
-- l'hypothermie pour un minimum de 15-18°C, plus pour les espèces rustiques) et vite à l'abri :
-- on peut sortir, mais il faut revenir.
local TEMP_RATE_OUTSIDE = 0.008
local TEMP_RATE_SHELTER = 0.1
-- Dégâts de froid progressifs : plein tarif à 10°C sous le minimum de l'espèce.
local HYPOTHERMIA_DAMAGE_PER_SECOND = 0.75
local OXYGEN_DRAIN_PER_SECOND = 2
local OXYGEN_REGEN_PER_SECOND = 7.5
local DROWN_DAMAGE_PER_SECOND = 1.5
local SWIM_DRINK_PER_SECOND = 3

-- Listes taguées relues UNE fois par tick (pas une allocation par joueur et par fonction).
local warmSpots: { Instance } = {}
local pondZones: { Instance } = {}
local shelters: { Instance } = {}

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

-- Sous terre (galerie creusée, salle de la souche, terrier) = du Terrain solide au-dessus de la
-- tête. L'eau est ignorée : nager au fond de la mare n'est pas "être à l'abri".
local undergroundParams = RaycastParams.new()
undergroundParams.FilterType = Enum.RaycastFilterType.Include
undergroundParams.FilterDescendantsInstances = { workspace.Terrain }
undergroundParams.IgnoreWater = true

local function isUnderground(rootPart: BasePart): boolean
	return workspace:Raycast(rootPart.Position, Vector3.new(0, 30, 0), undergroundParams) ~= nil
end

-- Bonus de chaleur : tag "WarmSpot" (nid d'oiseau, hotte de l'écureuil...) avec attribut
-- WarmBonus/WarmRadius, et la "Chaleur de ruche" d'une abeille de la même famille à proximité.
local function getWarmthBonus(player: Player, rootPart: BasePart): number
	local bonus = 0
	for _, spot in ipairs(warmSpots) do
		if spot:IsA("BasePart") then
			local radius = (spot:GetAttribute("WarmRadius") :: number?) or 20
			if (spot.Position - rootPart.Position).Magnitude <= radius then
				bonus = math.max(bonus, (spot:GetAttribute("WarmBonus") :: number?) or 10)
			end
		end
	end
	local familyId = player:GetAttribute("FamilyId")
	if familyId then
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player and other:GetAttribute("FamilyId") == familyId and other:GetAttribute("Species") == "AbeilleMellifere" then
				local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if otherRoot and (otherRoot.Position - rootPart.Position).Magnitude <= 15 then
					bonus += 4
					break
				end
			end
		end
	end
	return bonus
end

local function isInPondZoneXZ(position: Vector3): boolean
	for _, zonePart in ipairs(pondZones) do
		if zonePart:IsA("BasePart") then
			local relative = zonePart.CFrame:PointToObjectSpace(position)
			local halfSize = zonePart.Size * 0.5
			if math.abs(relative.X) <= halfSize.X and math.abs(relative.Z) <= halfSize.Z then
				return true
			end
		end
	end
	return false
end

local function isPlayerSubmerged(rootPart: BasePart): boolean
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevel or rootPart.Position.Y >= waterLevel then
		return false
	end
	return isInPondZoneXZ(rootPart.Position)
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

	if isUnderground(rootPart) then
		return true
	end

	for _, shelterInstance in ipairs(shelters) do
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


local function advanceDayNightCycle()
	local now = (workspace:GetServerTimeNow() + DAY_START_OFFSET_SECONDS) % DAY_NIGHT_CYCLE_SECONDS
	Lighting.ClockTime = (now / DAY_NIGHT_CYCLE_SECONDS) * 24
end

local function survivalTick(player: Player, seasonInfo: SeasonConfig.SeasonInfo, ambientTemp: number)
	local character = player.Character
	local rootPart = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid or not rootPart or humanoid.Health <= 0 then
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
	local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"

	local hunger = (player:GetAttribute("Hunger") :: number) or 100
	local thirst = (player:GetAttribute("Thirst") :: number) or 100

	local drainFactor = if stage == "Oeuf" then 0.1 elseif stage == "Cocon" then 0.2 else 1.0
	hunger = math.clamp(hunger - (HUNGER_PER_SECOND * TICK_SECONDS * drainFactor), 0, 100)
	thirst = math.clamp(thirst - (THIRST_PER_SECOND * TICK_SECONDS * drainFactor * seasonInfo.ThirstDrainMultiplier), 0, 100)

	local inShelter = isPlayerSheltered(player, rootPart)
	player:SetAttribute("InShelterOrColony", inShelter)
	local rainIntensity = if not inShelter and workspace:GetAttribute("Precipitation") == "Rain"
		then math.clamp((workspace:GetAttribute("RainIntensity") :: number?) or 0.6, 0, 1)
		else 0
	if rainIntensity > 0 then
		-- Sous la pluie à découvert : les gouttelettes réhydratent doucement l'insecte et rafraîchissent l'air.
		thirst = math.clamp(thirst + 0.35 * rainIntensity * TICK_SECONDS, 0, 100)
	end
	local outdoorTemp = ambientTemp - 2.5 * rainIntensity
	local targetTemp = if inShelter then math.max(GameConstants.SHELTER_TEMPERATURE, ambientTemp) else outdoorTemp
	targetTemp += getWarmthBonus(player, rootPart)
	local bodyTemp = (player:GetAttribute("BodyTemperature") :: number) or 20
	local tempRate = if inShelter then TEMP_RATE_SHELTER else TEMP_RATE_OUTSIDE
	bodyTemp = MathUtils.Lerp(bodyTemp, targetTemp, 1 - (1 - tempRate) ^ TICK_SECONDS)

	if bodyTemp > species.IdealTempMax then
		-- Surchauffe : la soif descend bien plus vite (GDD section 3).
		thirst = math.clamp(thirst - OVERHEAT_THIRST_PER_SECOND * TICK_SECONDS, 0, 100)
	end

	local isHypothermic = bodyTemp < species.IdealTempMin
	player:SetAttribute("FlightBlocked", isHypothermic)
	if isHypothermic then
		MovementService.AddModifier(player, HYPOTHERMIA_MODIFIER_KEY, "Multiplier", 0.5)
		local severity = math.clamp((species.IdealTempMin - bodyTemp) / 10, 0.2, 1)
		humanoid:TakeDamage(HYPOTHERMIA_DAMAGE_PER_SECOND * severity * TICK_SECONDS)
	else
		MovementService.RemoveModifier(player, HYPOTHERMIA_MODIFIER_KEY)
	end

	-- Oxygène : seules les espèces plongeuses sans passif respiratoire se noient. Les petits
	-- des espèces aquatiques (oeuf, larve, nymphe, cocon) respirent sous l'eau (branchies).
	local aquaticYoung = stage ~= "Adulte" and (GameConstants.AQUATIC_LARVA_SPECIES[speciesId] == true or species.Category == "Aquatique")
	if aquaticYoung then
		player:SetAttribute("Oxygen", 100)
	elseif species.CanSwim and not hasOxygenPassive(speciesId) then
		local submerged = isPlayerSubmerged(rootPart)
		local oxygen = (player:GetAttribute("Oxygen") :: number) or 100
		if submerged then
			oxygen = math.clamp(oxygen - OXYGEN_DRAIN_PER_SECOND * TICK_SECONDS, 0, 100)
			if oxygen <= 0 then
				humanoid:TakeDamage(DROWN_DAMAGE_PER_SECOND * TICK_SECONDS)
			end
		else
			oxygen = math.clamp(oxygen + OXYGEN_REGEN_PER_SECOND * TICK_SECONDS, 0, 100)
		end
		player:SetAttribute("Oxygen", MathUtils.RoundToDecimal(oxygen, 1))
	end

	-- Boire en nageant / en patinant sur la mare (sauf gelée en hiver).
	if (species.CanSwim or species.CanWalkOnWater) and workspace:GetAttribute("PondFrozenNow") ~= true then
		local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
		if waterLevel and rootPart.Position.Y < waterLevel + 3 and isInPondZoneXZ(rootPart.Position) then
			thirst = math.clamp(thirst + SWIM_DRINK_PER_SECOND * TICK_SECONDS, 0, 100)
		end
	end

	-- Déshydratation : ralentissement (la vision trouble est gérée côté client).
	if thirst < 15 then
		MovementService.AddModifier(player, "Thirsty", "Multiplier", 0.75)
	else
		MovementService.RemoveModifier(player, "Thirsty")
	end

	if hunger <= 0 then
		humanoid:TakeDamage(STARVE_DAMAGE_PER_SECOND * TICK_SECONDS)
	end
	if thirst <= 0 then
		humanoid:TakeDamage(DEHYDRATION_DAMAGE_PER_SECOND * TICK_SECONDS)
	end

	-- 2 décimales : arrondir à 0.1 avec des pas aussi fins fausserait les taux (et figerait la température).
	player:SetAttribute("Hunger", MathUtils.RoundToDecimal(hunger, 2))
	player:SetAttribute("Thirst", MathUtils.RoundToDecimal(thirst, 2))
	player:SetAttribute("BodyTemperature", MathUtils.RoundToDecimal(bodyTemp, 2))
end

function SurvivalService.Start()
	-- Le serveur démarre à 8h : l'origine du cycle est recalée sur l'heure serveur actuelle.
	DAY_START_OFFSET_SECONDS -= workspace:GetServerTimeNow() % DAY_NIGHT_CYCLE_SECONDS
	workspace:SetAttribute("DayCycleSeconds", DAY_NIGHT_CYCLE_SECONDS)
	workspace:SetAttribute("DayStartOffset", DAY_START_OFFSET_SECONDS)
	advanceDayNightCycle()
	local sinceWrite = 0
	RunService.Heartbeat:Connect(function(dt: number)
		sinceWrite += dt
		if sinceWrite >= DAY_NIGHT_WRITE_SECONDS then
			sinceWrite = 0
			advanceDayNightCycle()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps
			local isNight = Lighting.ClockTime < 6 or Lighting.ClockTime > 19
			local ambientTemp = if isNight then seasonInfo.NightAmbientTemp else seasonInfo.DayAmbientTemp
			workspace:SetAttribute("PondFrozenNow", seasonInfo.PondFrozen)
			warmSpots = CollectionService:GetTagged("WarmSpot")
			pondZones = CollectionService:GetTagged("PondZone")
			shelters = CollectionService:GetTagged("Shelter")

			for _, player in ipairs(Players:GetPlayers()) do
				local ok, err = pcall(survivalTick, player, seasonInfo, ambientTemp)
				if not ok then
					warn("[SurvivalService] " .. player.Name .. " : " .. tostring(err))
				end
			end
		end
	end)
end

return SurvivalService
