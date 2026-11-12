--!strict
-- SurvivalService.luau
-- Service gérant la Faim, la Soif, la Température corporelle et l'Oxygène

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MathUtils = require(ServerScriptService.utils.MathUtils)

local SurvivalService = {}

function SurvivalService.Start()
	task.spawn(function()
		while true do
			task.wait(GameConstants.SURVIVAL_TICK_INTERVAL)

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps
			local isNight = Lighting.ClockTime < 6 or Lighting.ClockTime > 19
			local ambientTemp = if isNight then seasonInfo.NightAmbientTemp else seasonInfo.DayAmbientTemp

			for _, player in ipairs(Players:GetPlayers()) do
				local character = player.Character
				local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
				if not humanoid or humanoid.Health <= 0 then
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

				local inShelter = (player:GetAttribute("InShelterOrColony") :: boolean) or false
				local targetTemp = if inShelter then GameConstants.SHELTER_TEMPERATURE else ambientTemp
				local bodyTemp = (player:GetAttribute("BodyTemperature") :: number) or 20
				bodyTemp = MathUtils.Lerp(bodyTemp, targetTemp, 0.15)

				if bodyTemp > species.IdealTempMax then
					thirst = math.clamp(thirst - 0.8, 0, 100)
				end

				if bodyTemp < species.IdealTempMin then
					humanoid.WalkSpeed = species.WalkSpeed * 0.5
					humanoid:TakeDamage(1.5)
				elseif stage == "Adulte" then
					humanoid.WalkSpeed = species.WalkSpeed
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
