--!strict
-- GameConstants.luau
-- Constantes serveur pour la survie, l'évolution et les saisons

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)

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

	-- Sol de la carte : source unique dans shared/WorldLayout.
	GROUND_TOP_Y = WorldLayout.GROUND_TOP_Y,
	-- Sous cette profondeur relative au sol, un insecte est "sous terre" = abrité (galeries creusées).
	UNDERGROUND_DEPTH = 3,

	NEST_RADIUS = 18, -- zone du nid : dépôt de nourriture, chaleur, laisse des larves
	LARVA_LEASH_RADIUS = 45, -- une larve ne peut pas quitter son nid/sa mare (GDD §2 étape 2)

	-- Fouisseurs (GDD §7.A) : seuls eux peuvent creuser avec la touche C.
	DIGGER_SPECIES = {
		FourmiRousse = true,
		TermiteSoldat = true,
		ScorpionEmpereur = true,
		Cigale = true,
		ScarabeeHercule = true,
		ScarabeeBombardier = true,
		LucaneCerfVolant = true,
		VeuveNoire = true,
		AraigneeSauteuse = true,
		Ephemere = true,
	} :: { [string]: boolean },

	-- Espèces dont la larve naît et grandit dans l'eau (GDD §2) : leur "nid IA" est la mare.
	AQUATIC_LARVA_SPECIES = {
		LibelluleEmpereur = true,
		MoustiqueTigre = true,
		Ephemere = true,
	} :: { [string]: boolean },

	FOOD_RESPAWN_SECONDS = 75,
	BITE_RANGE = 7,
	BITE_COOLDOWN = 0.8,
	KILL_EVOLUTION_POINTS = 40,

	-- Galerie de tous les modèles 3D, à l'ouest de la carte (ShowcaseService) : Studio seulement
	-- (des milliers de parts et ~140 Humanoids de trop pour les serveurs live / mobiles).
	SHOWCASE_IN_GAME = game:GetService("RunService"):IsStudio(),
}

return GameConstants
