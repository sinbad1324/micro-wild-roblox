--!strict
-- UIManager.luau
-- Point d'entrée unique pour monter toutes les vues client (StarterPlayerScripts.managers).

local playerScripts = script.Parent.Parent

local AbilityController = require(playerScripts.controllers.AbilityController)
local SurvivalHudView = require(playerScripts.views.SurvivalHudView)
local NotificationToastView = require(playerScripts.views.NotificationToastView)
local GrabPromptView = require(playerScripts.views.GrabPromptView)
local SpawnMenuView = require(playerScripts.views.SpawnMenuView)
local AbilityHotbarView = require(playerScripts.views.AbilityHotbarView)
local DeathScreenView = require(playerScripts.views.DeathScreenView)
local ControlsHelpView = require(playerScripts.views.ControlsHelpView)
local AdminPanelView = require(playerScripts.views.AdminPanelView)

local UIManager = {}

-- Isole chaque Mount : une vue qui plante ne doit pas bloquer les suivantes ni les contrôleurs.
local function safeMount(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn("[UIManager] " .. name .. ".Mount : " .. tostring(err))
	end
end

function UIManager.Init()
	-- Chaque vue garde son propre garde-fou "déjà monté", donc l'appel est sûr même si
	-- ClientBootstrap monte encore une vue individuellement en plus de cet Init().
	safeMount("SurvivalHudView", SurvivalHudView.Mount)
	safeMount("NotificationToastView", NotificationToastView.Mount)
	safeMount("GrabPromptView", GrabPromptView.Mount)
	safeMount("SpawnMenuView", SpawnMenuView.Mount)
	-- Le signal de recharge existe dès le require (BindableEvent), avant AbilityController.Start().
	safeMount("AbilityHotbarView", function()
		AbilityHotbarView.Mount(AbilityController.CooldownStarted)
	end)
	safeMount("DeathScreenView", DeathScreenView.Mount)
	safeMount("ControlsHelpView", ControlsHelpView.Mount)
	safeMount("AdminPanelView", AdminPanelView.Mount)
end

return UIManager
