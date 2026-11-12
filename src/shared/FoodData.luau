--!strict
-- FoodData.luau
-- Contrat partagé : types de nourriture consommables (nœuds du monde, carcasses, champignons).
-- Les générateurs de monde, le système de carcasses et le système de repas s'appuient TOUS sur
-- cette table pour décider qui peut manger quoi, plutôt que de coder la compatibilité ailleurs.

export type DietType = "Herbivore" | "Carnivore" | "Omnivore"

export type FoodTypeId =
	"Feuille" | "Pollen" | "Nectar" | "Seve" | "Bois"
	| "Insecte" | "Larve" | "Poisson" | "Sang"
	| "Fruit" | "Graine" | "Miette" | "Champignon"
	| "CarcasseFraiche" | "CarcassePutride"

export type FoodInfo = {
	Diets: { DietType },
	NutritionValue: number, -- points de Faim rendus (0..100)
	ToxicForStrictCarnivore: boolean?, -- vrai pour la viande en putréfaction avancée
}

local FoodTable: { [string]: FoodInfo } = {
	Feuille = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 10 },
	Pollen = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 8 },
	Nectar = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 12 },
	Seve = { Diets = { "Herbivore" }, NutritionValue = 14 },
	Bois = { Diets = { "Herbivore" }, NutritionValue = 6 },
	Insecte = { Diets = { "Carnivore", "Omnivore" }, NutritionValue = 20 },
	Larve = { Diets = { "Carnivore", "Omnivore" }, NutritionValue = 18 },
	Poisson = { Diets = { "Carnivore", "Omnivore" }, NutritionValue = 30 },
	Sang = { Diets = { "Carnivore", "Omnivore" }, NutritionValue = 15 },
	Fruit = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 22 },
	Graine = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 10 },
	Miette = { Diets = { "Omnivore" }, NutritionValue = 6 },
	Champignon = { Diets = { "Herbivore", "Omnivore" }, NutritionValue = 16 },
	-- Carcasse fraîche : valeur max pour carnivores/sanguinaires.
	CarcasseFraiche = { Diets = { "Carnivore", "Omnivore" }, NutritionValue = 35 },
	-- Début de putréfaction : toxique pour les carnivores stricts, mais 2x la valeur pour
	-- les nécrophages/omnivores (GDD section 7.B).
	CarcassePutride = { Diets = { "Omnivore" }, NutritionValue = 50, ToxicForStrictCarnivore = true },
}

local FoodData = {
	Table = FoodTable,
}

function FoodData.Get(foodTypeId: string): FoodInfo?
	return FoodTable[foodTypeId]
end

function FoodData.CanEat(dietType: DietType, foodTypeId: string): boolean
	local info = FoodTable[foodTypeId]
	if not info then
		return false
	end
	for _, diet in ipairs(info.Diets) do
		if diet == dietType then
			return true
		end
	end
	return false
end

return FoodData
