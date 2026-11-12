--!strict
-- ServerBootstrap.server.luau
-- Point d'entrée principal du serveur (ServerScriptService.bootstrap)

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataRepository = require(ServerScriptService.data.PlayerDataRepository)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local SeasonService = require(ServerScriptService.services.SeasonService)
local SurvivalService = require(ServerScriptService.services.SurvivalService)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local function onPlayerAdded(player: Player)
	PlayerDataRepository.InitPlayerAttributes(player)
	player.CharacterAdded:Connect(function(character)
		task.wait(0.2)
		local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
		local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"
		EvolutionDomain.ApplyStageStats(character, speciesId, stage)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

SeasonService.Start()
SurvivalService.Start()
GrowthAndNestService.Start()
