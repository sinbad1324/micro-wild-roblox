--!strict
-- PlayerLifecycleService.luau
-- Source unique de vérité pour "ce joueur vient d'apparaître" / "ce joueur vient de mourir".
-- Écoute Humanoid.Died (qui se déclenche quelle que soit la cause : faim, froid, noyade, combat)
-- plutôt que de dupliquer la détection de mort dans chaque service qui inflige des dégâts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local PlayerDataRepository = require(ServerScriptService.data.PlayerDataRepository)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MovementService = require(ServerScriptService.services.MovementService)
local CarcassService = require(ServerScriptService.services.CarcassService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local PlayerLifecycleService = {}

-- Un coup reçu il y a plus longtemps que ça ne compte plus comme "kill" (mort de faim après fuite).
local KILL_CREDIT_SECONDS = 15

local function resetToEgg(player: Player)
	-- GDD : chaque vie recommence sous forme d'oeuf. HasConfirmedSpawn=false rouvre le menu de spawn
	-- (choix d'espèce / de nid) et gèle la croissance tant qu'aucun choix n'est fait.
	player:SetAttribute("Stage", "Oeuf")
	player:SetAttribute("Growth", 0)
	player:SetAttribute("HasConfirmedSpawn", false)
	player:SetAttribute("CanLeaveNest", false)
	player:SetAttribute("IsMolting", false)
	player:SetAttribute("HomePosition", nil)
	player:SetAttribute("Mutation", nil)
	player:SetAttribute("IsGrabbed", false)
	player:SetAttribute("CarriedFood", nil)
	player:SetAttribute("CarriedFoodType", nil)
	player:SetAttribute("LifeToken", ((player:GetAttribute("LifeToken") :: number?) or 0) + 1)
end

local function onCharacterDied(player: Player, character: Model)
	-- Snapshot AVANT la réinitialisation (espèce pour la carcasse, maternité pour le nid).
	local speciesIdAtDeath = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	local wasMother = player:GetAttribute("IsMother") == true

	-- La réinitialisation passe en premier : une erreur plus bas (carcasse, kill) ne doit jamais
	-- laisser le joueur coincé à son ancien stade.
	resetToEgg(player)
	MovementService.CleanupPlayer(player)
	if wasMother then
		GrowthAndNestService.RemoveNest(player.UserId)
		Remotes.Get("NestListChanged"):FireAllClients(GrowthAndNestService.GetNestSummaries())
	else
		GrowthAndNestService.LeaveNest(player)
	end

	-- Repli hors du tronc du Chêne (centre de la carte) : la dalle de spawn.
	local position = WorldLayout.SPAWN_POSITION + Vector3.new(0, 2, 0)
	if character.PrimaryPart then
		position = character.PrimaryPart.Position
	end

	local species = InsectData[speciesIdAtDeath]
	local ok, err = pcall(function()
		local template = InsectVisualService.BuildCarcassTemplate(character)
		CarcassService.SpawnCarcassFor(position, player.Name, false, character:GetScale(), template)
	end)
	if not ok then
		warn("[PlayerLifecycleService] carcasse : " .. tostring(err))
	end

	-- Attribution du kill (posé par DamageService à chaque coup reçu).
	local lastAttacker = character:GetAttribute("LastAttackerUserId") :: number?
	local lastAttackAt = (character:GetAttribute("LastAttackAt") :: number?) or 0
	if lastAttacker and lastAttacker ~= player.UserId and os.clock() - lastAttackAt <= KILL_CREDIT_SECONDS then
		ProgressionService.RecordKill(lastAttacker, if species then species.Name else player.Name, false)
	end
	ProgressionService.RecordDeath(player)
end

local function onCharacterAdded(player: Player, character: Model)
	-- Died est connecté AVANT tout le reste : si la construction du corps 3D échoue, la mort doit
	-- quand même renvoyer le joueur à l'état d'oeuf.
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.BreakJointsOnDeath = false
	humanoid.Died:Connect(function()
		onCharacterDied(player, character)
	end)

	task.wait(0.2)
	if character.Parent == nil then
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES
	local stage = (player:GetAttribute("Stage") :: string?) or "Oeuf"
	local ok, err = pcall(EvolutionDomain.SetStage, player, speciesId, stage :: any, true)
	if not ok then
		warn("[PlayerLifecycleService] SetStage : " .. tostring(err))
	end

	-- Un corps neuf repart avec des réserves pleines : sinon il remeurt instantanément et la
	-- croissance reste gelée (elle s'arrête sous 20 de Faim/Soif, voir GrowthAndNestService).
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)
	player:SetAttribute("Oxygen", 100)
	player:SetAttribute("BodyTemperature", GameConstants.SHELTER_TEMPERATURE)

	local home = player:GetAttribute("HomePosition") :: Vector3?
	if home and player:GetAttribute("HasConfirmedSpawn") == true then
		character:PivotTo(CFrame.new(home + Vector3.new(0, 3, 0)))
	end
end

local function onPlayerAdded(player: Player)
	PlayerDataRepository.InitPlayerAttributes(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function PlayerLifecycleService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return PlayerLifecycleService
