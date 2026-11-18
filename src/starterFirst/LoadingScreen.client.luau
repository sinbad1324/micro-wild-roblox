--!strict
-- LoadingScreen.client.luau
-- Écran de chargement (ReplicatedFirst.startFirst) : remplace celui de Roblox et reste affiché
-- jusqu'à ce que le jeu soit chargé ET que le serveur ait fini de générer la carte
-- (attribut workspace "WorldGenerated"). Ne requiert aucun module (ReplicatedFirst tourne avant
-- la réplication du reste) : uniquement des services. Aucun travail par frame : animations en
-- tweens bouclés créés une seule fois.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

-- Repli : une erreur de génération ne doit jamais bloquer le joueur derrière l'écran.
local WORLD_TIMEOUT = 45
-- Évite un simple flash quand tout est déjà prêt.
local MIN_DISPLAY = 1.5

local TIPS = {
	"Restez au chaud : un œuf qui gèle ne grandit pas.",
	"[G] pour manger ou boire, [T] pour transporter de la nourriture au nid.",
	"Sous 20 de Faim ou de Soif, votre croissance se met en pause.",
	"Les animaux géants ne pardonnent pas : cachez-vous dans les abris.",
	"À 100% de croissance, un adulte peut fonder une colonie.",
	"[H] affiche l'aide des commandes à tout moment.",
}

local PANEL = Color3.fromRGB(16, 18, 22)
local TRACK = Color3.fromRGB(38, 41, 48)
local ACCENT = Color3.fromRGB(95, 215, 120)
local TEXT = Color3.fromRGB(238, 240, 242)
local MUTED = Color3.fromRGB(150, 155, 165)

local startTime = os.clock()
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

-- Le nôtre est en place : on peut retirer celui de Roblox sans écran vide entre les deux.
ReplicatedFirst:RemoveDefaultLoadingScreen()

local root = Instance.new("CanvasGroup")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = PANEL
root.BorderSizePixel = 0
root.Parent = screenGui

local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Color = ColorSequence.new(Color3.fromRGB(24, 40, 28), PANEL)
gradient.Parent = root

local content = Instance.new("Frame")
content.Name = "Content"
content.AnchorPoint = Vector2.new(0.5, 0.5)
content.Position = UDim2.fromScale(0.5, 0.5)
content.Size = UDim2.fromOffset(420, 200)
content.BackgroundTransparency = 1
content.Parent = root

local contentScale = Instance.new("UIScale")
contentScale.Parent = content

local function label(parent: Instance, font: Enum.Font, size: number, color: Color3, y: number, height: number): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextSize = size
	text.TextColor3 = color
	text.TextWrapped = true
	text.Position = UDim2.fromOffset(0, y)
	text.Size = UDim2.new(1, 0, 0, height)
	text.Text = ""
	text.Parent = parent
	return text
end

-- Œuf stylisé qui "respire" (un seul tween en boucle).
local egg = Instance.new("Frame")
egg.Name = "Egg"
egg.AnchorPoint = Vector2.new(0.5, 0)
egg.Position = UDim2.new(0.5, 0, 0, 0)
egg.Size = UDim2.fromOffset(34, 44)
egg.BackgroundColor3 = Color3.fromRGB(245, 238, 215)
egg.BorderSizePixel = 0
egg.Parent = content
local eggCorner = Instance.new("UICorner")
eggCorner.CornerRadius = UDim.new(0.5, 0)
eggCorner.Parent = egg
local eggScale = Instance.new("UIScale")
eggScale.Parent = egg
local eggPulse = TweenService:Create(
	eggScale,
	TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Scale = 1.12 }
)
eggPulse:Play()

local title = label(content, Enum.Font.GothamBlack, 30, TEXT, 54, 36)
title.Text = "Micro Wild : Survival"

local status = label(content, Enum.Font.GothamMedium, 14, ACCENT, 96, 20)
status.Text = "Chargement du jeu…"

local track = Instance.new("Frame")
track.Name = "Track"
track.Position = UDim2.fromOffset(40, 124)
track.Size = UDim2.new(1, -80, 0, 8)
track.BackgroundColor3 = TRACK
track.BorderSizePixel = 0
track.Parent = content
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(0, 4)
trackCorner.Parent = track

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = ACCENT
fill.BorderSizePixel = 0
fill.Parent = track
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 4)
fillCorner.Parent = fill

local tip = label(content, Enum.Font.Gotham, 13, MUTED, 146, 40)
tip.Text = TIPS[math.random(1, #TIPS)]

-- Mise à l'échelle (téléphone -> écran large), recalculée seulement au redimensionnement.
local function fitToScreen()
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 1 then
		local size = camera.ViewportSize
		contentScale.Scale = math.clamp(math.min(size.X / 480, size.Y / 320), 0.6, 1.4)
	end
end
local viewportConnection: RBXScriptConnection? = nil
-- La caméra peut ne pas exister encore aussi tôt (ReplicatedFirst) : on se raccroche à chaque changement.
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

-- Progression "ressentie" : la barre avance doucement (sans jamais finir) tant qu'on attend.
local function progressTo(ratio: number, seconds: number)
	TweenService:Create(fill, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(ratio, 1),
	}):Play()
end

progressTo(0.35, 2)
if not game:IsLoaded() then
	game.Loaded:Wait()
end

status.Text = "Génération du monde…"
progressTo(0.9, 12)
local deadline = os.clock() + WORLD_TIMEOUT
local tipClock = os.clock()
while workspace:GetAttribute("WorldGenerated") ~= true and os.clock() < deadline do
	task.wait(0.25)
	-- Change d'astuce toutes les 5 s pendant une longue attente.
	if os.clock() - tipClock > 5 then
		tipClock = os.clock()
		tip.Text = TIPS[math.random(1, #TIPS)]
	end
end
if workspace:GetAttribute("WorldGenerated") ~= true then
	warn("[LoadingScreen] WorldGenerated toujours absent après " .. tostring(WORLD_TIMEOUT) .. " s : on continue quand même.")
end

status.Text = "Prêt !"
progressTo(1, 0.3)
local remaining = MIN_DISPLAY - (os.clock() - startTime)
task.wait(math.max(remaining, 0.4))

local fadeOut = TweenService:Create(root, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
	GroupTransparency = 1,
})
fadeOut:Play()
fadeOut.Completed:Wait()
eggPulse:Cancel()
cameraConnection:Disconnect()
if viewportConnection then
	viewportConnection:Disconnect()
end
screenGui:Destroy()
