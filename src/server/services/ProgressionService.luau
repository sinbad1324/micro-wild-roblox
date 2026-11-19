--!strict
-- ProgressionService.luau
-- Points d'Évolution (PE), classement PvP (leaderstats) et Mutations rares / skins (GDD §2 étape 4,
-- §9 étape 4). Persisté via DataStore ; toute erreur DataStore est absorbée (Studio sans accès API,
-- quota...) : on joue alors sans sauvegarde plutôt que de bloquer le serveur.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local ProgressionService = {}

type Profile = {
	EvolutionPoints: number,
	Kills: number,
	Deaths: number,
	Mutations: { [string]: boolean },
	ReachedAdult: boolean, -- a atteint l'âge adulte au moins une fois (débloque "Être une Maman")
}

local STORE_NAME = "MicroWild_Profile_v1"
-- Déblocage du spawn "Être une Maman" : adulte une fois OU ce nombre de PE.
local MOTHER_SPAWN_MIN_POINTS = 500
local AUTOSAVE_SECONDS = 120
local STAGE_POINTS = 20
local MOTHER_POINTS_PER_CHILD_STAGE = 15

local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
-- Vrai si le chargement a échoué : on ne sauvegarde JAMAIS par-dessus des données qu'on n'a pas lues.
local loadFailed: { [Player]: boolean } = {}

local function newProfile(): Profile
	return { EvolutionPoints = 0, Kills = 0, Deaths = 0, Mutations = {}, ReachedAdult = false }
end

local function sanitize(raw: unknown): Profile
	local profile = newProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	local data = raw :: { [string]: any }
	if typeof(data.EvolutionPoints) == "number" then
		profile.EvolutionPoints = math.max(0, math.floor(data.EvolutionPoints))
	end
	if typeof(data.Kills) == "number" then
		profile.Kills = math.max(0, math.floor(data.Kills))
	end
	if typeof(data.Deaths) == "number" then
		profile.Deaths = math.max(0, math.floor(data.Deaths))
	end
	profile.ReachedAdult = data.ReachedAdult == true
	if typeof(data.Mutations) == "table" then
		for id, unlocked in pairs(data.Mutations :: { [any]: any }) do
			if typeof(id) == "string" and unlocked == true and InsectBodyPlans.Mutations[id] then
				profile.Mutations[id] = true
			end
		end
	end
	return profile
end

local function keyFor(player: Player): string
	return "u_" .. tostring(player.UserId)
end

local function loadProfile(player: Player): Profile
	if not store then
		return newProfile()
	end
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return (store :: DataStore):GetAsync(keyFor(player))
		end)
		if ok then
			return sanitize(result)
		end
		if attempt < 3 then
			task.wait(attempt)
		end
	end
	if player.Parent then
		loadFailed[player] = true
	end
	warn("[ProgressionService] Chargement du profil impossible pour " .. player.Name .. " : pas de sauvegarde cette session.")
	return newProfile()
end

local function saveProfile(player: Player)
	local profile = profiles[player]
	if not store or not profile or loadFailed[player] then
		return
	end
	for attempt = 1, 3 do
		-- UpdateAsync + fusion : tous les compteurs ne font que croître, donc on garde le max de
		-- chaque champ et l'union des mutations. Un serveur qui a lu une version périmée (joueur
		-- passé vite d'un serveur à l'autre) ne peut pas effacer la progression de l'autre.
		local ok = pcall(function()
			(store :: DataStore):UpdateAsync(keyFor(player), function(old: unknown)
				local stored = sanitize(old)
				local merged: { [string]: any } = {
					Version = 1,
					EvolutionPoints = math.max(stored.EvolutionPoints, profile.EvolutionPoints),
					Kills = math.max(stored.Kills, profile.Kills),
					Deaths = math.max(stored.Deaths, profile.Deaths),
					Mutations = table.clone(stored.Mutations),
					ReachedAdult = stored.ReachedAdult or profile.ReachedAdult, -- OU : ne se perd jamais
				}
				for id in pairs(profile.Mutations) do
					merged.Mutations[id] = true
				end
				return merged
			end)
		end)
		if ok then
			return
		end
		if attempt < 3 then
			task.wait(attempt)
		end
	end
	warn("[ProgressionService] Sauvegarde échouée pour " .. player.Name)
end

local function refreshLeaderstats(player: Player)
	local profile = profiles[player]
	local leaderstats = player:FindFirstChild("leaderstats")
	if not profile or not leaderstats then
		return
	end
	local kills = leaderstats:FindFirstChild("Kills") :: IntValue?
	local points = leaderstats:FindFirstChild("PE") :: IntValue?
	if kills then
		kills.Value = profile.Kills
	end
	if points then
		points.Value = profile.EvolutionPoints
	end
	player:SetAttribute("EvolutionPoints", profile.EvolutionPoints)
	player:SetAttribute("Kills", profile.Kills)
	-- Lu par le menu de spawn (option "Être une Maman" verrouillée/déverrouillée).
	player:SetAttribute("MotherSpawnUnlocked", profile.ReachedAdult or profile.EvolutionPoints >= MOTHER_SPAWN_MIN_POINTS)
	player:SetAttribute("MotherSpawnMinPoints", MOTHER_SPAWN_MIN_POINTS)
end

local function createLeaderstats(player: Player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Parent = leaderstats

	local points = Instance.new("IntValue")
	points.Name = "PE"
	points.Parent = leaderstats

	local stage = Instance.new("StringValue")
	stage.Name = "Stade"
	stage.Value = (player:GetAttribute("Stage") :: string?) or "Oeuf"
	stage.Parent = leaderstats
	player:GetAttributeChangedSignal("Stage"):Connect(function()
		stage.Value = (player:GetAttribute("Stage") :: string?) or "Oeuf"
	end)

	leaderstats.Parent = player
end

function ProgressionService.AddEvolutionPoints(player: Player, amount: number)
	local profile = profiles[player]
	if not profile or amount <= 0 then
		return
	end
	profile.EvolutionPoints += math.floor(amount)
	refreshLeaderstats(player)
end

function ProgressionService.RecordKill(attackerUserId: number?, victimName: string, victimIsGiant: boolean)
	if not attackerUserId then
		return
	end
	local attacker = Players:GetPlayerByUserId(attackerUserId)
	local profile = if attacker then profiles[attacker] else nil
	if not attacker or not profile then
		return
	end
	profile.Kills += 1
	ProgressionService.AddEvolutionPoints(attacker, if victimIsGiant then 400 else 40)
	Remotes.Get("NotifyClient"):FireClient(attacker, "Vous avez tué " .. victimName .. " !", "info")
end

-- Validation serveur du spawn "Être une Maman" : (autorisé, raison du refus).
function ProgressionService.CanSpawnAsMother(player: Player): (boolean, string?)
	local profile = profiles[player]
	if not profile then
		return false, "Profil en cours de chargement, réessayez."
	end
	if profile.ReachedAdult or profile.EvolutionPoints >= MOTHER_SPAWN_MIN_POINTS then
		return true, nil
	end
	return false, string.format("Devenez adulte une fois ou atteignez %d PE pour naître Maman.", MOTHER_SPAWN_MIN_POINTS)
end

function ProgressionService.RecordDeath(player: Player)
	local profile = profiles[player]
	if profile then
		profile.Deaths += 1
	end
end

-- Tirée à chaque naissance (choix d'espèce). Une mutation obtenue est débloquée pour toujours
-- (sauvegardée) mais ne s'applique qu'à la vie en cours ; une nouvelle vie retire au sort.
function ProgressionService.RollMutation(player: Player): string?
	local roll = math.random()
	local cumulative = 0
	local chosen: string? = nil
	for _, id in ipairs(InsectBodyPlans.MutationOrder) do
		cumulative += InsectBodyPlans.Mutations[id].Chance
		if roll <= cumulative then
			chosen = id
			break
		end
	end
	player:SetAttribute("Mutation", chosen)
	local profile = profiles[player]
	if chosen and profile then
		local isNew = not profile.Mutations[chosen]
		profile.Mutations[chosen] = true
		local mutationName = InsectBodyPlans.Mutations[chosen].Name
		Remotes.Get("NotifyClient"):FireClient(
			player,
			string.format("MUTATION RARE : %s !%s", mutationName, if isNew then " (nouvelle)" else ""),
			"info"
		)
	end
	return chosen
end

-- Remplacé au démarrage pour reconstruire le corps 3D avec la mutation (évite un require).
function ProgressionService.MutationRolledHook(_player: Player) end

function ProgressionService.GetUnlockedMutationCount(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	local count = 0
	for _ in pairs(profile.Mutations) do
		count += 1
	end
	return count
end

local function onPlayerAdded(player: Player)
	createLeaderstats(player)
	local profile = loadProfile(player)
	if not player.Parent then
		return -- parti pendant le chargement
	end
	profiles[player] = profile
	refreshLeaderstats(player)
end

function ProgressionService.Start()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[ProgressionService] DataStore indisponible (accès API désactivé ?) : progression non sauvegardée.")
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		saveProfile(player)
		profiles[player] = nil
		loadFailed[player] = nil
	end)

	game:BindToClose(function()
		local pending = 0
		for player in pairs(profiles) do
			pending += 1
			task.spawn(function()
				saveProfile(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.2)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for player in pairs(profiles) do
				task.spawn(saveProfile, player)
			end
		end
	end)

	-- Chaque nouveau stade rapporte des PE ; la Maman gagne aussi des PE quand ses enfants grandissent.
	GrowthAndNestService.StageChanged.Event:Connect(function(player: Player, newStage: string)
		-- Pas de PE pour l'éclosion (20 s après la naissance) : sinon reset = farm.
		if newStage ~= "Larve" then
			ProgressionService.AddEvolutionPoints(player, STAGE_POINTS)
		end
		-- La mutation rare se tire à l'âge adulte : il faut survivre pour la débloquer.
		if newStage == "Adulte" then
			local profile = profiles[player]
			if profile and not profile.ReachedAdult then
				profile.ReachedAdult = true
				refreshLeaderstats(player)
			end
			ProgressionService.RollMutation(player)
			local character = player.Character
			if player:GetAttribute("Mutation") ~= nil and character then
				ProgressionService.MutationRolledHook(player)
			end
		end
		local motherUserId = player:GetAttribute("OwnerNestUserId") :: number?
		local mother = if motherUserId then Players:GetPlayerByUserId(motherUserId) else nil
		-- Pas de prime à la Maman pour l'éclosion non plus : sinon rejoindre/mourir en boucle = farm.
		if mother and newStage ~= "Larve" then
			ProgressionService.AddEvolutionPoints(mother, MOTHER_POINTS_PER_CHILD_STAGE)
		end
	end)
end

return ProgressionService
