--!strict
-- SeasonService.luau
-- Service gérant le cycle des 4 saisons (Printemps, Été, Automne, Hiver)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SeasonConfig = require(ReplicatedStorage.shared.SeasonConfig)

local SeasonService = {}

local currentIndex = 1
local cycleThread: thread? = nil

local function applySeason(index: number)
	currentIndex = ((index - 1) % #SeasonConfig.Order) + 1
	local seasonName = SeasonConfig.Order[currentIndex]
	local info = SeasonConfig.Seasons[seasonName]

	workspace:SetAttribute("CurrentSeason", seasonName)
	workspace:SetAttribute("SeasonDisplayName", info.DisplayName)
	workspace:SetAttribute("PondFrozen", info.PondFrozen)

	print(string.format("[MicroWild] Saison : %s - %s", info.DisplayName, info.Description))
end

local function startCycle()
	if cycleThread then
		task.cancel(cycleThread)
	end
	cycleThread = task.spawn(function()
		while true do
			applySeason(currentIndex)
			local seasonName = SeasonConfig.Order[currentIndex]
			local info = SeasonConfig.Seasons[seasonName]
			task.wait(info.DurationSeconds)
			currentIndex = (currentIndex % #SeasonConfig.Order) + 1
		end
	end)
end

function SeasonService.NextSeason(): string
	currentIndex = (currentIndex % #SeasonConfig.Order) + 1
	startCycle()
	return SeasonConfig.Order[currentIndex]
end

function SeasonService.Start()
	startCycle()
end

return SeasonService
