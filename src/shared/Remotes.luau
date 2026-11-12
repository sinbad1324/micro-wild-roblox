--!strict
-- Remotes.luau
-- Contrat réseau partagé : liste unique des RemoteEvents de Micro Wild : Survival.
-- Le serveur crée ces instances au boot (EnsureServerRemotes). Le client n'écrit jamais
-- de statistiques lui-même : il envoie une INTENTION, le serveur valide et applique.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type RemoteEventName =
	-- Intentions client -> serveur
	"RequestUseAbility" -- (slot: "E" | "R")
	| "RequestLeftClickBite" -- ()
	| "RequestGrab" -- ()
	| "RequestGrabEscape" -- (): QTE mash pendant qu'on est agrippé
	| "RequestDig" -- (targetPosition: Vector3)
	| "RequestEatFood" -- (foodInstance: Instance)
	| "RequestDrink" -- (sourceInstance: Instance)
	| "RequestCreateNest" -- ()
	| "RequestJoinNest" -- (motherUserId: number)
	| "RequestLeaveNest" -- ()
	| "RequestSelectSpecies" -- (speciesId: string)
	| "RequestCarcassInteract" -- (carcassInstance: Instance)
	-- Diffusions serveur -> client
	| "NestListChanged" -- ({ NestSummary })
	| "AbilityFeedback" -- (success: boolean, reason: string?)
	| "GrabStateChanged" -- (isGrabbed: boolean, grabberName: string?)
	| "NotifyClient" -- (message: string, kind: string)
	| "KaijuFeastEvent" -- (animalName: string, position: Vector3)

local Remotes = {}

Remotes.FolderName = "Remotes"

Remotes.EventNames = {
	"RequestUseAbility",
	"RequestLeftClickBite",
	"RequestGrab",
	"RequestGrabEscape",
	"RequestDig",
	"RequestEatFood",
	"RequestDrink",
	"RequestCreateNest",
	"RequestJoinNest",
	"RequestLeaveNest",
	"RequestSelectSpecies",
	"RequestCarcassInteract",
	"NestListChanged",
	"AbilityFeedback",
	"GrabStateChanged",
	"NotifyClient",
	"KaijuFeastEvent",
}

function Remotes.GetFolder(): Folder
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
