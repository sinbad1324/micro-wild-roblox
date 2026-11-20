--!strict
-- Remotes.luau
-- Contrat réseau partagé : liste unique des RemoteEvents de Micro Wild : Survival.
-- Le serveur crée ces instances au boot (EnsureServerRemotes). Le client n'écrit jamais
-- de statistiques lui-même : il envoie une INTENTION, le serveur valide et applique.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type RemoteEventName =
	-- Intentions client -> serveur
	"RequestUseAbility" -- (slot: "E" | "R", aim: Vector3?)
	| "RequestWebLine" -- (anchor: Vector3?): fil de balancier des araignées (nil = lâché), visuel serveur
	| "RequestNestBuild" -- ("Place", pieceId: string, cframe: CFrame) | ("Remove", piece: Model): mode construction
	| "RequestLeftClickBite" -- ()
	| "RequestGrab" -- ()
	| "RequestGrabEscape" -- (): QTE mash pendant qu'on est agrippé
	| "RequestDig" -- (targetPosition: Vector3, strength: number 1..3)
	| "RequestBoost" -- (active: boolean): boost de vitesse maintenu (marche, vol, nage)
	| "RequestCreateNest" -- ()
	| "RequestJoinNest" -- (motherUserId: number)
	| "RequestLeaveNest" -- ()
	| "RequestSelectSpecies" -- (speciesId: string)
	| "RequestSpawnAsMother" -- (speciesId: string): naître adulte à 100% et fonder sa colonie
	| "AdminCommand" -- (command: "Grow" | "Adult" | "Fill" | "NextSeason", amount: number?): tests, admins seulement
	-- Diffusions serveur -> client
	| "NestListChanged" -- ({ NestSummary })
	| "AbilityFeedback" -- (success: boolean, reason: string?)
	| "GrabStateChanged" -- (isGrabbed: boolean, grabberName: string?, escapePressesNeeded: number?)
	| "NotifyClient" -- (message: string, kind: string)
	| "KaijuFeastEvent" -- (animalName: string, position: Vector3)
	| "AbilityCast" -- (slot: string, primitive: string, cooldown: number, range: number, extra: Vector3?): mouvement/VFX local
	| "CameraShake" -- (intensity: number, duration: number)
	-- VFX de combat rendus par chaque client (CombatFxController), diffusés à tous. (kind, a, b, c, d) :
	--   "Hit"    (victim: Model, amount: number, attackerUserId: number, quiet: boolean)
	--   "Proj"   (from: Vector3, to: Vector3, color: Color3, travelSeconds: number)
	--   "Flash"  (position: Vector3, color: Color3, size: number)
	--   "Cone"   (origin: Vector3, lookTimesRange: Vector3, color: Color3)
	--   "Tele"   (caster: Model, primitive: "Lunge" | "Leap", lookTimesRange | landing: Vector3, windupSeconds: number)
	--   "Web"    (web: BasePart)  -- obsolète : les toiles sont tissées via le tag "SpiderWeb"
	--   "Silk"   (from: Vector3, to: Vector3, travelSeconds: number, caster: Model?): fil de soie lancé
	--   "Status" (victim: Model, status: string, duration: number)
	| "CombatFx"

local Remotes = {}

Remotes.FolderName = "Remotes"

Remotes.EventNames = {
	"RequestUseAbility",
	"RequestLeftClickBite",
	"RequestGrab",
	"RequestGrabEscape",
	"RequestDig",
	"RequestBoost",
	"RequestWebLine",
	"RequestNestBuild",
	"RequestCreateNest",
	"RequestJoinNest",
	"RequestLeaveNest",
	"RequestSelectSpecies",
	"RequestSpawnAsMother",
	"AdminCommand",
	"NestListChanged",
	"AbilityFeedback",
	"GrabStateChanged",
	"NotifyClient",
	"KaijuFeastEvent",
	"AbilityCast",
	"CameraShake",
	"CombatFx",
}

function Remotes.GetFolder(): Folder
	-- Côté client, ne JAMAIS créer le dossier : un dossier local vide masquerait celui du serveur
	-- (pas encore répliqué) et chaque Remotes.Get échouerait après 15 s.
	if game:GetService("RunService"):IsClient() then
		return ReplicatedStorage:WaitForChild(Remotes.FolderName) :: Folder
	end
	local folder = ReplicatedStorage:FindFirstChild(Remotes.FolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Remotes.FolderName
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

-- À appeler une seule fois, côté serveur, avant tout le reste (ServerBootstrap).
function Remotes.EnsureServerRemotes()
	local folder = Remotes.GetFolder()
	for _, name in ipairs(Remotes.EventNames) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
end

-- Utilisable des deux côtés une fois les remotes garantis créés par le serveur.
function Remotes.Get(name: RemoteEventName): RemoteEvent
	local folder = Remotes.GetFolder()
	local remote = folder:WaitForChild(name, 15)
	assert(remote ~= nil and remote:IsA("RemoteEvent"), "Remote invalide ou introuvable: " .. name)
	return remote :: RemoteEvent
end

return Remotes
