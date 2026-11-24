--!strict
-- SwimProfiles.luau
-- Nage réaliste par espèce (SwimController) au lieu d'une même glisse fluide "de poisson" :
--   * Rameur     (dytique, notonecte, punaise d'eau géante) : coups de pattes-rames synchronisés
--                = poussée par à-coups puis glisse freinée ; corps plein d'air => remonte tout seul,
--                il faut ramer vers le bas pour rester au fond.
--   * Jet        (larve de libellule) : propulsion par jet d'eau expulsé de l'abdomen = gros
--                à-coups vers l'avant, espacés.
--   * Ondulation (larves de moustique, d'éphémère) : le corps se tortille = avance faible en zigzag.
--   * Fond       (nèpe, larve de phrygane, argyronète, crabe) : mauvais nageurs, plus lourds que
--                l'eau : ils coulent et marchent sur le fond ; quelques battements maladroits pour monter.
--   * Poisson    (poisson rouge) : nage continue et fluide (la seule vraie "nage de poisson").

export type Style = "Rameur" | "Jet" | "Ondulation" | "Fond" | "Poisson"
export type Profile = {
	Style: Style,
	StrokePeriod: number, -- s entre deux coups (0 = poussée continue)
	StrokeImpulse: number, -- × vitesse de nage ajoutée à chaque coup
	Drag: number, -- freinage de l'eau entre deux coups (1/s)
	MaxSpeed: number, -- × vitesse de nage (plafond)
	Buoyancy: number, -- studs/s² vers le haut (< 0 = coule)
	Wiggle: number, -- amplitude du zigzag latéral (0 = aucun)
}

local SwimProfiles = {}

local STYLES: { [Style]: Profile } = {
	Rameur = { Style = "Rameur", StrokePeriod = 0.34, StrokeImpulse = 0.9, Drag = 3.2, MaxSpeed = 1.6, Buoyancy = 5, Wiggle = 0 },
	Jet = { Style = "Jet", StrokePeriod = 0.7, StrokeImpulse = 1.8, Drag = 2.4, MaxSpeed = 2.2, Buoyancy = 0.5, Wiggle = 0 },
	Ondulation = { Style = "Ondulation", StrokePeriod = 0, StrokeImpulse = 0.55, Drag = 4, MaxSpeed = 0.6, Buoyancy = 1, Wiggle = 0.6 },
	Fond = { Style = "Fond", StrokePeriod = 0.55, StrokeImpulse = 0.8, Drag = 5, MaxSpeed = 0.7, Buoyancy = -3, Wiggle = 0 }, -- remonte à ~2 studs/s : assez pour respirer
	Poisson = { Style = "Poisson", StrokePeriod = 0, StrokeImpulse = 1, Drag = 6, MaxSpeed = 1, Buoyancy = 0, Wiggle = 0 },
}

local BY_SPECIES: { [string]: Style } = {
	DytiqueBorde = "Rameur",
	Notonecte = "Rameur",
	PunaiseEauGeante = "Rameur",
	LibelluleEmpereur = "Jet",
	MoustiqueTigre = "Ondulation",
	Ephemere = "Ondulation",
	Nepe = "Fond",
	LarvePhrygane = "Fond",
	Argyronete = "Fond",
	Crabe = "Fond",
	PoissonRouge = "Poisson",
}

function SwimProfiles.For(speciesId: string): Profile
	return STYLES[BY_SPECIES[speciesId] or "Rameur"]
end

return SwimProfiles
