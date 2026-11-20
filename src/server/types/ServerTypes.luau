--!strict
-- ServerTypes.luau
-- Types serveur pour Micro Wild : Survival

export type StageType = "Oeuf" | "Larve" | "Mue" | "Cocon" | "Adulte"

export type NestData = {
	OwnerUserId: number,
	FamilyId: string,
	SpeciesId: string,
	Position: Vector3,
	StoredFood: number,
	Children: { Player },
	Model: Model?, -- modèle 3D du nid (fourmilière, ruche, toile...)
	Style: string?, -- nom affiché du type de nid
	IsNpc: boolean?, -- nid d'une Maman PNJ (OwnerUserId = GameConstants.NPC_NEST_ID_BASE - n)
	DisplayName: string?, -- nom de la Maman PNJ (ex: "Reine Fourmi Rousse (PNJ)")
	MotherAlive: boolean?, -- false : Maman PNJ morte, le nid attend sa réapparition
	BuildPoints: number?, -- matériaux déposés (NestBuildingService)
	BuildLevel: number?, -- niveau de construction atteint (0..4)
	Materials: { [string]: number }?, -- stock de matériaux du nid (mode construction)
}

export type NestSummary = {
	OwnerUserId: number,
	OwnerName: string,
	SpeciesId: string,
	ChildCount: number,
	IsNpc: boolean?,
	MotherAlive: boolean?, -- nid PNJ : false si sa Maman est morte
}

export type PlayerSurvivalProfile = {
	SpeciesId: string,
	Stage: StageType,
	Growth: number,
	Hunger: number,
	Thirst: number,
	BodyTemperature: number,
	Oxygen: number,
}

export type CarcassStage = "Frais" | "Putrefaction" | "Pourrissement" | "Squelette"

export type CarcassData = {
	OwnerName: string,
	IsGiantAnimal: boolean,
	Stage: CarcassStage,
	SpawnedAt: number,
	Position: Vector3,
}

return nil
