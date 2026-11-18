--!strict
-- StatusEffectController.luau
-- Effets locaux des statuts posés par le serveur (attributs "Status_X" sur le personnage) :
--   Blind -> écran éblouissant ; InvertControls / MindControl -> touches inversées (Guêpe Émeraude)
-- + tremblements de caméra (remote CameraShake : Cri sonique, Écureuil qui saute sur l'arbre)
-- + vision trouble quand la Soif est basse (GDD §3), teinte givrée en hypothermie.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)

local StatusEffectController = {}

local player = Players.LocalPlayer
local started = false

-- Clés et couleurs précalculées : aucune concaténation ni Color3 alloué par frame.
local STATUS_BLIND = "Status_Blind"
local STATUS_INVERT = "Status_InvertControls"
local STATUS_MIND_CONTROL = "Status_MindControl"
local FROST_TINT = Color3.fromRGB(200, 225, 255)
local NEUTRAL_TINT = Color3.new(1, 1, 1)
local AMBIENT_REFRESH = 0.25 -- s : soif/froid changent lentement, inutile de les lire à chaque frame

local shakeUntil = 0
local shakeIntensity = 0
local shakeDuration = 1

-- Secousse de caméra locale (remote CameraShake, coups donnés/reçus via CombatFxController).
-- Seul ce module écrit Humanoid.CameraOffset ; une secousse faible n'écrase pas une forte en cours.
function StatusEffectController.Shake(intensity: number, duration: number)
	local now = os.clock()
	intensity = math.clamp(intensity, 0, 3)
	duration = math.clamp(duration, 0, 5)
	if duration <= 0 then
		return
	end
	if now < shakeUntil and shakeIntensity * (shakeUntil - now) / shakeDuration > intensity then
		return
	end
	shakeIntensity = intensity
	shakeDuration = duration
	shakeUntil = now + duration
end

local function getHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function hasStatus(key: string): boolean
	local character = player.Character
	return character ~= nil and character:GetAttribute(key) == true
end

function StatusEffectController.Start()
	if started then
		return
	end
	started = true

	local playerGui = player:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StatusEffectsOverlay"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 5
	screenGui.Parent = playerGui

	local blindFrame = Instance.new("Frame")
	blindFrame.Size = UDim2.fromScale(1, 1)
	blindFrame.BackgroundColor3 = Color3.fromRGB(255, 250, 210)
	blindFrame.BackgroundTransparency = 1
	blindFrame.BorderSizePixel = 0
	blindFrame.Parent = screenGui

	local invertLabel = Instance.new("TextLabel")
	invertLabel.AnchorPoint = Vector2.new(0.5, 0)
	invertLabel.Position = UDim2.new(0.5, 0, 0, 90)
	invertLabel.Size = UDim2.fromOffset(360, 32)
	invertLabel.BackgroundTransparency = 1
	invertLabel.Font = Enum.Font.GothamBlack
	invertLabel.TextSize = 22
	invertLabel.TextColor3 = Color3.fromRGB(80, 255, 170)
	invertLabel.TextStrokeTransparency = 0.3
	invertLabel.Text = "CONTRÔLE MENTAL : touches inversées !"
	invertLabel.Visible = false
	invertLabel.Parent = screenGui

	local blur = Instance.new("BlurEffect")
	blur.Name = "ThirstBlur"
	blur.Size = 0
	blur.Parent = Lighting

	local frost = Instance.new("ColorCorrectionEffect")
	frost.Name = "HypothermiaTint"
	frost.TintColor = NEUTRAL_TINT
	frost.Parent = Lighting

	local wasBlind = false
	local blindFade: Tween? = nil
	local controls: any = nil
	task.spawn(function()
		local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		if playerModule then
			local ok, module = pcall(require, playerModule)
			if ok then
				controls = (module :: any):GetControls()
			end
		end
	end)

	-- Après le ControlModule (priorité Input) : notre Move() inverse remplace le sien pour la frame.
	RunService:BindToRenderStep("MicroWildInvertControls", Enum.RenderPriority.Character.Value + 1, function()
		local inverted = hasStatus(STATUS_INVERT) or hasStatus(STATUS_MIND_CONTROL)
		invertLabel.Visible = inverted
		if not inverted or not controls then
			return
		end
		local humanoid = getHumanoid()
		local camera = workspace.CurrentCamera
		if not humanoid or not camera then
			return
		end
		local moveVector: Vector3 = controls:GetMoveVector()
		if moveVector.Magnitude < 0.01 then
			return
		end
		local world = camera.CFrame:VectorToWorldSpace(moveVector)
		local flat = Vector3.new(world.X, 0, world.Z)
		if flat.Magnitude > 0.01 then
			humanoid:Move(-flat.Unit, false)
		end
	end)

	RunService.RenderStepped:Connect(function()
		-- Éblouissement.
		local blind = hasStatus(STATUS_BLIND)
		if blind and not wasBlind then
			if blindFade then
				blindFade:Cancel()
			end
			blindFrame.BackgroundTransparency = 0
		elseif not blind and wasBlind then
			blindFade = TweenService:Create(blindFrame, TweenInfo.new(0.6), { BackgroundTransparency = 1 })
			;(blindFade :: Tween):Play()
		end
		wasBlind = blind

		-- Tremblement de caméra.
		local humanoid = getHumanoid()
		if humanoid then
			local shakeLeft = shakeUntil - os.clock()
			if shakeLeft > 0 then
				-- L'amplitude décroît jusqu'à zéro : pas de coupure nette en fin de secousse.
				local amplitude = shakeIntensity * shakeLeft / shakeDuration
				humanoid.CameraOffset = Vector3.new(
					(math.random() - 0.5) * amplitude,
					(math.random() - 0.5) * amplitude,
					(math.random() - 0.5) * amplitude
				)
			elseif humanoid.CameraOffset ~= Vector3.zero then
				humanoid.CameraOffset = Vector3.zero
			end
		end
	end)

	-- Soif : vision trouble ; hypothermie : teinte bleutée. Écrit seulement quand la valeur change.
	task.spawn(function()
		local wasCold = false
		while true do
			local thirst = (player:GetAttribute("Thirst") :: number?) or 100
			local blurSize = if thirst < 20 then (20 - thirst) * 0.6 else 0
			if blur.Size ~= blurSize then
				blur.Size = blurSize
			end
			local bodyTemp = (player:GetAttribute("BodyTemperature") :: number?) or 20
			local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
			local cold = species ~= nil and bodyTemp < species.IdealTempMin
			if cold ~= wasCold then
				wasCold = cold
				frost.TintColor = if cold then FROST_TINT else NEUTRAL_TINT
				frost.Saturation = if cold then -0.3 else 0
			end
			task.wait(AMBIENT_REFRESH)
		end
	end)

	Remotes.Get("CameraShake").OnClientEvent:Connect(function(intensity: unknown, duration: unknown)
		if typeof(intensity) ~= "number" or typeof(duration) ~= "number" then
			return
		end
		StatusEffectController.Shake(intensity :: number, duration :: number)
	end)
end

return StatusEffectController
