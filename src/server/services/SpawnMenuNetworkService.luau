--!strict
-- SpawnMenuNetworkService.luau
-- Gestionnaires réseau du menu de spawn : choix d'espèce + création/jonction/sortie de nid
-- (GDD §2 "Spawn" et §8.2 "Menu de Spawn"). Le client envoie une intention, ce module valide.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local SpawnMenuNetworkService = {}

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function broadcastNestList()
	Remotes.Get("NestListChanged"):FireAllClients(GrowthAndNestService.GetNestSummaries())
end

-- Le choix d'espèce n'est permis qu'avant l'éclosion (Oeuf, 0% de croissance) : une fois la
-- croissance démarrée, l'espèce est verrouillée.
local function onSelectSpecies(player: Player, speciesId: unknown)
	local isValidId = typeof(speciesId) == "string" and InsectData[speciesId :: string] ~= nil
	local canChoose = player:GetAttribute("Stage") == "Oeuf" and player:GetAttribute("Growth") == 0
	if not isValidId or not canChoose then
		notify(player, "Choix impossible maintenant.", "warning")
		return
	end

	local id = speciesId :: string
	player:SetAttribute("Species", id)
	-- Débloque la croissance (voir GrowthAndNestService) : le menu de spawn reste visible tant
	-- que Growth == 0, donc l'espèce doit être verrouillée AVANT que Growth ne bouge.
	player:SetAttribute("HasConfirmedSpawn", true)
	notify(player, "Espèce choisie: " .. InsectData[id].Name, "info")
end

local function onCreateNest(player: Player)
	-- CreateNest écrase Children = {} : un double-clic viderait une colonie déjà fondée.
	if player:GetAttribute("IsMother") == true then
		notify(player, "Vous dirigez déjà une colonie.", "warning")
		return
	end

	if GrowthAndNestService.CreateNest(player) then
		notify(player, "Colonie fondée !", "info")
		broadcastNestList()
	else
		notify(player, "Impossible de fonder une colonie maintenant.", "warning")
	end
end

local function onJoinNest(player: Player, motherUserId: unknown)
	if typeof(motherUserId) ~= "number" or motherUserId == player.UserId then
		notify(player, "Nid invalide.", "warning")
		return
	end
	-- Une Maman qui rejoint un autre nid écraserait son propre FamilyId (no-friendly-fire cassé).
	if player:GetAttribute("IsMother") == true then
		notify(player, "Vous dirigez déjà votre propre colonie.", "warning")
		return
	end

	-- JoinNest ne retire pas l'ancien enfant de son précédent nid : on quitte d'abord pour
	-- éviter de compter le joueur deux fois si le menu est utilisé plusieurs fois.
	if player:GetAttribute("OwnerNestUserId") ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end

	if GrowthAndNestService.JoinNest(player, motherUserId :: number) then
		notify(player, "Vous avez rejoint le nid !", "info")
		broadcastNestList()
	else
		notify(player, "Ce nid n'existe plus.", "warning")
	end
end

local function onLeaveNest(player: Player)
	GrowthAndNestService.LeaveNest(player)
	broadcastNestList()
end

function SpawnMenuNetworkService.Start()
	Remotes.Get("RequestSelectSpecies").OnServerEvent:Connect(onSelectSpecies)
	Remotes.Get("RequestCreateNest").OnServerEvent:Connect(onCreateNest)
	Remotes.Get("RequestJoinNest").OnServerEvent:Connect(onJoinNest)
	Remotes.Get("RequestLeaveNest").OnServerEvent:Connect(onLeaveNest)

	-- Snapshot immédiat pour l'arrivant (sinon jusqu'à 10s de liste vide) ; GetNestSummaries
	-- s'auto-nettoie déjà, mais un enfant qui se déconnecte doit aussi libérer sa place.
	Players.PlayerAdded:Connect(function(player)
		Remotes.Get("NestListChanged"):FireClient(player, GrowthAndNestService.GetNestSummaries())
	end)
	Players.PlayerRemoving:Connect(function(player)
		GrowthAndNestService.LeaveNest(player)
		broadcastNestList()
	end)

	task.spawn(function()
		task.wait(1) -- laisse GrowthAndNestService.Start() démarrer avant le premier snapshot
		broadcastNestList()
		while true do
			task.wait(10) -- filet de sécurité (ex: Maman déconnectée sans PlayerRemoving propre)
			broadcastNestList()
		end
	end)
end

return SpawnMenuNetworkService
