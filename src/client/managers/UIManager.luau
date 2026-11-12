--!strict
-- UIManager.luau
-- Point d'entrée unique pour monter toutes les vues client (StarterPlayerScripts.managers).

local playerScripts = script.Parent.Parent

local SurvivalHudView = require(playerScripts.views.SurvivalHudView)
local NotificationToastView = require(playerScripts.views.NotificationToastView)
local GrabPromptView = require(playerScripts.views.GrabPromptView)
local SpawnMenuView = require(playerScripts.views.SpawnMenuView)

local UIManager = {}

function UIManager.Init()
	-- Chaque vue garde son propre garde-fou "déjà monté", donc l'appel est sûr même si
	-- ClientBootstrap monte encore une vue individuellement en plus de cet Init().
	SurvivalHudView.Mount()
	NotificationToastView.Mount()
	GrabPromptView.Mount()
	SpawnMenuView.Mount()
end

return UIManager
