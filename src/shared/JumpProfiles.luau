--!strict
-- JumpProfiles.luau
-- Saut réaliste par espèce (au lieu d'un même saut vertical pour tous) :
--   * Catapulte : pattes-ressorts (sauterelle, araignée sauteuse) : bond très haut ET très loin vers l'avant.
--   * Bond      : sauteurs moyens (gerris, mante, écureuil) : petit bond vers l'avant.
--   * Envol     : volants : petite impulsion pour décoller (le vol prend le relais).
--   * Lourd     : marcheurs (fourmis, scarabées, scorpions...) : ils ne sautent presque pas.
-- Larves : une chenille / un asticot (métamorphose) ne saute pas ; une nymphe (mue) saute à moitié.
-- Power = Humanoid.JumpPower (serveur, MovementService) ; Forward = élan horizontal ajouté au
-- décollage (client, JumpController).

local InsectData = require(script.Parent.InsectData)

export type Style = "Catapulte" | "Bond" | "Envol" | "Lourd"
export type Profile = { Style: Style, Power: number, Forward: number }

local JumpProfiles = {}

local STYLES: { [Style]: Profile } = {
	Catapulte = { Style = "Catapulte", Power = 72, Forward = 48 },
	Bond = { Style = "Bond", Power = 46, Forward = 22 },
	Envol = { Style = "Envol", Power = 40, Forward = 0 },
	Lourd = { Style = "Lourd", Power = 24, Forward = 0 },
}

local BY_SPECIES: { [string]: Style } = {
	Sauterelle = "Catapulte",
	AraigneeSauteuse = "Catapulte",
	Gerris = "Bond", -- bondit à la surface de l'eau
	ManteReligieuse = "Bond",
	Ecureuil = "Bond",
	Cigale = "Envol",
	Oiseau = "Envol",
}

local LARVA_NO_JUMP = 8 -- chenille / asticot : juste de quoi passer une brindille
local NYMPH_FACTOR = 0.5

function JumpProfiles.For(speciesId: string): Profile
	local style = BY_SPECIES[speciesId]
	if not style then
		local species = InsectData[speciesId]
		style = if species and species.CanFly then "Envol" else "Lourd"
	end
	return STYLES[style :: Style]
end

-- JumpPower du stade : adulte = profil complet ; larve / mue selon le type de croissance.
function JumpProfiles.PowerFor(speciesId: string, stage: string): number
	local profile = JumpProfiles.For(speciesId)
	if stage == "Adulte" then
		return profile.Power
	end
	if stage == "Larve" or stage == "Mue" then
		local species = InsectData[speciesId]
		if species and species.GrowthType == "Metamorphose" then
			return LARVA_NO_JUMP
		end
		return math.max(LARVA_NO_JUMP, profile.Power * NYMPH_FACTOR)
	end
	return 0
end

return JumpProfiles
