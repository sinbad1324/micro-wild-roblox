--!strict
-- SpawnMenuNetworkService.luau
-- Gestionnaires réseau du menu de spawn : choix d'espèce, jonction/sortie de nid, naissance directe
-- en Maman (débloquée par le profil) et fondation de colonie par un adulte (GDD §2 "Spawn" et §8.2).
-- Le client envoie une intention, ce module valide.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local EvolutionTraits = require(ReplicatedStorage.shared.EvolutionTraits)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local ServerTypes = require(ServerScriptService.types.ServerTypes)

local SpawnMenuNetworkService = {}

local lastRequest: { [Player]: number } = {}
-- Délai entre deux naissances en Maman (anti mort/renaissance en boucle). Indexé par UserId et
-- jamais vidé au départ : quitter/revenir sur le serveur ne remet pas le délai à zéro (seules les
-- entrées expirées sont purgées par la boucle de Start).
local MOTHER_SPAWN_COOLDOWN = 60
local MOTHER_NEST_DELAY = 1.5 -- laisse le corps se poser avant de construire le nid
local lastMotherSpawn: { [number]: number } = {}
-- Taille max d'un nid : répartit les nouveaux joueurs entre Mamans (dont PNJ). Miroir côté client (SpawnMenuView).
local MAX_NEST_CHILDREN = 6

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

-- Signature compacte de la liste (ordre stable) : la boucle de sécurité n'envoie que si elle change.
local lastBroadcastSignature = ""
local function nestSignature(summaries: { ServerTypes.NestSummary }): string
	local parts = table.create(#summaries)
	for _, summary in ipairs(summaries) do
		table.insert(parts, tostring(summary.OwnerUserId) .. ":" .. summary.SpeciesId .. ":" .. tostring(summary.ChildCount) .. ":" .. tostring(summary.MotherAlive))
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

-- Diffusions sur événement (création/jonction/départ) : toujours envoyées, et le cache suit.
local function broadcastNestList()
	local summaries = GrowthAndNestService.GetNestSummaries()
	lastBroadcastSignature = nestSignature(summaries)
	Remotes.Get("NestListChanged"):FireAllClients(summaries)
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
	if InsectData[id].Category == "Animal" then
		-- Animal jouable : pas d'oeuf ni de croissance, il naît adulte dans son habitat.
		if player:GetAttribute("OwnerNestUserId") ~= nil then
			GrowthAndNestService.LeaveNest(player)
		end
		local home = GrowthAndNestService.GetDefaultHome(id) or (WorldLayout.SPAWN_POSITION + Vector3.new(0, 2, 0))
		player:SetAttribute("Species", id)
		player:SetAttribute("HomePosition", home)
		player:SetAttribute("Mutation", nil)
		-- Ordre synchrone (comme onSpawnAsMother) : Growth à 100 AVANT HasConfirmedSpawn.
		player:SetAttribute("Growth", 100)
		player:SetAttribute("CanLeaveNest", true)
		player:SetAttribute("HasConfirmedSpawn", true)
		EvolutionDomain.SetStage(player, id, "Adulte", true)
		local character = player.Character
		if character and character.Parent then
			character:PivotTo(CFrame.new(home + Vector3.new(0, 4, 0)))
		end
		notify(player, "Vous êtes un " .. InsectData[id].Name .. " ! Chassez les insectes.", "info")
		return
	end
	confirmSpawn(player, id, GrowthAndNestService.GetDefaultHome(id))
	notify(player, "Vous êtes un oeuf de " .. InsectData[id].Name .. ". Restez au chaud !", "info")
end

-- Fondation de colonie : réservée à un adulte à 100% de croissance (bouton de la barre de pouvoirs).
local DECLARE_REACH = 45 -- GameConstants.NEST_RADIUS * 2.5, portée du mode construction
local function onCreateNest(player: Player, at: unknown)
	if not throttle(player) then
		return
	end
	-- Maison déclarée en visant (mode construction) : point fini et à portée du joueur.
	local declared: Vector3? = nil
	if typeof(at) == "Vector3" then
		local point = at :: Vector3
		local root = player.Character and player.Character.PrimaryPart
		if point.Magnitude ~= point.Magnitude or point.Magnitude == math.huge or not root or (root.Position - point).Magnitude > DECLARE_REACH then
			return
		end
		declared = point
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
	if not EvolutionTraits.CanFoundColony(player) then
		notify(player, "Seule une Reine peut fonder une colonie : vous servez la vôtre.", "warning")
		return
	end
	-- Mêmes gardes que CreateNest AVANT de quitter sa famille (sinon famille perdue pour rien).
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	local swimming = species ~= nil and species.CanSwim and humanoid ~= nil and humanoid:GetState() == Enum.HumanoidStateType.Swimming
	if humanoid and humanoid.FloorMaterial == Enum.Material.Air and not swimming then
		notify(player, "Posez-vous au sol pour construire votre nid.", "warning")
		return
	end
	-- CreateNest peut encore refuser (espacement des nids) : on mémorise la famille pour y revenir.
	local previousOwner = player:GetAttribute("OwnerNestUserId") :: number?
	if previousOwner ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end
	if GrowthAndNestService.CreateNest(player, declared) then
		notify(player, "Colonie fondée ! Les nouveaux joueurs peuvent naître dans votre nid.", "info")
		broadcastNestList()
	else
		-- Retour dans la famille d'origine : liste inchangée, pas de diffusion. CreateNest a déjà
		-- expliqué le refus (espacement), pas de second toast.
		if previousOwner and GrowthAndNestService.GetNest(previousOwner) then
			GrowthAndNestService.JoinNest(player, previousOwner)
		end
	end
end

-- Point de naissance d'une Maman : au sol, hors de l'espacement minimal des nids (CreateNest refuse
-- à moins de NEST_RADIUS*2 d'un autre nid). Repli décalé hors de la maison après plusieurs essais.
local function motherSpawnPoint(home: Vector3, character: Model?): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = false -- une mère terrestre ne naît pas au fond de l'eau
	local minSpacing = GameConstants.NEST_RADIUS * 2
	local aiNests = CollectionService:GetTagged("AINest")
	for _ = 1, 8 do
		local angle = math.random() * 2 * math.pi
		local distance = minSpacing + 4 + math.random() * 20
		local probe = home + Vector3.new(math.cos(angle) * distance, 40, math.sin(angle) * distance)
		local result = workspace:Raycast(probe, Vector3.new(0, -120, 0), params)
		-- Sol trop haut/bas (souche, rocher, tronc) ou eau : nouvel essai.
		if result and result.Material ~= Enum.Material.Water and math.abs(result.Position.Y - home.Y) <= 10 then
			local spot = result.Position + Vector3.new(0, 2, 0)
			local free = true
			for _, nest in pairs(GrowthAndNestService.ActiveNests) do
				if (nest.Position - spot).Magnitude < minSpacing then
					free = false
					break
				end
			end
			-- CreateNest refuse aussi la proximité des nids IA (tag "AINest").
			if free then
				for _, tagged in ipairs(aiNests) do
					if tagged:IsA("BasePart") and (tagged.Position - spot).Magnitude < minSpacing then
						free = false
						break
					end
				end
			end
			if free then
				return spot
			end
		end
	end
	-- Repli hors de l'espacement de la maison (sinon la colonie automatique est toujours refusée).
	return home + Vector3.new(minSpacing + 4, 0, 0)
end

-- "Être une Maman" : naissance directe en adulte à 100%, puis fondation de colonie automatique.
local function onSpawnAsMother(player: Player, speciesId: unknown)
	if not throttle(player) then
		return
	end
	local isValidId = typeof(speciesId) == "string" and #(speciesId :: string) <= 64 and InsectData[speciesId :: string] ~= nil
	if not isValidId or not canStillChoose(player) then
		notify(player, "Choix impossible maintenant.", "warning")
		return
	end
	if InsectData[speciesId :: string].Category == "Animal" then
		notify(player, "Les animaux ne fondent pas de colonie : choisissez-les dans la liste.", "warning")
		return
	end
	local allowed, reason = ProgressionService.CanSpawnAsMother(player)
	if not allowed then
		notify(player, reason or "Option verrouillée.", "warning")
		return
	end
	local now = os.clock()
	local last = lastMotherSpawn[player.UserId]
	if last and now - last < MOTHER_SPAWN_COOLDOWN then
		notify(player, string.format("Naître Maman à nouveau dans %d s.", math.ceil(MOTHER_SPAWN_COOLDOWN - (now - last))), "warning")
		return
	end
	lastMotherSpawn[player.UserId] = now
	-- Horloge partagée client/serveur : le menu affiche le compte à rebours au lieu d'un faux bouton actif.
	player:SetAttribute("MotherSpawnReadyAt", workspace:GetServerTimeNow() + MOTHER_SPAWN_COOLDOWN)

	local id = speciesId :: string
	local character = player.Character
	local aquatic = InsectData[id].Category == "Aquatique"
	-- Seule une Maman aquatique naît à la nurserie de la mare ; les volants à larve aquatique
	-- (Libellule, Moustique...) sont adultes : nid sauvage terrestre, sinon noyade au fond.
	local home = GrowthAndNestService.GetDefaultHome(if aquatic then id else GameConstants.DEFAULT_SPECIES)
		or (WorldLayout.SPAWN_POSITION + Vector3.new(0, 2, 0))
	-- Aquatique : la maison est sous l'eau (nurserie de la mare, centrée en X sur une mare de 200 studs) :
	-- on se décale hors de l'espacement minimal des nids, sinon la colonie automatique est refusée.
	local spot = if aquatic then home + Vector3.new(GameConstants.NEST_RADIUS * 2 + 4, 0, 0) else motherSpawnPoint(home, character)

	-- Ordre synchrone (aucune attente avant SetStage) : Growth à 100 AVANT HasConfirmedSpawn, sinon
	-- la boucle de croissance ferait avancer l'oeuf. Pas de StageChanged (ni PE ni mutation).
	if player:GetAttribute("OwnerNestUserId") ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end
	player:SetAttribute("Species", id)
	player:SetAttribute("HomePosition", spot)
	player:SetAttribute("Mutation", nil)
	player:SetAttribute("Growth", 100)
	player:SetAttribute("CanLeaveNest", true)
	player:SetAttribute("HasConfirmedSpawn", true)
	-- Pas de mutation tirée ici : elle reste la récompense d'une vie menée jusqu'à l'âge adulte.
	EvolutionDomain.SetStage(player, id, "Adulte", true)
	if character and character.Parent then
		character:PivotTo(CFrame.new(spot + Vector3.new(0, 3, 0)))
	end
	notify(player, "Vous êtes une Maman " .. InsectData[id].Name .. " ! Votre colonie se construit...", "info")

	local lifeToken = player:GetAttribute("LifeToken")
	task.delay(MOTHER_NEST_DELAY, function()
		if not player.Parent
			or player:GetAttribute("LifeToken") ~= lifeToken
			or player:GetAttribute("Stage") ~= "Adulte"
			or player:GetAttribute("IsMother") == true
		then
			return
		end
		if GrowthAndNestService.CreateNest(player) then
			notify(player, "Colonie fondée ! Les nouveaux joueurs peuvent naître dans votre nid.", "info")
			broadcastNestList()
		else
			notify(player, "Trouvez un bon endroit au sol puis appuyez sur « Fonder une colonie ».", "warning")
		end
	end)
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
		-- Liste fraîche à ce seul client : la ligne périmée disparaît sans attendre la boucle de sécurité.
		Remotes.Get("NestListChanged"):FireClient(player, GrowthAndNestService.GetNestSummaries())
		return
	end
	-- Seuls les enfants encore dépendants comptent : un adulte reste dans Children (FamilyId) sans occuper de place.
	local dependents = 0
	for _, child in ipairs(nest.Children) do
		if child:GetAttribute("CanLeaveNest") ~= true then
			dependents += 1
		end
	end
	if dependents >= MAX_NEST_CHILDREN then
		notify(player, "Ce nid est complet, choisissez-en un autre.", "warning")
		return
	end
	if player:GetAttribute("OwnerNestUserId") ~= nil then
		GrowthAndNestService.LeaveNest(player)
	end
	if GrowthAndNestService.JoinNest(player, motherUserId :: number) then
		confirmSpawn(player, nest.SpeciesId, nest.Position)
		if nest.MotherAlive == false then
			-- Nid orphelin : personne ne viendra nourrir l'oeuf (GDD §8.2), on le dit tout de suite.
			notify(player, "Nid sans mère : personne ne vous nourrira, trouvez vite à manger !", "warning")
		else
			notify(player, "Vous êtes né(e) dans le nid de votre Maman !", "info")
		end
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
	Remotes.Get("RequestSpawnAsMother").OnServerEvent:Connect(onSpawnAsMother)

	-- Snapshot immédiat pour l'arrivant (sinon jusqu'à 10s de liste vide).
	Players.PlayerAdded:Connect(function(player)
		-- Reconnexion pendant le délai Maman : le compte à rebours reste visible.
		local last = lastMotherSpawn[player.UserId]
		local remaining = if last then MOTHER_SPAWN_COOLDOWN - (os.clock() - last) else 0
		if remaining > 0 then
			player:SetAttribute("MotherSpawnReadyAt", workspace:GetServerTimeNow() + remaining)
		end
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
			-- GetNestSummaries nettoie aussi les nids orphelins : appelé à chaque tour, envoyé seulement si changé.
			local summaries = GrowthAndNestService.GetNestSummaries()
			local signature = nestSignature(summaries)
			if signature ~= lastBroadcastSignature then
				lastBroadcastSignature = signature
				Remotes.Get("NestListChanged"):FireAllClients(summaries)
			end
			-- Délais Maman expirés : inutile de les garder (borne la table).
			local now = os.clock()
			for userId, last in pairs(lastMotherSpawn) do
				if now - last >= MOTHER_SPAWN_COOLDOWN then
					lastMotherSpawn[userId] = nil
				end
			end
		end
	end)
end

return SpawnMenuNetworkService
