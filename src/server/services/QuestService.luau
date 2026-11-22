--!strict
-- QuestService.luau
-- Défis enchaînés : chaque joueur a toujours 3 défis courts (manger, chasser, travailler,
-- ramasser, bâtir, survivre, monter de niveau), tirés selon le mode de vie de son espèce et
-- dimensionnés sur son niveau. Un défi réussi rapporte PE + XP (parfois DOUBLÉ), tous les 5 défis
-- un coffre bonus, et un nouveau défi le remplace aussitôt : il y a toujours un objectif proche.
--   * Progression : ProgressionService.ActionHook (branché au boot) + tick de survie.
--   * Client : attributs "Quests" (JSON [{T, P, G}]) et "QuestsDone" (QuestTrackerView).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local EvolutionTraits = require(ReplicatedStorage.shared.EvolutionTraits)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local QuestService = {}

local ACTIVE_COUNT = 3
local SURVIVAL_TICK = 5
local DOUBLE_CHANCE = 0.15
local CHEST_EVERY = 5
local MAIN_KIND_WEIGHT = 3

type QuestDef = { Kind: string, Text: string, Base: number, PerLevel: number, Points: number, NeedsNest: boolean? }
type Quest = { Def: QuestDef, Goal: number, Progress: number }

local DEFS: { QuestDef } = {
	{ Kind = "Manger", Text = "Mangez %d fois", Base = 4, PerLevel = 0.4, Points = 20 },
	{ Kind = "Chasse", Text = "Chassez %d proies", Base = 2, PerLevel = 0.25, Points = 35 },
	{ Kind = "Travail", Text = "Rapportez %d chargements au nid", Base = 3, PerLevel = 0.3, Points = 30, NeedsNest = true },
	{ Kind = "Ramasser", Text = "Ramassez %d matériaux", Base = 5, PerLevel = 0.5, Points = 20 },
	{ Kind = "Batir", Text = "Posez %d blocs ou pièces au nid", Base = 6, PerLevel = 0.6, Points = 25, NeedsNest = true },
	{ Kind = "Survie", Text = "Survivez %d minutes", Base = 3, PerLevel = 0.3, Points = 25 },
	{ Kind = "Niveau", Text = "Atteignez le niveau %d", Base = 2, PerLevel = 0, Points = 40 },
}

local states: { [Player]: { Quest } } = {}
local rng = Random.new()

local function goalText(quest: Quest): (string, number, number)
	if quest.Def.Kind == "Survie" then
		return string.format(quest.Def.Text, quest.Goal // 60), quest.Progress // 60, quest.Goal // 60
	end
	return string.format(quest.Def.Text, quest.Goal), math.min(quest.Progress, quest.Goal), quest.Goal
end

local function publish(player: Player)
	local list = {}
	for _, quest in ipairs(states[player] or {}) do
		local text, progress, goal = goalText(quest)
		table.insert(list, { T = text, P = progress, G = goal })
	end
	player:SetAttribute("Quests", HttpService:JSONEncode(list))
end

-- Tirage pondéré : l'activité principale de l'espèce sort 3x plus souvent ; pas deux fois le même type.
local function pick(player: Player, active: { Quest }): Quest?
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	local main = EvolutionTraits.MainXpSource(speciesId)
	local level = EvolutionDomain.GetLevel(player)
	local hasNest = player:GetAttribute("FamilyId") ~= nil
	local pool: { QuestDef } = {}
	local total = 0
	for _, def in ipairs(DEFS) do
		local taken = false
		for _, quest in ipairs(active) do
			taken = taken or quest.Def.Kind == def.Kind
		end
		if taken or (def.NeedsNest and not hasNest) or (def.Kind == "Niveau" and level >= EvolutionDomain.MAX_LEVEL) then
			continue
		end
		local weight = if def.Kind == main then MAIN_KIND_WEIGHT else 1
		for _ = 1, weight do
			table.insert(pool, def)
		end
		total += weight
	end
	if total == 0 then
		return nil
	end
	local def = pool[rng:NextInteger(1, total)]
	local goal = if def.Kind == "Niveau"
		then math.min(EvolutionDomain.MAX_LEVEL, level + def.Base)
		else math.max(1, math.floor(def.Base + def.PerLevel * (level - 1) + 0.5))
	if def.Kind == "Survie" then
		goal *= 60
	end
	return { Def = def, Goal = goal, Progress = if def.Kind == "Niveau" then level else 0 }
end

local function ensure(player: Player): { Quest }
	local active = states[player]
	if not active then
		active = {}
		states[player] = active
	end
	while #active < ACTIVE_COUNT do
		local quest = pick(player, active)
		if not quest then
			break
		end
		table.insert(active, quest)
	end
	return active
end

local function complete(player: Player, index: number)
	local active = states[player]
	local quest = active[index]
	table.remove(active, index)
	local level = EvolutionDomain.GetLevel(player)
	local double = rng:NextNumber() < DOUBLE_CHANCE
	local factor = if double then 2 else 1
	local points = math.floor(quest.Def.Points * (1 + 0.1 * (level - 1))) * factor
	local xpNext = (player:GetAttribute("XPNext") :: number?) or 0
	local xp = math.max(15, xpNext * 0.35) * factor
	local done = ((player:GetAttribute("QuestsDone") :: number?) or 0) + 1
	player:SetAttribute("QuestsDone", done)
	ProgressionService.AddEvolutionPoints(player, points)
	local source = EvolutionTraits.MainXpSource((player:GetAttribute("Species") :: string?) or "") or "Manger"
	-- Différé : un passage de niveau relance Record ("Niveau") pendant qu'on parcourt les défis.
	task.defer(ProgressionService.AddExperience, player, xp, source, true)
	local text = goalText(quest)
	Remotes.Get("NotifyClient"):FireClient(
		player,
		string.format("%s Défi réussi : %s  +%d PE, +%d XP", if double then "💥 DOUBLE !" else "🎯", text, points, math.floor(xp)),
		"info"
	)
	if done % CHEST_EVERY == 0 then
		local chest = points * 3
		ProgressionService.AddEvolutionPoints(player, chest)
		Remotes.Get("NotifyClient"):FireClient(player, string.format("🎁 COFFRE (%d défis) : +%d PE !", done, chest), "info")
	end
	ensure(player)
end

-- Progression d'un type d'action. "Niveau" : `amount` = niveau atteint (valeur absolue).
function QuestService.Record(player: Player, kind: string, amount: number)
	if player.Parent == nil or player:GetAttribute("HasConfirmedSpawn") ~= true then
		return
	end
	local active = ensure(player)
	local changed = false
	for i = #active, 1, -1 do
		local quest = active[i]
		if not quest or quest.Def.Kind ~= kind then
			continue
		end
		quest.Progress = if kind == "Niveau" then math.max(quest.Progress, amount) else quest.Progress + amount
		changed = true
		if quest.Progress >= quest.Goal then
			complete(player, i)
		end
	end
	if changed then
		publish(player)
	end
end

function QuestService.Start()
	-- Premier tirage dès le choix d'espèce (pour que le mode de vie pèse sur les défis).
	local function watch(player: Player)
		-- Nouvelle vie (retour au niveau 1) : un défi "Atteignez le niveau X" n'a plus de sens.
		player:GetAttributeChangedSignal("LifeStartedAt"):Connect(function()
			local active = states[player]
			if not active then
				return
			end
			for i = #active, 1, -1 do
				if active[i].Def.Kind == "Niveau" then
					table.remove(active, i)
				end
			end
			ensure(player)
			publish(player)
		end)
		player:GetAttributeChangedSignal("HasConfirmedSpawn"):Connect(function()
			if player:GetAttribute("HasConfirmedSpawn") == true and not states[player] then
				ensure(player)
				publish(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(SURVIVAL_TICK)
			for _, player in ipairs(Players:GetPlayers()) do
				local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					local ok, err = pcall(QuestService.Record, player, "Survie", SURVIVAL_TICK)
					if not ok then
						warn("[QuestService] survie : " .. tostring(err))
					end
				end
			end
		end
	end)
end

return QuestService
