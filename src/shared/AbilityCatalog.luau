--!strict
-- AbilityCatalog.luau
-- Contrat partagé : classifie CHAQUE identifiant d'habileté utilisé dans InsectData/AnimalData
-- sur un petit nombre de "primitives" génériques, pour que le pipeline de combat (CombatService /
-- AbilityService / DamageService) n'ait besoin d'implémenter que ~10 mécaniques au lieu de 75.
--
-- Un agent/服 qui ajoute une capacité NE DOIT PAS inventer une nouvelle primitive sans l'ajouter ici
-- d'abord : AbilityService.Execute ne sait exécuter que les primitives listées dans AbilityPrimitive.

export type AbilityPrimitive =
	"Projectile" -- tir à distance (dégâts + statut optionnel), ligne droite
	| "ConeBurst" -- explosion/onde en cône devant soi (dégâts + statut, plusieurs cibles)
	| "LungeCharge" -- charge/ruée vers l'avant, dégâts d'impact
	| "Leap" -- bond ciblé vers une proie, dégâts à l'atterrissage
	| "Grab" -- agrippe une proie plus petite -> déclenche le QTE d'évasion (RequestGrab/RequestGrabEscape)
	| "StatusBite" -- morsure/piqûre de mêlée qui applique un statut (poison, paralysie, etc.)
	| "Camouflage" -- invisibilité/mimétisme tant qu'immobile ou pendant une durée
	| "ArmorBuff" -- réduction de dégâts temporaire ou passive
	| "SupportAura" -- soigne/nourrit/alerte les membres de la famille à portée
	| "Light" -- lumière ambiante + flash aveuglant optionnel
	| "Utility" -- trait numérique divers (oxygène, portée de détection, capacité de transport...)

export type AbilitySlot = "E" | "R" | "Passive" | "F" | "LeftClick" | "AI"

export type StatusEffectName = "Poison" | "Slow" | "Stun" | "Blind" | "InvertControls" | "Toxic" | "MindControl" | "Bleed" | "Glue"

export type AbilityDefinition = {
	Primitive: AbilityPrimitive,
	Slot: AbilitySlot,
	Cooldown: number, -- secondes
	Power: number, -- dégâts bruts OU magnitude de l'effet (buff %, oxygène bonus, etc.) selon la primitive
	Range: number, -- portée en studs (0 = contact/mêlée)
	Duration: number, -- durée du canal / de l'effet / du buff en secondes (0 = instantané)
	Status: StatusEffectName?,
	StatusDuration: number?,
	StatusMagnitude: number?, -- 0..1, ex: 0.8 = ralentit de 80%
	Description: string,
}

local function Def(
	primitive: AbilityPrimitive,
	slot: AbilitySlot,
	cooldown: number,
	power: number,
	range: number,
	duration: number,
	description: string,
	status: StatusEffectName?,
	statusDuration: number?,
	statusMagnitude: number?
): AbilityDefinition
	return {
		Primitive = primitive,
		Slot = slot,
		Cooldown = cooldown,
		Power = power,
		Range = range,
		Duration = duration,
		Status = status,
		StatusDuration = statusDuration,
		StatusMagnitude = statusMagnitude,
		Description = description,
	}
end

local AbilityCatalog: { [string]: AbilityDefinition } = {
	-- ==========================================
	-- A. TERRESTRES
	-- ==========================================
	JetAcideFormique = Def("Projectile", "E", 6, 18, 35, 0, "Jet d'acide formique à distance."),
	PheromonesColonie = Def("SupportAura", "R", 12, 0.15, 25, 6, "Alerte et booste la vitesse de la famille à portée."),
	ForceHerculeenne = Def("Utility", "Passive", 0, 10, 0, 0, "Peut porter des proies/objets 10x plus lourds."),

	PattesRavisseuses = Def("Grab", "F", 8, 0, 8, 0, "Saisit et bloque une proie plus petite instantanément."),
	CamouflageFeuille = Def("Camouflage", "E", 15, 0, 0, 8, "Se fond dans le feuillage tant qu'immobile."),

	ProjectionMandibules = Def("Grab", "F", 10, 25, 7, 0, "Soulève un ennemi et le jette dans le vide depuis une branche."),
	CarapaceBlindee = Def("ArmorBuff", "Passive", 0, 0.2, 0, 0, "Réduit les dégâts reçus de 20% en permanence."),

	ChargeCorne = Def("LungeCharge", "E", 7, 30, 12, 0, "Charge frontale avec la corne, repousse la cible."),
	BouclierChitine = Def("ArmorBuff", "Passive", 0, 0.25, 0, 0, "Carapace la plus résistante du jeu (-25% dégâts)."),

	TisserToilePiege = Def("Utility", "E", 10, 0, 10, 45, "Construit une toile piège qui immobilise les joueurs qui la touchent.", "Stun", 2, 1),
	MorsureNeurotoxique = Def("StatusBite", "LeftClick", 4, 22, 0, 0, "Morsure venimeuse mortelle à petites doses.", "Poison", 8, 0.6),
	FilDeRappel = Def("Utility", "Passive", 0, 0, 0, 0, "Pose un fil de sécurité, aucune chute mortelle."),

	BondDePrecision = Def("Leap", "E", 6, 20, 16, 0, "Bond ciblé précis, touche même les proies en vol bas."),
	Vision360 = Def("Utility", "Passive", 0, 20, 0, 0, "Détecte les menaces dans toutes les directions (rayon)."),

	PincesBroyeuses = Def("Grab", "F", 9, 15, 6, 0, "Maintient l'ennemi avant le coup de dard."),
	DardVenimeux = Def("StatusBite", "E", 5, 20, 6, 0, "Coup de dard venimeux puissant.", "Poison", 10, 0.7),
	EnfouissementSable = Def("Utility", "Passive", 0, 1, 0, 0, "Peut se cacher/creuser dans le sable chaud."),

	SuperSautCatapulte = Def("Leap", "E", 5, 10, 22, 0, "Saute par-dessus les obstacles pour fuir ou surprendre."),
	CoupDePatteArriere = Def("LungeCharge", "R", 6, 15, 6, 0, "Coup de patte arrière éjecteur."),

	SaignementReflexeToxique = Def("ConeBurst", "E", 10, 8, 6, 0, "Liquide jaune toxique qui aveugle l'attaquant.", "Blind", 3, 1),
	RepliSousCarapace = Def("ArmorBuff", "R", 8, 0.6, 0, 3, "Repli total sous la carapace, très résistant mais immobile."),

	CanonAGlu = Def("Projectile", "E", 7, 6, 20, 0, "Tire une colle collante qui ralentit les ennemis.", "Glue", 5, 0.8),
	CreuserBois = Def("Utility", "Passive", 0, 1, 0, 0, "Peut creuser le bois pourri/mort."),

	EtreinteVenimeuse = Def("Grab", "E", 9, 24, 5, 0, "S'enroule autour de sa proie pour l'étouffer et l'empoisonner.", "Poison", 8, 0.5),
	SprintOndulant = Def("Utility", "Passive", 0, 1.3, 0, 0, "Vitesse de course augmentée de 30% en ligne droite."),

	MimetismeBrindille = Def("Camouflage", "Passive", 0, 0, 0, 0, "100% indiscernable d'une branche quand immobile."),
	AutotomieFuite = Def("Utility", "R", 30, 0, 0, 0, "Sacrifie une patte pour échapper à une prise (annule un Grab)."),

	-- ==========================================
	-- B. VOLANTS
	-- ==========================================
	RecoltePollenMiel = Def("SupportAura", "E", 10, 15, 10, 0, "Rapporte du pollen/miel qui soigne toute la ruche."),
	PiqureUltime = Def("StatusBite", "R", 20, 60, 4, 0, "Piqûre kamikaze: dégâts énormes + poison, mais la fléchit après usage.", "Poison", 6, 0.5),
	ChaleurDeRuche = Def("SupportAura", "Passive", 0, 4, 15, 0, "Les membres de la ruche à proximité gagnent +Température."),

	PiqueAssaut = Def("LungeCharge", "E", 6, 28, 18, 0, "Attaque en piqué à haute vitesse depuis les airs."),
	MarquagePheromoneCible = Def("Utility", "R", 15, 0, 20, 10, "Marque une cible pour appeler tout l'essaim à l'attaquer."),

	Vol360Stationnaire = Def("Utility", "Passive", 0, 1, 0, 0, "Vol avant/arrière/latéral à très haute vitesse."),
	InterceptionAerienne = Def("Grab", "F", 7, 20, 10, 0, "Capture les insectes en plein vol."),

	AilesToxiques = Def("ArmorBuff", "Passive", 0, 1, 0, 0, "Tout prédateur qui mord ce papillon subit du poison en retour.", "Poison", 6, 0.3),
	CourantAscendant = Def("Utility", "R", 12, 1.4, 0, 6, "Endurance de vol immense, plane sans dépense d'énergie."),

	SuccionDeSangXP = Def("StatusBite", "F", 8, 10, 4, 0, "Boit le sang d'un animal géant ou gros insecte pour un boost d'XP.", "Bleed", 4, 0.2),
	DetectionThermique = Def("Utility", "Passive", 0, 25, 0, 0, "Détecte la chaleur corporelle des cibles à travers le feuillage."),

	LanterneBioluminescente = Def("Light", "Passive", 0, 15, 0, 0, "Éclaire les grottes et la nuit autour de soi."),
	FlashAveuglant = Def("Light", "E", 10, 0, 8, 0, "Flash lumineux qui éblouit un prédateur proche.", "Blind", 3, 1),

	ReflexeEsquive = Def("Utility", "Passive", 0, 0.35, 0, 0, "Chance d'esquiver automatiquement une attaque."),
	OdoratCharogne = Def("Utility", "Passive", 0, 40, 0, 0, "Détecte les carcasses en décomposition à longue portée."),

	SprayChimiqueBouillant = Def("ConeBurst", "E", 9, 26, 7, 0, "Explosion chimique bouillante (100°C) tirée par l'abdomen.", "Stun", 1.5, 1),
	CarapaceResistante = Def("ArmorBuff", "Passive", 0, 0.2, 0, 0, "Carapace renforcée (-20% dégâts)."),

	CriSoniqueEtourdissant = Def("ConeBurst", "E", 14, 5, 14, 0, "Onde sonore qui étourdit tous les ennemis proches.", "Stun", 2.5, 1),
	VieSouterraineLarve = Def("Utility", "Passive", 0, 1, 0, 0, "La larve vit sous terre, invisible et protégée."),

	PiqureControleMental = Def("StatusBite", "R", 18, 14, 4, 0, "Inverse les touches de déplacement de la cible.", "InvertControls", 5, 1),
	VolAcrobatique = Def("Utility", "Passive", 0, 1.15, 0, 0, "Maniabilité en vol accrue de 15%."),

	-- ==========================================
	-- C. AQUATIQUES & SEMI-AQUATIQUES
	-- ==========================================
	PatinageSurface = Def("Utility", "Passive", 0, 1, 0, 0, "Glisse à haute vitesse sur la surface de l'eau."),
	RadarVibrationsEau = Def("Utility", "Passive", 0, 30, 0, 0, "Détecte tout insecte tombé à l'eau par vibration."),

	BulleOxygene = Def("Utility", "Passive", 0, 60, 0, 0, "Réserve d'oxygène portable, plongée longue durée."),
	MachoiresChassePoisson = Def("StatusBite", "LeftClick", 4, 24, 0, 0, "Mâchoires redoutables contre petits poissons en groupe."),

	TubaRespiratoire = Def("Utility", "Passive", 0, 999, 0, 0, "Respire sous l'eau indéfiniment via un siphon caudal."),
	CamouflageFeuilleMorte = Def("Camouflage", "Passive", 0, 0, 0, 0, "Camouflage permanent dans la vase."),
	PincesPiege = Def("Grab", "F", 8, 18, 5, 0, "Pattes avant en piège à loup."),

	NageSurLeDos = Def("Utility", "Passive", 0, 1, 0, 0, "Nage sur le dos, attaque par en dessous."),
	RostrePiqueur = Def("StatusBite", "E", 6, 22, 3, 0, "Rostre perforant, douloureux même pour les gros poissons.", "Bleed", 5, 0.3),

	FourreauArmureCailloux = Def("ArmorBuff", "Passive", 0, 0.8, 0, 0, "Fourreau de cailloux/brindilles (+80% défense)."),
	EnvolAdulte = Def("Utility", "Passive", 0, 1, 0, 0, "Devient volant une fois adulte."),

	ClocheDePlongeeToile = Def("Utility", "Passive", 0, 120, 0, 0, "Cloche d'air tissée sous l'eau : respire, stocke, pond."),
	MorsureSubaquatique = Def("StatusBite", "LeftClick", 5, 20, 0, 0, "Morsure venimeuse sous-marine.", "Poison", 6, 0.4),

	BranchiesAquatiques = Def("Utility", "Passive", 0, 999, 0, 0, "Respire sous l'eau illimité via des branchies."),
	FouisseurDeVase = Def("Camouflage", "R", 10, 0, 0, 10, "S'enterre dans la vase, introuvable."),

	ChasseurDePoisson = Def("Grab", "F", 11, 35, 6, 0, "Assez puissant pour chasser et tuer des poissons en solo."),
	EnzymesDigestives = Def("StatusBite", "E", 7, 30, 0, 0, "Injecte des enzymes digestives dévastatrices.", "Poison", 10, 0.8),
	SaisieGeante = Def("Grab", "Passive", 0, 0, 0, 0, "Prise surpuissante, difficile à briser en QTE."),

	-- ==========================================
	-- 5 ANIMAUX GÉANTS (pilotés par l'IA, Slot = "AI")
	-- ==========================================
	PiqueDuCiel = Def("LungeCharge", "AI", 8, 90, 40, 0, "L'oiseau fond du ciel à grande vitesse sur une proie à découvert."),
	LangueGrappinCamouflage = Def("Grab", "AI", 10, 55, 22, 0, "Langue grappin ultra-rapide qui colle et avale la proie."),
	AspirationEtSautHorsDeLEau = Def("ConeBurst", "AI", 12, 70, 14, 0, "Aspire les insectes proches puis saute hors de l'eau."),
	CarapaceInvulnerableDeFace = Def("ArmorBuff", "AI", 0, 1, 0, 0, "Invulnérable de face, vulnérable uniquement attaqué par l'arrière."),
	TremblementBranchesEtChuteDeFruits = Def("ConeBurst", "AI", 9, 20, 18, 0, "Fait trembler l'arbre: secoue les insectes grimpeurs et fait tomber des fruits."),
}

return AbilityCatalog
