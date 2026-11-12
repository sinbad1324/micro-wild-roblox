--!strict
-- GrowthAndNestService.luau
-- Service gérant les nids (Maman/Colonie) et la progression de croissance des insectes

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local MathUtils = require(ServerScriptService.utils.MathUtils)
local ServerTypes = require(ServerScriptService.types.ServerTypes)

local GrowthAndNestService = {}
GrowthAndNestService.ActiveNests = {} :: { [number]: ServerTypes.NestData }

function GrowthAndNestService.CreateNest(motherPlayer: Player)
	if motherPlayer:GetAttribute("Stage") ~= "Adulte" then
		return
	end
	local character = motherPlayer.Character
	if not character or not character.PrimaryPart then
		return
	end

	local speciesId = (motherPlayer:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
	GrowthAndNestService.ActiveNests[motherPlayer.UserId] = {
		OwnerUserId = motherPlayer.UserId,
		SpeciesId = speciesId,
		Position = character.PrimaryPart.Position,
		StoredFood = 100,
		Children = {},
	}
	motherPlayer:SetAttribute("IsMother", true)
end

function GrowthAndNestService.Start()
	task.spawn(function()
		while true do
			task.wait(GameConstants.GROWTH_TICK_INTERVAL)

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps

			for _, player in ipairs(Players:GetPlayers()) do
				local hunger = (player:GetAttribute("Hunger") :: number) or 0
				local thirst = (player:GetAttribute("Thirst") :: number) or 0
				if hunger < 20 or thirst < 20 then
					continue
				end

				local growth = (player:GetAttribute("Growth") :: number) or 0
				if growth >= GameConstants.STAGE_THRESHOLDS.MAX_GROWTH then
					continue
				end

				local speciesId = (player:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
				local previousStage = (player:GetAttribute("Stage") :: string) or "Oeuf"

				growth = math.clamp(
					growth + (1.5 * seasonInfo.GrowthSpeedMultiplier),
					0,
					GameConstants.STAGE_THRESHOLDS.MAX_GROWTH
				)
				player:SetAttribute("Growth", MathUtils.RoundToDecimal(growth, 1))

				local newStage = EvolutionDomain.GetStageForGrowth(speciesId, growth)
				if newStage ~= previousStage then
					player:SetAttribute("Stage", newStage)
					if newStage == "Adulte" then
						player:SetAttribute("CanLeaveNest", true)
					end
					if player.Character then
						EvolutionDomain.ApplyStageStats(player.Character, speciesId, newStage)
					end
				end
			end
		end
	end)
end

return GrowthAndNestService
