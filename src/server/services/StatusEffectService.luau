--!strict
-- StatusEffectService.luau
-- Statuts temporaires (AbilityCatalog.StatusEffectName) sur un personnage joueur OU un animal :
--   Poison / Bleed / Toxic : dégâts sur la durée (via DamageService, armure ignorée)
--   Slow / Glue            : ralentissement (MovementService pour les joueurs, attribut pour l'IA)
--   Stun                   : immobilisé
--   Blind / InvertControls / MindControl : effets côté client (attributs "Status_X" répliqués)
-- Chaque statut actif est exposé en attribut "Status_<Nom>" = true sur le Model : le client
-- (StatusEffectController) et l'IA des animaux le lisent sans remote supplémentaire.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MovementService = require(ServerScriptService.services.MovementService)
local DamageService = require(ServerScriptService.services.DamageService)
local Remotes = require(ReplicatedStorage.shared.Remotes)

local StatusEffectService = {}

type ActiveStatus = {
	ExpiresAt: number,
	Magnitude: number,
	AttackerUserId: number?,
}

local TICK_SECONDS = 0.5
local DOT_PER_SECOND_PER_MAGNITUDE = 6

local active: { [Model]: { [string]: ActiveStatus } } = {}

local function modifierKey(status: string): string
	return "Status_" .. status
end

function StatusEffectService.Apply(character: Model, status: string, duration: number, magnitude: number?, attackerUserId: number?)
	if duration <= 0 then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local resolvedMagnitude = magnitude or 1
	local statuses = active[character]
	if not statuses then
		statuses = {}
		active[character] = statuses
	end

	local expiresAt = os.clock() + duration
	local existing = statuses[status]
	if existing then
		-- Fusion : garde le plus long ET le plus fort (un poison court ne raccourcit pas un long).
		expiresAt = math.max(existing.ExpiresAt, expiresAt)
		resolvedMagnitude = math.max(existing.Magnitude, resolvedMagnitude)
		duration = expiresAt - os.clock()
	end
	statuses[status] = { ExpiresAt = expiresAt, Magnitude = resolvedMagnitude, AttackerUserId = attackerUserId or (existing and existing.AttackerUserId) }
	character:SetAttribute(modifierKey(status), true)
	-- Aura visuelle (bulles de poison, fils de glu, étoiles d'étourdissement) rendue par les clients.
	Remotes.Get("CombatFx"):FireAllClients("Status", character, status, duration)

	local player = Players:GetPlayerFromCharacter(character)
	if status == "Slow" or status == "Glue" then
		if player then
			MovementService.AddModifier(player, modifierKey(status), "Multiplier", math.clamp(1 - resolvedMagnitude, 0.05, 1), duration)
		end
	elseif status == "Stun" then
		if player then
			MovementService.AddModifier(player, modifierKey(status), "Override", 0, duration)
		end
	end
end

function StatusEffectService.Has(character: Model, status: string): boolean
	local statuses = active[character]
	local entry = statuses and statuses[status]
	return entry ~= nil and entry.ExpiresAt > os.clock()
end

-- Facteur de vitesse à appliquer par l'IA des animaux (1 = normal, 0 = immobile).
function StatusEffectService.GetSpeedFactor(character: Model): number
	local statuses = active[character]
	if not statuses then
		return 1
	end
	local now = os.clock()
	local factor = 1
	for name, entry in pairs(statuses) do
		if entry.ExpiresAt > now then
			if name == "Stun" then
				return 0
			elseif name == "Slow" or name == "Glue" then
				factor *= math.clamp(1 - entry.Magnitude, 0.05, 1)
			end
		end
	end
	return factor
end

local function removeStatus(character: Model, status: string)
	local statuses = active[character]
	if statuses then
		statuses[status] = nil
	end
	character:SetAttribute(modifierKey(status), nil)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		MovementService.RemoveModifier(player, modifierKey(status))
	end
end

function StatusEffectService.Clear(character: Model, status: string?)
	local statuses = active[character]
	if not statuses then
		return
	end
	if status then
		removeStatus(character, status)
		return
	end
	for name in pairs(statuses) do
		removeStatus(character, name)
	end
	active[character] = nil
end

local function tick()
	local now = os.clock()
	for character, statuses in pairs(active) do
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not character.Parent or not humanoid or humanoid.Health <= 0 then
			active[character] = nil
			continue
		end
		for name, entry in pairs(statuses) do
			if entry.ExpiresAt <= now then
				removeStatus(character, name)
			elseif name == "Poison" or name == "Bleed" or name == "Toxic" then
				DamageService.ApplyDamage(character, entry.Magnitude * DOT_PER_SECOND_PER_MAGNITUDE * TICK_SECONDS, {
					AttackerUserId = entry.AttackerUserId,
					IgnoreArmor = true,
					IsDamageOverTime = true,
				})
			end
		end
		if next(statuses) == nil then
			active[character] = nil
		end
	end
end

function StatusEffectService.Start()
	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)
			-- Une erreur ne doit jamais figer les statuts (aveuglé / glué pour toujours).
			local ok, err = pcall(tick)
			if not ok then
				warn("[StatusEffectService] " .. tostring(err))
			end
		end
	end)
end

return StatusEffectService
