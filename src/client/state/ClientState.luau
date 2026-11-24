--!strict
-- ClientState.luau
-- État local du joueur (StarterPlayerScripts.state)

-- Signal émis à chaque ouverture/fermeture du menu de spawn (les vues de jeu s'effacent derrière).
local menuChanged = Instance.new("BindableEvent")

local ClientState = {
	SelectedSpecies = "FourmiRousse",
	IsInMenu = false,
	CurrentSeason = "Printemps",
	MenuChanged = menuChanged,
}

-- Met à jour IsInMenu et prévient les vues abonnées, uniquement si la valeur change.
function ClientState.SetInMenu(value: boolean)
	if ClientState.IsInMenu == value then
		return
	end
	ClientState.IsInMenu = value
	menuChanged:Fire(value)
end

return ClientState
