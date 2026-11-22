--!strict
-- EvolutionTraits.luau
-- Deux évolutions en plus des stades / niveaux / mutations :
--   * BRANCHES : aux niveaux 5, 10 et 15, on choisit 1 trait parmi les 3 de son mode de vie
--     (chasseur, brouteur, travailleur, opportuniste). Reprendre le même trait le renforce.
--     Rangs = attributs joueur "Trait_<Id>" ; choix en attente = "PendingTraitChoices".
--   * CASTES (insectes sociaux) : attribuée à l'âge adulte selon la vie menée (attribut "Caste").
--     Reine = larve nourrie à la gelée royale (souvent nourrie au nid ; UNE héritière vivante par
--     colonie, la première adulte) ou fondatrice sans colonie :
--     seule caste sociale qui peut fonder une colonie. Sinon Ouvrière (a surtout travaillé) ou Soldat.
-- Partagé : le serveur applique et valide, le client affiche les choix.

local InsectData = require(script.Parent.InsectData)

export type XpSource = "Chasse" | "Manger" | "Travail"
export type Bonus = { Damage: number?, Armor: number?, Speed: number?, Health: number?, Xp: number? }
export type Trait = { Id: string, Name: string, Icon: string, Description: string, Bonus: Bonus }
export type Totals = { Damage: number, Armor: number, Speed: number, Health: number, Xp: number }

local EvolutionTraits = {}

EvolutionTraits.BRANCH_LEVELS = { 5, 10, 15 }
EvolutionTraits.ROYAL_JELLY_FEEDINGS = 8 -- repas au nid (larve) pour devenir Reine

-- Insectes sociaux : ils grandissent en travaillant pour la colonie et ont des castes.
local SOCIAL: { [string]: boolean } = {
	FourmiRousse = true, TermiteSoldat = true, AbeilleMellifere = true, FrelonAsiatique = true, GuepeEmeraude = true,
}

function EvolutionTraits.IsSocial(speciesId: string): boolean
	return SOCIAL[speciesId] == true
end

-- Activité principale d'une espèce (nil = omnivore polyvalent).
function EvolutionTraits.MainXpSource(speciesId: string): XpSource?
	if SOCIAL[speciesId] then
		return "Travail"
	end
	local species = InsectData[speciesId]
	local diet = species and species.Diet
	return if diet == "Carnivore" then "Chasse" elseif diet == "Herbivore" then "Manger" else nil
end

local function trait(id: string, name: string, icon: string, description: string, bonus: Bonus): Trait
	return { Id = id, Name = name, Icon = icon, Description = description, Bonus = bonus }
end

-- 3 branches par mode de vie (clé = activité principale, "Polyvalent" pour les omnivores).
local BRANCHES: { [string]: { Trait } } = {
	Chasse = {
		trait("Crocs", "Crocs acérés", "🦷", "+10 % de dégâts", { Damage = 0.10 }),
		trait("CarapaceChasseur", "Carapace de chasseur", "🛡", "-8 % de dégâts reçus", { Armor = 0.08 }),
		trait("Traqueur", "Traqueur", "👣", "+6 % de vitesse, +15 % d'XP", { Speed = 0.06, Xp = 0.15 }),
	},
	Manger = {
		trait("EstomacVorace", "Estomac vorace", "🍃", "+20 % d'XP, +5 % de vie", { Xp = 0.20, Health = 0.05 }),
		trait("CorpsRobuste", "Corps robuste", "💪", "+12 % de vie", { Health = 0.12 }),
		trait("FuiteRapide", "Fuite rapide", "💨", "+8 % de vitesse", { Speed = 0.08 }),
	},
	Travail = {
		trait("Mandibules", "Mandibules puissantes", "🦷", "+10 % de dégâts", { Damage = 0.10 }),
		trait("Infatigable", "Infatigable", "⚒", "+20 % d'XP", { Xp = 0.20 }),
		trait("Exosquelette", "Exosquelette épais", "🛡", "+10 % de vie, -5 % de dégâts reçus", { Health = 0.10, Armor = 0.05 }),
	},
	Polyvalent = {
		trait("Opportuniste", "Opportuniste", "🎲", "+12 % d'XP", { Xp = 0.12 }),
		trait("Resistant", "Résistant", "💪", "+10 % de vie", { Health = 0.10 }),
		trait("Agile", "Agile", "💨", "+6 % de vitesse", { Speed = 0.06 }),
	},
}

local byId: { [string]: Trait } = {}
for _, list in pairs(BRANCHES) do
	for _, t in ipairs(list) do
		byId[t.Id] = t
	end
end

export type Caste = { Id: string, Name: string, Icon: string, Description: string, CanFound: boolean, Bonus: Bonus }
EvolutionTraits.CASTES = {
	Reine = { Id = "Reine", Name = "Reine", Icon = "👑", Description = "Peut fonder une colonie. +30 % de vie, -10 % de vitesse.", CanFound = true, Bonus = { Health = 0.30, Speed = -0.10 } },
	Ouvriere = { Id = "Ouvriere", Name = "Ouvrière", Icon = "⚒", Description = "+25 % d'XP, +5 % de vitesse.", CanFound = false, Bonus = { Xp = 0.25, Speed = 0.05 } },
	Soldat = { Id = "Soldat", Name = "Soldat", Icon = "⚔", Description = "+15 % de dégâts, -10 % de dégâts reçus.", CanFound = false, Bonus = { Damage = 0.15, Armor = 0.10 } },
} :: { [string]: Caste }

function EvolutionTraits.BranchFor(speciesId: string): { Trait }
	return BRANCHES[EvolutionTraits.MainXpSource(speciesId) or "Polyvalent"]
end

function EvolutionTraits.Get(traitId: string): Trait?
	return byId[traitId]
end

function EvolutionTraits.All(): { [string]: Trait }
	return byId
end

-- Une caste sociale non-Reine ne fonde pas de colonie (les autres espèces ne sont pas concernées).
function EvolutionTraits.CanFoundColony(player: Player): boolean
	local caste = EvolutionTraits.CASTES[(player:GetAttribute("Caste") :: string?) or ""]
	return caste == nil or caste.CanFound
end

local function addBonus(totals: Totals, bonus: Bonus, times: number)
	totals.Damage += (bonus.Damage or 0) * times
	totals.Armor += (bonus.Armor or 0) * times
	totals.Speed += (bonus.Speed or 0) * times
	totals.Health += (bonus.Health or 0) * times
	totals.Xp += (bonus.Xp or 0) * times
end

-- Somme des bonus des traits choisis et de la caste (lu sur les attributs répliqués).
function EvolutionTraits.Totals(player: Player): Totals
	local totals: Totals = { Damage = 0, Armor = 0, Speed = 0, Health = 0, Xp = 0 }
	for id, t in pairs(byId) do
		local rank = player:GetAttribute("Trait_" .. id)
		if type(rank) == "number" and rank > 0 then
			addBonus(totals, t.Bonus, rank)
		end
	end
	local caste = EvolutionTraits.CASTES[(player:GetAttribute("Caste") :: string?) or ""]
	if caste then
		addBonus(totals, caste.Bonus, 1)
	end
	totals.Armor = math.clamp(totals.Armor, 0, 0.5)
	return totals
end

return EvolutionTraits
