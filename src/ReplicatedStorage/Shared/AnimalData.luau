--!strict
-- AnimalData.luau
-- Configuration des 5 petits animaux géants (Oiseau, Caméléon, Poisson Rouge, Crabe, Écureuil)

export type AnimalInfo = {
	Id: string,
	Name: string,
	Habitat: string,
	MaxHealth: number,
	AttackDamage: number,
	CanBeHunted: boolean,
	MeatReward: number,
	SpecialMechanic: string,
	Description: string,
}

local AnimalData: { [string]: AnimalInfo } = {
	Oiseau = {
		Id = "Oiseau",
		Name = "Rouge-Gorge / Martin-Pêcheur",
		Habitat = "Grand Chêne & Prairie",
		MaxHealth = 1500,
		AttackDamage = 120,
		CanBeHunted = false, -- Trop grand, mais peut être repoussé en essaim
		MeatReward = 0,
		SpecialMechanic = "PiqueDuCiel",
		Description = "Patrouille depuis les branches et fond sur les insectes non camouflés.",
	},
	Cameleon = {
		Id = "Cameleon",
		Name = "Caméléon",
		Habitat = "Branches du Grand Chêne",
		MaxHealth = 1200,
		AttackDamage = 95,
		CanBeHunted = true,
		MeatReward = 500,
		SpecialMechanic = "LangueGrappinCamouflage",
		Description = "Change de couleur sur l'écorce et tire sa langue collante à longue distance.",
	},
	PoissonRouge = {
		Id = "PoissonRouge",
		Name = "Poisson Rouge (& Bancs d'alevins)",
		Habitat = "La Mare & Le Ruisseau",
		MaxHealth = 800, -- Les petits poissons ont 120 PV et sont chassables en solo
		AttackDamage = 80,
		CanBeHunted = true,
		MeatReward = 350,
		SpecialMechanic = "AspirationEtSautHorsDeLEau",
		Description = "Règne sous l'eau mais peut être chassé par les punaises d'eau géantes et les dytiques.",
	},
	Crabe = {
		Id = "Crabe",
		Name = "Crabe de Rivière",
		Habitat = "Berges rocheuses & Fond de la mare",
		MaxHealth = 1400,
		AttackDamage = 110,
		CanBeHunted = true,
		MeatReward = 450,
		SpecialMechanic = "CarapaceInvulnerableDeFace",
		Description = "Blindé de face avec des pinces mortelles, vulnérable aux attaques en colonie par l'arrière.",
	},
	Ecureuil = {
		Id = "Ecureuil",
		Name = "Écureuil Roux",
		Habitat = "Grand Chêne",
		MaxHealth = 1800,
		AttackDamage = 90,
		CanBeHunted = false,
		MeatReward = 0,
		SpecialMechanic = "TremblementBranchesEtChuteDeFruits",
		Description = "Fait trembler tout l'arbre en sautant et fait tomber des glands et morceaux de fruits.",
	},
}

return AnimalData
