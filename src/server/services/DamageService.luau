--!strict
-- DamageService.luau
-- Point d'entrée UNIQUE pour infliger des dégâts à un insecte-joueur ou à un animal.
-- Applique dans l'ordre : no-friendly-fire en famille, vulnérabilité de mue/cocon, armure passive,
-- invulnérabilité frontale (Crabe). N'importe quel système de combat/habileté DOIT appeler
-- DamageService.ApplyDamage plutôt que humanoid:TakeDamage directement, sinon ces règles sont
-- contournées. La mort est détectée via Humanoid.Died (voir PlayerLifecycleService), pas ici :
-- TakeDamage(0) reste un no-op et un humanoïde peut mourir par la faim/le froid sans passer par ce
-- module, donc Died est la seule source de vérité unique pour "ce personnage vient de mourir".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local GameConstants = require(ServerScriptService.constant.GameConstants)

local DamageService = {}

export type DamageSource = {
	AttackerUserId: number?,
	AbilityId: string?,
	IgnoreArmor: boolean?,
	FromBehind: boolean?, -- requis pour blesser un animal avec FrontInvulnerable=true (ex: Crabe)
	IsDamageOverTime: boolean?, -- poison/saignement : ne réinitialise pas l'attribution du kill
	Quiet: boolean?, -- dégâts en continu (prise) : petit chiffre côté client, sans flash ni secousse
}

local fxRemote: RemoteEvent? = nil

-- Multiplicateur de dégâts reçus d'une cible "marquée" par un Frelon (MarquagePheromoneCible).
local MARKED_DAMAGE_MULTIPLIER = 1.25

local function isSameFamily(attackerPlayer: Player, victimPlayer: Player): boolean
	local attackerFamily = attackerPlayer:GetAttribute("FamilyId")
	local victimFamily = victimPlayer:GetAttribute("FamilyId")
	return attackerFamily ~= nil and attackerFamily == victimFamily
end

local function getPassiveArmorReduction(speciesId: string): number
	local species = InsectData[speciesId]
	if not species then
		return 0
	end
	local totalReduction = 0
	for _, abilityId in ipairs(species.Abilities) do
		local definition = AbilityCatalog[abilityId]
		if definition and definition.Primitive == "ArmorBuff" and definition.Slot == "Passive" then
			totalReduction += definition.Power
		end
	end
	return math.clamp(totalReduction, 0, 0.75)
end

-- Retourne true si les dégâts ont été appliqués (false = bloqués par une règle ci-dessus).
function DamageService.ApplyDamage(victimCharacter: Model, rawAmount: number, source: DamageSource?): boolean
	local humanoid = victimCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local resolvedSource: DamageSource = source or {}
	local amount = rawAmount
	local victimPlayer = Players:GetPlayerFromCharacter(victimCharacter)

	if victimPlayer then
		local attackerPlayer: Player? = nil
		if resolvedSource.AttackerUserId then
			attackerPlayer = Players:GetPlayerByUserId(resolvedSource.AttackerUserId)
		end
		if attackerPlayer and isSameFamily(attackerPlayer, victimPlayer) then
			return false
		end

		local stage = victimPlayer:GetAttribute("Stage")
		if stage == "Mue" then
			amount *= GameConstants.MOLT_DAMAGE_MULTIPLIER
		elseif stage == "Cocon" then
			amount *= 0.3
		end

		if not resolvedSource.IgnoreArmor then
			local speciesId = (victimPlayer:GetAttribute("Species") :: string) or GameConstants.DEFAULT_SPECIES
			amount *= (1 - getPassiveArmorReduction(speciesId))
		end
	else
		-- Cible = un des 5 animaux géants (ou tout autre NPC) : vérifie l'invulnérabilité
		-- frontale posée par son IA (ex: Crabe.CarapaceInvulnerableDeFace).
		if victimCharacter:GetAttribute("FrontInvulnerable") == true and resolvedSource.FromBehind ~= true then
			return false
		end
	end

	-- Armure active temporaire (ex: Coccinelle "RepliSousCarapace") posée en attribut par
	-- CombatService : lue ici sans require pour garder ce module sans dépendance de service.
	local activeArmor = victimCharacter:GetAttribute("ActiveArmor") :: number?
	if activeArmor and not resolvedSource.IgnoreArmor then
		amount *= (1 - math.clamp(activeArmor, 0, 0.9))
	end
	if victimCharacter:GetAttribute("Marked") == true then
		amount *= MARKED_DAMAGE_MULTIPLIER
	end

	if resolvedSource.AttackerUserId then
		victimCharacter:SetAttribute("LastAttackerUserId", resolvedSource.AttackerUserId)
		if not resolvedSource.IsDamageOverTime then
			victimCharacter:SetAttribute("LastAttackAt", os.clock())
		end
	end

	amount = math.max(0, amount)
	humanoid:TakeDamage(amount)
	if amount > 0 then
		-- Chiffre de dégâts + flash d'impact rendus par les clients (CombatFxController).
		if not fxRemote then
			fxRemote = Remotes.Get("CombatFx")
		end
		local quiet = resolvedSource.IsDamageOverTime == true or resolvedSource.Quiet == true
		;(fxRemote :: RemoteEvent):FireAllClients("Hit", victimCharacter, amount, resolvedSource.AttackerUserId or 0, quiet)
	end
	return true
end

return DamageService
