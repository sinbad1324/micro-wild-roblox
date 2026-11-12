--!strict
-- ServerBootstrap.server.luau
-- Point d'entrée principal du serveur (ServerScriptService.bootstrap)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local MovementService = require(ServerScriptService.services.MovementService)
local PlayerLifecycleService = require(ServerScriptService.services.PlayerLifecycleService)
local SeasonService = require(ServerScriptService.services.SeasonService)
local WorldGenerationService = require(ServerScriptService.services.WorldGenerationService)
local SurvivalService = require(ServerScriptService.services.SurvivalService)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local SpawnMenuNetworkService = require(ServerScriptService.services.SpawnMenuNetworkService)

-- Les remotes doivent exister AVANT que le moindre client ne se connecte ou n'appelle Remotes.Get.
Remotes.EnsureServerRemotes()

MovementService.Start()
PlayerLifecycleService.Start()
SeasonService.Start()
-- AVANT SurvivalService : il lit PondWaterLevel/PondZone/Shelter dès son tout premier tick.
WorldGenerationService.Start()
SurvivalService.Start()
GrowthAndNestService.Start()
SpawnMenuNetworkService.Start()
