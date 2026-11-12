--!strict
-- SeasonConfig.luau
-- Gestion des 4 saisons (Printemps, Été, Automne, Hiver)

export type SeasonName = "Printemps" | "Ete" | "Automne" | "Hiver"

export type SeasonInfo = {
	Name: SeasonName,
	DisplayName: string,
	DurationSeconds: number,
	DayAmbientTemp: number,
	NightAmbientTemp: number,
	GrowthSpeedMultiplier: number,
	ThirstDrainMultiplier: number,
	PondFrozen: boolean,
	Description: string,
}

local SeasonConfig = {
	Order = { "Printemps", "Ete", "Automne", "Hiver" } :: { SeasonName },

	Seasons = {
		Printemps = {
			Name = "Printemps",
			DisplayName = "🌸 Printemps",
			DurationSeconds = 900, -- 15 minutes
			DayAmbientTemp = 22,
			NightAmbientTemp = 12,
			GrowthSpeedMultiplier = 1.25,
			ThirstDrainMultiplier = 0.8,
			PondFrozen = false,
			Description = "Fleurs et gouttes de rosée abondantes. Croissance des larves accélérée (+25%).",
		},
		Ete = {
			Name = "Ete",
			DisplayName = "☀️ Été",
			DurationSeconds = 900,
			DayAmbientTemp = 34,
			NightAmbientTemp = 22,
			GrowthSpeedMultiplier = 1.0,
			ThirstDrainMultiplier = 1.6,
			PondFrozen = false,
			Description = "Fortes chaleurs. Les petites flaques sèchent, obligeant à boire à la mare.",
		},
		Automne = {
			Name = "Automne",
			DisplayName = "🍁 Automne",
			DurationSeconds = 900,
			DayAmbientTemp = 16,
			NightAmbientTemp = 8,
			GrowthSpeedMultiplier = 1.0,
			ThirstDrainMultiplier = 1.0,
			PondFrozen = false,
			Description = "Chute de fruits mûrs et de feuilles mortes. Vents forts pour les insectes volants.",
		},
		Hiver = {
			Name = "Hiver",
			DisplayName = "❄️ Hiver",
			DurationSeconds = 900,
			DayAmbientTemp = 0,
			NightAmbientTemp = -8,
			GrowthSpeedMultiplier = 0.75,
			ThirstDrainMultiplier = 0.7,
			PondFrozen = true,
			Description = "Froid glacial et mare gelée en surface. Abritez-vous sous terre ou dans une colonie !",
		},
	} :: { [string]: SeasonInfo },
}

return SeasonConfig
