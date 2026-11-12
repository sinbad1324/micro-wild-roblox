--!strict
-- SurvivalManager.server.luau
-- Gère la Faim (Herbivore/Carnivore/Omnivore), la Soif, la Température et l'Oxygène des joueurs

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InsectData = require(Shared:WaitForChild("InsectData"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))

local TICK_INTERVAL = 2 -- Mise à jour toutes les 2 secondes

local function initPlayerSurvival(player: Player)
	player:SetAttribute("Species", "FourmiRousse") -- Espèce par défaut
	player:SetAttribute("Stage", "Oeuf") -- Oeuf -> Larve -> Cocon -> Adulte
	player:SetAttribute("Growth", 0) -- 0 à 100%
	player:SetAttribute("Hunger", 100) -- 0 à 100
	player:SetAttribute("Thirst", 100) -- 0 à 100
	player:SetAttribute("BodyTemperature", 22) -- en °C
	player:SetAttribute("Oxygen", 100) -- 0 à 100
	player:SetAttribute("InShelterOrColony", true) -- Dans le nid au spawn
end

Players.PlayerAdded:Connect(initPlayerSurvival)
for _, player in ipairs(Players:GetPlayers()) do
	initPlayerSurvival(player)
end

-- Boucle principale de survie
task.spawn(function()
	while true do
		task.wait(TICK_INTERVAL)

		local currentSeasonName = workspace:GetAttribute("CurrentSeason") or "Printemps"
		local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps
		local isNight = Lighting.ClockTime < 6 or Lighting.ClockTime > 19
		local ambientTemp = if isNight then seasonInfo.NightAmbientTemp else seasonInfo.DayAmbientTemp

		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if not humanoid or humanoid.Health <= 0 then
				continue
			end

			local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
			local species = InsectData[speciesId] or InsectData.FourmiRousse
			local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"

			-- 1. Diminution Faim & Soif (l'œuf ne consomme presque rien)
			local hunger = (player:GetAttribute("Hunger") :: number) or 100
			local thirst = (player:GetAttribute("Thirst") :: number) or 100

			local drainFactor = if stage == "Oeuf" then 0.1 elseif stage == "Cocon" then 0.2 else 1.0
			hunger = math.clamp(hunger - (0.35 * drainFactor), 0, 100)
			thirst = math.clamp(thirst - (0.45 * drainFactor * seasonInfo.ThirstDrainMultiplier), 0, 100)

			-- 2. Calcul de la Température Corporelle
			local inShelter = (player:GetAttribute("InShelterOrColony") :: boolean) or false
			local targetTemp = ambientTemp
			if inShelter then
				-- Les fourmilières, ruches et terriers gardent une température douce (~20°C) même en hiver
				targetTemp = 20
			end

			local bodyTemp = (player:GetAttribute("BodyTemperature") :: number) or 20
			bodyTemp = bodyTemp + (targetTemp - bodyTemp) * 0.15

			-- Surchauffe : fait baisser la soif plus vite
			if bodyTemp > species.IdealTempMax then
				thirst = math.clamp(thirst - 0.8, 0, 100)
			end

			-- Hypothermie : ralentit l'insecte et inflige des dégâts de froid
			if bodyTemp < species.IdealTempMin then
				humanoid.WalkSpeed = species.WalkSpeed * 0.5
				humanoid:TakeDamage(1.5)
			elseif stage == "Adulte" then
				humanoid.WalkSpeed = species.WalkSpeed
			end

			-- Dégâts de famine ou déshydratation
			if hunger <= 0 then
				humanoid:TakeDamage(2)
			end
			if thirst <= 0 then
				humanoid:TakeDamage(2.5)
			end

			player:SetAttribute("Hunger", hunger)
			player:SetAttribute("Thirst", thirst)
			player:SetAttribute("BodyTemperature", math.round(bodyTemp * 10) / 10)
		end
	end
end)
