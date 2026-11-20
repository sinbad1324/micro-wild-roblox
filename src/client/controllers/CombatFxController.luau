--!strict
-- CombatFxController.luau
-- Rend localement TOUS les VFX de combat diffusés par le serveur via le remote "CombatFx"
-- (voir shared/Remotes) : projectiles, éclats d'impact, cônes, télégraphes de charge/bond,
-- apparition des toiles, auras de statut, chiffres de dégâts, flash de surbrillance sur la cible
-- touchée, micro-pause d'impact et coup de caméra. Le serveur ne crée ni n'anime aucune part.
--
-- Budget mobile : un seul dossier local, parts ancrées sans collision ni requête, tout est animé
-- par TweenService (aucune boucle par frame), effets lointains ignorés, chiffres et surbrillances
-- plafonnés. Aucun son : aucun asset importé.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local AbilityController = require(script.Parent.AbilityController)
local StatusEffectController = require(script.Parent.StatusEffectController)

local CombatFxController = {}

local MAX_FX_DISTANCE = 160 -- au-delà, l'effet d'un autre joueur n'est pas rendu
local MAX_DAMAGE_NUMBERS = 20
local HIGHLIGHT_POOL_SIZE = 3 -- les Highlight sont limités par le moteur : petit pool réutilisé
local QUIET_MERGE_SECONDS = 0.6 -- dégâts continus (poison, prise) regroupés en un seul chiffre
local HIT_STOP_SECONDS = 0.06 -- micro-pause de l'éclat quand c'est NOTRE coup qui porte
local FOV_PUNCH = 3
local CONE_DROPLETS = 6
local TELEGRAPH_COLOR = Color3.fromRGB(255, 70, 50)
local WHITE = Color3.fromRGB(255, 255, 255)

local STATUS_COLORS: { [string]: Color3 } = {
	Poison = Color3.fromRGB(110, 230, 80),
	Toxic = Color3.fromRGB(170, 230, 40),
	Bleed = Color3.fromRGB(200, 20, 30),
	Glue = Color3.fromRGB(245, 240, 210),
	Slow = Color3.fromRGB(120, 170, 255),
	Blind = Color3.fromRGB(255, 250, 200),
	InvertControls = Color3.fromRGB(80, 255, 170),
	MindControl = Color3.fromRGB(80, 255, 170),
}

type Aura = {
	Instance: Instance,
	ExpiresAt: number,
	Connection: RBXScriptConnection,
}

local player = Players.LocalPlayer
local started = false
local fxFolder: Folder? = nil
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local activeNumbers = 0
local highlightPool: { Highlight } = {}
local nextHighlight = 1
local quietPending: { [Model]: number } = {}
local auras: { [Model]: { [string]: Aura } } = {}
local baseFov = 70
local punchTween: Tween? = nil

-- ============================================================
-- Utilitaires
-- ============================================================

local function tween(instance: Instance, seconds: number, goals: { [string]: any }, style: Enum.EasingStyle?, delayTime: number?): Tween
	local created = TweenService:Create(
		instance,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delayTime or 0),
		goals
	)
	created:Play()
	return created
end

local function nearCamera(position: Vector3): boolean
	local camera = workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - position).Magnitude <= MAX_FX_DISTANCE
end

local function modelRoot(model: Model): BasePart?
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function asModel(value: unknown): Model?
	if typeof(value) == "Instance" and (value :: Instance):IsA("Model") then
		return value :: Model
	end
	return nil
end

local function makePart(shape: Enum.PartType, color: Color3, size: Vector3, cframe: CFrame, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = size
	part.CFrame = cframe
	part.Transparency = transparency
	part.Parent = fxFolder
	return part
end

-- Sol sous une position (télégraphes posés au sol), le personnage lanceur ignoré.
local function groundAt(position: Vector3, ignore: Instance?): Vector3
	local filter: { Instance } = {}
	if fxFolder then
		table.insert(filter, fxFolder)
	end
	if ignore then
		table.insert(filter, ignore)
	end
	raycastParams.FilterDescendantsInstances = filter
	local result = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -30, 0), raycastParams)
	if result then
		return result.Position
	end
	return position - Vector3.new(0, 1.5, 0)
end

-- ============================================================
-- Briques visuelles
-- ============================================================

-- Sphère qui gonfle et s'efface. `hold` > 0 = micro-pause d'impact avant l'expansion.
local function flash(position: Vector3, color: Color3, size: number, hold: number)
	local part = makePart(Enum.PartType.Ball, color, Vector3.one * (size * 0.35), CFrame.new(position), 0.1)
	tween(part, 0.25, { Size = Vector3.one * size, Transparency = 1 }, Enum.EasingStyle.Quad, hold)
	Debris:AddItem(part, hold + 0.3)
end

local function showNumber(root: BasePart, text: string, color: Color3, big: boolean)
	if activeNumbers >= MAX_DAMAGE_NUMBERS then
		return
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	activeNumbers += 1

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = if big then UDim2.fromOffset(96, 40) else UDim2.fromOffset(64, 26)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = MAX_FX_DISTANCE
	billboard.ResetOnSpawn = false
	billboard.Adornee = root
	local offset = Vector3.new((math.random() - 0.5) * 2, 2.5, (math.random() - 0.5) * 2)
	billboard.StudsOffsetWorldSpace = offset

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1.5, 1.5) -- "pop" : part gros puis se pose
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.Parent = billboard
	billboard.Parent = playerGui

	tween(label, 0.12, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Back)
	tween(billboard, 0.75, { StudsOffsetWorldSpace = offset + Vector3.new(0, 2.5, 0) })
	tween(label, 0.45, { TextTransparency = 1, TextStrokeTransparency = 1 }, Enum.EasingStyle.Quad, 0.3)
	task.delay(0.8, function()
		billboard:Destroy()
		activeNumbers -= 1
	end)
end

local function flashHighlight(model: Model)
	local highlight = highlightPool[nextHighlight]
	if not highlight then
		return
	end
	nextHighlight = nextHighlight % #highlightPool + 1
	highlight.Adornee = model
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 0.3
	highlight.Enabled = true
	local fade = tween(highlight, 0.2, { FillTransparency = 1, OutlineTransparency = 1 })
	fade.Completed:Connect(function(state)
		-- Une surbrillance réutilisée entre-temps est annulée : elle reste allumée pour le nouveau coup.
		if state == Enum.PlaybackState.Completed then
			highlight.Enabled = false
			highlight.Adornee = nil
		end
	end)
end

-- Coup de caméra (FOV) : revient toujours au FOV de base, même sous une rafale de coups.
local function cameraPunch()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if punchTween then
		punchTween:Cancel()
	else
		baseFov = camera.FieldOfView
	end
	camera.FieldOfView = baseFov - FOV_PUNCH
	local created = TweenService:Create(camera, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = baseFov })
	punchTween = created
	created.Completed:Connect(function()
		if punchTween == created then
			punchTween = nil
		end
	end)
	created:Play()
end

-- ============================================================
-- Handlers par type d'effet
-- ============================================================

local function queueQuiet(model: Model, amount: number)
	local pending = quietPending[model]
	quietPending[model] = (pending or 0) + amount
	if pending ~= nil then
		return -- un affichage est déjà programmé pour cette cible
	end
	task.delay(QUIET_MERGE_SECONDS, function()
		local total = quietPending[model] or 0
		quietPending[model] = nil
		local root = modelRoot(model)
		if root and model.Parent then
			showNumber(root, tostring(math.max(1, math.floor(total + 0.5))), Color3.fromRGB(170, 230, 120), false)
		end
	end)
end

local function onHit(victim: unknown, amount: unknown, attackerUserId: unknown, quiet: unknown)
	local model = asModel(victim)
	if not model or typeof(amount) ~= "number" then
		return
	end
	local root = modelRoot(model)
	if not root then
		return
	end
	local isMine = attackerUserId == player.UserId
	local isMe = model == player.Character
	if not isMine and not isMe and not nearCamera(root.Position) then
		return
	end
	if quiet == true then
		queueQuiet(model, amount :: number)
		return
	end

	local color = if isMe then Color3.fromRGB(255, 80, 70) elseif isMine then Color3.fromRGB(255, 230, 90) else WHITE
	showNumber(root, tostring(math.max(1, math.floor((amount :: number) + 0.5))), color, isMine or isMe)
	local radius = (model:GetAttribute("HitRadius") :: number?) or 1.5
	flash(root.Position, color, math.clamp(radius * 1.3, 2, 10), if isMine then HIT_STOP_SECONDS else 0)
	flashHighlight(model)
	if isMine then
		cameraPunch()
		StatusEffectController.Shake(0.25, 0.12)
	elseif isMe then
		StatusEffectController.Shake(0.6, 0.25)
	end
end

local function onProjectile(from: unknown, to: unknown, color: unknown, travel: unknown)
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" or typeof(color) ~= "Color3" or typeof(travel) ~= "number" then
		return
	end
	local startPosition = from :: Vector3
	local endPosition = to :: Vector3
	local tint = color :: Color3
	if not nearCamera(startPosition) and not nearCamera(endPosition) then
		return
	end
	local seconds = math.clamp(travel :: number, 0.05, 2)
	local ball = makePart(Enum.PartType.Ball, tint, Vector3.one * 0.9, CFrame.new(startPosition), 0)

	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 0.3, 0)
	top.Parent = ball
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -0.3, 0)
	bottom.Parent = ball
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = ColorSequence.new(tint)
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Lifetime = 0.18
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Parent = ball

	tween(ball, seconds, { CFrame = CFrame.new(endPosition) }, Enum.EasingStyle.Linear)
	task.delay(seconds, function()
		ball:Destroy()
		flash(endPosition, tint, 2.4, 0)
	end)
end

local function onFlash(position: unknown, color: unknown, size: unknown)
	if typeof(position) ~= "Vector3" or typeof(color) ~= "Color3" or typeof(size) ~= "number" then
		return
	end
	if nearCamera(position :: Vector3) then
		flash(position :: Vector3, color :: Color3, math.clamp(size :: number, 1, 30), 0)
	end
end

local function onCone(origin: unknown, vector: unknown, color: unknown)
	if typeof(origin) ~= "Vector3" or typeof(vector) ~= "Vector3" or typeof(color) ~= "Color3" then
		return
	end
	local start = origin :: Vector3
	local reach = vector :: Vector3
	local tint = color :: Color3
	local range = math.min(reach.Magnitude, 60)
	if range < 0.1 or not nearCamera(start) then
		return
	end
	local look = reach.Unit
	flash(start + look * 1.5, tint, 3, 0)
	for i = 1, CONE_DROPLETS do
		-- Gouttes réparties sur ±35° (même ouverture visuelle que le cône serveur).
		local angle = math.rad(-35 + 70 * (i - 1) / (CONE_DROPLETS - 1) + (math.random() - 0.5) * 8)
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(look)
		local droplet = makePart(Enum.PartType.Ball, tint, Vector3.one * 0.6, CFrame.new(start + direction * 1.5), 0.1)
		tween(droplet, 0.32, {
			CFrame = CFrame.new(start + direction * range),
			Size = Vector3.one * (1.2 + range * 0.12),
			Transparency = 1,
		})
		Debris:AddItem(droplet, 0.4)
	end
end

local function onTelegraph(caster: unknown, primitive: unknown, vector: unknown, windupSeconds: unknown)
	if typeof(vector) ~= "Vector3" then
		return
	end
	local casterModel = asModel(caster)
	local target = vector :: Vector3
	-- Délai envoyé par le serveur (absent sur un ancien serveur : valeurs par défaut).
	local windup = if typeof(windupSeconds) == "number" then math.clamp(windupSeconds :: number, 0.05, 1.5) else nil
	if primitive == "Lunge" then
		-- Traînée rouge au sol qui se déploie devant le chargeur (la charge frappe `windup` s après).
		local root = casterModel and modelRoot(casterModel)
		local flat = Vector3.new(target.X, 0, target.Z)
		if not root or flat.Magnitude < 0.5 or not nearCamera(root.Position) then
			return
		end
		local range = math.min(flat.Magnitude, 60)
		local direction = flat.Unit
		local ground = groundAt(root.Position, casterModel)
		local width = math.clamp(casterModel and casterModel:GetScale() * 1.6 or 1.6, 1, 8)
		local basis = CFrame.lookAt(ground, ground + direction) + Vector3.new(0, 0.1, 0)
		local streak = makePart(Enum.PartType.Block, TELEGRAPH_COLOR, Vector3.new(width, 0.12, 0.5), basis * CFrame.new(0, 0, -0.25), 0.25)
		local lungeWindup = windup or 0.25
		tween(streak, lungeWindup * 0.6, { Size = Vector3.new(width, 0.12, range), CFrame = basis * CFrame.new(0, 0, -range / 2) })
		tween(streak, 0.35, { Transparency = 1 }, Enum.EasingStyle.Quad, lungeWindup * 0.8)
		Debris:AddItem(streak, lungeWindup + 0.4)
	elseif primitive == "Leap" then
		-- Disque d'atterrissage qui se resserre pendant le bond (`windup` s) : la proie voit où il tombe.
		if not nearCamera(target) then
			return
		end
		local ground = groundAt(target, casterModel)
		local flatDisc = CFrame.new(ground + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
		local disc = makePart(Enum.PartType.Cylinder, TELEGRAPH_COLOR, Vector3.new(0.1, 12, 12), flatDisc, 0.55)
		local airtime = windup or 0.6
		tween(disc, airtime, { Size = Vector3.new(0.1, 3, 3), Transparency = 0.2 }, Enum.EasingStyle.Quad)
		tween(disc, 0.2, { Transparency = 1 }, Enum.EasingStyle.Quad, airtime)
		Debris:AddItem(disc, airtime + 0.3)
		task.delay(airtime, function()
			flash(ground + Vector3.new(0, 0.5, 0), TELEGRAPH_COLOR, 5, 0)
		end)
	end
end

local function onWeb(web: unknown)
	if typeof(web) ~= "Instance" or not (web :: Instance):IsA("BasePart") then
		return -- part pas encore répliquée (streaming) : la toile apparaît simplement sans animation
	end
	local part = web :: BasePart
	if not nearCamera(part.Position) then
		return
	end
	-- Changement local seulement (le serveur garde la vraie taille pour la détection).
	local fullSize = part.Size
	part.Size = Vector3.new(fullSize.X * 0.15, fullSize.Y, fullSize.Z * 0.15)
	tween(part, 0.35, { Size = fullSize }, Enum.EasingStyle.Back)
	flash(part.Position, WHITE, 4, 0)
end

-- ============================================================
-- Toiles d'araignée : tissage local (rayons + spirale) sur le volume serveur invisible
-- ============================================================

local SILK = Color3.fromRGB(242, 242, 248)
local WEB_APPEAR_SECONDS = 0.6

-- Fil de soie fin entre deux points (repère de la toile).
local function thread(parent: Instance, a: Vector3, b: Vector3, width: number): Part
	local delta = b - a
	local part = Instance.new("Part")
	part.Name = "Silk"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = SILK
	part.Size = Vector3.new(width, width, math.max(delta.Magnitude, 0.01))
	part.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
	part.Transparency = 0.15
	part.Parent = parent
	return part
end

-- Toile orbiculaire : rayons irréguliers, spirale de capture (anneaux reliant les rayons), légère
-- poche vers l'intérieur au centre. Déterministe (même toile pour tous) : graine = position.
local function weaveWeb(web: BasePart)
	if not fxFolder or not web:IsDescendantOf(workspace) then
		return
	end
	local trap = web:GetAttribute("WebKind") ~= "Patch"
	local radius = math.min(web.Size.X, web.Size.Z) * 0.5
	local spokes = if trap then 11 else 7
	local rings = if trap then 6 else 2
	local width = math.clamp(radius * 0.012, 0.025, 0.08)
	local seed = math.floor(web.Position.X * 7 + web.Position.Z * 13 + web.Position.Y * 3)
	local rng = Random.new(seed)
	local frame = web.CFrame
	local model = Instance.new("Model")
	model.Name = "SpiderWebVisual"

	-- Angles et longueurs des rayons légèrement irréguliers (toile tissée, pas un dessin parfait).
	local angles: { number } = {}
	local reach: { number } = {}
	for i = 1, spokes do
		angles[i] = (i - 1) / spokes * math.pi * 2 + rng:NextNumber(-0.18, 0.18)
		reach[i] = radius * rng:NextNumber(0.82, 1)
	end
	-- Point sur le rayon i à la fraction f, en monde (petite poche : le centre est un peu plus bas).
	local function at(i: number, f: number): Vector3
		local angle = angles[i]
		local sag = (1 - f) * radius * 0.06
		return frame * Vector3.new(math.cos(angle) * reach[i] * f, 0.05 - sag, math.sin(angle) * reach[i] * f)
	end

	local parts: { { Part: Part, Delay: number } } = {}
	for i = 1, spokes do
		local spoke = thread(model, at(i, 0), at(i, 1), width)
		table.insert(parts, { Part = spoke, Delay = (i - 1) / spokes * 0.18 })
	end
	for r = 1, rings do
		local f = 0.18 + (r - 1) / math.max(rings - 1, 1) * 0.8
		for i = 1, spokes do
			local j = i % spokes + 1
			local wobble = rng:NextNumber(-0.03, 0.03)
			local ring = thread(model, at(i, f + wobble), at(j, f - wobble), width * 0.8)
			table.insert(parts, { Part = ring, Delay = 0.18 + (r - 1) / rings * 0.35 + (i - 1) / spokes * 0.06 })
		end
	end
	-- Moyeu dense au centre.
	local hub = thread(model, at(1, 0.06), at(math.floor(spokes / 2) + 1, 0.06), width * 2.2)
	table.insert(parts, { Part = hub, Delay = 0 })
	model.Parent = fxFolder

	-- Toile qui vient d'être posée : elle se tisse sous les yeux (rayons puis spirale).
	local born = web:GetAttribute("BornAt")
	local fresh = type(born) == "number" and workspace:GetServerTimeNow() - born < WEB_APPEAR_SECONDS
	if fresh and nearCamera(web.Position) then
		for _, entry in ipairs(parts) do
			entry.Part.Transparency = 1
			tween(entry.Part, 0.18, { Transparency = 0.15 }, Enum.EasingStyle.Quad, entry.Delay)
		end
		flash(web.Position, WHITE, radius * 0.6, 0)
	end

	-- La toile serveur disparaît (durée, remplacement) : le tissage local aussi.
	local connection: RBXScriptConnection? = nil
	connection = web.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			if connection then
				connection:Disconnect()
			end
			for _, entry in ipairs(parts) do
				tween(entry.Part, 0.3, { Transparency = 1 })
			end
			Debris:AddItem(model, 0.35)
		end
	end)
end

-- Fil de soie lancé : petite boule de soie + fil tendu derrière elle depuis le lanceur.
local function onSilk(from: unknown, to: unknown, travel: unknown, caster: unknown)
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" or typeof(travel) ~= "number" then
		return
	end
	local startPosition = from :: Vector3
	local endPosition = to :: Vector3
	if not nearCamera(startPosition) and not nearCamera(endPosition) then
		return
	end
	local seconds = math.clamp(travel :: number, 0.03, 2)
	local blob = makePart(Enum.PartType.Ball, SILK, Vector3.one * 0.35, CFrame.new(startPosition), 0)
	blob.Material = Enum.Material.SmoothPlastic
	local tip = Instance.new("Attachment")
	tip.Parent = blob

	-- Le fil part de l'abdomen du lanceur s'il est visible, sinon du point de départ.
	local origin: Attachment
	local casterModel = asModel(caster)
	local casterRoot = if casterModel then modelRoot(casterModel) else nil
	local holder: BasePart? = nil
	if casterRoot then
		origin = Instance.new("Attachment")
		origin.Parent = casterRoot
	else
		local fixed = makePart(Enum.PartType.Ball, SILK, Vector3.one * 0.05, CFrame.new(startPosition), 1)
		holder = fixed
		origin = Instance.new("Attachment")
		origin.Parent = fixed
	end
	local strandBeam = Instance.new("Beam")
	strandBeam.Attachment0 = origin
	strandBeam.Attachment1 = tip
	strandBeam.Width0 = 0.06
	strandBeam.Width1 = 0.04
	strandBeam.Color = ColorSequence.new(SILK)
	strandBeam.Transparency = NumberSequence.new(0.1)
	strandBeam.FaceCamera = true
	strandBeam.Segments = 1
	strandBeam.Parent = blob

	tween(blob, seconds, { CFrame = CFrame.new(endPosition) }, Enum.EasingStyle.Linear)
	task.delay(seconds, function()
		flash(endPosition, SILK, 1.6, 0)
		-- Le fil reste tendu un instant après l'impact puis s'efface.
		tween(blob, 0.25, { Transparency = 1 })
		task.delay(0.15, function()
			strandBeam.Transparency = NumberSequence.new(0.6)
		end)
		task.delay(0.3, function()
			blob:Destroy()
			origin:Destroy()
			if holder then
				holder:Destroy()
			end
		end)
	end)
end

local function endAura(model: Model, status: string)
	local list = auras[model]
	local aura = list and list[status]
	if not list or not aura then
		return
	end
	list[status] = nil
	if next(list) == nil then
		auras[model] = nil
	end
	aura.Connection:Disconnect()
	local instance = aura.Instance
	if instance:IsA("ParticleEmitter") then
		instance.Enabled = false -- les particules déjà émises finissent leur vie
		Debris:AddItem(instance, 1.5)
	else
		instance:Destroy()
	end
end

local function buildAura(root: BasePart, status: string, scale: number): Instance
	if status == "Stun" then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "StunAura"
		billboard.Size = UDim2.fromOffset(72, 26)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.2 * scale, 0)
		billboard.AlwaysOnTop = false
		billboard.LightInfluence = 0
		billboard.MaxDistance = MAX_FX_DISTANCE
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 225, 60)
		label.TextStrokeTransparency = 0.3
		label.Text = "★ ★ ★"
		label.Parent = billboard
		-- Rotation en boucle par tween (pas de boucle par frame).
		TweenService:Create(label, TweenInfo.new(1.2, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), { Rotation = 360 }):Play()
		billboard.Parent = root -- détruit avec le modèle
		return billboard
	end

	local color = STATUS_COLORS[status] or WHITE
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "StatusAura_" .. status
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.4
	emitter.Lifetime = NumberRange.new(0.7, 1.1)
	emitter.Rate = 9
	emitter.Speed = NumberRange.new(1.5, 3)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Size = NumberSequence.new(0.35 * scale, 0.1 * scale)
	emitter.Transparency = NumberSequence.new(0.15, 1)
	if status == "Bleed" or status == "Glue" then
		-- Gouttes de sang / filaments de glu qui pendent et tombent.
		emitter.Acceleration = Vector3.new(0, -14, 0)
		emitter.Speed = NumberRange.new(0.5, 1.5)
		emitter.Rate = if status == "Glue" then 7 else 12
	elseif status == "Poison" or status == "Toxic" then
		-- Bulles qui montent.
		emitter.Acceleration = Vector3.new(0, 3, 0)
		emitter.Size = NumberSequence.new(0.2 * scale, 0.5 * scale)
	else
		emitter.RotSpeed = NumberRange.new(-180, 180)
	end
	emitter.Parent = root -- détruit avec le modèle
	return emitter
end

local function onStatus(victim: unknown, status: unknown, duration: unknown)
	local model = asModel(victim)
	if not model or typeof(status) ~= "string" or typeof(duration) ~= "number" then
		return
	end
	local name = status :: string
	local seconds = math.clamp(duration :: number, 0, 60)
	local root = modelRoot(model)
	if not root or seconds <= 0 or (model ~= player.Character and not nearCamera(root.Position)) then
		return
	end
	local expiresAt = os.clock() + seconds
	local list = auras[model]
	if not list then
		list = {}
		auras[model] = list
	end
	local existing = list[name]
	if existing then
		-- Statut rafraîchi/fusionné par le serveur : on prolonge l'aura, pas de doublon.
		existing.ExpiresAt = math.max(existing.ExpiresAt, expiresAt)
	else
		local scale = math.clamp(model:GetScale(), 0.3, 6)
		list[name] = {
			Instance = buildAura(root, name, scale),
			ExpiresAt = expiresAt,
			-- Vérité serveur : l'attribut disparaît à l'expiration ou au nettoyage (mort...).
			Connection = model:GetAttributeChangedSignal("Status_" .. name):Connect(function()
				if model:GetAttribute("Status_" .. name) == nil then
					endAura(model, name)
				end
			end),
		}
	end
	-- Borne haute si l'attribut n'arrive jamais (modèle détruit, streaming).
	task.delay(seconds + 0.3, function()
		local current = auras[model] and auras[model][name]
		if current and os.clock() >= current.ExpiresAt then
			endAura(model, name)
		end
	end)
end

-- Morsure prédite localement : petit claquement blanc devant les mandibules, dès l'appui.
local function onLocalBite()
	local character = player.Character
	local root = character and modelRoot(character)
	if not character or not root then
		return
	end
	local scale = math.clamp(character:GetScale(), 0.5, 4)
	flash(root.Position + root.CFrame.LookVector * (2.2 * scale), WHITE, 1.4 * scale, 0)
end

local function dispatch(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown)
	if kind == "Hit" then
		onHit(a, b, c, d)
	elseif kind == "Proj" then
		onProjectile(a, b, c, d)
	elseif kind == "Flash" then
		onFlash(a, b, c)
	elseif kind == "Cone" then
		onCone(a, b, c)
	elseif kind == "Tele" then
		onTelegraph(a, b, c, d)
	elseif kind == "Web" then
		onWeb(a)
	elseif kind == "Silk" then
		onSilk(a, b, c, d)
	elseif kind == "Status" then
		onStatus(a, b, c)
	end
end

function CombatFxController.Start()
	if started then
		return
	end
	started = true

	local folder = Instance.new("Folder")
	folder.Name = "CombatFxLocal"
	folder.Parent = workspace
	fxFolder = folder

	for _ = 1, HIGHLIGHT_POOL_SIZE do
		local highlight = Instance.new("Highlight")
		highlight.Name = "HitFlash"
		highlight.FillColor = WHITE
		highlight.OutlineColor = WHITE
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Enabled = false
		highlight.Parent = folder
		table.insert(highlightPool, highlight)
	end

	Remotes.Get("CombatFx").OnClientEvent:Connect(function(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown)
		-- Un effet raté ne doit jamais casser les suivants.
		local ok, err = pcall(dispatch, kind, a, b, c, d)
		if not ok then
			warn("[CombatFxController] " .. tostring(err))
		end
	end)
	AbilityController.LocalBite.Event:Connect(onLocalBite)

	-- Toiles d'araignée (posées avant ou après notre arrivée) : tissées localement.
	CollectionService:GetInstanceAddedSignal("SpiderWeb"):Connect(function(instance)
		if instance:IsA("BasePart") then
			weaveWeb(instance)
		end
	end)
	for _, instance in ipairs(CollectionService:GetTagged("SpiderWeb")) do
		if instance:IsA("BasePart") then
			weaveWeb(instance)
		end
	end
end

return CombatFxController
