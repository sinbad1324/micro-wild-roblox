--!strict
-- SeasonManager.server.luau
-- Fait tourner les 4 saisons (Printemps, Été, Automne, Hiver) et met à jour l'environnement

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))

local currentIndex = 1

local function applySeason(seasonName: SeasonConfig.SeasonName)
	local info = SeasonConfig.Seasons[seasonName]
	workspace:SetAttribute("CurrentSeason", seasonName)
	workspace:SetAttribute("SeasonDisplayName", info.DisplayName)
	workspace:SetAttribute("PondFrozen", info.PondFrozen)

	print(string.format("[Micro Wild] Changement de saison : %s - %s", info.DisplayName, info.Description))
end

task.spawn(function()
	while true do
		local seasonName = SeasonConfig.Order[currentIndex]
		local info = SeasonConfig.Seasons[seasonName]

		applySeason(seasonName)
		task.wait(info.DurationSeconds)

		currentIndex = (currentIndex % #SeasonConfig.Order) + 1
	end
end)
