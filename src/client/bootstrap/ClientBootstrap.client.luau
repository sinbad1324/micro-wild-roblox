--!strict
-- ClientBootstrap.client.luau
-- Point d'entrée principal du client (StarterPlayerScripts.bootstrap)

local StarterPlayer = game:GetService("StarterPlayer")
local playerScripts = StarterPlayer.StarterPlayerScripts

local UIManager = require(playerScripts.managers.UIManager)
local SurvivalHudView = require(playerScripts.views.SurvivalHudView)
local AbilityController = require(playerScripts.controllers.AbilityController)

UIManager.Init()
SurvivalHudView.Mount()
AbilityController.Start()
