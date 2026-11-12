--!strict
-- PlayerDataRepository.luau
-- Gestion des données de profil des joueurs (Espèce, Croissance, Survie)

local ServerScriptService = game:GetService("ServerScriptService")
local GameConstants = require(ServerScriptService.constant.GameConstants)

local PlayerDataRepository = {}

function PlayerDataRepository.InitPlayerAttributes(player: Player)
	player:SetAttribute("Species", GameConstants.DEFAULT_SPECIES)
	player:SetAttribute("Stage", "Oeuf")
	player:SetAttribute("Growth", 0)
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)
	player:SetAttribute("BodyTemperature", 22)
	player:SetAttribute("Oxygen", 100)
	player:SetAttribute("InShelterOrColony", true)
	player:SetAttribute("CanLeaveNest", false)
end

return PlayerDataRepository
