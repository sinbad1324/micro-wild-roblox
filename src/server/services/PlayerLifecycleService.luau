--!strict
-- PlayerLifecycleService.luau
-- Source unique de vérité pour "ce joueur vient d'apparaître" / "ce joueur vient de mourir".
-- Écoute Humanoid.Died (qui se déclenche quelle que soit la cause : faim, froid, noyade, combat)
-- plutôt que de dupliquer la détection de mort dans chaque service qui inflige des dégâts.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataRepository = require(ServerScriptService.data.PlayerDataRepository)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local MovementService = require(ServerScriptService.services.MovementService)
local CarcassService = require(ServerScriptService.services.CarcassService)
local InsectVisualService = require(ServerScriptService.services.InsectVisualService)

local PlayerLifecycleService = {}

local function onCharacterDied(player: Player, character: Model)
	local position = Vector3.new(0, 5, 0)
	if character.PrimaryPart then
		position = character.PrimaryPart.Position
	end

	CarcassService.SpawnCarcassFor(position, player.Name, false, 1, nil)

	-- La mort retire le joueur de son nid natal / de sa colonie.
	player:SetAttribute("FamilyId", nil)
	player:SetAttribute("OwnerNestUserId", nil)
	player:SetAttribute("IsGrabbed", false)

	MovementService.CleanupPlayer(player)
end

local function onCharacterAdded(player: Player, character: Model)
	task.wait(0.2)

	local speciesId = (player:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
	local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"
	EvolutionDomain.ApplyStageStats(player, character, speciesId, stage)
	InsectVisualService.ApplyVisual(character, speciesId, stage)

	-- Un corps neuf repart avec des réserves pleines : sinon il remeurt instantanément et la
	-- croissance reste gelée (elle s'arrête sous 20 de Faim/Soif, voir GrowthAndNestService).
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)
	player:SetAttribute("Oxygen", 100)
	player:SetAttribute("BodyTemperature", GameConstants.SHELTER_TEMPERATURE)

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		onCharacterDied(player, character)
	end)
end

local function onPlayerAdded(player: Player)
	PlayerDataRepository.InitPlayerAttributes(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

function PlayerLifecycleService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return PlayerLifecycleService
