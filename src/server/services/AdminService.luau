--!strict
-- AdminService.luau
-- Commandes de test réservées aux admins : grandir d'un coup, passer adulte, remplir les stats.
-- Admin = le créateur du jeu (game.CreatorId), les UserId de GameConstants.ADMIN_USER_IDS, ou
-- n'importe qui dans Roblox Studio. Vérifié CÔTÉ SERVEUR à chaque commande : le panneau client
-- (AdminPanelView) n'est qu'une commodité, un exploit qui envoie le remote n'obtient rien.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)

local AdminService = {}

local COMMAND_COOLDOWN = 0.25
local lastCommand: { [Player]: number } = {}

local function isAdmin(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return table.find(GameConstants.ADMIN_USER_IDS, player.UserId) ~= nil
end

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

-- Même chemin que la croissance normale (GrowthAndNestService) : stade, stats, corps 3D, PE,
-- mutation et déblocage "Être une Maman" passent tous par SetStage + StageChanged.
local function grow(player: Player, amount: number)
	if player:GetAttribute("HasConfirmedSpawn") ~= true then
		notify(player, "[Admin] Choisis d'abord une espèce dans le menu.", "warning")
		return
	end
	local speciesId = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	local previousStage = (player:GetAttribute("Stage") :: string?) or "Oeuf"
	local growth = (player:GetAttribute("Growth") :: number?) or 0
	growth = math.clamp(growth + amount, 0, GameConstants.STAGE_THRESHOLDS.MAX_GROWTH)
	player:SetAttribute("IsMolting", false) -- une mue en cours ne doit pas bloquer le saut de stade
	player:SetAttribute("Growth", growth)

	local newStage = EvolutionDomain.GetStageForGrowth(speciesId, growth)
	if newStage == "Adulte" then
		player:SetAttribute("CanLeaveNest", true)
	end
	if newStage ~= previousStage then
		task.spawn(EvolutionDomain.SetStage, player, speciesId, newStage)
		GrowthAndNestService.StageChanged:Fire(player, newStage)
	end
	notify(player, string.format("[Admin] Croissance %d%% (%s)", math.floor(growth), newStage), "info")
end

local function fill(player: Player)
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)
	player:SetAttribute("Oxygen", 100)
	player:SetAttribute("BodyTemperature", GameConstants.SHELTER_TEMPERATURE)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = humanoid.MaxHealth
	end
	notify(player, "[Admin] Faim, soif, oxygène, température et vie remplis.", "info")
end

local function onCommand(player: Player, command: unknown, amount: unknown)
	if not isAdmin(player) or typeof(command) ~= "string" then
		return
	end
	local now = os.clock()
	if lastCommand[player] and now - lastCommand[player] < COMMAND_COOLDOWN then
		return
	end
	lastCommand[player] = now

	if command == "Grow" then
		if typeof(amount) ~= "number" or amount ~= amount then
			return
		end
		grow(player, math.clamp(amount :: number, 1, 100))
	elseif command == "Adult" then
		grow(player, 100)
	elseif command == "Fill" then
		fill(player)
	end
end

function AdminService.Start()
	local function onPlayerAdded(player: Player)
		player:SetAttribute("IsAdmin", isAdmin(player))
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCommand[player] = nil
	end)
	Remotes.Get("AdminCommand").OnServerEvent:Connect(onCommand)
end

return AdminService
