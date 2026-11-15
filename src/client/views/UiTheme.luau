--!strict
-- UiTheme.luau
-- Boîte à outils commune des vues (ce n'est PAS une vue : pas de Mount). Couleurs, petits
-- constructeurs (coins, contour, marges), tweens et mise à l'échelle responsive.
-- Ne requiert aucune autre vue (pas de cycle possible).

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiTheme = {}

UiTheme.Colors = {
	Panel = Color3.fromRGB(16, 18, 22),
	Card = Color3.fromRGB(30, 33, 40),
	CardHover = Color3.fromRGB(42, 46, 56),
	Track = Color3.fromRGB(38, 41, 48),
	Accent = Color3.fromRGB(95, 215, 120),
	AccentDark = Color3.fromRGB(15, 30, 15),
	Text = Color3.fromRGB(238, 240, 242),
	Muted = Color3.fromRGB(150, 155, 165),
	Warning = Color3.fromRGB(235, 175, 50),
	Danger = Color3.fromRGB(230, 80, 70),
	Cold = Color3.fromRGB(90, 170, 255),
	Info = Color3.fromRGB(70, 135, 230),
}

function UiTheme.Corner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

-- Contour du CADRE (sur un TextLabel/TextButton, le mode par défaut contournerait le texte).
function UiTheme.Stroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.Parent = parent
	return stroke
end

function UiTheme.Padding(parent: Instance, horizontal: number, vertical: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, horizontal)
	padding.PaddingRight = UDim.new(0, horizontal)
	padding.PaddingTop = UDim.new(0, vertical)
	padding.PaddingBottom = UDim.new(0, vertical)
	padding.Parent = parent
	return padding
end

-- Étiquette de texte transparente, alignée à gauche, prête à remplir.
function UiTheme.Label(parent: Instance, font: Enum.Font, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = font
	label.TextSize = textSize
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = parent
	return label
end

-- Crée ET joue un tween. Un nouveau tween sur la même propriété remplace l'ancien (moteur).
function UiTheme.Tween(
	instance: Instance,
	duration: number,
	goals: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local info = TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance, info, goals)
	tween:Play()
	return tween
end

-- Vrai sur téléphone/tablette sans clavier : le stick virtuel occupe le bas-gauche de l'écran.
function UiTheme.IsTouchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- ---------- Taille d'écran : un seul abonnement caméra partagé par toutes les vues ----------
local viewportCallbacks: { (Vector2) -> () } = {}
local cameraConnection: RBXScriptConnection? = nil
local hooked = false

local function fireViewport()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	if size.X < 2 or size.Y < 2 then
		return -- caméra pas encore dimensionnée
	end
	for _, callback in ipairs(viewportCallbacks) do
		task.spawn(callback, size)
	end
end

local function hookCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(fireViewport)
	end
	fireViewport()
end

-- Appelle `callback(taille)` tout de suite (si la caméra est prête) puis à chaque redimensionnement
-- ou rotation d'écran. Aucun coût par frame.
function UiTheme.OnViewportChanged(callback: (Vector2) -> ())
	table.insert(viewportCallbacks, callback)
	if not hooked then
		hooked = true
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
		hookCamera()
		return -- hookCamera vient d'appeler tous les callbacks, dont celui-ci
	end
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X >= 2 and camera.ViewportSize.Y >= 2 then
		task.spawn(callback, camera.ViewportSize)
	end
end

-- UIScale qui fait tenir un bloc conçu pour designWidth x designHeight dans l'écran.
function UiTheme.BindScale(parent: Instance, designWidth: number, designHeight: number, minScale: number, maxScale: number): UIScale
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = parent
	UiTheme.OnViewportChanged(function(size: Vector2)
		uiScale.Scale = math.clamp(math.min(size.X / designWidth, size.Y / designHeight), minScale, maxScale)
	end)
	return uiScale
end

return UiTheme
