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
-- Jour / nuit (nuit sombre & atmosphérique, lueur bioluminescente préservée)
-- ============================================================

local dayCycleSeconds: number? = nil
local dayStartOffset: number? = nil
local nightGrading: ColorCorrectionEffect? = nil
local smoothedRainLevel = 0

local DAY_AMBIENT = Color3.fromRGB(78, 84, 76)
local NIGHT_AMBIENT = Color3.fromRGB(5, 7, 14)
local DAY_OUTDOOR_AMBIENT = Color3.fromRGB(115, 122, 110)
local RAIN_OUTDOOR_AMBIENT = Color3.fromRGB(74, 88, 106)
local NIGHT_OUTDOOR_AMBIENT = Color3.fromRGB(9, 13, 25)
local DAY_ATMO_FALLBACK = Color3.fromRGB(200, 220, 240)
local RAIN_ATMO_COLOR = Color3.fromRGB(130, 152, 178)
local NIGHT_ATMO_COLOR = Color3.fromRGB(7, 10, 20)
local NIGHT_ATMO_DECAY = Color3.fromRGB(4, 6, 14)
local DAY_TINT = Color3.new(1, 1, 1)
local RAIN_TINT = Color3.fromRGB(222, 234, 248)
local NIGHT_TINT = Color3.fromRGB(135, 155, 210)

local function getNightGrading(): ColorCorrectionEffect
	if nightGrading and nightGrading.Parent == Lighting then
		return nightGrading
	end
	local existing = Lighting:FindFirstChild("NightGrading")
	if existing and existing:IsA("ColorCorrectionEffect") then
		nightGrading = existing
		return existing
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "NightGrading"
	cc.Parent = Lighting
	nightGrading = cc
	return cc
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Renvoie 0 en plein jour (7h00..17h30) et 1 en pleine nuit (19h45..5h00), avec transitions crépuscule/aube fluides.
local function computeNightFactor(clockTime: number): number
	if clockTime >= 7.0 and clockTime <= 17.5 then
		return 0
	elseif clockTime > 17.5 and clockTime < 19.75 then
		return smoothstep(17.5, 19.75, clockTime)
	elseif clockTime > 5.0 and clockTime < 7.0 then
		return 1 - smoothstep(5.0, 7.0, clockTime)
	else
		return 1
	end
end

local function readDayCycle()
	local cycle = workspace:GetAttribute("DayCycleSeconds")
	local offset = workspace:GetAttribute("DayStartOffset")
	dayCycleSeconds = if type(cycle) == "number" and cycle > 0 then cycle else nil
	dayStartOffset = if type(offset) == "number" then offset else nil
end

local function updateClock(_dt: number?)
	local cycle, offset = dayCycleSeconds, dayStartOffset
	local clockTime = Lighting.ClockTime
	if cycle and offset then
		clockTime = ((workspace:GetServerTimeNow() + offset) % cycle) / cycle * 24
		Lighting.ClockTime = clockTime
	end

	local night = computeNightFactor(clockTime)
	local rain = smoothedRainLevel
	local dayOutdoor = DAY_OUTDOOR_AMBIENT:Lerp(RAIN_OUTDOOR_AMBIENT, rain * 0.7)
	Lighting.Ambient = DAY_AMBIENT:Lerp(NIGHT_AMBIENT, night)
	Lighting.OutdoorAmbient = dayOutdoor:Lerp(NIGHT_OUTDOOR_AMBIENT, night)
	Lighting.Brightness = math.max(0.15, (2.2 - rain * 0.55) - night * (2.02 - rain * 0.48))
	Lighting.ExposureCompensation = -0.72 * night - 0.14 * rain * (1 - night)
	Lighting.EnvironmentDiffuseScale = 1 - night * 0.82
	-- Reflets humides sur les feuilles, le sol et les carapaces sous la pluie.
	Lighting.EnvironmentSpecularScale = math.clamp((1 - night * 0.75) + rain * 0.35, 0, 1)

	local cc = getNightGrading()
	cc.Brightness = -0.09 * night - 0.03 * rain * (1 - night)
	cc.Contrast = 0.16 * night + 0.04 * rain
	cc.Saturation = -0.14 * night - 0.08 * rain
	local dayTint = DAY_TINT:Lerp(RAIN_TINT, rain * 0.75)
	cc.TintColor = dayTint:Lerp(NIGHT_TINT, night)

	local atmo = Lighting:FindFirstChild("SeasonAtmosphere")
	if atmo and atmo:IsA("Atmosphere") then
		local dayColorAttr = atmo:GetAttribute("DayColor")
		local baseDayColor = if typeof(dayColorAttr) == "Color3" then dayColorAttr else DAY_ATMO_FALLBACK
		local dayColor = baseDayColor:Lerp(RAIN_ATMO_COLOR, rain * 0.65)
		atmo.Color = dayColor:Lerp(NIGHT_ATMO_COLOR, night)
		atmo.Decay = dayColor:Lerp(NIGHT_ATMO_DECAY, night)
	end
end

-- ============================================================
-- Précipitations
-- ============================================================

type Weather = { Emitter: ParticleEmitter, Kind: string, MaxRate: number, Rate: number }

local sky: Part? = nil
local ambientBox: Part? = nil
local windBox: Part? = nil
local rainBox: Part? = nil
local windStreakEmitter: ParticleEmitter? = nil
local windDebrisEmitter: ParticleEmitter? = nil
local rainCloseEmitter: ParticleEmitter? = nil
local rainMistEmitter: ParticleEmitter? = nil
local weathers: { Weather } = {}
local ambientWeathers: { Weather } = {}
local underCover = false
local shelterTimer = 0
local wasGust = false
local wasHeavyRain = false
local lastDebrisSeason = ""
local lastQuantizedWindLevel = -1
local lastQuantizedRainLevel = -1
local windRng = Random.new()

local MAX_WIND_SPEED = 34

type WindRibbon = {
	Carrier: Part,
	Att0: Attachment,
	Att1: Attachment,
	Trail: Trail,
	BasePos: Vector3,
	Age: number,
	Duration: number,
	SpeedFactor: number,
	WaveAmp: number,
	WaveFreq: number,
	Phase: number,
	CurlFactor: number,
	Active: boolean,
	JustSpawned: boolean,
}

local WIND_RIBBON_COUNT = 18
local windRibbons: { WindRibbon } = {}

type RainDropFx = {
	Carrier: Part,
	Att0: Attachment,
	Att1: Attachment,
	Trail: Trail,
	Ring: Part,
	Bead: Part,
	StartPos: Vector3,
	HitPos: Vector3,
	FallDuration: number,
	SplashDuration: number,
	MaxRingRadius: number,
	BounceHeight: number,
	Age: number,
	State: string, -- "Idle" | "Falling" | "Splashing"
	JustSpawned: boolean,
	HasGround: boolean,
}

local RAIN_DROP_COUNT = 18
local rainDrops: { RainDropFx } = {}

local shelterParams = RaycastParams.new()
shelterParams.FilterType = Enum.RaycastFilterType.Include
shelterParams.FilterDescendantsInstances = { workspace.Terrain }
shelterParams.IgnoreWater = true

local rainSplashParams = RaycastParams.new()
rainSplashParams.FilterType = Enum.RaycastFilterType.Exclude
rainSplashParams.IgnoreWater = false

local function createWeather(skyPart: Part, kind: string): Weather
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = kind
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.LightInfluence = 0.7
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
		emitter.Lifetime = NumberRange.new(0.8, 1.15)
		emitter.Speed = NumberRange.new(56, 70)
		emitter.SpreadAngle = Vector2.new(3, 3)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.16),
			NumberSequenceKeypoint.new(0.5, 0.28),
			NumberSequenceKeypoint.new(1, 0.14),
		})
		emitter.Color = ColorSequence.new(Color3.fromRGB(210, 232, 255), Color3.fromRGB(165, 205, 245))
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.75),
			NumberSequenceKeypoint.new(0.15, 0.22),
			NumberSequenceKeypoint.new(0.85, 0.28),
			NumberSequenceKeypoint.new(1, 0.85),
		})
		emitter.LightEmission = 0.35
		emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
		emitter.Squash = NumberSequence.new(-4.2)
	end
	emitter.Parent = skyPart
	return { Emitter = emitter, Kind = kind, MaxRate = maxRate, Rate = 0 }
end

local function createRainCloseEmitter(boxPart: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RainCloseStreaks"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Lifetime = NumberRange.new(0.38, 0.62)
	emitter.Speed = NumberRange.new(46, 62)
	emitter.SpreadAngle = Vector2.new(3, 3)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(0.5, 0.26),
		NumberSequenceKeypoint.new(1, 0.10),
	})
	emitter.Squash = NumberSequence.new(-4.6)
	emitter.Color = ColorSequence.new(Color3.fromRGB(225, 242, 255), Color3.fromRGB(175, 215, 250))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.18, 0.16),
		NumberSequenceKeypoint.new(0.82, 0.22),
		NumberSequenceKeypoint.new(1, 0.9),
	})
	emitter.LightEmission = 0.45
	emitter.LightInfluence = 0.55
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = boxPart
	return emitter
end

local function createRainMistEmitter(boxPart: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RainMist"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Lifetime = NumberRange.new(1.1, 1.9)
	emitter.Speed = NumberRange.new(1.5, 4.5)
	emitter.SpreadAngle = Vector2.new(120, 120)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(0.5, 2.2),
		NumberSequenceKeypoint.new(1, 2.8),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(205, 226, 248), Color3.fromRGB(175, 202, 232))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.78),
		NumberSequenceKeypoint.new(0.75, 0.82),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.2
	emitter.LightInfluence = 0.8
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = boxPart
	return emitter
end

local function createAmbientWeather(boxPart: Part, kind: string): Weather
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = kind
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Rate = 0
	emitter.Enabled = false

	local maxRate = 18
	if kind == "SpringPollen" then
		maxRate = 22
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.Lifetime = NumberRange.new(4, 7)
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0.4) })
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 200, 225), Color3.fromRGB(255, 240, 170))
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		emitter.RotSpeed = NumberRange.new(-90, 90)
		emitter.LightInfluence = 0.8
	elseif kind == "SummerFireflies" then
		maxRate = 16
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Lifetime = NumberRange.new(3, 5)
		emitter.Speed = NumberRange.new(1.5, 4)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0) })
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 230, 110), Color3.fromRGB(190, 255, 130))
		emitter.LightEmission = 1
		emitter.LightInfluence = 0
	elseif kind == "AutumnLeaves" then
		maxRate = 28
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.Lifetime = NumberRange.new(4, 7)
		emitter.Speed = NumberRange.new(4, 9)
		emitter.SpreadAngle = Vector2.new(45, 45)
		emitter.Size = NumberSequence.new(0.55)
		emitter.Color = ColorSequence.new(Color3.fromRGB(225, 110, 40), Color3.fromRGB(235, 180, 50))
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.85, 0.2), NumberSequenceKeypoint.new(1, 1) })
		emitter.RotSpeed = NumberRange.new(-140, 140)
		emitter.LightInfluence = 1
	else -- WinterFrost
		maxRate = 20
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Lifetime = NumberRange.new(3, 5)
		emitter.Speed = NumberRange.new(1, 3)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.35) })
		emitter.Color = ColorSequence.new(Color3.fromRGB(220, 240, 255))
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		emitter.LightEmission = 0.4
	end
	emitter.Parent = boxPart
	return { Emitter = emitter, Kind = kind, MaxRate = maxRate, Rate = 0 }
end

local function createWindStreakEmitter(boxPart: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "WindStreaks"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Lifetime = NumberRange.new(0.85, 1.45)
	emitter.Speed = NumberRange.new(18, 32)
	emitter.SpreadAngle = Vector2.new(6, 4)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.14),
		NumberSequenceKeypoint.new(0.45, 0.44),
		NumberSequenceKeypoint.new(1, 0.10),
	})
	emitter.Squash = NumberSequence.new(-3.4)
	emitter.Color = ColorSequence.new(Color3.fromRGB(245, 255, 250), Color3.fromRGB(200, 242, 225))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.25),
		NumberSequenceKeypoint.new(0.8, 0.32),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.45
	emitter.LightInfluence = 0.55
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = boxPart
	return emitter
end

local DEBRIS_COLORS: { [string]: ColorSequence } = {
	Printemps = ColorSequence.new(Color3.fromRGB(130, 210, 95), Color3.fromRGB(255, 195, 220)),
	Ete = ColorSequence.new(Color3.fromRGB(240, 220, 120), Color3.fromRGB(155, 210, 90)),
	Automne = ColorSequence.new(Color3.fromRGB(230, 105, 35), Color3.fromRGB(240, 180, 45)),
	Hiver = ColorSequence.new(Color3.fromRGB(225, 242, 255), Color3.fromRGB(255, 255, 255)),
}

local function createWindDebrisEmitter(boxPart: Part): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "WindDebris"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Lifetime = NumberRange.new(1.2, 2.1)
	emitter.Speed = NumberRange.new(14, 24)
	emitter.SpreadAngle = Vector2.new(14, 9)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-320, 320)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.16),
		NumberSequenceKeypoint.new(0.5, 0.36),
		NumberSequenceKeypoint.new(1, 0.12),
	})
	emitter.Squash = NumberSequence.new(-0.55)
	emitter.Color = DEBRIS_COLORS.Printemps
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.15),
		NumberSequenceKeypoint.new(0.85, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.15
	emitter.LightInfluence = 0.85
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = boxPart
	return emitter
end

local function createWindRibbons()
	table.clear(windRibbons)
	for i = 1, WIND_RIBBON_COUNT do
		local carrier = makeFxPart("WindRibbon_" .. tostring(i), Vector3.new(0.2, 0.2, 0.2))
		local att0 = Instance.new("Attachment")
		att0.Position = Vector3.new(0, 0.15, 0)
		att0.Parent = carrier
		local att1 = Instance.new("Attachment")
		att1.Position = Vector3.new(0, -0.15, 0)
		att1.Parent = carrier

		local trail = Instance.new("Trail")
		trail.Attachment0 = att0
		trail.Attachment1 = att1
		trail.FaceCamera = true
		trail.Lifetime = 0.45
		trail.MinLength = 0.05
		trail.LightEmission = 0.55
		trail.LightInfluence = 0.45
		trail.Color = ColorSequence.new(Color3.fromRGB(242, 255, 252), Color3.fromRGB(195, 242, 225))
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.2, 1),
			NumberSequenceKeypoint.new(0.75, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0.25),
			NumberSequenceKeypoint.new(0.7, 0.38),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Enabled = false
		trail.Parent = carrier

		table.insert(windRibbons, {
			Carrier = carrier,
			Att0 = att0,
			Att1 = att1,
			Trail = trail,
			BasePos = Vector3.zero,
			Age = 0,
			Duration = 1,
			SpeedFactor = 2.2,
			WaveAmp = 1.0,
			WaveFreq = 8,
			Phase = 0,
			CurlFactor = 0,
			Active = false,
			JustSpawned = false,
		})
	end
end

local function spawnRibbonUpwind(ribbon: WindRibbon, focusPos: Vector3, windDir: Vector3, rightDir: Vector3, windLevel: number)
	local upwindDist = 7 + windLevel * 18
	ribbon.BasePos = focusPos
		- windDir * windRng:NextNumber(upwindDist * 0.55, upwindDist)
		+ rightDir * windRng:NextNumber(-22, 22)
		+ Vector3.new(0, windRng:NextNumber(-3.5, 11), 0)
	ribbon.Age = 0
	ribbon.Duration = windRng:NextNumber(0.65, 1.15)
	ribbon.SpeedFactor = windRng:NextNumber(2.0, 2.75)
	ribbon.WaveAmp = windRng:NextNumber(0.45, 1.15)
	ribbon.WaveFreq = windRng:NextNumber(6.5, 11.5)
	ribbon.Phase = windRng:NextNumber(0, math.pi * 2)
	ribbon.CurlFactor = if windRng:NextNumber() < (0.2 + windLevel * 0.55) then windRng:NextNumber(0.8, 1.9) else 0
	ribbon.Active = true
	ribbon.JustSpawned = true
	ribbon.Trail.Enabled = false
	ribbon.Carrier.CFrame = CFrame.new(ribbon.BasePos)
end

local function updateWindRibbons(dt: number, focusPos: Vector3, windFlat: Vector3, windSpeed: number, windLevel: number)
	local activeWind = not underCover and windSpeed > 0.8
	-- Nombre de rubans strictement proportionnel au niveau du vent (1 ruban en brise très légère -> 18 rubans en tempête).
	local desiredCount = if activeWind
		then math.clamp(math.ceil(windLevel * #windRibbons), 1, #windRibbons)
		else 0
	local windDir = if windSpeed > 0.1 then windFlat / windSpeed else Vector3.zAxis
	local rightDir = Vector3.new(-windDir.Z, 0, windDir.X)
	-- Épaisseur des rubans calée sur la force du vent : fins filets en brise douce, larges rubans en bourrasque.
	local halfWidth = 0.06 + windLevel * 0.30

	for i, ribbon in ipairs(windRibbons) do
		if i <= desiredCount and not ribbon.Active then
			spawnRibbonUpwind(ribbon, focusPos, windDir, rightDir, windLevel)
		elseif ribbon.Active then
			if ribbon.JustSpawned then
				ribbon.JustSpawned = false
				ribbon.Trail.Enabled = true
			end
			ribbon.Att0.Position = Vector3.new(0, halfWidth, 0)
			ribbon.Att1.Position = Vector3.new(0, -halfWidth, 0)
			ribbon.Age += dt
			if ribbon.Age >= ribbon.Duration then
				if i <= desiredCount then
					spawnRibbonUpwind(ribbon, focusPos, windDir, rightDir, windLevel)
				else
					ribbon.Active = false
					ribbon.Trail.Enabled = false
				end
			else
				-- Vitesse, ondulation et boucles réagissent en temps réel à la force instantanée du vent.
				local liveSpeed = math.max(6, windSpeed * ribbon.SpeedFactor)
				ribbon.BasePos += windDir * (liveSpeed * dt)

				local waveScale = 0.35 + windLevel * 1.45
				local angle = ribbon.Age * ribbon.WaveFreq + ribbon.Phase
				local lateral = math.sin(angle) * (ribbon.WaveAmp * waveScale)
				local vertical = math.cos(angle * 0.85) * (ribbon.WaveAmp * waveScale * 0.45)

				local curlAlong = 0
				local curlUp = 0
				local curlRadius = ribbon.CurlFactor * math.max(0, (windLevel - 0.2) / 0.8)
				if curlRadius > 0.05 then
					local t = ribbon.Age / ribbon.Duration
					if t > 0.25 and t < 0.75 then
						local loopT = (t - 0.25) / 0.5
						local loopAngle = loopT * math.pi * 2
						local env = math.sin(loopT * math.pi)
						curlAlong = -math.sin(loopAngle) * curlRadius * env
						curlUp = (1 - math.cos(loopAngle)) * curlRadius * env
					end
				end
				local pos = ribbon.BasePos
					+ windDir * curlAlong
					+ rightDir * lateral
					+ Vector3.new(0, vertical + curlUp, 0)
				ribbon.Carrier.CFrame = CFrame.new(pos)
			end
		end
	end
end

local function applyWindIntensityToEmitters(windLevel: number, streakEmitter: ParticleEmitter?, debrisEmitter: ParticleEmitter?)
	-- Quantifié par paliers de 5 % pour éviter d'allouer des NumberSequence à chaque image.
	local quantized = math.floor(windLevel * 20 + 0.5)
	if quantized == lastQuantizedWindLevel then
		return
	end
	lastQuantizedWindLevel = quantized
	local lvl = quantized / 20

	if streakEmitter then
		local peakSize = 0.14 + lvl * 0.44
		local minAlpha = math.clamp(0.62 - lvl * 0.46, 0.14, 0.65)
		streakEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, peakSize * 0.35),
			NumberSequenceKeypoint.new(0.45, peakSize),
			NumberSequenceKeypoint.new(1, peakSize * 0.25),
		})
		streakEmitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, minAlpha),
			NumberSequenceKeypoint.new(0.8, math.min(0.95, minAlpha + 0.1)),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	if debrisEmitter then
		local debrisPeak = 0.16 + lvl * 0.30
		debrisEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, debrisPeak * 0.45),
			NumberSequenceKeypoint.new(0.5, debrisPeak),
			NumberSequenceKeypoint.new(1, debrisPeak * 0.35),
		})
		local spin = 70 + lvl * 350
		debrisEmitter.RotSpeed = NumberRange.new(-spin, spin)
	end
end

local function createRainDrops()
	table.clear(rainDrops)
	for i = 1, RAIN_DROP_COUNT do
		local carrier = makeFxPart("RainDropStreak_" .. tostring(i), Vector3.new(0.2, 0.2, 0.2))
		local att0 = Instance.new("Attachment")
		att0.Position = Vector3.new(0, 0.12, 0)
		att0.Parent = carrier
		local att1 = Instance.new("Attachment")
		att1.Position = Vector3.new(0, -0.12, 0)
		att1.Parent = carrier

		local trail = Instance.new("Trail")
		trail.Attachment0 = att0
		trail.Attachment1 = att1
		trail.FaceCamera = true
		trail.Lifetime = 0.11
		trail.MinLength = 0.04
		trail.LightEmission = 0.6
		trail.LightInfluence = 0.4
		trail.Color = ColorSequence.new(Color3.fromRGB(235, 248, 255), Color3.fromRGB(165, 212, 250))
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.3, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.65, 0.32),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Enabled = false
		trail.Parent = carrier

		local ring = makeFxPart("RainSplashRing_" .. tostring(i), Vector3.new(0.12, 1.2, 1.2))
		ring.Shape = Enum.PartType.Cylinder
		ring.Material = Enum.Material.Glass
		ring.Color = Color3.fromRGB(190, 226, 255)
		ring.Transparency = 1

		local bead = makeFxPart("RainSplashBead_" .. tostring(i), Vector3.new(0.28, 0.28, 0.28))
		bead.Shape = Enum.PartType.Ball
		bead.Material = Enum.Material.Glass
		bead.Color = Color3.fromRGB(215, 240, 255)
		bead.Transparency = 1

		table.insert(rainDrops, {
			Carrier = carrier,
			Att0 = att0,
			Att1 = att1,
			Trail = trail,
			Ring = ring,
			Bead = bead,
			StartPos = Vector3.zero,
			HitPos = Vector3.zero,
			FallDuration = 0.3,
			SplashDuration = 0.35,
			MaxRingRadius = 3.2,
			BounceHeight = 1.1,
			Age = 0,
			State = "Idle",
			JustSpawned = false,
			HasGround = false,
		})
	end
end

local function spawnRainDrop(drop: RainDropFx, focusPos: Vector3, windFlat: Vector3, rainLevel: number)
	local spread = 24
	local targetXZ = focusPos + Vector3.new(windRng:NextNumber(-spread, spread), 0, windRng:NextNumber(-spread, spread))
	rainSplashParams.FilterDescendantsInstances = { getFolder() }
	local rayOrigin = Vector3.new(targetXZ.X, focusPos.Y + 26, targetXZ.Z)
	local hit = workspace:Raycast(rayOrigin, Vector3.new(0, -48, 0), rainSplashParams)
	local hitPos = if hit then hit.Position else Vector3.new(targetXZ.X, focusPos.Y - 6, targetXZ.Z)
	local fallHeight = windRng:NextNumber(16, 25)
	local fallSpeed = windRng:NextNumber(54, 72) * (0.9 + rainLevel * 0.25)
	local fallDur = math.max(0.18, fallHeight / fallSpeed)
	-- Le vent incline la trajectoire de chute vers le point d'impact.
	local windOffset = -windFlat * (fallDur * 0.55)
	local startPos = hitPos + Vector3.new(windOffset.X, fallHeight, windOffset.Z)

	local halfWidth = 0.04 + rainLevel * 0.08
	drop.Att0.Position = Vector3.new(0, halfWidth, 0)
	drop.Att1.Position = Vector3.new(0, -halfWidth, 0)
	drop.StartPos = startPos
	drop.HitPos = hitPos
	drop.FallDuration = fallDur
	drop.SplashDuration = windRng:NextNumber(0.28, 0.44)
	drop.MaxRingRadius = windRng:NextNumber(2.0, 3.6) * (0.75 + rainLevel * 0.55)
	drop.BounceHeight = windRng:NextNumber(0.55, 1.35) * (0.7 + rainLevel * 0.5)
	drop.Age = 0
	drop.State = "Falling"
	drop.JustSpawned = true
	drop.HasGround = hit ~= nil
	drop.Trail.Enabled = false
	drop.Ring.Transparency = 1
	drop.Bead.Transparency = 1
	drop.Carrier.CFrame = CFrame.new(startPos)
end

local function updateRainDrops(dt: number, focusPos: Vector3, windFlat: Vector3, rainLevel: number)
	local activeRain = not underCover and rainLevel > 0.03
	local desiredCount = if activeRain
		then math.clamp(math.ceil(rainLevel * #rainDrops), 1, #rainDrops)
		else 0

	for i, drop in ipairs(rainDrops) do
		if underCover then
			if drop.State ~= "Idle" then
				drop.State = "Idle"
				drop.Trail.Enabled = false
				drop.Ring.Transparency = 1
				drop.Bead.Transparency = 1
			end
		elseif i <= desiredCount and drop.State == "Idle" then
			spawnRainDrop(drop, focusPos, windFlat, rainLevel)
		elseif drop.State == "Falling" then
			if drop.JustSpawned then
				drop.JustSpawned = false
				drop.Trail.Enabled = true
			end
			drop.Age += dt
			local t = drop.Age / drop.FallDuration
			if t >= 1 then
				drop.Carrier.CFrame = CFrame.new(drop.HitPos)
				drop.Trail.Enabled = false
				if drop.HasGround then
					drop.State = "Splashing"
					drop.Age = 0
				elseif i <= desiredCount then
					spawnRainDrop(drop, focusPos, windFlat, rainLevel)
				else
					drop.State = "Idle"
				end
			else
				drop.Carrier.CFrame = CFrame.new(drop.StartPos:Lerp(drop.HitPos, t))
			end
		elseif drop.State == "Splashing" then
			drop.Age += dt
			local t = drop.Age / drop.SplashDuration
			if t >= 1 then
				drop.Ring.Transparency = 1
				drop.Bead.Transparency = 1
				if i <= desiredCount then
					spawnRainDrop(drop, focusPos, windFlat, rainLevel)
				else
					drop.State = "Idle"
				end
			else
				local diam = 0.6 + (drop.MaxRingRadius - 0.6) * (1 - (1 - t) * (1 - t))
				drop.Ring.Size = Vector3.new(0.10, diam, diam)
				drop.Ring.CFrame = CFrame.new(drop.HitPos + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90))
				drop.Ring.Transparency = 0.25 + t * 0.75

				local arc = 4 * t * (1 - t)
				local beadScale = 0.22 + (1 - t) * 0.14
				drop.Bead.Size = Vector3.new(beadScale, beadScale, beadScale)
				drop.Bead.CFrame = CFrame.new(drop.HitPos + Vector3.new(0, 0.12 + arc * drop.BounceHeight, 0))
				drop.Bead.Transparency = 0.2 + t * 0.8
			end
		end
	end
end

local function applyRainIntensityToEmitters(rainLevel: number, closeEmitter: ParticleEmitter?, farEmitter: ParticleEmitter?)
	local quantized = math.floor(rainLevel * 20 + 0.5)
	if quantized == lastQuantizedRainLevel then
		return
	end
	lastQuantizedRainLevel = quantized
	local lvl = quantized / 20

	local peakClose = 0.15 + lvl * 0.18
	local minAlpha = math.clamp(0.42 - lvl * 0.28, 0.12, 0.45)
	if closeEmitter then
		closeEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, peakClose * 0.45),
			NumberSequenceKeypoint.new(0.5, peakClose),
			NumberSequenceKeypoint.new(1, peakClose * 0.4),
		})
		closeEmitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.85),
			NumberSequenceKeypoint.new(0.18, minAlpha),
			NumberSequenceKeypoint.new(0.82, math.min(0.9, minAlpha + 0.08)),
			NumberSequenceKeypoint.new(1, 0.9),
		})
	end
	if farEmitter then
		local peakFar = 0.18 + lvl * 0.20
		farEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, peakFar * 0.5),
			NumberSequenceKeypoint.new(0.5, peakFar),
			NumberSequenceKeypoint.new(1, peakFar * 0.45),
		})
	end
end

local function updateWeather(dt: number, cameraCFrame: CFrame)
	local skyPart = sky
	if not skyPart then
		return
	end
	local cameraPosition = cameraCFrame.Position
	local focusPos = cameraPosition + cameraCFrame.LookVector * 9
	local windAttr = workspace:GetAttribute("WindVector")
	local wind = if typeof(windAttr) == "Vector3" then windAttr else Vector3.zero
	local windFlat = Vector3.new(wind.X, 0, wind.Z)
	local windSpeed = windFlat.Magnitude
	local windLevel = math.clamp(windSpeed / MAX_WIND_SPEED, 0, 1)
	local windDir = if windSpeed > 0.1 then windFlat / windSpeed else Vector3.zAxis

	-- Décalé en amont du vent pour que le rideau de pluie inclinée tombe toujours autour de la caméra.
	skyPart.CFrame = CFrame.new(cameraPosition + SKY_OFFSET - windFlat * 0.45)
	if ambientBox then
		local boxCenter = cameraPosition + Vector3.new(0, 10, 0)
		if windSpeed > 0.1 then
			ambientBox.CFrame = CFrame.lookAt(boxCenter, boxCenter + windFlat)
		else
			ambientBox.CFrame = CFrame.new(boxCenter)
		end
	end
	if windBox then
		-- Décalée en amont du vent proportionnellement à sa vitesse pour que les particules traversent l'écran.
		local windCenter = focusPos + Vector3.new(0, 2.5, 0) - windDir * (6 + windLevel * 12)
		if windSpeed > 0.1 then
			windBox.CFrame = CFrame.lookAt(windCenter, windCenter + windFlat)
		else
			windBox.CFrame = CFrame.new(windCenter)
		end
	end
	if rainBox then
		local rainCenter = focusPos + Vector3.new(0, 10, 0) - windFlat * 0.25
		rainBox.CFrame = CFrame.new(rainCenter)
	end

	shelterTimer -= dt
	if shelterTimer <= 0 then
		shelterTimer = SHELTER_CHECK_SECONDS
		underCover = workspace:Raycast(cameraPosition, SHELTER_RAY, shelterParams) ~= nil
	end

	local precipitation = workspace:GetAttribute("Precipitation")
	local rainIntensityAttr = workspace:GetAttribute("RainIntensity")
	local rawRainIntensity = if precipitation == "Rain"
		then (if typeof(rainIntensityAttr) == "number" then math.clamp(rainIntensityAttr, 0, 1) else 0.75)
		else 0
	local targetRainLevel = if underCover then 0 else rawRainIntensity
	local alpha = math.min(dt * RATE_SMOOTHING, 1)
	if underCover then
		smoothedRainLevel = math.max(0, smoothedRainLevel - dt * 3.5)
	else
		smoothedRainLevel += (targetRainLevel - smoothedRainLevel) * alpha
	end

	local ambientFx = workspace:GetAttribute("SeasonAmbientFx")
	local windAccel = wind * 0.45
	local farRainEmitter: ParticleEmitter? = nil
	for _, weather in ipairs(weathers) do
		local intensityScale = if weather.Kind == "Rain" then targetRainLevel else 1
		local target = if precipitation == weather.Kind and not underCover then weather.MaxRate * intensityScale else 0
		if underCover then
			weather.Rate = 0 -- coupure nette : pas de pluie dans les galeries
		else
			weather.Rate += (target - weather.Rate) * alpha
		end
		local enabled = weather.Rate > 1
		if weather.Emitter.Enabled ~= enabled then
			weather.Emitter.Enabled = enabled
		end
		if weather.Kind == "Rain" then
			farRainEmitter = weather.Emitter
		end
		if enabled then
			weather.Emitter.Acceleration = if weather.Kind == "Snow" then wind * 0.7 else wind * 1.25
			if math.abs(weather.Emitter.Rate - weather.Rate) > 2 then
				weather.Emitter.Rate = weather.Rate
			end
		end
	end

	-- Pluie dense de proximité + brume humide + gouttes 3D qui éclaboussent au sol.
	local rainActive = not underCover and smoothedRainLevel > 0.02
	local isHeavyRain = workspace:GetAttribute("RainHeavy") == true or smoothedRainLevel >= 0.7
	local heavyRainTriggered = rainActive and isHeavyRain and not wasHeavyRain
	wasHeavyRain = rainActive and isHeavyRain

	local closeRain = rainCloseEmitter
	local mistRain = rainMistEmitter
	if rainActive then
		applyRainIntensityToEmitters(smoothedRainLevel, closeRain, farRainEmitter)
	end
	if closeRain then
		if closeRain.Enabled ~= rainActive then
			closeRain.Enabled = rainActive
		end
		if rainActive then
			local targetCloseRate = 45 + smoothedRainLevel * 135 + smoothedRainLevel * smoothedRainLevel * 220
			if math.abs(closeRain.Rate - targetCloseRate) > 2 then
				closeRain.Rate = targetCloseRate
			end
			closeRain.Acceleration = wind * 1.2
			local minRainSpd = 44 + smoothedRainLevel * 16
			closeRain.Speed = NumberRange.new(minRainSpd, minRainSpd + 16)
			if heavyRainTriggered then
				closeRain:Emit(math.floor(18 + smoothedRainLevel * 28))
			end
		end
	end
	if mistRain then
		local mistActive = rainActive and smoothedRainLevel > 0.2
		if mistRain.Enabled ~= mistActive then
			mistRain.Enabled = mistActive
		end
		if mistActive then
			local mistRate = (smoothedRainLevel - 0.2) * 42
			if math.abs(mistRain.Rate - mistRate) > 1 then
				mistRain.Rate = mistRate
			end
			mistRain.Acceleration = wind * 0.35
		end
	end
	updateRainDrops(dt, focusPos, windFlat, smoothedRainLevel)

	for _, weather in ipairs(ambientWeathers) do
		local target = if ambientFx == weather.Kind and not underCover then weather.MaxRate else 0
		if underCover then
			weather.Rate = 0
		else
			weather.Rate += (target - weather.Rate) * alpha
		end
		local enabled = weather.Rate > 0.8
		if weather.Emitter.Enabled ~= enabled then
			weather.Emitter.Enabled = enabled
		end
		if enabled then
			if weather.Kind == "AutumnLeaves" then
				weather.Emitter.Acceleration = windAccel + Vector3.new(0, -1.5, 0)
			elseif weather.Kind == "SpringPollen" or weather.Kind == "WinterFrost" then
				weather.Emitter.Acceleration = wind * 0.3
			end
			if math.abs(weather.Emitter.Rate - weather.Rate) > 1.5 then
				weather.Emitter.Rate = weather.Rate
			end
		end
	end

	-- VFX de vent strictement proportionnels à la force actuelle du vent (windLevel 0..1).
	local isGust = workspace:GetAttribute("WindGust") == true
	local windActive = not underCover and windSpeed > 0.8
	local gustTriggered = windActive and isGust and not wasGust
	wasGust = windActive and isGust

	local streakEmitter = windStreakEmitter
	local debrisEmitter = windDebrisEmitter
	if windActive then
		applyWindIntensityToEmitters(windLevel, streakEmitter, debrisEmitter)
	end

	if streakEmitter then
		if streakEmitter.Enabled ~= windActive then
			streakEmitter.Enabled = windActive
		end
		if windActive then
			-- Débit continu de ~3/s (petite brise) jusqu'à ~125/s (violente rafale d'automne).
			local targetRate = 3 + windLevel * 38 + windLevel * windLevel * 84
			if math.abs(streakEmitter.Rate - targetRate) > 1 then
				streakEmitter.Rate = targetRate
			end
			local minSpd = math.max(7, windSpeed * 1.65)
			streakEmitter.Speed = NumberRange.new(minSpd, minSpd * 1.45)
			if gustTriggered then
				streakEmitter:Emit(math.floor(10 + windLevel * 24))
			end
		end
	end

	if debrisEmitter then
		local season = (workspace:GetAttribute("CurrentSeason") :: string?) or "Printemps"
		if season ~= lastDebrisSeason then
			lastDebrisSeason = season
			debrisEmitter.Color = DEBRIS_COLORS[season] or DEBRIS_COLORS.Printemps
		end
		if debrisEmitter.Enabled ~= windActive then
			debrisEmitter.Enabled = windActive
		end
		if windActive then
			-- Débit continu de ~2/s (petite brise) jusqu'à ~80/s (forte bourrasque).
			local debrisRate = 1.5 + windLevel * 22 + windLevel * windLevel * 56
			if math.abs(debrisEmitter.Rate - debrisRate) > 1 then
				debrisEmitter.Rate = debrisRate
			end
			local minDebrisSpd = math.max(5, windSpeed * 1.3)
			debrisEmitter.Speed = NumberRange.new(minDebrisSpd, minDebrisSpd * 1.5)
			debrisEmitter.Acceleration = Vector3.new(0, -1.2 + windLevel * 3.8, 0)
			if gustTriggered then
				debrisEmitter:Emit(math.floor(8 + windLevel * 18))
			end
		end
	end

	updateWindRibbons(dt, focusPos, windFlat, windSpeed, windLevel)
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
	local windAttr = workspace:GetAttribute("WindVector")
	local wind = if typeof(windAttr) == "Vector3" then Vector3.new(windAttr.X, 0, windAttr.Z) else Vector3.zero
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
			-- Le vent courbe la chute vers la position finale (départ décalé en amont du vent, arrivée exacte à t=1).
			local windDrift = -wind * ((1 - eased) * fallDuration[i] * 0.45)
			part.CFrame = fallRest[i] + Vector3.new(windDrift.X, fallHeight[i] * (1 - eased * eased), windDrift.Z)
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

	local boxPart = makeFxPart("AmbianceSaisonLocal", Vector3.new(110, 36, 110))
	ambientBox = boxPart
	table.insert(ambientWeathers, createAmbientWeather(boxPart, "SpringPollen"))
	table.insert(ambientWeathers, createAmbientWeather(boxPart, "SummerFireflies"))
	table.insert(ambientWeathers, createAmbientWeather(boxPart, "AutumnLeaves"))
	table.insert(ambientWeathers, createAmbientWeather(boxPart, "WinterFrost"))

	local windPart = makeFxPart("VentLocal", Vector3.new(56, 22, 56))
	windBox = windPart
	windStreakEmitter = createWindStreakEmitter(windPart)
	windDebrisEmitter = createWindDebrisEmitter(windPart)
	createWindRibbons()

	local rainPart = makeFxPart("PluieLocale", Vector3.new(46, 22, 46))
	rainBox = rainPart
	rainCloseEmitter = createRainCloseEmitter(rainPart)
	rainMistEmitter = createRainMistEmitter(rainPart)
	createRainDrops()

	for _, instance in ipairs(CollectionService:GetTagged("FxFalling")) do
		onFallingAdded(instance)
	end
	CollectionService:GetInstanceAddedSignal("FxFalling"):Connect(onFallingAdded)

	-- Avant le rendu : une valeur ClockTime répliquée (en retard) n'est jamais affichée une image.
	RunService:BindToRenderStep("WorldFxClock", Enum.RenderPriority.First.Value, updateClock)
	RunService.Heartbeat:Connect(function(dt: number)
		local camera = workspace.CurrentCamera
		if camera then
			local cameraCFrame = camera.CFrame
			updateFalls(cameraCFrame.Position)
			updateWeather(dt, cameraCFrame)
		end
	end)
end

return WorldFxController
