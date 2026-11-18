--!strict
-- CameraController.luau
-- Ressenti caméra adapté à des personnages minuscules (client uniquement, par-dessus la caméra Roblox) :
--   * zoom max proportionnel à character:GetScale() (un oeuf ne regarde pas la carte à 128 studs)
--   * suivi vertical lissé : les bosses du terrain et les petits sauts ne secouent plus la vue
--   * léger élargissement du FOV quand on va plus vite que sa marche (ruée, vol, glissade)
--   * en tunnel (plafond proche), zoom max réduit : la caméra reste près du corps au lieu de
--     traverser la roche
-- N'écrit jamais Humanoid.CameraOffset (propriété de StatusEffectController) et laisse passer le
-- "punch" FOV de CombatFxController (on attend que son tween se termine avant de reprendre la main).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CameraController = {}

local player = Players.LocalPlayer
local started = false

local BASE_FOV = 70
local MAX_FOV_KICK = 8 -- degrés en plus à pleine vitesse
local FOV_RATE = 6 -- 1/s : vitesse de rapprochement du FOV cible
local ZOOM_MAX_PER_SCALE = 25 -- recul max (studs) par unité d'échelle du personnage
local ZOOM_MAX_FLOOR = 6
local TUNNEL_ZOOM_PER_SCALE = 5
local TUNNEL_ZOOM_FLOOR = 2
local TUNNEL_CEILING_PER_SCALE = 8 -- plafond plus proche que ça (au-dessus de la racine) = tunnel
local FOLLOW_RATE = 12 -- 1/s : rattrapage vertical
local FOLLOW_MAX_LAG_PER_SCALE = 0.4 -- retard vertical max (studs par unité d'échelle)
local PROBE_INTERVAL = 0.25 -- s entre deux sondages plafond/échelle (pas de raycast par frame)
local TUNNEL_EXIT_PROBES = 3 -- sondages dégagés consécutifs avant de sortir du mode tunnel (hystérésis)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true -- feuilles décoratives/déclencheurs ne comptent pas comme plafond

local filteredCharacter: Model? = nil
local probeClock = PROBE_INTERVAL
local inTunnel = false
local clearProbes = 0
local savedZoom: number? = nil -- recul caméra juste avant d'entrer en tunnel
local restoreMinZoom: number? = nil -- CameraMinZoomDistance à remettre au sondage suivant
local scale = 1
local appliedMaxZoom = -1
local smoothRootY: number? = nil
local lastFov = BASE_FOV -- dernière valeur écrite par ce module
local seenFov = BASE_FOV -- valeur observée à la frame précédente

local function applyZoomLimits()
	local maxZoom = if inTunnel
		then math.max(TUNNEL_ZOOM_PER_SCALE * scale, TUNNEL_ZOOM_FLOOR)
		else math.max(ZOOM_MAX_PER_SCALE * scale, ZOOM_MAX_FLOOR)
	if math.abs(maxZoom - appliedMaxZoom) < 0.05 then
		return
	end
	appliedMaxZoom = maxZoom
	player.CameraMaxZoomDistance = maxZoom
end

local function probe(character: Model, root: BasePart)
	if character ~= filteredCharacter then
		filteredCharacter = character
		rayParams.FilterDescendantsInstances = { character }
		smoothRootY = nil
	end
	-- Le zoom min relevé à la sortie du tunnel a déjà repoussé la caméra : on le rend au joueur.
	if restoreMinZoom ~= nil then
		player.CameraMinZoomDistance = restoreMinZoom
		restoreMinZoom = nil
	end
	scale = math.max(character:GetScale(), 0.1)
	local hit = workspace:Raycast(root.Position, Vector3.new(0, TUNNEL_CEILING_PER_SCALE * scale, 0), rayParams)
	local exiting = false
	if hit then
		clearProbes = 0
		if not inTunnel then
			inTunnel = true
			local camera = workspace.CurrentCamera
			savedZoom = if camera then (camera.CFrame.Position - camera.Focus.Position).Magnitude else nil
		end
	elseif inTunnel then
		clearProbes += 1
		if clearProbes >= TUNNEL_EXIT_PROBES then
			inTunnel = false
			exiting = true
		end
	end
	applyZoomLimits()
	-- Roblox a clampé le zoom en entrant : sans ça la caméra resterait collée après le tunnel.
	if exiting and savedZoom ~= nil then
		local current = player.CameraMinZoomDistance
		local target = math.min(savedZoom, appliedMaxZoom)
		if target > current then
			restoreMinZoom = current
			player.CameraMinZoomDistance = target
		end
		savedZoom = nil
	end
end

local function updateFov(camera: Camera, kickTarget: number, alpha: number)
	local current = camera.FieldOfView
	-- Quelqu'un d'autre anime le FOV (punch de CombatFx) : on attend qu'il se stabilise.
	if math.abs(current - lastFov) > 0.01 and math.abs(current - seenFov) > 0.001 then
		seenFov = current
		return
	end
	local nextFov = current + (BASE_FOV + kickTarget - current) * alpha
	if math.abs(nextFov - current) > 0.01 then
		camera.FieldOfView = nextFov
	end
	lastFov = camera.FieldOfView
	seenFov = lastFov
end

-- Appelé juste APRÈS la caméra Roblox : on retouche la position qu'elle vient de calculer
-- sans changer sa rotation (sa LookVector reste donc la sienne à la frame suivante).
local function onRender(dt: number)
	local camera = workspace.CurrentCamera
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if humanoid then humanoid.RootPart else nil
	if not camera or not character or not humanoid or not root then
		smoothRootY = nil
		return
	end

	probeClock += dt
	if probeClock >= PROBE_INTERVAL then
		probeClock = 0
		probe(character, root)
	end

	-- FOV : élargi seulement au-delà de la vitesse de marche normale.
	local walk = math.max(humanoid.WalkSpeed, 1)
	local velocity = root.AssemblyLinearVelocity
	local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	local kickTarget = math.clamp((horizontalSpeed - walk * 1.15) / walk, 0, 1) * MAX_FOV_KICK
	updateFov(camera, kickTarget, 1 - math.exp(-FOV_RATE * dt))

	-- Suivi vertical lissé (désactivé en tunnel : un retard y ferait passer la caméra sous le sol).
	local rootY = root.Position.Y
	local maxLag = FOLLOW_MAX_LAG_PER_SCALE * scale
	local y = smoothRootY
	if y == nil or inTunnel or math.abs(rootY - y) > maxLag * 6 then
		smoothRootY = rootY -- respawn, téléportation, grande chute : pas de traînée
		return
	end
	y += (rootY - y) * (1 - math.exp(-FOLLOW_RATE * dt))
	y = math.clamp(y, rootY - maxLag, rootY + maxLag)
	smoothRootY = y
	local offset = y - rootY
	if math.abs(offset) > 0.001 then
		camera.CFrame = camera.CFrame + Vector3.new(0, offset, 0)
	end
end

function CameraController.Start()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep("MicroWildCamera", Enum.RenderPriority.Camera.Value + 1, onRender)
end

return CameraController
