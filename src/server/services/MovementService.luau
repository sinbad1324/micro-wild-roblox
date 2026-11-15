--!strict
-- MovementService.luau
-- Propriétaire UNIQUE de Humanoid.WalkSpeed/JumpPower pour les joueurs.
-- Toute autre partie du serveur (survie, croissance, habiletés, combat) qui veut ralentir,
-- accélérer ou immobiliser un joueur doit passer par AddModifier/RemoveModifier ici plutôt que
-- d'écrire directement sur le Humanoid, sinon les effets s'écrasent entre eux (ex: la toile de
-- la Veuve Noire effacée par le prochain tick de SurvivalService).

local Players = game:GetService("Players")

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

	humanoid.WalkSpeed = if overrideValue ~= nil then overrideValue else math.max(0, speed)
end

function MovementService.CleanupPlayer(player: Player)
	baseWalkSpeed[player] = nil
	baseJumpPower[player] = nil
	speedModifiers[player] = nil
end

-- Balaye les modificateurs expirés même si rien d'autre n'appelle Recompute entre-temps
-- (ex: un effet avec une durée qui se termine pendant que le joueur est immobile).
function MovementService.Start()
	Players.PlayerRemoving:Connect(MovementService.CleanupPlayer)

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
