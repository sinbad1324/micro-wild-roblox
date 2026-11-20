--!strict
-- DigService.luau
-- Creusement dynamique du sol (GDD §7.A) : les insectes fouisseurs (GameConstants.DIGGER_SPECIES)
-- sculptent des galeries dans le Terrain avec la touche C. Un tunnel creusé est automatiquement
-- un abri (SurvivalService détecte le Terrain au-dessus de la tête).
--
-- API aussi utilisée par l'IA des animaux (terriers du Crabe, trous de l'Écureuil/Caméléon) :
--   DigService.CarveHole(position, radius)

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local NestBuildingService = require(ServerScriptService.services.NestBuildingService)

local DigService = {}

-- Le client envoie une petite demande toutes les ~0.12 s (AbilityController) avec une FORCE 1..3 :
-- une seule sculpture par demande, reliée à la précédente par un cylindre -> galerie continue et lisse.
local DIG_MIN_INTERVAL = 0.07 -- ~0.6x la cadence client : la gigue réseau ne fait pas sauter de demande
local DIG_RADII = { 2.2, 3.2, 4.4 } -- rayon (studs, échelle 1) par force : fine / moyenne / forte
local MIN_RADIUS = 2 -- en dessous, le Terrain (voxels de 4 studs) ne creuse presque rien
local BODY_MARGIN = 0.6 -- le trou laisse toujours passer le corps (sinon on creuse un trou où on ne rentre pas)
local BRIDGE_MAX_AGE = 0.5 -- relie deux sculptures récentes et proches (jamais après une téléportation)
local SHELL_MARGIN = 2 -- les parois de FillBall s'arrêtent ~2 studs au-delà du rayon (centres de voxels)
-- La pelouse en surface garde son herbe : seules les parois SOUS le sol deviennent de la terre.
local LAWN_KEEP_Y = GameConstants.GROUND_TOP_Y - 4
local FEEDBACK_PERIOD = 0.5
local TUNNEL_COUNT_PERIOD = 0.5 -- "TunnelsDug" : au plus un point par demi-seconde sous terre
local DIG_FX_SECONDS = 0.3
local MAX_REACH = 9
local MIN_DIG_Y = WorldLayout.GROUND_BOTTOM_Y + 4 -- ne jamais percer le fond de la carte

local GRASSY: { [Enum.Material]: boolean } = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
}

local lastDig: { [Player]: number } = {}
local lastCarvePos: { [Player]: Vector3 } = {}
local lastCarveAt: { [Player]: number } = {}
local lastTunnelCount: { [Player]: number } = {}
local lastFeedback: { [Player]: number } = {}

-- Un refus par demi-seconde au plus (C maintenu = ~8 demandes/s).
local function refuse(player: Player, reason: string)
	local now = os.clock()
	if now - (lastFeedback[player] or 0) >= FEEDBACK_PERIOD then
		lastFeedback[player] = now
		Remotes.Get("AbilityFeedback"):FireClient(player, false, reason)
	end
end
-- Un émetteur de terre par fouisseur, déplacé et allumé/éteint (Enabled est répliqué : aucun code client).
local digFxParts: { [Player]: Part } = {}
local digFxStopAt: { [Player]: number } = {}

-- La mare et le ruisseau ne se creusent pas (FillBall en Air viderait l'eau).
local function isNearWater(position: Vector3, margin: number): boolean
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			local relative = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size * 0.5
			if math.abs(relative.X) <= half.X + margin and math.abs(relative.Z) <= half.Z + margin then
				return true
			end
		end
	end
	return false
end

local function playDigFx(player: Player, position: Vector3)
	local part = digFxParts[player]
	if not part or not part.Parent then
		part = Instance.new("Part")
		part.Name = "DigFx"
		part.Size = Vector3.one
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Spoil"
		emitter.Enabled = false
		emitter.Color = ColorSequence.new(Color3.fromRGB(105, 80, 55))
		emitter.Size = NumberSequence.new(0.5, 0.1)
		emitter.Lifetime = NumberRange.new(0.4, 0.8)
		emitter.Rate = 40
		emitter.Speed = NumberRange.new(6, 12)
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.Acceleration = Vector3.new(0, -40, 0)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Parent = part
		part.Parent = workspace
		digFxParts[player] = part
	end
	local emitter = part:FindFirstChild("Spoil")
	if not emitter or not emitter:IsA("ParticleEmitter") then
		return
	end
	part.CFrame = CFrame.new(position)
	emitter.Enabled = true
	local stopAt = os.clock() + DIG_FX_SECONDS
	digFxStopAt[player] = stopAt
	task.delay(DIG_FX_SECONDS, function()
		-- Une demande plus récente a prolongé l'effet : c'est elle qui l'éteindra.
		if digFxStopAt[player] == stopAt then
			emitter.Enabled = false
		end
	end)
end

local function canCarve(position: Vector3, radius: number): boolean
	return position.Y - radius >= MIN_DIG_Y and not isNearWater(position, radius + 2)
end

function DigService.CarveHole(position: Vector3, radius: number): boolean
	if not canCarve(position, radius) then
		return false
	end
	workspace.Terrain:FillBall(position, radius, Enum.Material.Air)
	return true
end

-- Le sol est entièrement en Grass (WorldGenerationService) : chaque paroi creusée serait de l'herbe
-- (texture verte + brins d'herbe qui poussent au fond des galeries). On repeint la coque en terre.
-- À appeler APRÈS la sculpture (sinon WriteVoxels rebouche le trou avec les anciennes occupations).
local function dirtShell(center: Vector3, reach: number)
	local terrain = workspace.Terrain
	local region = Region3.new(center - Vector3.one * reach, center + Vector3.one * reach):ExpandToGrid(4)
	local materials, occupancies = terrain:ReadVoxels(region, 4)
	local size: Vector3 = materials.Size
	local corner = region.CFrame.Position - region.Size * 0.5
	local changed = false
	for x = 1, size.X do
		local materialPlane, occupancyPlane = materials[x], occupancies[x]
		for y = 1, size.Y do
			local materialRow, occupancyRow = materialPlane[y], occupancyPlane[y]
			for z = 1, size.Z do
				if GRASSY[materialRow[z]] and occupancyRow[z] > 0 then
					local voxel = corner + Vector3.new(x - 0.5, y - 0.5, z - 0.5) * 4
					if voxel.Y < LAWN_KEEP_Y and (voxel - center).Magnitude <= reach then
						materialRow[z] = Enum.Material.Ground
						changed = true
					end
				end
			end
		end
	end
	-- Pas d'écriture inutile : chaque écriture de Terrain est répliquée à tous les clients.
	if changed then
		terrain:WriteVoxels(region, 4, materials, occupancies)
	end
end

local function onDig(player: Player, targetPosition: unknown, strength: unknown)
	if typeof(targetPosition) ~= "Vector3" then
		return
	end
	local target = targetPosition :: Vector3
	-- NaN / infini envoyés par un exploit : jamais transmis à une écriture de Terrain.
	for _, component in ipairs({ target.X, target.Y, target.Z }) do
		if component ~= component or math.abs(component) == math.huge then
			return
		end
	end
	-- Force 1..3 (jamais un rayon venu du client) ; absente / invalide = moyenne.
	local level = 2
	if type(strength) == "number" and strength == strength and math.abs(strength) ~= math.huge then
		level = math.clamp(math.floor(strength), 1, #DIG_RADII)
	end
	local now = os.clock()
	if lastDig[player] and now - lastDig[player] < DIG_MIN_INTERVAL then
		return
	end
	lastDig[player] = now
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	if not GameConstants.DIGGER_SPECIES[speciesId] then
		refuse(player, "Votre espèce ne sait pas creuser.")
		return
	end
	local stage = player:GetAttribute("Stage")
	if stage ~= "Adulte" and stage ~= "Larve" then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	-- Ne jamais faire confiance à la position client : on la ramène dans la portée de l'insecte.
	local offset = target - root.Position
	if offset.Magnitude > MAX_REACH then
		offset = offset.Unit * MAX_REACH
	end
	local scale = math.max(character:GetScale(), 0.6)
	local bodyRadius = math.max(root.Size.X, root.Size.Y) * 0.5 + BODY_MARGIN
	local radius = math.max(DIG_RADII[level] * scale, bodyRadius, MIN_RADIUS)
	-- Le centre s'enfonce d'un demi-rayon dans la paroi visée : on creuse DEVANT soi, pas une cuvette.
	local direction = if offset.Magnitude > 0.1 then offset.Unit else root.CFrame.LookVector
	local center = root.Position + offset + direction * (radius * 0.5)
	if not canCarve(center, radius) then
		refuse(player, "Impossible de creuser ici.")
		return
	end

	local terrain = workspace.Terrain
	terrain:FillBall(center, radius, Enum.Material.Air)
	-- Relie à la sculpture précédente : parois lisses et aucune marche si une demande s'est perdue.
	local previous = lastCarvePos[player]
	local shellCenter, shellReach = center, radius + SHELL_MARGIN
	if previous and now - (lastCarveAt[player] or 0) < BRIDGE_MAX_AGE then
		local gap = center - previous
		local length = gap.Magnitude
		if length > 0.2 and length < radius * 2 and canCarve(previous, radius) then
			local middle = previous + gap * 0.5
			-- FillCylinder : la hauteur suit l'axe Y du CFrame -> on couche Y sur le segment.
			terrain:FillCylinder(CFrame.lookAt(middle, center) * CFrame.Angles(-math.pi / 2, 0, 0), length, radius, Enum.Material.Air)
			shellCenter, shellReach = middle, length * 0.5 + radius + SHELL_MARGIN
		end
	end
	lastCarvePos[player] = center
	lastCarveAt[player] = now
	NestBuildingService.OnDig(player) -- la terre creusée sert à bâtir le nid
	dirtShell(shellCenter, shellReach)

	playDigFx(player, center - direction * (radius * 0.6))
	if center.Y < GameConstants.GROUND_TOP_Y - 2 and now - (lastTunnelCount[player] or 0) >= TUNNEL_COUNT_PERIOD then
		lastTunnelCount[player] = now
		player:SetAttribute("TunnelsDug", ((player:GetAttribute("TunnelsDug") :: number?) or 0) + 1)
	end
end

function DigService.Start()
	Remotes.Get("RequestDig").OnServerEvent:Connect(onDig)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastDig[player] = nil
		lastCarvePos[player] = nil
		lastCarveAt[player] = nil
		lastTunnelCount[player] = nil
		lastFeedback[player] = nil
		digFxStopAt[player] = nil
		local fxPart = digFxParts[player]
		digFxParts[player] = nil
		if fxPart then
			fxPart:Destroy()
		end
	end)
end

return DigService
