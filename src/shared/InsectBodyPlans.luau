--!strict
-- InsectBodyPlans.luau
-- Plans de corps 3D des 30 espèces (GDD §5) + leurs larves (GDD §2) + mutations rares (GDD §9.4).
-- Données uniquement : InsectVisualService (serveur) assemble les modèles procéduraux à partir de
-- ces plans avec une dizaine de "constructeurs" génériques (pattes, ailes, mâchoires, queue...),
-- plutôt que 30 fonctions écrites à la main.

export type Antennae = "Long" | "Short" | "Clubbed" | "Feathery" | "Elbowed" | "None"
export type Jaws = "Mandibles" | "Stag" | "Proboscis" | "Fangs" | "Rostrum" | "Nozzle" | "None"
export type FrontLimbs = "Raptorial" | "Pincers" | "WaterGrabbers" | "None"
export type Tail = "Stinger" | "ScorpionTail" | "Siphon" | "Cerci" | "Spinnerets" | "None"
export type Wings = "Membrane" | "Elytra" | "Butterfly" | "Dragonfly" | "Mosquito" | "Fly" | "Mayfly" | "Folded" | "Tent" | "None"
export type BodyShape = "Insect" | "Spider" | "Centipede" | "Stick" | "Dome" | "Flat"
export type LegStyle = "Normal" | "Jumper" | "Strider" | "Oars" | "Long"
export type LarvaType = "Grub" | "Crawler" | "Caterpillar" | "Nymph" | "AquaticNymph" | "Wiggler" | "CaseLarva"
export type ColorRole = "Primary" | "Secondary" | "Accent" | "Dark"
export type HeadShape = "Round" | "Triangle" | "Wide"
export type Pronotum = "None" | "Shield" | "Saddle"
export type StripeStyle = "Alternate" | "RearBand"
export type LegColor = "Body" | "Dark" | "Tipped" | "Thighs" | "Striped"
export type EyeStyle = "Compound" | "Simple" -- "Simple" = ocelles d'arachnide (scorpion) au lieu d'yeux composés

export type BodyPlan = {
	Shape: BodyShape,
	Primary: Color3,
	Secondary: Color3,
	Accent: Color3,
	EyeColor: Color3,
	Length: number, -- échelle globale (1 = ~3.5 studs de long à l'âge adulte)
	HeadSize: number,
	HeadShape: HeadShape, -- "Triangle" = mante, "Wide" = cigale (yeux aux coins)
	HeadColor: ColorRole, -- termite soldat (tête orange), frelon (face orange)
	EyeSize: number,
	EyeStyle: EyeStyle,
	Pronotum: Pronotum, -- "Shield" = bouclier des coléoptères, "Saddle" = selle de la sauterelle
	PronotumColor: ColorRole,
	ThoraxLength: number,
	AbdomenLength: number,
	AbdomenWidth: number,
	Waist: boolean, -- pétiole fin (fourmis, guêpes)
	Legs: number, -- 6 (insectes) ou 8 (arachnides) ; ignoré pour la scolopendre
	LegStyle: LegStyle,
	LegLength: number,
	LegColor: LegColor, -- "Tipped" = tibias/tarses LegTint, "Thighs" = fémurs LegTint, "Striped" = annelées
	LegTint: Color3,
	PollenBaskets: boolean, -- corbeilles à pollen (abeille)
	Antennae: Antennae,
	Jaws: Jaws,
	ProboscisLength: number,
	Horn: boolean,
	FrontLimbs: FrontLimbs,
	Tail: Tail,
	TailLength: number, -- siphon / cerques
	Wings: Wings,
	WingColor: Color3,
	ElytraColor: ColorRole,
	ElytraRim: boolean, -- liseré Accent autour des élytres (dytique, luciole)
	Stripes: boolean, -- anneaux sur l'abdomen (Accent)
	StripeStyle: StripeStyle, -- "Alternate" = Primary/Accent, "RearBand" = une large bande à l'arrière
	Spots: boolean, -- points (Accent) sur la carapace
	Fuzzy: boolean, -- abeille, araignée sauteuse : matière "Fabric"
	Metallic: boolean, -- guêpe émeraude, scarabée : reflets
	Glow: boolean, -- luciole : abdomen lumineux + PointLight
	Segments: number, -- scolopendre
	Bubble: boolean, -- bulle d'air (argyronète, dytique)
	Larva: LarvaType,
	LarvaColor: Color3,
}

export type MutationInfo = {
	Name: string,
	Chance: number,
	Primary: Color3?,
	Secondary: Color3?,
	Material: Enum.Material?,
	Rainbow: boolean?,
}

local rgb = Color3.fromRGB

local DEFAULTS: BodyPlan = {
	Shape = "Insect",
	Primary = rgb(90, 60, 40),
	Secondary = rgb(60, 40, 28),
	Accent = rgb(20, 20, 20),
	EyeColor = rgb(15, 15, 15),
	Length = 1,
	HeadSize = 1,
	HeadShape = "Round",
	HeadColor = "Primary",
	EyeSize = 1,
	EyeStyle = "Compound",
	Pronotum = "None",
	PronotumColor = "Primary",
	ThoraxLength = 1,
	AbdomenLength = 1,
	AbdomenWidth = 1,
	Waist = false,
	Legs = 6,
	LegStyle = "Normal",
	LegLength = 1,
	LegColor = "Body",
	LegTint = rgb(240, 200, 50),
	PollenBaskets = false,
	Antennae = "Long",
	Jaws = "Mandibles",
	ProboscisLength = 1,
	Horn = false,
	FrontLimbs = "None",
	Tail = "None",
	TailLength = 1,
	Wings = "None",
	WingColor = rgb(220, 230, 240),
	ElytraColor = "Secondary",
	ElytraRim = false,
	Stripes = false,
	StripeStyle = "Alternate",
	Spots = false,
	Fuzzy = false,
	Metallic = false,
	Glow = false,
	Segments = 0,
	Bubble = false,
	Larva = "Grub",
	LarvaColor = rgb(240, 235, 220),
}

local function plan(overrides: { [string]: any }): BodyPlan
	local result = table.clone(DEFAULTS) :: any
	for key, value in pairs(overrides) do
		assert((DEFAULTS :: any)[key] ~= nil, "InsectBodyPlans: champ inconnu " .. tostring(key))
		result[key] = value
	end
	return result :: BodyPlan
end

local Plans: { [string]: BodyPlan } = {
	-- ==========================================
	-- A. TERRESTRES
	-- ==========================================
	FourmiRousse = plan({
		Primary = rgb(150, 55, 30), Secondary = rgb(60, 30, 20), Length = 0.85,
		HeadSize = 1.1, AbdomenLength = 1.1, AbdomenWidth = 0.95, Waist = true, Antennae = "Elbowed",
		Jaws = "Mandibles", Larva = "Grub",
	}),
	ManteReligieuse = plan({
		Primary = rgb(110, 175, 70), Secondary = rgb(80, 140, 50), Accent = rgb(170, 210, 120),
		Length = 1.2, HeadSize = 0.9, ThoraxLength = 1.8, AbdomenLength = 1.3, AbdomenWidth = 0.8,
		FrontLimbs = "Raptorial", Wings = "Folded", WingColor = rgb(140, 190, 100), Antennae = "Short",
		Jaws = "Mandibles", LegLength = 1.2, EyeSize = 1.4, HeadShape = "Triangle", Larva = "Nymph",
		LarvaColor = rgb(150, 200, 110),
	}),
	LucaneCerfVolant = plan({
		Primary = rgb(70, 35, 20), Secondary = rgb(45, 25, 15), Length = 1.25, HeadSize = 1.2,
		AbdomenWidth = 1.15, Jaws = "Stag", Wings = "Elytra", Antennae = "Clubbed", Metallic = true,
		Pronotum = "Shield",
		Larva = "Grub", LarvaColor = rgb(235, 225, 200),
	}),
	ScarabeeHercule = plan({
		Primary = rgb(25, 25, 25), Secondary = rgb(170, 155, 80), Length = 1.3, HeadSize = 1.0,
		AbdomenWidth = 1.25, AbdomenLength = 1.2, Jaws = "None", Horn = true, Wings = "Elytra",
		Antennae = "Short", Metallic = true, Pronotum = "Shield", Spots = true, LegColor = "Dark",
		Larva = "Grub", LarvaColor = rgb(230, 220, 190),
	}),
	VeuveNoire = plan({
		Shape = "Spider", Primary = rgb(18, 18, 22), Secondary = rgb(25, 25, 30), Accent = rgb(200, 20, 25),
		Length = 0.95, Legs = 8, LegStyle = "Long", LegLength = 1.4, AbdomenWidth = 1.35, AbdomenLength = 1.1,
		Antennae = "None", Jaws = "Fangs", Tail = "Spinnerets", Spots = true, Metallic = true,
		Larva = "Nymph", LarvaColor = rgb(200, 190, 170),
	}),
	AraigneeSauteuse = plan({
		Shape = "Spider", Primary = rgb(40, 35, 30), Secondary = rgb(70, 60, 50), Accent = rgb(230, 230, 230),
		Length = 0.8, Legs = 8, LegLength = 0.9, HeadSize = 1.3, EyeSize = 1.8, Antennae = "None",
		Jaws = "Fangs", Fuzzy = true, Stripes = true, Larva = "Nymph", LarvaColor = rgb(150, 130, 110),
	}),
	ScorpionEmpereur = plan({
		Shape = "Flat", Primary = rgb(15, 20, 30), Secondary = rgb(25, 30, 40), Length = 1.3, Legs = 8,
		HeadSize = 0.9, ThoraxLength = 1.2, AbdomenLength = 1.0, Antennae = "None", Jaws = "Mandibles",
		FrontLimbs = "Pincers", Tail = "ScorpionTail", Metallic = true, EyeStyle = "Simple", Larva = "Nymph",
		LarvaColor = rgb(220, 215, 205),
	}),
	Sauterelle = plan({
		Primary = rgb(110, 150, 60), Secondary = rgb(140, 120, 60), Length = 1.05, HeadSize = 1.0,
		ThoraxLength = 1.2, AbdomenLength = 1.3, AbdomenWidth = 0.85, LegStyle = "Jumper",
		Antennae = "Long", Wings = "Folded", WingColor = rgb(130, 160, 80), Pronotum = "Saddle", Larva = "Nymph",
		LarvaColor = rgb(150, 190, 90),
	}),
	Coccinelle = plan({
		Shape = "Dome", Primary = rgb(210, 25, 25), Secondary = rgb(15, 15, 15), Accent = rgb(15, 15, 15),
		Length = 0.75, HeadSize = 0.8, Antennae = "Clubbed", Jaws = "None", Spots = true, Wings = "Elytra",
		LegLength = 0.7, LegColor = "Dark", Metallic = true, Larva = "Crawler", LarvaColor = rgb(45, 45, 60),
	}),
	TermiteSoldat = plan({
		Primary = rgb(225, 210, 175), Secondary = rgb(190, 100, 40), Length = 0.85, HeadSize = 1.4,
		AbdomenLength = 1.1, Jaws = "Nozzle", Antennae = "Short", HeadColor = "Secondary", Larva = "Nymph",
		LarvaColor = rgb(240, 235, 215),
	}),
	ScolopendreGeante = plan({
		Shape = "Centipede", Primary = rgb(150, 50, 25), Secondary = rgb(30, 25, 25), Accent = rgb(230, 170, 40),
		Length = 1.4, Segments = 12, HeadSize = 0.9, Antennae = "Long", Jaws = "Fangs", LegLength = 0.8,
		Metallic = true, Larva = "Nymph", LarvaColor = rgb(200, 120, 80),
	}),
	PhasmeBaton = plan({
		Shape = "Stick", Primary = rgb(120, 95, 60), Secondary = rgb(95, 75, 45), Length = 1.45,
		HeadSize = 0.6, ThoraxLength = 1.8, AbdomenLength = 1.8, AbdomenWidth = 0.4, LegStyle = "Long",
		LegLength = 1.5, Antennae = "Long", Jaws = "None", Larva = "Nymph", LarvaColor = rgb(140, 160, 90),
	}),

	-- ==========================================
	-- B. VOLANTS
	-- ==========================================
	AbeilleMellifere = plan({
		-- Trapue et ronde (vs frelon long et guêpe émeraude fine).
		Primary = rgb(225, 165, 30), Secondary = rgb(60, 40, 20), Accent = rgb(25, 20, 15), Length = 0.8,
		HeadSize = 0.9, EyeSize = 1.15, AbdomenLength = 0.95, AbdomenWidth = 1.25, LegLength = 0.9, Waist = true, Antennae = "Elbowed",
		Jaws = "Proboscis", ProboscisLength = 0.7, Tail = "Stinger", Wings = "Membrane", Stripes = true,
		Fuzzy = true, LegColor = "Dark", PollenBaskets = true, Larva = "Grub",
	}),
	FrelonAsiatique = plan({
		-- Grand et allongé, grosse tête orange.
		Primary = rgb(30, 25, 20), Secondary = rgb(25, 20, 18), Accent = rgb(230, 140, 30), Length = 1.2,
		HeadSize = 1.1, AbdomenLength = 1.35, LegLength = 1.1, Waist = true, Antennae = "Elbowed", Jaws = "Mandibles",
		Tail = "Stinger", Wings = "Membrane", WingColor = rgb(180, 150, 110), Stripes = true,
		StripeStyle = "RearBand", HeadColor = "Accent", LegColor = "Tipped", Larva = "Grub",
	}),
	LibelluleEmpereur = plan({
		Primary = rgb(40, 120, 200), Secondary = rgb(60, 170, 90), Accent = rgb(15, 30, 60), Length = 1.25,
		HeadSize = 1.0, EyeSize = 2.0, EyeColor = rgb(30, 90, 140), ThoraxLength = 1.0, AbdomenLength = 2.4,
		AbdomenWidth = 0.4, LegLength = 0.8, Antennae = "Short", Wings = "Dragonfly", Stripes = true,
		Larva = "AquaticNymph",
		LarvaColor = rgb(90, 100, 60),
	}),
	PapillonMonarque = plan({
		Primary = rgb(30, 25, 25), Secondary = rgb(30, 25, 25), Accent = rgb(245, 245, 245), Length = 0.95,
		HeadSize = 0.7, AbdomenLength = 1.1, AbdomenWidth = 0.55, Antennae = "Clubbed", Jaws = "Proboscis",
		ProboscisLength = 0.8, LegColor = "Dark",
		Wings = "Butterfly", WingColor = rgb(240, 130, 20), Larva = "Caterpillar", LarvaColor = rgb(245, 220, 40),
	}),
	MoustiqueTigre = plan({
		Primary = rgb(25, 25, 25), Secondary = rgb(30, 30, 30), Accent = rgb(240, 240, 240), Length = 0.7,
		HeadSize = 0.7, AbdomenLength = 1.3, AbdomenWidth = 0.5, LegStyle = "Long", LegLength = 1.6,
		Antennae = "Feathery", Jaws = "Proboscis", ProboscisLength = 1.8, Wings = "Mosquito", Stripes = true,
		LegColor = "Striped", LegTint = rgb(240, 240, 240), Larva = "Wiggler",
		LarvaColor = rgb(70, 70, 60),
	}),
	Luciole = plan({
		Primary = rgb(50, 45, 35), Secondary = rgb(200, 90, 60), Accent = rgb(230, 255, 90), Length = 0.8,
		HeadSize = 0.75, Antennae = "Long", Jaws = "None", Wings = "Elytra", Glow = true, Pronotum = "Shield",
		PronotumColor = "Secondary", ElytraColor = "Primary", ElytraRim = true, Larva = "Crawler",
		LarvaColor = rgb(60, 50, 45),
	}),
	MoucheTaon = plan({
		Primary = rgb(70, 70, 75), Secondary = rgb(50, 50, 55), Accent = rgb(110, 110, 110), Length = 0.8,
		HeadSize = 1.0, EyeSize = 2.0, EyeColor = rgb(170, 30, 25), AbdomenWidth = 1.05, Antennae = "Short",
		Jaws = "Proboscis", ProboscisLength = 0.6, Wings = "Fly", WingColor = rgb(200, 205, 215), Fuzzy = true,
		LegColor = "Dark", Larva = "Grub",
	}),
	ScarabeeBombardier = plan({
		Primary = rgb(220, 110, 30), Secondary = rgb(25, 45, 90), Accent = rgb(230, 190, 60), Length = 0.85,
		HeadSize = 0.9, AbdomenWidth = 1.1, Antennae = "Long", Jaws = "Mandibles", Wings = "Elytra",
		Metallic = true, Pronotum = "Shield", Larva = "Crawler", LarvaColor = rgb(215, 190, 140),
	}),
	Cigale = plan({
		Primary = rgb(60, 90, 50), Secondary = rgb(40, 50, 35), Accent = rgb(120, 160, 80), Length = 1.05,
		HeadSize = 1.25, HeadShape = "Wide", EyeSize = 1.6, EyeColor = rgb(150, 40, 30), AbdomenWidth = 1.2,
		Antennae = "Short", Jaws = "Rostrum",
		Wings = "Tent", WingColor = rgb(200, 225, 200), Larva = "Nymph", LarvaColor = rgb(200, 170, 120),
	}),
	GuepeEmeraude = plan({
		-- Fine, longues pattes, grosse tête aux yeux saillants.
		Primary = rgb(20, 150, 110), Secondary = rgb(25, 110, 140), Accent = rgb(200, 30, 40), Length = 0.8,
		HeadSize = 1.0, EyeSize = 1.2, AbdomenLength = 1.1, AbdomenWidth = 0.7, LegLength = 1.25, Waist = true, Antennae = "Long",
		Jaws = "Mandibles", Tail = "Stinger", Wings = "Membrane", WingColor = rgb(170, 200, 210),
		Metallic = true, LegColor = "Thighs", LegTint = rgb(200, 30, 40), Larva = "Grub",
	}),

	-- ==========================================
	-- C. AQUATIQUES & SEMI-AQUATIQUES
	-- ==========================================
	Gerris = plan({
		Primary = rgb(35, 35, 40), Secondary = rgb(60, 60, 65), Length = 0.9, HeadSize = 0.6,
		ThoraxLength = 1.3, AbdomenLength = 1.0, AbdomenWidth = 0.45, LegStyle = "Strider", LegLength = 2.2,
		Antennae = "Long", Jaws = "Rostrum", Larva = "Nymph", LarvaColor = rgb(80, 80, 85),
	}),
	DytiqueBorde = plan({
		Primary = rgb(45, 55, 30), Secondary = rgb(35, 45, 25), Accent = rgb(220, 190, 70), Length = 1.05,
		HeadSize = 0.8, AbdomenWidth = 1.25, AbdomenLength = 1.2, LegStyle = "Oars", Antennae = "Long",
		Jaws = "Mandibles", Wings = "Elytra", Metallic = true, Bubble = true, Pronotum = "Shield",
		ElytraRim = true, Larva = "AquaticNymph",
		LarvaColor = rgb(120, 110, 70),
	}),
	Nepe = plan({
		-- Feuille morte étroite et grise (vs punaise d'eau géante large et brun chaud).
		Shape = "Flat", Primary = rgb(95, 85, 65), Secondary = rgb(75, 65, 50), Length = 1.0, HeadSize = 0.6,
		ThoraxLength = 0.85, AbdomenWidth = 0.75, AbdomenLength = 1.3, LegLength = 0.9, Antennae = "None", Jaws = "Rostrum",
		FrontLimbs = "WaterGrabbers", Tail = "Siphon", TailLength = 1.4, Wings = "Folded",
		WingColor = rgb(120, 90, 60), Larva = "Nymph",
		LarvaColor = rgb(130, 100, 70),
	}),
	Notonecte = plan({
		Primary = rgb(225, 215, 180), Secondary = rgb(120, 100, 70), Accent = rgb(40, 40, 40), Length = 0.85,
		HeadSize = 0.9, EyeSize = 1.5, EyeColor = rgb(160, 40, 30), AbdomenWidth = 0.9, LegStyle = "Oars",
		LegLength = 1.35,
		Antennae = "None", Jaws = "Rostrum", Wings = "Folded", WingColor = rgb(230, 225, 200),
		Larva = "Nymph", LarvaColor = rgb(220, 215, 190),
	}),
	LarvePhrygane = plan({
		Primary = rgb(130, 100, 70), Secondary = rgb(100, 80, 55), Length = 0.9, HeadSize = 0.7,
		AbdomenWidth = 0.8, Antennae = "Long", Jaws = "None", Wings = "Tent", WingColor = rgb(150, 120, 80),
		Fuzzy = true, Larva = "CaseLarva", LarvaColor = rgb(225, 215, 190),
	}),
	Argyronete = plan({
		Shape = "Spider", Primary = rgb(60, 45, 35), Secondary = rgb(80, 65, 50), Length = 0.85, Legs = 8,
		LegLength = 1.1, Antennae = "None", Jaws = "Fangs", Tail = "Spinnerets", Fuzzy = true, Bubble = true,
		Larva = "Nymph", LarvaColor = rgb(140, 120, 100),
	}),
	Ephemere = plan({
		Primary = rgb(200, 180, 120), Secondary = rgb(150, 130, 90), Accent = rgb(110, 80, 50), Length = 0.85,
		HeadSize = 0.6, AbdomenLength = 1.5, AbdomenWidth = 0.5, Antennae = "Short", Jaws = "None",
		Tail = "Cerci", TailLength = 1.2, Wings = "Mayfly", WingColor = rgb(235, 235, 225), Stripes = true,
		Larva = "AquaticNymph", LarvaColor = rgb(150, 130, 90),
	}),
	PunaiseEauGeante = plan({
		Shape = "Flat", Primary = rgb(105, 75, 45), Secondary = rgb(80, 55, 35), Accent = rgb(60, 40, 25),
		Length = 1.45, HeadSize = 0.75, EyeSize = 1.3, AbdomenWidth = 1.5, AbdomenLength = 1.3, Antennae = "None",
		Jaws = "Rostrum", FrontLimbs = "WaterGrabbers", LegStyle = "Oars", Tail = "Siphon", TailLength = 0.35,
		Wings = "Folded",
		WingColor = rgb(120, 90, 55), Larva = "Nymph", LarvaColor = rgb(160, 150, 100),
	}),
}

local Mutations: { [string]: MutationInfo } = {
	Albinos = { Name = "Albinos", Chance = 0.03, Primary = rgb(245, 245, 240), Secondary = rgb(235, 200, 200) },
	Melanique = { Name = "Mélanique", Chance = 0.03, Primary = rgb(20, 20, 22), Secondary = rgb(35, 35, 40) },
	Doree = { Name = "Dorée", Chance = 0.012, Primary = rgb(230, 185, 50), Secondary = rgb(200, 150, 30), Material = Enum.Material.Foil },
	Neon = { Name = "Néon", Chance = 0.006, Primary = rgb(40, 240, 220), Secondary = rgb(250, 60, 220), Material = Enum.Material.Neon },
	Arcenciel = { Name = "Arc-en-ciel", Chance = 0.002, Rainbow = true },
}

local InsectBodyPlans = {
	Plans = Plans,
	Default = DEFAULTS,
	Mutations = Mutations,
	-- Ordre déterministe pour le tirage (les plus rares en dernier).
	MutationOrder = { "Albinos", "Melanique", "Doree", "Neon", "Arcenciel" },
}

function InsectBodyPlans.Get(speciesId: string): BodyPlan
	return Plans[speciesId] or DEFAULTS
end

return InsectBodyPlans
