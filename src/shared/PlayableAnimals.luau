--!strict
-- PlayableAnimals.luau
-- Animaux JOUABLES (espèces de catégorie "Animal" dans InsectData) : réutilisent les modèles 3D des
-- animaux de l'IA (AnimalModels), réduits à une taille jouable (~2-3x un insecte adulte au lieu de
-- l'échelle "kaiju" de l'IA). Utilisé côté serveur (corps du joueur, InsectVisualService) et côté
-- client (aperçu du menu, CreatureViewport).

local AnimalModels = require(script.Parent.AnimalModels)

export type Entry = {
	Build: () -> Model,
	Length: number, -- plus grande dimension horizontale à l'échelle 1 (studs)
}

local PlayableAnimals = {}

local ENTRIES: { [string]: Entry } = {
	Oiseau = { Build = function() return AnimalModels.BuildBird(100) end, Length = 8 },
	Cameleon = { Build = function() return AnimalModels.BuildChameleon(100) end, Length = 9 },
	PoissonRouge = { Build = function() return AnimalModels.BuildGoldfish(100, 1, "Poisson Rouge") end, Length = 7 },
	Crabe = { Build = function() return AnimalModels.BuildCrab(100) end, Length = 7 },
	Ecureuil = { Build = function() return AnimalModels.BuildSquirrel(100) end, Length = 9 },
}

function PlayableAnimals.Get(speciesId: string): Entry?
	return ENTRIES[speciesId]
end

-- Modèle de l'animal mis à l'échelle (plus grande dimension horizontale = Length * scale), sans
-- son Humanoid d'IA. Le modèle garde sa PrimaryPart "Root" (repère : -Z = avant, Y = haut).
function PlayableAnimals.BuildScaled(speciesId: string, scale: number): Model?
	local entry = ENTRIES[speciesId]
	if not entry then
		return nil
	end
	local model = entry.Build()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	local _, size = model:GetBoundingBox()
	local current = math.max(size.X, size.Z, 0.1)
	local factor = entry.Length * scale / current
	model:ScaleTo(model:GetScale() * factor)
	-- ScaleTo ne met pas les attributs à l'échelle : pivots des membres (AnimalAnimationController).
	for _, descendant in ipairs(model:GetDescendants()) do
		local rest = descendant:GetAttribute("RestC0")
		if typeof(rest) == "CFrame" then
			descendant:SetAttribute("RestC0", rest.Rotation + rest.Position * factor)
		end
	end
	return model
end

return PlayableAnimals
