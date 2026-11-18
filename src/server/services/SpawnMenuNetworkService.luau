--!strict
-- SpawnMenuNetworkService.luau
-- Gestionnaires réseau du menu de spawn : choix d'espèce + jonction/sortie de nid, et fondation
-- de colonie par un adulte (GDD §2 "Spawn" et §8.2). Le client envoie une intention, ce module valide.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)

local SpawnMenuNetworkService = {}

local lastRequest: { [Player]: number } = {}

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function broadcastNestList()
	Remotes.Get("NestListChanged"):FireAllClients(GrowthAndNestService.GetNestSummaries())
end

local function throttle(player: Player): boolean
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < 0.5 then
		return false
	end
	lastRequest[player] = now
	return true
end

-- Le choix n'est permis qu'avant l'éclosion (Oeuf, 0% de croissance, pas encore confirmé).
local function canStillChoose(player: Player): boolean
	-- Pas de choix pendant les 5 s de réapparition (le corps est encore celui de la vie précédente).
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	return player:GetAttribute("Stage") == "Oeuf"
		and player:GetAttribute("Growth") == 0
		and player:GetAttribute("HasConfirmedSpawn") ~= true
end

-- Verrouille l'espèce, choisit le lieu de naissance, tire une mutation et démarre la croissance.
local function confirmSpawn(player: Player, speciesId: string, home: Vector3?)
	player:SetAttribute("Species", speciesId)
	player:SetAttribute("HomePosition", home)
	player:SetAttribute("Mutation", nil) -- tirée à l'âge adulte (ProgressionService), pas à la naissance
	-- Débloque la croissance (voir GrowthAndNestService) : le menu de spawn reste visible tant
	-- que Growth == 0, donc l'espèce doit être verrouillée AVANT que Growth ne bouge.
	player:SetAttribute("HasConfirmedSpawn", true)
	EvolutionDomain.SetStage(player, speciesId, "Oeuf", true) -- corps neuf : pas de transition

	local character = player.Character
	if home and character then
		character:PivotTo(CFrame.new(home + Vector3.new(0, 3, 0)))
	end
end

local function onSelectSpecies(player: Player, speciesId: unknown)
	if not throttle(player) then
		return
	end
	local isValidId = typeof(speciesId) == "string" and InsectData[speciesId :: string] ~= nil
	if not isValidId or not canStillChoose(player) then
		notify(player, "Choix impossible maintenant.", "warning")
		return
	end
	local id = speciesId :: string
	confirmSpawn(player, id, GrowthAndNestService.GetDefaultHome(id))
	notify(player, "Vous êtes un oeuf de " .. InsectData[id].Name .. ". Restez au chaud !", "info")
end

-- Fondation de colonie : réservée à un adulte à 100% de croissance (bouton de la barre de pouvoirs).
local function onCreateNest(player: Player)
	if not throttle(player) then
		return
	end
	-- CreateNest écraserait une colonie déjà fondée (enfants perdus).
	if player:GetAttribute("IsMother") == true then
		notify(player, "Vous dirigez déjà une colonie.", "warning")
		return
	end
	-- Éligibilité AVANT de quitter sa famille (sinon un enfant à 99% perd sa famille pour rien).
	local growth = (player:GetAttribute("Growth") :: number?) or 0
	if player:GetAttribute("Stage") ~= "Adulte" or growth < 100 then
		notify(player, "Il faut être adulte à 100% de croissance pour fonder une colonie.", "warning")
		return
	end
	if player:GetAttribute("OwnerNestUserId") ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end
	if GrowthAndNestService.CreateNest(player) then
		notify(player, "Colonie fondée ! Les nouveaux joueurs peuvent naître dans votre nid.", "info")
		broadcastNestList()
	else
		notify(player, "Impossible de construire le nid ici (posez-vous au sol).", "warning")
	end
end

local function onJoinNest(player: Player, motherUserId: unknown)
	if not throttle(player) then
		return
	end
	if typeof(motherUserId) ~= "number" or motherUserId == player.UserId then
		notify(player, "Nid invalide.", "warning")
		return
	end
	if not canStillChoose(player) then
		notify(player, "On ne peut naître dans un nid qu'en tant qu'oeuf.", "warning")
		return
	end
	local nest = GrowthAndNestService.GetNest(motherUserId :: number)
	if not nest then
		notify(player, "Ce nid n'existe plus.", "warning")
		return
	end
	if player:GetAttribute("OwnerNestUserId") ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end
	if GrowthAndNestService.JoinNest(player, motherUserId :: number) then
		confirmSpawn(player, nest.SpeciesId, nest.Position)
		notify(player, "Vous êtes né(e) dans le nid de votre Maman !", "info")
		local mother = Players:GetPlayerByUserId(motherUserId :: number)
		if mother then
			notify(mother, player.Name .. " a éclos dans votre nid !", "info")
		end
		broadcastNestList()
	end
end

local function onLeaveNest(player: Player)
	if not throttle(player) then
		return
	end
	-- Seul un membre de nid autorisé à partir peut quitter (sinon : flood de diffusions / téléport).
	if player:GetAttribute("OwnerNestUserId") == nil or player:GetAttribute("CanLeaveNest") ~= true then
		return
	end
	GrowthAndNestService.LeaveNest(player)
	broadcastNestList()
end

function SpawnMenuNetworkService.Start()
	Remotes.Get("RequestSelectSpecies").OnServerEvent:Connect(onSelectSpecies)
	Remotes.Get("RequestCreateNest").OnServerEvent:Connect(onCreateNest)
	Remotes.Get("RequestJoinNest").OnServerEvent:Connect(onJoinNest)
	Remotes.Get("RequestLeaveNest").OnServerEvent:Connect(onLeaveNest)

	-- Snapshot immédiat pour l'arrivant (sinon jusqu'à 10s de liste vide).
	Players.PlayerAdded:Connect(function(player)
		Remotes.Get("NestListChanged"):FireClient(player, GrowthAndNestService.GetNestSummaries())
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		if player:GetAttribute("IsMother") == true then
			GrowthAndNestService.RemoveNest(player.UserId)
		else
			GrowthAndNestService.LeaveNest(player)
		end
		broadcastNestList()
	end)

	task.spawn(function()
		task.wait(1)
		broadcastNestList()
		while true do
			task.wait(10) -- filet de sécurité (ex: Maman déconnectée sans PlayerRemoving propre)
			broadcastNestList()
		end
	end)
end

return SpawnMenuNetworkService
