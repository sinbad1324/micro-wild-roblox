--!strict
-- WorldFxController.luau
-- Effets de monde rendus localement (le serveur ne garde que le gameplay) :
--   * cycle jour/nuit fluide : Lighting.ClockTime recalculé à chaque image depuis l'heure serveur
--     (attributs workspace DayCycleSeconds / DayStartOffset posés par SurvivalService)
--   * pluie / neige qui suit la caméra (attribut workspace "Precipitation" = Rain/Snow/None),
--     avec montée/descente progressive du débit et coupure sous terre
--   * chutes (fruits d'automne, bombes d'eau) : tag "FxFalling" + attributs FxFallHeight /
--     FxFallDuration / FxFallStart ; la part est déjà à sa position finale côté serveur, on la fait
--     tomber localement puis éclabousser si FxSplash (SeasonVisualService)

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local WorldFxController = {}

local started = false

-- Débits pour une zone de 160x160 studs autour de la caméra (budget particules mobile).
local RAIN_RATE = 450
local SNOW_RATE = 160
local SKY_SIZE = Vector3.new(160, 1, 160)
local SKY_OFFSET = Vector3.new(0, 45, 0)
-- Montée/descente du débit : ~4 s pour une transition de saison, rapide en entrant sous terre.
local RATE_SMOOTHING = 0.6
local SHELTER_CHECK_SECONDS = 0.3
local SHELTER_RAY = Vector3.new(0, 40, 0)
-- Au-delà, les chutes ne sont pas animées (ni éclaboussure) : économie sur la grande carte.
local FX_DISTANCE = 400

local fxFolder: Folder? = nil

local function getFolder(): Folder
	if fxFolder and fxFolder.Parent then
		return fxFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClientWorldFx"
	folder.Parent = workspace
	fxFolder = folder
	return folder
end

local function makeFxPart(name: string, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Parent = getFolder()
	return part
end

-- ============================================================
-- Jour / nuit
-- ============================================================

local dayCycleSeconds: number? = nil
local dayStartOffset: number? = nil

local function readDayCycle()
	local cycle = workspace:GetAttribute("DayCycleSeconds")
	local offset = workspace:GetAttribute("DayStartOffset")
	dayCycleSeconds = if type(cycle) == "number" and cycle > 0 then cycle else nil
	dayStartOffset = if type(offset) == "number" then offset else nil
end

local function updateClock(_dt: number?)
	local cycle, offset = dayCycleSeconds, dayStartOffset
	if cycle and offset then
		Lighting.ClockTime = ((workspace:GetServerTimeNow() + offset) % cycle) / cycle * 24
	end
end

-- ============================================================
-- Précipitations
-- ============================================================

type Weather = { Emitter: ParticleEmitter, Kind: string, MaxRate: number, Rate: number }

local sky: Part? = nil
local weathers: { Weather } = {}
local underCover = false
local shelterTimer = 0

local shelterParams = RaycastParams.new()
shelterParams.FilterType = Enum.RaycastFilterType.Include
shelterParams.FilterDescendantsInstances = { workspace.Terrain }
shelterParams.IgnoreWater = true

local function createWeather(skyPart: Part, kind: string): Weather
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = kind
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.LightInfluence = 1
	emitter.Rate = 0
	emitter.Enabled = false
	local maxRate: number
	if kind == "Snow" then
		maxRate = SNOW_RATE
		emitter.Lifetime = NumberRange.new(5, 7)
		emitter.Speed = NumberRange.new(9, 14)
		emitter.SpreadAngle = Vector2.new(20, 20)
		emitter.Size = NumberSequence.new(0.5)
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.RotSpeed = NumberRange.new(-60, 60)
	else
		maxRate = RAIN_RATE
		emitter.Lifetime = NumberRange.new(1.1, 1.4)
		emitter.Speed = NumberRange.new(55, 65)
		emitter.Size = NumberSequence.new(0.12)
		emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 230))
		emitter.Transparency = NumberSequence.new(0.4)
		emitter.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
		emitter.Squash = NumberSequence.new(-3)
	end
	emitter.Parent = skyPart
	return { Emitter = emitter, Kind = kind, MaxRate = maxRate, Rate = 0 }
end

local function updateWeather(dt: number, cameraPosition: Vector3)
	local skyPart = sky
	if not skyPart then
		return
	end
	skyPart.CFrame = CFrame.new(cameraPosition + SKY_OFFSET)

	shelterTimer -= dt
	if shelterTimer <= 0 then
		shelterTimer = SHELTER_CHECK_SECONDS
		underCover = workspace:Raycast(cameraPosition, SHELTER_RAY, shelterParams) ~= nil
	end

	local precipitation = workspace:GetAttribute("Precipitation")
	local alpha = math.min(dt * RATE_SMOOTHING, 1)
	for _, weather in ipairs(weathers) do
		local target = if precipitation == weather.Kind and not underCover then weather.MaxRate else 0
		if underCover then
			weather.Rate = 0 -- coupure nette : pas de pluie dans les galeries
		else
			weather.Rate += (target - weather.Rate) * alpha
		end
		local enabled = weather.Rate > 1
		if weather.Emitter.Enabled ~= enabled then
			weather.Emitter.Enabled = enabled
		end
		if enabled and math.abs(weather.Emitter.Rate - weather.Rate) > 2 then
			weather.Emitter.Rate = weather.Rate
		end
	end
end

-- ============================================================
-- Chutes (fruits, bombes d'eau)
-- ============================================================

-- Tableaux parallèles + retrait par échange : aucune allocation de table par image.
local fallParts: { BasePart } = {}
local fallRest: { CFrame } = {}
local fallStart: { number } = {}
local fallDuration: { number } = {}
local fallHeight: { number } = {}

local function spawnSplash(position: Vector3)
	local splash = makeFxPart("Eclaboussure", Vector3.new(0.4, 8, 8))
	splash.Shape = Enum.PartType.Cylinder
	splash.Material = Enum.Material.Glass
	splash.Color = Color3.fromRGB(170, 210, 250)
	splash.Transparency = 0.4
	splash.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	TweenService:Create(splash, TweenInfo.new(0.6), { Size = Vector3.new(0.2, 16, 16), Transparency = 1 }):Play()
	task.delay(0.7, function()
		splash:Destroy()
	end)
end

local function removeFall(index: number)
	local last = #fallParts
	fallParts[index] = fallParts[last]
	fallRest[index] = fallRest[last]
	fallStart[index] = fallStart[last]
	fallDuration[index] = fallDuration[last]
	fallHeight[index] = fallHeight[last]
	table.remove(fallParts)
	table.remove(fallRest)
	table.remove(fallStart)
	table.remove(fallDuration)
	table.remove(fallHeight)
end

local function finishFall(part: BasePart, rest: CFrame, cameraPosition: Vector3)
	if part.Parent then
		part.CFrame = rest
	end
	if part:GetAttribute("FxSplash") == true and (rest.Position - cameraPosition).Magnitude <= FX_DISTANCE then
		-- La bombe est posée 2 studs au-dessus du sol (SeasonVisualService).
		spawnSplash(rest.Position - Vector3.new(0, 2, 0))
	end
end

local function onFallingAdded(instance: Instance)
	if not instance:IsA("BasePart") or table.find(fallParts, instance) then
		return
	end
	local height = instance:GetAttribute("FxFallHeight")
	local duration = instance:GetAttribute("FxFallDuration")
	local start = instance:GetAttribute("FxFallStart")
	if type(height) ~= "number" or type(duration) ~= "number" or type(start) ~= "number" or duration <= 0 then
		return
	end
	if workspace:GetServerTimeNow() >= start + duration then
		return -- arrivé après l'impact : la part est déjà au sol
	end
	table.insert(fallParts, instance)
	table.insert(fallRest, instance.CFrame)
	table.insert(fallStart, start)
	table.insert(fallDuration, duration)
	table.insert(fallHeight, height)
	-- Évite une image au sol avant la première mise à jour.
	instance.CFrame = instance.CFrame + Vector3.new(0, height, 0)
end

local function updateFalls(cameraPosition: Vector3)
	if #fallParts == 0 then
		return
	end
	local now = workspace:GetServerTimeNow()
	local i = 1
	while i <= #fallParts do
		local part = fallParts[i]
		local t = (now - fallStart[i]) / fallDuration[i]
		if t >= 1 or not part.Parent then
			-- Détruite par le serveur à l'impact (bombe) : on éclabousse quand même.
			if t >= 0.8 then
				finishFall(part, fallRest[i], cameraPosition)
			end
			removeFall(i)
		elseif (fallRest[i].Position - cameraPosition).Magnitude > FX_DISTANCE then
			-- Trop loin : pas d'animation, la part reprend tout de suite sa place finale.
			part.CFrame = fallRest[i]
			removeFall(i)
		else
			local eased = math.max(t, 0)
			part.CFrame = fallRest[i] + Vector3.new(0, fallHeight[i] * (1 - eased * eased), 0)
			i += 1
		end
	end
end

-- ============================================================
-- Démarrage
-- ============================================================

function WorldFxController.Start()
	if started then
		return
	end
	started = true

	readDayCycle()
	workspace:GetAttributeChangedSignal("DayCycleSeconds"):Connect(readDayCycle)
	workspace:GetAttributeChangedSignal("DayStartOffset"):Connect(readDayCycle)

	local skyPart = makeFxPart("CielLocal", SKY_SIZE)
	sky = skyPart
	table.insert(weathers, createWeather(skyPart, "Rain"))
	table.insert(weathers, createWeather(skyPart, "Snow"))

	for _, instance in ipairs(CollectionService:GetTagged("FxFalling")) do
		onFallingAdded(instance)
	end
	CollectionService:GetInstanceAddedSignal("FxFalling"):Connect(onFallingAdded)

	-- Avant le rendu : une valeur ClockTime répliquée (en retard) n'est jamais affichée une image.
	RunService:BindToRenderStep("WorldFxClock", Enum.RenderPriority.First.Value, updateClock)
	RunService.Heartbeat:Connect(function(dt: number)
		local camera = workspace.CurrentCamera
		if camera then
			local cameraPosition = camera.CFrame.Position
			updateFalls(cameraPosition)
			updateWeather(dt, cameraPosition)
		end
	end)
end

return WorldFxController
