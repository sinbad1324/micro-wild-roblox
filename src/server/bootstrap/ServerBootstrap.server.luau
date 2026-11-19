--!strict
-- ServerBootstrap.server.luau
-- Point d'entrée principal du serveur (ServerScriptService.bootstrap). L'ORDRE compte :
-- chaque service ne doit démarrer qu'une fois les contrats dont il dépend posés. Chaque Start est
-- protégé : un système secondaire qui plante (IA, effets) ne doit jamais empêcher la boucle de jeu
-- (spawn, croissance, survie, menu) de démarrer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local services = ServerScriptService.services
local MovementService = require(services.MovementService)
local StatusEffectService = require(services.StatusEffectService)
local SeasonService = require(services.SeasonService)
local WorldGenerationService = require(services.WorldGenerationService)
local GrowthAndNestService = require(services.GrowthAndNestService)
local ProgressionService = require(services.ProgressionService)
local PlayerLifecycleService = require(services.PlayerLifecycleService)
local SurvivalService = require(services.SurvivalService)
local FoodService = require(services.FoodService)
local SpawnMenuNetworkService = require(services.SpawnMenuNetworkService)
local AdminService = require(services.AdminService)
local NpcMotherService = require(services.NpcMotherService)
local CombatService = require(services.CombatService)
local DigService = require(services.DigService)
local AnimalService = require(services.AnimalService)
local SeasonVisualService = require(services.SeasonVisualService)
local EvolutionDomain = require(ServerScriptService.domain.EvolutionDomain)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local ShowcaseService = require(services.ShowcaseService)

local function start(name: string, startFunction: () -> ())
	local ok, err = pcall(startFunction)
	if not ok then
		warn(string.format("[ServerBootstrap] %s.Start a échoué : %s", name, tostring(err)))
	end
end

-- Les remotes doivent exister AVANT que le moindre client ne se connecte ou n'appelle Remotes.Get.
Remotes.EnsureServerRemotes()

-- Les joueurs sont des insectes : pas de vêtements ni d'accessoires Roblox chargés sur le corps
-- (le corps de base restant est caché par InsectVisualService.HideDefaultAvatar).
game:GetService("StarterPlayer").LoadCharacterAppearance = false

-- 1. Boucle de jeu critique.
start("MovementService", MovementService.Start)
start("StatusEffectService", StatusEffectService.Start)
start("SeasonService", SeasonService.Start)
-- Le monde (sol, mare/PondWaterLevel, abris, nourriture) avant tout ce qui le lit.
start("WorldGenerationService", WorldGenerationService.Start)
-- Nids IA (posés sur le spawn et dans la mare générés ci-dessus).
start("GrowthAndNestService", GrowthAndNestService.Start)
-- Profils/leaderstats avant que PlayerLifecycleService ne gère les personnages.
start("ProgressionService", ProgressionService.Start)
start("PlayerLifecycleService", PlayerLifecycleService.Start)
start("SurvivalService", SurvivalService.Start)
start("FoodService", FoodService.Start)
-- Nids PNJ enregistrés avant la première diffusion de la liste des nids (menu de spawn).
start("NpcMotherService", NpcMotherService.Start)
start("SpawnMenuNetworkService", SpawnMenuNetworkService.Start)
start("AdminService", AdminService.Start)

-- Mutation tirée à l'âge adulte : reconstruit le corps 3D avec ses couleurs rares.
ProgressionService.MutationRolledHook = function(player: Player)
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	task.spawn(EvolutionDomain.SetStage, player, speciesId, "Adulte")
end

-- 2. Systèmes de gameplay secondaires (combat, creusement, animaux, effets de saison).
CombatService.EvolutionPointsHook = ProgressionService.AddEvolutionPoints
CombatService.ReleaseAnimalHoldHook = AnimalService.ReleaseHold
start("CombatService", CombatService.Start)
start("DigService", DigService.Start)
start("AnimalService", AnimalService.Start)
start("SeasonVisualService", SeasonVisualService.Start)

-- 3. Galerie d'exemples de tous les modèles 3D (désactivable dans GameConstants).
if GameConstants.SHOWCASE_IN_GAME then
	start("ShowcaseService", function()
		ShowcaseService.Build()
	end)
end
