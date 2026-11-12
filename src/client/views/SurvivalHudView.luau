--!strict
-- SurvivalHudView.luau
-- Vue du HUD de survie : Faim, Soif, Température, Croissance et Saison (StarterPlayerScripts.views)

local Players = game:GetService("Players")

local SurvivalHudView = {}

function SurvivalHudView.Mount()
	local player = Players.LocalPlayer
	player:GetAttributeChangedSignal("Stage"):Connect(function()
		local newStage = player:GetAttribute("Stage")
		print(string.format("[MicroWild HUD] Nouveau stade d'évolution : %s", tostring(newStage)))
	end)
end

return SurvivalHudView
