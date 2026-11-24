--!strict
-- ProgressionService.luau
-- Points d'Évolution (PE), classement PvP (leaderstats) et Mutations rares / skins (GDD §2 étape 4,
-- §9 étape 4). Persisté via DataStore ; toute erreur DataStore est absorbée (Studio sans accès API,
-- quota...) : on joue alors sans sauvegarde plutôt que de bloquer le serveur.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local EvolutionTraits = require(ReplicatedStorage.shared.EvolutionTraits)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)

local ProgressionService = {}

type Profile = {
	EvolutionPoints: number,
	Kills: number,
	Deaths: number,
	Mutations: { [string]: boolean },
	ReachedAdult: boolean, -- a atteint l'âge adulte au moins une fois (débloque "Être une Maman")
	-- Récompense quotidienne : série de jours consécutifs (jour = os.time() // 86400, UTC).
	DailyStreak: number,
	LastDailyDay: number,
	-- Records de vie (à battre) : affichés sur l'écran de mort.
	BestLevel: number,
	BestLifeSeconds: number,
	BestLifeKills: number,
}

local DAILY_BASE_POINTS = 50 -- x jour de série (plafonné à 7)
local DAILY_STREAK_CAP = 7

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
	return {
		EvolutionPoints = 0, Kills = 0, Deaths = 0, Mutations = {}, ReachedAdult = false,
		DailyStreak = 0, LastDailyDay = 0, BestLevel = 0, BestLifeSeconds = 0, BestLifeKills = 0,
	}
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
	for _, field in ipairs({ "DailyStreak", "LastDailyDay", "BestLevel", "BestLifeSeconds", "BestLifeKills" }) do
		if typeof(data[field]) == "number" then
			(profile :: any)[field] = math.max(0, math.floor(data[field]))
		end
	end
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
					BestLevel = math.max(stored.BestLevel, profile.BestLevel),
					BestLifeSeconds = math.max(stored.BestLifeSeconds, profile.BestLifeSeconds),
					BestLifeKills = math.max(stored.BestLifeKills, profile.BestLifeKills),
					-- La série peut retomber à 1 : on garde la version du jour le plus récent.
					DailyStreak = if profile.LastDailyDay >= stored.LastDailyDay then profile.DailyStreak else stored.DailyStreak,
					LastDailyDay = math.max(stored.LastDailyDay, profile.LastDailyDay),
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

-- ============================================================
-- Expérience et niveaux (par vie) : chasser et manger font monter de niveau
-- ============================================================

-- XP nécessaire pour passer du niveau `level` au suivant : ~470 XP jusqu'au niveau 10 (plafond de
-- croissance >= COCON, voir EvolutionDomain.LARVA_TARGET_LEVEL), ~1750 XP jusqu'au niveau 20.
-- Rythme visé pour une larve tenue en laisse : ~25-30 XP/min de croissance passive (bien nourrie,
-- voir GROWING_XP_PER_SECOND) + bouchées (~2-8 XP) + défis (35 % d'un niveau) => niveau 10 en
-- ~11-13 min, puis cocon/mues jusqu'à l'âge adulte en ~1-2 min.
local function xpToNext(level: number): number
	return 20 + 8 * (level - 1)
end

-- Croissance "passive" d'un bébé éclos bien nourri (Faim et Soif >= 20) : la larve progresse même si
-- peu de nourriture pousse dans le rayon de sa laisse. XP de récompense (ne compte pas comme action).
-- Versée par paquets (l'attribut XP est entier et chaque gain affiche un "+N XP" côté client).
local GROWING_XP_TICK_SECONDS = 1
local GROWING_XP_PER_SECOND = 0.35
local GROWING_XP_GRANT = 5 -- ~1 paquet toutes les 15 s
local GROWING_MIN_STAT = 20
local growingXp: { [Player]: number } = {}

local function publishExperience(player: Player, level: number, xp: number)
	player:SetAttribute("Level", level)
	player:SetAttribute("XP", xp)
	player:SetAttribute("XPNext", if level >= EvolutionDomain.MAX_LEVEL then 0 else xpToNext(level))
end

-- Nombre d'ACTIONS par source pendant la vie (un kill = un dépôt = 1) : décide de la caste.
local xpBySource: { [Player]: { [string]: number } } = {}

-- `source` : chasse / manger / travail, pondéré par le mode de vie de l'espèce (EvolutionDomain)
-- et par les traits / la caste (EvolutionTraits).
-- `reward` = XP de récompense (défi...) : ne compte pas comme une action (caste, défis).
function ProgressionService.AddExperience(player: Player, amount: number, source: EvolutionDomain.XpSource, reward: boolean?)
	if amount <= 0 or player.Parent == nil then
		return
	end
	if not reward then
		local tally = xpBySource[player] or {}
		xpBySource[player] = tally
		tally[source] = (tally[source] or 0) + 1
		ProgressionService.ActionHook(player, source, 1)
	end
	amount *= EvolutionDomain.XpMultiplier((player:GetAttribute("Species") :: string?) or "", source)
	amount *= 1 + EvolutionTraits.Totals(player).Xp
	local level = EvolutionDomain.GetLevel(player)
	if level >= EvolutionDomain.MAX_LEVEL then
		return
	end
	local xp = ((player:GetAttribute("XP") :: number?) or 0) + amount
	local gained = 0
	while level < EvolutionDomain.MAX_LEVEL and xp >= xpToNext(level) do
		xp -= xpToNext(level)
		level += 1
		gained += 1
		-- Paliers de branche : un trait à choisir (EvolutionChoiceController côté client).
		if table.find(EvolutionTraits.BRANCH_LEVELS, level) then
			player:SetAttribute("PendingTraitChoices", ((player:GetAttribute("PendingTraitChoices") :: number?) or 0) + 1)
			Remotes.Get("NotifyClient"):FireClient(player, "🧬 Nouvelle évolution disponible : choisissez un trait !", "info")
		end
	end
	if level >= EvolutionDomain.MAX_LEVEL then
		xp = 0
	end
	publishExperience(player, level, math.floor(xp))
	if gained > 0 then
		ProgressionService.ActionHook(player, "Niveau", level)
		EvolutionDomain.ApplyLevel(player)
		Remotes.Get("NotifyClient"):FireClient(
			player,
			if level >= EvolutionDomain.MAX_LEVEL
				then string.format("⭐ Niveau %d (max) ! Vous êtes au sommet de votre espèce.", level)
				else string.format("⭐ Niveau %d ! Plus grand, plus fort, plus rapide.", level),
			"info"
		)
	end
end

-- Nouvelle vie : retour au niveau 1.
-- Fin de vie : bilan + records battus (attribut "LastLife", JSON lu par l'écran de mort).
local function closeLife(player: Player)
	local startedAt = player:GetAttribute("LifeStartedAt")
	local profile = profiles[player]
	if type(startedAt) ~= "number" or not profile then
		return
	end
	local summary = {
		Level = EvolutionDomain.GetLevel(player),
		Seconds = math.floor(os.time() - startedAt),
		Kills = (xpBySource[player] or {}).Chasse or 0,
		Records = {} :: { string },
		BestLevel = 0,
		BestSeconds = 0,
		BestKills = 0,
	}
	local function beat(field: string, value: number, label: string)
		if value > (profile :: any)[field] then
			if (profile :: any)[field] > 0 then
				table.insert(summary.Records, label)
			end
			(profile :: any)[field] = value
		end
	end
	beat("BestLevel", summary.Level, "Niveau")
	beat("BestLifeSeconds", summary.Seconds, "Survie")
	beat("BestLifeKills", summary.Kills, "Chasse")
	summary.BestLevel, summary.BestSeconds, summary.BestKills = profile.BestLevel, profile.BestLifeSeconds, profile.BestLifeKills
	player:SetAttribute("LastLife", HttpService:JSONEncode(summary))
end

-- Remplacé au démarrage (QuestService) : action de jeu ("Chasse"/"Manger"/"Travail"/"Niveau"...).
function ProgressionService.ActionHook(_player: Player, _kind: string, _amount: number) end

-- Récompense quotidienne : série de jours consécutifs, plafonnée à 7 jours.
local function claimDaily(player: Player, profile: Profile)
	local today = os.time() // 86400
	if profile.LastDailyDay >= today then
		player:SetAttribute("DailyStreak", profile.DailyStreak)
		return
	end
	profile.DailyStreak = if profile.LastDailyDay == today - 1 then profile.DailyStreak + 1 else 1
	profile.LastDailyDay = today
	local points = DAILY_BASE_POINTS * math.min(profile.DailyStreak, DAILY_STREAK_CAP)
	ProgressionService.AddEvolutionPoints(player, points)
	player:SetAttribute("DailyStreak", profile.DailyStreak)
	Remotes.Get("NotifyClient"):FireClient(
		player,
		string.format("🔥 Série de %d jour(s) ! +%d PE. Revenez demain pour plus%s", profile.DailyStreak, points,
			if profile.DailyStreak < DAILY_STREAK_CAP then string.format(" (+%d PE)", DAILY_BASE_POINTS * (profile.DailyStreak + 1)) else " !"),
		"info"
	)
end

function ProgressionService.ResetExperience(player: Player)
	closeLife(player)
	publishExperience(player, 1, 0)
	player:SetAttribute("LifeStartedAt", os.time()) -- après le niveau 1 : QuestService retire alors ses défis de niveau
	player:SetAttribute("GrowthBlocked", nil)
	-- Branches et caste sont propres à une vie.
	for id in pairs(EvolutionTraits.All()) do
		player:SetAttribute("Trait_" .. id, nil)
	end
	player:SetAttribute("PendingTraitChoices", nil)
	player:SetAttribute("Caste", nil)
	player:SetAttribute("RoyalJelly", nil)
	xpBySource[player] = nil
	EvolutionDomain.ApplyLevel(player)
end

-- Choix d'un trait de branche : validé (choix en attente, trait de SA branche).
local function onEvolutionChoice(player: Player, traitId: unknown)
	local pending = (player:GetAttribute("PendingTraitChoices") :: number?) or 0
	if type(traitId) ~= "string" or pending <= 0 then
		return
	end
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	local chosen: EvolutionTraits.Trait? = nil
	for _, t in ipairs(EvolutionTraits.BranchFor(speciesId)) do
		if t.Id == traitId then
			chosen = t
		end
	end
	if not chosen then
		return
	end
	local key = "Trait_" .. chosen.Id
	player:SetAttribute(key, ((player:GetAttribute(key) :: number?) or 0) + 1)
	player:SetAttribute("PendingTraitChoices", if pending > 1 then pending - 1 else nil)
	EvolutionDomain.ApplyLevel(player)
	Remotes.Get("NotifyClient"):FireClient(player, string.format("%s Évolution : %s (%s)", chosen.Icon, chosen.Name, chosen.Description), "info")
end

-- Caste d'un insecte social, décidée par sa vie de larve (gelée royale) et ce qu'il a fait.
local function assignCaste(player: Player)
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	if not EvolutionTraits.IsSocial(speciesId) or player:GetAttribute("Caste") ~= nil then
		return
	end
	local tally = xpBySource[player] or {}
	-- Gelée royale : larve bien nourrie au nid, et une seule héritière Reine vivante par colonie.
	local familyId = player:GetAttribute("FamilyId")
	local heirExists = false
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other:GetAttribute("FamilyId") == familyId and other:GetAttribute("Caste") == "Reine" and other:GetAttribute("IsMother") ~= true then
			heirExists = true
		end
	end
	local royal = not heirExists and ((player:GetAttribute("RoyalJelly") :: number?) or 0) >= EvolutionTraits.ROYAL_JELLY_FEEDINGS
	-- Sans colonie, on est une fondatrice solitaire (sinon personne ne pourrait jamais fonder).
	local caste = if royal or familyId == nil then "Reine"
		elseif (tally.Chasse or 0) > (tally.Travail or 0) then "Soldat"
		else "Ouvriere"
	player:SetAttribute("Caste", caste)
	EvolutionDomain.ApplyLevel(player)
	local info = EvolutionTraits.CASTES[caste]
	Remotes.Get("NotifyClient"):FireClient(player, string.format("%s Vous êtes devenu %s ! %s", info.Icon, info.Name, info.Description), "info")
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
	ProgressionService.AddExperience(attacker, if victimIsGiant then 250 else 60, "Chasse")
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
	publishExperience(player, 1, 0)
	player:SetAttribute("LifeStartedAt", os.time()) -- 1re vie : sinon aucun bilan à la 1re mort
	createLeaderstats(player)
	local profile = loadProfile(player)
	if not player.Parent then
		return -- parti pendant le chargement
	end
	profiles[player] = profile
	refreshLeaderstats(player)
	task.delay(6, function() -- après l'écran de chargement, pour qu'on voie la récompense
		if profiles[player] == profile then
			claimDaily(player, profile)
		end
	end)
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
	Remotes.Get("RequestEvolutionChoice").OnServerEvent:Connect(onEvolutionChoice)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		saveProfile(player)
		profiles[player] = nil
		loadFailed[player] = nil
		xpBySource[player] = nil
		growingXp[player] = nil
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
			task.wait(GROWING_XP_TICK_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				local stage = player:GetAttribute("Stage")
				local hunger = (player:GetAttribute("Hunger") :: number?) or 0
				local thirst = (player:GetAttribute("Thirst") :: number?) or 0
				if (stage == "Larve" or stage == "Mue") and player:GetAttribute("HasConfirmedSpawn") == true
					and hunger >= GROWING_MIN_STAT and thirst >= GROWING_MIN_STAT then
					local pending = (growingXp[player] or 0) + GROWING_XP_PER_SECOND * GROWING_XP_TICK_SECONDS
					if pending >= GROWING_XP_GRANT then
						pending = 0
						local source = EvolutionDomain.MainXpSource((player:GetAttribute("Species") :: string?) or "") or "Manger"
						local ok, err = pcall(ProgressionService.AddExperience, player, GROWING_XP_GRANT, source, true)
						if not ok then
							warn("[ProgressionService] XP de croissance de " .. player.Name .. " : " .. tostring(err))
						end
					end
					growingXp[player] = pending
				end
			end
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
			assignCaste(player)
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
