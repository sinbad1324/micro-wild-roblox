--!strict
-- UiTheme.luau
-- Boîte à outils commune des vues (ce n'est PAS une vue : pas de Mount).
-- Thème visuel organique « Micro Wild : Survival » (forêt microscopique, chitine, mousse, ambre,
-- bioluminescence et saisons), constructeurs de style, effets de boutons et mise à l'échelle responsive.
-- Ne requiert aucune autre vue (pas de cycle possible).

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiTheme = {}

-- Palette organique « Micro-Forêt & Chitine » adaptée à l'univers du jeu.
UiTheme.Colors = {
	-- Fonds profonds (écorce sombre, mousse nocturne, terreau)
	Panel = Color3.fromRGB(16, 24, 19),
	PanelDeep = Color3.fromRGB(10, 16, 12),
	PanelTop = Color3.fromRGB(24, 36, 27),
	Card = Color3.fromRGB(26, 38, 30),
	CardTop = Color3.fromRGB(34, 50, 39),
	CardHover = Color3.fromRGB(38, 56, 43),
	CardSelected = Color3.fromRGB(44, 68, 50),
	Track = Color3.fromRGB(18, 27, 21),
	Border = Color3.fromRGB(78, 122, 86),

	-- Accents naturels (chlorophylle, bourgeon bioluminescent, ambre/miel, baies/venin, rosée)
	Accent = Color3.fromRGB(108, 224, 118),
	AccentBright = Color3.fromRGB(162, 250, 148),
	AccentDark = Color3.fromRGB(12, 28, 15),
	Gold = Color3.fromRGB(245, 192, 68),
	GoldDark = Color3.fromRGB(38, 25, 8),

	-- Textes (parchemin chaud & lichen doux)
	Text = Color3.fromRGB(242, 240, 228),
	Muted = Color3.fromRGB(154, 172, 156),

	-- États & alertes
	Warning = Color3.fromRGB(242, 182, 58),
	Danger = Color3.fromRGB(235, 82, 74),
	DangerDark = Color3.fromRGB(36, 12, 12),
	Cold = Color3.fromRGB(92, 188, 255),
	Info = Color3.fromRGB(78, 182, 232),
}

export type SeasonPalette = {
	Accent: Color3,
	Glow: Color3,
	Tint: Color3,
	Icon: string,
}

UiTheme.Seasons = {
	Printemps = {
		Accent = Color3.fromRGB(130, 235, 138),
		Glow = Color3.fromRGB(245, 165, 195),
		Tint = Color3.fromRGB(28, 46, 32),
		Icon = "🌸",
	},
	Ete = {
		Accent = Color3.fromRGB(248, 202, 78),
		Glow = Color3.fromRGB(135, 235, 110),
		Tint = Color3.fromRGB(44, 42, 22),
		Icon = "☀️",
	},
	Automne = {
		Accent = Color3.fromRGB(240, 138, 62),
		Glow = Color3.fromRGB(225, 95, 55),
		Tint = Color3.fromRGB(46, 30, 20),
		Icon = "🍁",
	},
	Hiver = {
		Accent = Color3.fromRGB(125, 205, 255),
		Glow = Color3.fromRGB(185, 235, 255),
		Tint = Color3.fromRGB(20, 34, 46),
		Icon = "❄️",
	},
} :: { [string]: SeasonPalette }

function UiTheme.GetSeasonPalette(seasonId: string?): SeasonPalette
	if typeof(seasonId) == "string" and UiTheme.Seasons[seasonId] then
		return UiTheme.Seasons[seasonId]
	end
	return UiTheme.Seasons.Printemps
end

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

-- Dégradé linéaire vertical ou incliné pour donner un aspect organique / chitineux aux panneaux.
function UiTheme.Gradient(parent: Instance, topColor: Color3, bottomColor: Color3, rotation: number?): UIGradient
	local existing = parent:FindFirstChildOfClass("UIGradient")
	local gradient = if existing then existing else Instance.new("UIGradient")
	gradient.Rotation = rotation or 90
	gradient.Color = ColorSequence.new(topColor, bottomColor)
	gradient.Parent = parent
	return gradient
end

-- Habillage complet d'un panneau principal (coins, dégradé forêt profonde, contour lumineux).
function UiTheme.StylePanel(panel: GuiObject, radius: number?, strokeColor: Color3?, strokeTransparency: number?): UIStroke
	panel.BackgroundColor3 = Color3.new(1, 1, 1)
	panel.BorderSizePixel = 0
	UiTheme.Corner(panel, radius or 14)
	UiTheme.Gradient(panel, UiTheme.Colors.PanelTop, UiTheme.Colors.PanelDeep, 100)
	return UiTheme.Stroke(panel, strokeColor or UiTheme.Colors.Border, 1.5, strokeTransparency or 0.55)
end

-- Habillage d'une carte (espèce, nid, emplacement de pouvoir).
function UiTheme.StyleCard(card: GuiObject, radius: number?, strokeColor: Color3?, strokeTransparency: number?): UIStroke
	card.BackgroundColor3 = UiTheme.Colors.Card
	card.BorderSizePixel = 0
	UiTheme.Corner(card, radius or 10)
	return UiTheme.Stroke(card, strokeColor or UiTheme.Colors.Border, 1.5, strokeTransparency or 0.72)
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

-- Animation fluide de bouton (survol + rebond élastique au clic via UIScale, sans déplacer la mise en page).
function UiTheme.BindButtonFX(button: GuiButton, hoverScale: number?, pressScale: number?): UIScale
	local existing = button:FindFirstChildOfClass("UIScale")
	local scale = if existing then existing else Instance.new("UIScale")
	scale.Parent = button

	local hScale = hoverScale or 1.035
	local pScale = pressScale or 0.94
	local hovered = false

	button.MouseEnter:Connect(function()
		hovered = true
		if button.Active ~= false then
			UiTheme.Tween(scale, 0.16, { Scale = hScale }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		UiTheme.Tween(scale, 0.16, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end)
	button.MouseButton1Down:Connect(function()
		if button.Active ~= false then
			UiTheme.Tween(scale, 0.09, { Scale = pScale }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end)
	button.MouseButton1Up:Connect(function()
		local target = if hovered then hScale else 1
		UiTheme.Tween(scale, 0.22, { Scale = target }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end)
	return scale
end

-- Petit rebond d'apparition ou de mise en valeur (pop élastique sur UIScale).
function UiTheme.Pop(target: Instance, fromScale: number?, duration: number?)
	local existing = target:FindFirstChildOfClass("UIScale")
	local scale = if existing then existing else Instance.new("UIScale")
	scale.Scale = fromScale or 0.86
	scale.Parent = target
	UiTheme.Tween(scale, duration or 0.28, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
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
