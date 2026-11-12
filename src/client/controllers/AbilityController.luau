--!strict
-- AbilityController.luau
-- Contrôleur des entrées clavier pour les pouvoirs d'insectes et la chasse (StarterPlayerScripts.controllers)

local UserInputService = game:GetService("UserInputService")

local AbilityController = {}

function AbilityController.Start()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.E then
			-- Pouvoir Spécial 1 (Venin, Acide, Toile, Camouflage, Flash...)
		elseif input.KeyCode == Enum.KeyCode.R then
			-- Pouvoir Spécial 2
		elseif input.KeyCode == Enum.KeyCode.F then
			-- Saisir une proie / Chasser un petit poisson
		end
	end)
end

return AbilityController
