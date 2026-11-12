--!strict
-- ServerTypes.luau
-- Types serveur pour Micro Wild : Survival

export type StageType = "Oeuf" | "Larve" | "Cocon" | "Adulte"

export type NestData = {
	OwnerUserId: number,
	SpeciesId: string,
	Position: Vector3,
	StoredFood: number,
	Children: { Player },
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

return nil
