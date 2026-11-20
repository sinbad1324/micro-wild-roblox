--!strict
-- MovementService.luau
-- Propriétaire UNIQUE de Humanoid.WalkSpeed/JumpPower pour les joueurs.
-- Toute autre partie du serveur (survie, croissance, habiletés, combat) qui veut ralentir,
-- accélérer ou immobiliser un joueur doit passer par AddModifier/RemoveModifier ici plutôt que
-- d'écrire directement sur le Humanoid, sinon les effets s'écrasent entre eux (ex: la toile de
-- la Veuve Noire effacée par le prochain tick de SurvivalService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.shared.Remotes)

export type ModifierKind = "Multiplier" | "Override"

type Modifier = {
	Kind: ModifierKind,
	Value: number,
	ExpiresAt: number?,
}

local MovementService = {}

local baseWalkSpeed: { [Player]: number } = {}
local baseJumpPower: { [Player]: number } = {}
local speedModifiers: { [Player]: { [string]: Modifier } } = {}

-- Lissage de WalkSpeed : les changements de vitesse glissent vers la cible au lieu de sauter
-- (fin d'hypothermie, ruée qui retombe...). Le serveur reste seul maître de la valeur.
local EASE_RATE = 10 -- 1/s : ~0,5 s pour rejoindre la cible
local targetWalkSpeed: { [Player]: number } = {}
local easedHumanoid: { [Player]: Humanoid } = {}
local easing: { [Player]: boolean } = {}

-- Boost de vitesse (Shift maintenu) : multiplicateur de WalkSpeed, donc aussi le vol et la nage
-- (Flight/SwimController dérivent leur vitesse de WalkSpeed). Jauge d'énergie qui se vide pendant
-- qu'on bouge en boost et se recharge sinon ; répliquée en attribut "BoostEnergy" (0..1) pour le HUD.
local BOOST_KEY = "Boost"
local BOOST_MULTIPLIER = 1.6
local BOOST_DRAIN = 1 / 3.5 -- jauge pleine = 3,5 s de boost
local BOOST_REGEN = 1 / 7 -- recharge complète en 7 s
local BOOST_RESTART = 0.25 -- vidée : il faut recharger un quart avant de re-booster
local boostWanted: { [Player]: boolean } = {}
local boostEnergy: { [Player]: number } = {}
local boostExhausted: { [Player]: boolean } = {}

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

function MovementService.SetBaseWalkSpeed(player: Player, speed: number)
	baseWalkSpeed[player] = speed
	MovementService.Recompute(player)
end

function MovementService.SetBaseJumpPower(player: Player, jumpPower: number)
	baseJumpPower[player] = jumpPower
	local humanoid = getHumanoid(player)
	if humanoid then
		-- Les places récentes utilisent JumpHeight par défaut : sans ça JumpPower est ignoré et un
		-- Oeuf/Cocon (JumpPower 0) pourrait encore sauter.
		humanoid.UseJumpPower = true
		humanoid.JumpPower = jumpPower
	end
end

-- key doit être stable et unique par effet (ex: "Hypothermia", "ToileAraignee", "CanonAGlu").
function MovementService.AddModifier(player: Player, key: string, kind: ModifierKind, value: number, durationSeconds: number?)
	local playerModifiers = speedModifiers[player]
	if not playerModifiers then
		playerModifiers = {}
		speedModifiers[player] = playerModifiers
	end
	playerModifiers[key] = {
		Kind = kind,
		Value = value,
		ExpiresAt = if durationSeconds then os.clock() + durationSeconds else nil,
	}
	MovementService.Recompute(player)
end

function MovementService.RemoveModifier(player: Player, key: string)
	local playerModifiers = speedModifiers[player]
	if playerModifiers and playerModifiers[key] ~= nil then
		playerModifiers[key] = nil
		MovementService.Recompute(player)
	end
end

function MovementService.HasModifier(player: Player, key: string): boolean
	local playerModifiers = speedModifiers[player]
	return playerModifiers ~= nil and playerModifiers[key] ~= nil
end

function MovementService.Recompute(player: Player)
	local humanoid = getHumanoid(player)
	if not humanoid then
		return
	end

	local base = baseWalkSpeed[player] or 16
	local speed = base
	local overrideValue: number? = nil

	local playerModifiers = speedModifiers[player]
	if playerModifiers then
		local now = os.clock()
		for key, modifier in pairs(playerModifiers) do
			if modifier.ExpiresAt ~= nil and modifier.ExpiresAt <= now then
				playerModifiers[key] = nil
				continue
			end
			if modifier.Kind == "Override" then
				overrideValue = if overrideValue then math.min(overrideValue, modifier.Value) else modifier.Value
			else
				speed *= modifier.Value
			end
		end
	end

	local target = if overrideValue ~= nil then overrideValue else math.max(0, speed)
	targetWalkSpeed[player] = target
	-- Immobilisations (toile, oeuf, cocon) et nouveau corps : instantané. Le reste glisse.
	if overrideValue ~= nil or target <= 0 or easedHumanoid[player] ~= humanoid then
		easedHumanoid[player] = humanoid
		easing[player] = nil
		humanoid.WalkSpeed = target
	elseif math.abs(humanoid.WalkSpeed - target) > 0.05 then
		easing[player] = true
	end
end

function MovementService.CleanupPlayer(player: Player)
	baseWalkSpeed[player] = nil
	baseJumpPower[player] = nil
	speedModifiers[player] = nil
	targetWalkSpeed[player] = nil
	easedHumanoid[player] = nil
	easing[player] = nil
	boostWanted[player] = nil
	boostEnergy[player] = nil
	boostExhausted[player] = nil
end

local function setBoost(player: Player, active: boolean)
	if active ~= MovementService.HasModifier(player, BOOST_KEY) then
		if active then
			MovementService.AddModifier(player, BOOST_KEY, "Multiplier", BOOST_MULTIPLIER)
		else
			MovementService.RemoveModifier(player, BOOST_KEY)
		end
	end
end

local function canBoost(player: Player): boolean
	return boostWanted[player] == true and not boostExhausted[player] and (boostEnergy[player] or 1) > 0
end

-- Jauge : vidée seulement en bougeant (Shift maintenu à l'arrêt ne coûte rien).
local function tickBoost(player: Player, dt: number)
	local energy = boostEnergy[player] or 1
	local humanoid = getHumanoid(player)
	local moving = humanoid ~= nil and humanoid.MoveDirection.Magnitude > 0.1
	if MovementService.HasModifier(player, BOOST_KEY) and moving then
		energy = math.max(0, energy - BOOST_DRAIN * dt)
		if energy <= 0 then
			boostExhausted[player] = true
		end
	else
		energy = math.min(1, energy + BOOST_REGEN * dt)
		if boostExhausted[player] and energy >= BOOST_RESTART then
			boostExhausted[player] = nil
		end
	end
	boostEnergy[player] = energy
	setBoost(player, canBoost(player))
	-- Réplication économe : seulement les pas de 2 %.
	local shown = player:GetAttribute("BoostEnergy")
	if type(shown) ~= "number" or math.abs(shown - energy) >= 0.02 or (energy >= 1 and shown < 1) then
		player:SetAttribute("BoostEnergy", energy)
	end
end

-- Balaye les modificateurs expirés même si rien d'autre n'appelle Recompute entre-temps
-- (ex: un effet avec une durée qui se termine pendant que le joueur est immobile).
function MovementService.Start()
	Players.PlayerRemoving:Connect(MovementService.CleanupPlayer)

	Remotes.Get("RequestBoost").OnServerEvent:Connect(function(player: Player, active: unknown)
		if type(active) ~= "boolean" then
			return
		end
		boostWanted[player] = active
		setBoost(player, canBoost(player))
	end)
	-- Nouveau corps : le boost repart éteint (le client renvoie l'appui s'il maintient encore Shift).
	local function watchCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			boostWanted[player] = nil
			setBoost(player, false)
		end)
	end
	Players.PlayerAdded:Connect(watchCharacter)
	for _, player in ipairs(Players:GetPlayers()) do
		watchCharacter(player)
	end

	-- Ne tourne que pour les joueurs en transition (quelques frames par changement de vitesse).
	-- 10 Hz au lieu de 60 : chaque écriture de WalkSpeed est répliquée, des paliers de 0,1 s sont invisibles.
	local easeAccum = 0
	RunService.Heartbeat:Connect(function(frameDt: number)
		easeAccum += frameDt
		if easeAccum < 0.1 then
			return
		end
		local dt = easeAccum
		easeAccum = 0
		for player in pairs(boostWanted) do
			tickBoost(player, dt)
		end
		local alpha = 1 - math.exp(-EASE_RATE * dt)
		for player in pairs(easing) do
			local humanoid = easedHumanoid[player]
			local target = targetWalkSpeed[player]
			if not humanoid or not target or not humanoid.Parent then
				easing[player] = nil
				continue
			end
			local current = humanoid.WalkSpeed
			if math.abs(target - current) <= 0.05 then
				humanoid.WalkSpeed = target
				easing[player] = nil
			else
				humanoid.WalkSpeed = current + (target - current) * alpha
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			for player in pairs(speedModifiers) do
				if player.Parent then
					MovementService.Recompute(player)
				end
			end
		end
	end)
end

return MovementService
