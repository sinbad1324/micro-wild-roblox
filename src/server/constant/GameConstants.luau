--!strict
-- GameConstants.luau
-- Constantes serveur pour la survie, l'évolution et les saisons

local GameConstants = {
	SURVIVAL_TICK_INTERVAL = 2,
	GROWTH_TICK_INTERVAL = 3,
	SHELTER_TEMPERATURE = 20,

	STAGE_THRESHOLDS = {
		LARVE = 15,
		COCON = 60,
		ADULTE = 75,
		MAX_GROWTH = 100,
	},

	DEFAULT_SPECIES = "FourmiRousse",
}

return GameConstants
