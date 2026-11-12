--!strict
-- GrowthAndNestService.luau
-- Service gérant les nids (Maman/Colonie) et la progression de croissance des insectes.
-- API stable utilisée par les contrôleurs réseau (RequestCreateNest/RequestJoinNest/RequestLeaveNest) :
--   CreateNest(motherPlayer), JoinNest(childPlayer, motherUserId), LeaveNest(childPlayer),
--   GetNestSummaries() -> { NestSummary } pour le menu de spawn.

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

local function familyIdFor(motherUserId: number): string
	return "Nest_" .. tostring(motherUserId)
end

function GrowthAndNestService.CreateNest(motherPlayer: Player): boolean
	local growth = (motherPlayer:GetAttribute("Growth") :: number) or 0
	if growth < GameConstants.NEST_MIN_GROWTH then
		return false
	end
	local character = motherPlayer.Character
	if not character or not character.PrimaryPart then
		return false
	end

	local speciesId = (motherPlayer:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
	GrowthAndNestService.ActiveNests[motherPlayer.UserId] = {
		OwnerUserId = motherPlayer.UserId,
		FamilyId = familyIdFor(motherPlayer.UserId),
		SpeciesId = speciesId,
		Position = character.PrimaryPart.Position,
		StoredFood = 100,
		Children = {},
	}
	motherPlayer:SetAttribute("IsMother", true)
	motherPlayer:SetAttribute("FamilyId", familyIdFor(motherPlayer.UserId))
	return true
end

function GrowthAndNestService.JoinNest(childPlayer: Player, motherUserId: number): boolean
	local nest = GrowthAndNestService.ActiveNests[motherUserId]
	if not nest then
		return false
	end
	table.insert(nest.Children, childPlayer)
	childPlayer:SetAttribute("FamilyId", nest.FamilyId)
	childPlayer:SetAttribute("OwnerNestUserId", motherUserId)
	return true
end

function GrowthAndNestService.LeaveNest(childPlayer: Player)
	local ownerUserId = childPlayer:GetAttribute("OwnerNestUserId") :: number?
	if ownerUserId then
		local nest = GrowthAndNestService.ActiveNests[ownerUserId]
		if nest then
			local index = table.find(nest.Children, childPlayer)
			if index then
				table.remove(nest.Children, index)
			end
		end
	end
	childPlayer:SetAttribute("FamilyId", nil)
	childPlayer:SetAttribute("OwnerNestUserId", nil)
end

function GrowthAndNestService.GetNestSummaries(): { ServerTypes.NestSummary }
	local summaries: { ServerTypes.NestSummary } = {}
	for ownerUserId, nest in pairs(GrowthAndNestService.ActiveNests) do
		local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
		if ownerPlayer then
			table.insert(summaries, {
				OwnerUserId = ownerUserId,
				OwnerName = ownerPlayer.Name,
				SpeciesId = nest.SpeciesId,
				ChildCount = #nest.Children,
			})
		else
			GrowthAndNestService.ActiveNests[ownerUserId] = nil
		end
	end
	return summaries
end

local function applyMoltWindow(player: Player, speciesId: string, growthAtTrigger: number)
	player:SetAttribute("IsMolting", true)
	player:SetAttribute("Stage", "Mue")
	if player.Character then
		EvolutionDomain.ApplyStageStats(player, player.Character, speciesId, "Mue")
	end

	task.delay(GameConstants.MOLT_SOFT_SHELL_SECONDS, function()
		if not player.Parent then
			return
		end
		player:SetAttribute("IsMolting", false)
		local currentGrowth = (player:GetAttribute("Growth") :: number) or growthAtTrigger
		local settledStage = EvolutionDomain.GetStageForGrowth(speciesId, currentGrowth)
		player:SetAttribute("Stage", settledStage)
		if player.Character then
			EvolutionDomain.ApplyStageStats(player, player.Character, speciesId, settledStage)
		end
	end)
end

function GrowthAndNestService.Start()
	task.spawn(function()
		while true do
			task.wait(GameConstants.GROWTH_TICK_INTERVAL)

			local currentSeasonName = (workspace:GetAttribute("CurrentSeason") :: string) or "Printemps"
			local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps

			for _, player in ipairs(Players:GetPlayers()) do
				-- La croissance ne démarre qu'après le choix d'espèce dans le menu de spawn
				-- (SpawnMenuNetworkService pose cet attribut) : sinon Growth quitte 0 en
				-- quelques secondes et le menu de spawn (visible tant que Growth == 0) disparaît
				-- avant que le joueur ait pu choisir.
				if player:GetAttribute("HasConfirmedSpawn") ~= true then
					continue
				end

				if player:GetAttribute("IsMolting") == true then
					continue
				end

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
				local previousGrowth = growth

				growth = math.clamp(
					growth + (1.5 * seasonInfo.GrowthSpeedMultiplier),
					0,
					GameConstants.STAGE_THRESHOLDS.MAX_GROWTH
				)
				player:SetAttribute("Growth", MathUtils.RoundToDecimal(growth, 1))

				if EvolutionDomain.ShouldTriggerMolt(speciesId, previousGrowth, growth) then
					applyMoltWindow(player, speciesId, growth)
					continue
				end

				local newStage = EvolutionDomain.GetStageForGrowth(speciesId, growth)
				if newStage ~= previousStage then
					player:SetAttribute("Stage", newStage)
					if newStage == "Adulte" then
						player:SetAttribute("CanLeaveNest", true)
					end
					if player.Character then
						EvolutionDomain.ApplyStageStats(player, player.Character, speciesId, newStage)
					end
				end
			end
		end
	end)
end

return GrowthAndNestService
