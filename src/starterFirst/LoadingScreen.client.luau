--!strict
-- LoadingScreen.client.luau
-- Écran de chargement (ReplicatedFirst.startFirst) au thème organique « Micro Wild : Survival » :
-- vitrine 3D d'un œuf posé sur sa feuille moussue, halo bioluminescent, barre de progression
-- organique et astuces en fondu. Ne requiert aucun module externe (ReplicatedFirst tourne avant
-- la réplication du reste).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local WORLD_TIMEOUT = 45
local MIN_DISPLAY = 1.5
local SKIP_AFTER = 12 -- bouton « Entrer quand même » si la génération traîne

local TIPS = {
	"🥚 Restez au chaud : un œuf qui gèle ne grandit pas.",
	"🍃 [G] pour manger ou boire, [T] pour rapporter de la nourriture au nid.",
	"🍖 Sous 20% de Faim ou de Soif, votre croissance se met en pause.",
	"🦎 Les 5 animaux géants ne pardonnent pas : réfugiez-vous dans les abris.",
	"👑 À 100% de croissance, un adulte peut fonder une colonie et devenir Maman.",
	"🌿 [H] affiche l'aide des commandes de survie à tout moment.",
}

local PANEL_TOP = Color3.fromRGB(24, 38, 28)
local PANEL_DEEP = Color3.fromRGB(10, 16, 12)
local CARD_BG = Color3.fromRGB(22, 34, 25)
local TRACK = Color3.fromRGB(16, 25, 19)
local BORDER = Color3.fromRGB(78, 122, 86)
local ACCENT = Color3.fromRGB(108, 224, 118)
local GOLD = Color3.fromRGB(245, 192, 68)
local TEXT = Color3.fromRGB(242, 240, 228)
local MUTED = Color3.fromRGB(154, 172, 156)

local startTime = os.clock()
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

ReplicatedFirst:RemoveDefaultLoadingScreen()

local root = Instance.new("CanvasGroup")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = Color3.new(1, 1, 1)
root.BorderSizePixel = 0
root.Parent = screenGui

local gradient = Instance.new("UIGradient")
gradient.Rotation = 105
gradient.Color = ColorSequence.new(PANEL_TOP, PANEL_DEEP)
gradient.Parent = root

local content = Instance.new("Frame")
content.Name = "Content"
content.AnchorPoint = Vector2.new(0.5, 0.5)
content.Position = UDim2.fromScale(0.5, 0.5)
content.Size = UDim2.fromOffset(440, 284)
content.BackgroundColor3 = CARD_BG
content.BackgroundTransparency = 0.15
content.BorderSizePixel = 0
content.Parent = root

local contentCorner = Instance.new("UICorner")
contentCorner.CornerRadius = UDim.new(0, 18)
contentCorner.Parent = content

local contentStroke = Instance.new("UIStroke")
contentStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
contentStroke.Color = BORDER
contentStroke.Thickness = 1.5
contentStroke.Transparency = 0.4
contentStroke.Parent = content

local contentScale = Instance.new("UIScale")
contentScale.Parent = content

local function label(parent: Instance, font: Enum.Font, size: number, color: Color3, y: number, height: number): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextSize = size
	text.TextColor3 = color
	text.TextWrapped = true
	text.Position = UDim2.fromOffset(16, y)
	text.Size = UDim2.new(1, -32, 0, height)
	text.Text = ""
	text.Parent = parent
	return text
end

-- ---------- Vitrine 3D de l'œuf sur sa feuille moussue ----------
local eggBox = Instance.new("Frame")
eggBox.Name = "EggBox3D"
eggBox.AnchorPoint = Vector2.new(0.5, 0)
eggBox.Position = UDim2.new(0.5, 0, 0, 14)
eggBox.Size = UDim2.fromOffset(76, 76)
eggBox.BackgroundColor3 = PANEL_DEEP
eggBox.BorderSizePixel = 0
eggBox.Parent = content

local eggBoxCorner = Instance.new("UICorner")
eggBoxCorner.CornerRadius = UDim.new(0, 38)
eggBoxCorner.Parent = eggBox

local eggBoxStroke = Instance.new("UIStroke")
eggBoxStroke.Color = ACCENT
eggBoxStroke.Thickness = 1.5
eggBoxStroke.Transparency = 0.35
eggBoxStroke.Parent = eggBox

local eggViewport = Instance.new("ViewportFrame")
eggViewport.Size = UDim2.fromScale(1, 1)
eggViewport.BackgroundTransparency = 1
eggViewport.Ambient = Color3.fromRGB(165, 185, 168)
eggViewport.LightColor = Color3.fromRGB(255, 245, 215)
eggViewport.LightDirection = Vector3.new(-0.5, -1, -0.5)
eggViewport.Parent = eggBox

local eggCam = Instance.new("Camera")
eggCam.FieldOfView = 34
eggCam.CFrame = CFrame.lookAt(Vector3.new(2.1, 1.5, 2.1), Vector3.new(0, 0.45, 0))
eggCam.Parent = eggViewport
eggViewport.CurrentCamera = eggCam

local eggModel = Instance.new("Model")
eggModel.Parent = eggViewport

local function makeSpherePart(size: Vector3, cf: CFrame, color: Color3, transparency: number?): Part
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	p.Parent = eggModel
	return p
end

makeSpherePart(Vector3.new(1.45, 0.12, 1.65), CFrame.new(0, 0.04, 0), Color3.fromRGB(95, 155, 68))
local eggPart = makeSpherePart(Vector3.new(0.82, 1.12, 0.82), CFrame.new(0, 0.58, 0), Color3.fromRGB(246, 240, 220))
makeSpherePart(Vector3.new(0.16, 0.26, 0.12), CFrame.new(0.16, 0.82, 0.22), Color3.new(1, 1, 1), 0.35)

local eggScale = Instance.new("UIScale")
eggScale.Parent = eggBox
local eggPulse = TweenService:Create(
	eggScale,
	TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Scale = 1.07 }
)
eggPulse:Play()

local eggBreathe = TweenService:Create(
	eggPart,
	TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Size = Vector3.new(0.88, 1.18, 0.88) }
)
eggBreathe:Play()

local title = label(content, Enum.Font.GothamBlack, 26, TEXT, 96, 32)
title.Text = "MICRO WILD : SURVIVAL"

local status = label(content, Enum.Font.GothamBold, 14, ACCENT, 130, 20)
status.Text = "Éveil de l'écosystème…"

local track = Instance.new("Frame")
track.Name = "Track"
track.Position = UDim2.fromOffset(36, 158)
track.Size = UDim2.new(1, -72, 0, 10)
track.BackgroundColor3 = TRACK
track.BorderSizePixel = 0
track.Parent = content
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(0, 5)
trackCorner.Parent = track
local trackStroke = Instance.new("UIStroke")
trackStroke.Color = BORDER
trackStroke.Thickness = 1
trackStroke.Transparency = 0.65
trackStroke.Parent = track

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = ACCENT
fill.BorderSizePixel = 0
fill.Parent = track
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 5)
fillCorner.Parent = fill

local tip = label(content, Enum.Font.GothamMedium, 12, MUTED, 188, 42)
tip.Text = TIPS[math.random(1, #TIPS)]

local percent = label(content, Enum.Font.GothamBold, 11, MUTED, 171, 14)
percent.TextXAlignment = Enum.TextXAlignment.Right
percent.Position = UDim2.fromOffset(36, 171)
percent.Size = UDim2.new(1, -72, 0, 14)

local skipButton = Instance.new("TextButton")
skipButton.Name = "Skip"
skipButton.AnchorPoint = Vector2.new(0.5, 1)
skipButton.Position = UDim2.new(0.5, 0, 1, -10)
skipButton.Size = UDim2.fromOffset(170, 26)
skipButton.BackgroundColor3 = TRACK
skipButton.BorderSizePixel = 0
skipButton.AutoButtonColor = true
skipButton.Font = Enum.Font.GothamBold
skipButton.TextSize = 12
skipButton.TextColor3 = MUTED
skipButton.Text = "Entrer quand même ›"
skipButton.Visible = false
skipButton.Parent = content
local skipCorner = Instance.new("UICorner")
skipCorner.CornerRadius = UDim.new(0, 8)
skipCorner.Parent = skipButton
local skipStroke = Instance.new("UIStroke")
skipStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
skipStroke.Color = BORDER
skipStroke.Transparency = 0.5
skipStroke.Parent = skipButton
local skipped = false
skipButton.MouseButton1Click:Connect(function()
	skipped = true
end)

local function fitToScreen()
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 1 then
		local size = camera.ViewportSize
		contentScale.Scale = math.clamp(math.min(size.X / 480, size.Y / 340), 0.6, 1.35)
	end
end
local viewportConnection: RBXScriptConnection? = nil
local function hookCamera()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToScreen)
	end
	fitToScreen()
end
hookCamera()
local cameraConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)

local function progressTo(ratio: number, seconds: number)
	TweenService:Create(fill, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(ratio, 1),
	}):Play()
	percent.Text = string.format("%d%%", math.floor(ratio * 100))
end

progressTo(0.35, 2)
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local STATUS_BASE = "Génération de la forêt et de la mare"
local DOTS = { "", ".", "..", "..." }
status.Text = STATUS_BASE .. "…"
local waitStart = os.clock()
local deadline = waitStart + WORLD_TIMEOUT
local tipClock = os.clock()
local step = 0
while workspace:GetAttribute("WorldGenerated") ~= true and os.clock() < deadline and not skipped do
	task.wait(0.25)
	step += 1
	local waited = os.clock() - waitStart
	-- Progression asymptotique : avance toujours, sans jamais prétendre avoir fini (0,35 → 0,95).
	if step % 2 == 0 then
		progressTo(0.35 + 0.6 * (1 - math.exp(-waited / 9)), 0.5)
		status.Text = STATUS_BASE .. DOTS[(step // 2) % #DOTS + 1]
	end
	if waited > SKIP_AFTER and not skipButton.Visible then
		skipButton.Visible = true
		skipButton.TextTransparency = 1
		TweenService:Create(skipButton, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
	end
	if os.clock() - tipClock > 5 then
		tipClock = os.clock()
		TweenService:Create(tip, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		task.delay(0.2, function()
			tip.Text = TIPS[math.random(1, #TIPS)]
			TweenService:Create(tip, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
		end)
	end
end
if workspace:GetAttribute("WorldGenerated") ~= true and not skipped then
	warn("[LoadingScreen] WorldGenerated toujours absent après " .. tostring(WORLD_TIMEOUT) .. " s : on continue quand même.")
end

status.Text = "Éclosion prête !"
status.TextColor3 = GOLD
progressTo(1, 0.3)
local remaining = MIN_DISPLAY - (os.clock() - startTime)
task.wait(math.max(remaining, 0.4))

local fadeOut = TweenService:Create(root, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
	GroupTransparency = 1,
})
fadeOut:Play()
fadeOut.Completed:Wait()
eggPulse:Cancel()
eggBreathe:Cancel()
cameraConnection:Disconnect()
if viewportConnection then
	viewportConnection:Disconnect()
end
screenGui:Destroy()
