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
}

export type NestSummary = {
	OwnerUserId: number,
	OwnerName: string,
	SpeciesId: string,
	ChildCount: number,
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
