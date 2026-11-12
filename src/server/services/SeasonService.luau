--!strict
-- SeasonService.luau
-- Service gérant le cycle des 4 saisons (Printemps, Été, Automne, Hiver)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)

local SeasonService = {}

function SeasonService.Start()
	task.spawn(function()
		local currentIndex = 1
		while true do
			local seasonName = SeasonConfig.Order[currentIndex]
			local info = SeasonConfig.Seasons[seasonName]

			workspace:SetAttribute("CurrentSeason", seasonName)
			workspace:SetAttribute("SeasonDisplayName", info.DisplayName)
			workspace:SetAttribute("PondFrozen", info.PondFrozen)

			print(string.format("[MicroWild] Saison : %s - %s", info.DisplayName, info.Description))
			task.wait(info.DurationSeconds)

			currentIndex = (currentIndex % #SeasonConfig.Order) + 1
		end
	end)
end

return SeasonService
