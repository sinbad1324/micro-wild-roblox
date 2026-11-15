--!strict
-- DigService.luau
-- Creusement dynamique du sol (GDD §7.A) : les insectes fouisseurs (GameConstants.DIGGER_SPECIES)
-- sculptent des galeries dans le Terrain avec la touche C. Un tunnel creusé est automatiquement
-- un abri (SurvivalService détecte le Terrain au-dessus de la tête).
--
-- API aussi utilisée par l'IA des animaux (terriers du Crabe, trous de l'Écureuil/Caméléon) :
--   DigService.CarveHole(position, radius)

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)

local DigService = {}

-- Le client envoie une demande toutes les ~0.5 s (AbilityController) ; chaque demande est sculptée
-- en plusieurs petites passes pour que la galerie s'ouvre en continu au lieu d'apparaître d'un coup.
local DIG_COOLDOWN = 0.2
local DIG_RADIUS = 3.2
local CARVE_PASS_RATIOS = { 0.75, 0.9, 1 } -- rayon de chaque passe (fraction du rayon final)
local CARVE_PASS_SECONDS = 0.15
local SPOIL_BALL_EVERY = 3 -- une boulette physique toutes les N demandes (le reste : particules)
local DIG_FX_SECONDS = 0.5
local MAX_REACH = 9
local MIN_DIG_Y = WorldLayout.GROUND_BOTTOM_Y + 4 -- ne jamais percer le fond de la carte
local MAX_SPOIL_BALLS = 60

local lastDig: { [Player]: number } = {}
local spoilCount = 0
local digRequests = 0
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

-- Boulette de terre excavée (GDD : "les joueurs excavent des boulettes de terre").
local function spawnSpoil(position: Vector3, size: number)
	if spoilCount >= MAX_SPOIL_BALLS then
		return
	end
	spoilCount += 1
	local ball = Instance.new("Part")
	ball.Name = "BouletteDeTerre"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * size
	ball.Material = Enum.Material.Ground
	ball.Color = Color3.fromRGB(105, 80, 55)
	ball.CanQuery = false
	ball.CFrame = CFrame.new(position)
	ball.Parent = workspace
	Debris:AddItem(ball, 25)
	task.delay(25, function()
		spoilCount -= 1
	end)
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
		emitter.Rate = 25
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

function DigService.CarveHole(position: Vector3, radius: number): boolean
	if position.Y - radius < MIN_DIG_Y or isNearWater(position, radius + 2) then
		return false
	end
	workspace.Terrain:FillBall(position, radius, Enum.Material.Air)
	return true
end

local function onDig(player: Player, targetPosition: unknown)
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
	local speciesId = (player:GetAttribute("Species") :: string?) or ""
	if not GameConstants.DIGGER_SPECIES[speciesId] then
		Remotes.Get("AbilityFeedback"):FireClient(player, false, "Votre espèce ne sait pas creuser.")
		return
	end
	local stage = player:GetAttribute("Stage")
	if stage ~= "Adulte" and stage ~= "Larve" then
		return
	end
	local now = os.clock()
	if lastDig[player] and now - lastDig[player] < DIG_COOLDOWN then
		return
	end
	lastDig[player] = now

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	-- Ne jamais faire confiance à la position client : on la ramène dans la portée de l'insecte.
	local offset = (targetPosition :: Vector3) - root.Position
	if offset.Magnitude > MAX_REACH then
		offset = offset.Unit * MAX_REACH
	end
	local radius = DIG_RADIUS * math.max(character:GetScale(), 0.6)
	if not DigService.CarveHole(root.Position + offset, radius * CARVE_PASS_RATIOS[1]) then
		Remotes.Get("AbilityFeedback"):FireClient(player, false, "Impossible de creuser ici.")
		return
	end
	-- Passes suivantes : le trou s'élargit en suivant l'insecte qui avance.
	for pass = 2, #CARVE_PASS_RATIOS do
		task.delay(CARVE_PASS_SECONDS * (pass - 1), function()
			if root.Parent then
				DigService.CarveHole(root.Position + offset, radius * CARVE_PASS_RATIOS[pass])
			end
		end)
	end

	playDigFx(player, root.Position + offset * 0.5)
	digRequests += 1
	if digRequests % SPOIL_BALL_EVERY == 0 then
		spawnSpoil(root.Position + Vector3.new(0, 2, 0) - root.CFrame.LookVector * 1.5, 0.8 * math.max(character:GetScale(), 0.6))
	end
	if root.Position.Y + offset.Y < GameConstants.GROUND_TOP_Y - 2 then
		player:SetAttribute("TunnelsDug", ((player:GetAttribute("TunnelsDug") :: number?) or 0) + 1)
	end
end

function DigService.Start()
	Remotes.Get("RequestDig").OnServerEvent:Connect(onDig)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastDig[player] = nil
		digFxStopAt[player] = nil
		local fxPart = digFxParts[player]
		digFxParts[player] = nil
		if fxPart then
			fxPart:Destroy()
		end
	end)
end

return DigService
