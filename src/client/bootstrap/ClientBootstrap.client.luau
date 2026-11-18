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
local CombatFxController = require(playerScripts.controllers.CombatFxController)
local InsectAnimationController = require(playerScripts.controllers.InsectAnimationController)
local AnimalAnimationController = require(playerScripts.controllers.AnimalAnimationController)
local CameraController = require(playerScripts.controllers.CameraController)
local WorldFxController = require(playerScripts.controllers.WorldFxController)

-- Les RemoteEvents sont créés par ServerBootstrap au boot ; on attend qu'ils existent avant de
-- câbler quoi que ce soit qui en dépend.
Remotes.Get("NotifyClient")

-- Monte toutes les vues (HUD, toasts, menu, barre de pouvoirs, mort, aide H).
UIManager.Init()
AbilityController.Start()
StatusEffectController.Start()
MarkerController.Start()
-- CombatFxController utilise AbilityController.LocalBite et StatusEffectController.Shake : après eux.
CombatFxController.Start()
InsectAnimationController.Start()
AnimalAnimationController.Start()
CameraController.Start()
WorldFxController.Start()
