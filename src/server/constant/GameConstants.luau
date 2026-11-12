--!strict
-- GameConstants.luau
-- Constantes serveur pour la survie, l'évolution et les saisons

local GameConstants = {
	SURVIVAL_TICK_INTERVAL = 2,
	GROWTH_TICK_INTERVAL = 3,
	SHELTER_TEMPERATURE = 20,
	SHELTER_CHECK_RADIUS = 14,

	-- Conforme au GDD section 2 : Oeuf 0-10, Larve 10-50, Cocon/Mue 50-75, Adulte 75-100+.
	STAGE_THRESHOLDS = {
		LARVE = 10,
		COCON = 50,
		ADULTE = 75,
		MAX_GROWTH = 100,
	},

	-- Fenêtres de mue (Hémimétaboles/Arachnides) entre 10 et 75 de croissance : à chaque
	-- franchissement, le joueur passe quelques secondes en "Mue" (carapace molle, vulnérable).
	MOLT_GROWTH_STEPS = { 25, 40, 55, 65 },
	MOLT_SOFT_SHELL_SECONDS = 6,
	MOLT_DAMAGE_MULTIPLIER = 1.6, -- carapace molle = +60% dégâts reçus

	COCOON_DURATION_SECONDS = 35,

	-- "Devenir Maman" exige la croissance maximale (100%), pas seulement le stade Adulte (75%).
	NEST_MIN_GROWTH = 100,

	DEFAULT_SPECIES = "FourmiRousse",
}

return GameConstants
