--!strict
-- ClientBootstrap.client.luau
-- Point d'entrée principal du client (StarterPlayerScripts.bootstrap)
--
-- IMPORTANT : on require via script.Parent.Parent (le PlayerScripts cloné en jeu), jamais via
-- game:GetService("StarterPlayer").StarterPlayerScripts (le gabarit non cloné). Les deux
-- instances sont différentes : les requérir séparément créerait deux modules dupliqués avec
-- un état indépendant (ex: deux ClientState désynchronisés).

local playerScripts = script.Parent.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.shared.Remotes)

local UIManager = require(playerScripts.managers.UIManager)
local AbilityController = require(playerScripts.controllers.AbilityController)
local StatusEffectController = require(playerScripts.controllers.StatusEffectController)
local MarkerController = require(playerScripts.controllers.MarkerController)
local AbilityHotbarView = require(playerScripts.views.AbilityHotbarView)

-- Les RemoteEvents sont créés par ServerBootstrap au boot ; on attend qu'ils existent avant de
-- câbler quoi que ce soit qui en dépend.
Remotes.Get("NotifyClient")

UIManager.Init()
AbilityController.Start()
AbilityHotbarView.Mount(AbilityController.CooldownStarted)
StatusEffectController.Start()
MarkerController.Start()
