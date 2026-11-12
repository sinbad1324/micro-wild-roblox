--!strict
-- PlayerDataRepository.luau
-- Gestion des données de profil des joueurs (Espèce, Croissance, Survie)

local ServerScriptService = game:GetService("ServerScriptService")
local GameConstants = require(ServerScriptService.constant.GameConstants)

local PlayerDataRepository = {}

function PlayerDataRepository.InitPlayerAttributes(player: Player)
	-- Ne réinitialise pas la progression si le joueur revient d'une déconnexion courte
	-- (BindToClose/teleport) : seuls les attributs absents sont posés.
	if player:GetAttribute("Species") == nil then
		player:SetAttribute("Species", GameConstants.DEFAULT_SPECIES)
	end
	if player:GetAttribute("Stage") == nil then
		player:SetAttribute("Stage", "Oeuf")
	end
	if player:GetAttribute("Growth") == nil then
		player:SetAttribute("Growth", 0)
	end
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)
	player:SetAttribute("BodyTemperature", 22)
	player:SetAttribute("Oxygen", 100)
	player:SetAttribute("InShelterOrColony", true)
	if player:GetAttribute("CanLeaveNest") == nil then
		player:SetAttribute("CanLeaveNest", false)
	end

	-- Famille / colonie : FamilyId (non posé tant que le joueur n'a pas rejoint un nid) est
	-- partagé par la Maman et ses enfants (no friendly-fire, voir DamageService). OwnerNestUserId
	-- pointe vers le nid natal pour JoinNest/LeaveNest.
	if player:GetAttribute("IsMother") == nil then
		player:SetAttribute("IsMother", false)
	end
	if player:GetAttribute("IsGrabbed") == nil then
		player:SetAttribute("IsGrabbed", false)
	end
	if player:GetAttribute("IsMolting") == nil then
		player:SetAttribute("IsMolting", false)
	end

	-- Posé par SpawnMenuNetworkService une fois l'espèce choisie : tant que c'est faux,
	-- GrowthAndNestService n'incrémente pas Growth (sinon le menu de spawn, visible tant que
	-- Growth == 0, disparaîtrait avant que le joueur ait pu choisir).
	if player:GetAttribute("HasConfirmedSpawn") == nil then
		player:SetAttribute("HasConfirmedSpawn", false)
	end
end

return PlayerDataRepository
