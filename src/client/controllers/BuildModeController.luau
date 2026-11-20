--!strict
-- BuildModeController.luau
-- Mode construction du nid (StarterPlayerScripts.controllers). [B] près du nid de sa famille :
-- catalogue des pièces du thème de l'espèce (NestPieces), aperçu fantôme qui suit la souris (centre
-- de l'écran en manette / tactile), [R] tourner, clic / bouton "Poser" pour placer, [X] mode
-- suppression (clic sur une pièce = la retirer, moitié remboursée), [B] / Échap pour quitter.
-- Le stock du nid est lu sur les attributs "Stock_<Matériau>" de son modèle (NestBuildingService) ;
-- le serveur valide tout (famille, distance, coût).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local AimUtil = require(ReplicatedStorage.shared.AimUtil)
local NestPieces = require(ReplicatedStorage.shared.NestPieces)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.Parent.views.UiTheme)

local BuildModeController = {}

local NEST_RADIUS = 18 -- GameConstants.NEST_RADIUS (serveur)
local BUILD_RADIUS = NEST_RADIUS * 1.6
local REACH = NEST_RADIUS * 2.5
local ROTATE_STEP = math.rad(45)
local AIM_DISTANCE = 120

local player = Players.LocalPlayer
local Colors = UiTheme.Colors

local active = false
local deleting = false
local selected: NestPieces.Piece? = nil
local yaw = 0
local ghost: Model? = nil
local ghostValid = false
local ghostCFrame = CFrame.identity
local hovered: Model? = nil
local nestModel: Model? = nil
local gui: ScreenGui? = nil
local stockLabel: TextLabel? = nil
local list: ScrollingFrame? = nil
local deleteButton: TextButton? = nil
local selection = Instance.new("SelectionBox")
selection.LineThickness = 0.06
selection.Color3 = Color3.fromRGB(235, 82, 74)
local renderConn: RBXScriptConnection? = nil

local PANEL_COLOR = Color3.fromRGB(26, 30, 26)

local function hint(text: string)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "Nid", Text = text, Duration = 4 })
	end)
end

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude

local function findNest(): Model?
	local familyId = player:GetAttribute("FamilyId")
	if type(familyId) ~= "string" then
		return nil
	end
	local nests = workspace:FindFirstChild("Nests")
	for _, descendant in ipairs(if nests then nests:GetDescendants() else workspace:GetDescendants()) do
		if descendant:IsA("Model") and descendant:GetAttribute("FamilyId") == familyId and descendant:GetAttribute("BuildTheme") ~= nil then
			return descendant
		end
	end
	return nil
end

local function nestCenter(model: Model): Vector3
	local center = model:GetAttribute("BuildCenter")
	return if typeof(center) == "Vector3" then center else model:GetPivot().Position
end

local function stockOf(model: Model, material: string): number
	local value = model:GetAttribute("Stock_" .. material)
	return if type(value) == "number" then value else 0
end

local function canAfford(model: Model, piece: NestPieces.Piece): boolean
	for material, amount in pairs(piece.Cost) do
		if stockOf(model, material) < (amount :: number) then
			return false
		end
	end
	return true
end

local function costText(piece: NestPieces.Piece): string
	local parts = {}
	for _, material in ipairs(NestPieces.MATERIAL_ORDER) do
		local amount = (piece.Cost :: any)[material]
		if amount then
			table.insert(parts, NestPieces.MATERIAL_ICONS[material] .. amount)
		end
	end
	return table.concat(parts, " ")
end

local function clearGhost()
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
end

local function makeGhost(piece: NestPieces.Piece)
	clearGhost()
	local model = NestPieces.Build(piece, CFrame.identity)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CastShadow = false
			part.Transparency = 0.45 + part.Transparency * 0.5
		end
	end
	model.Name = "BuildGhost"
	model.Parent = workspace
	ghost = model
end

local refreshList: () -> ()

local function refreshStock()
	local model = nestModel
	if not model or not stockLabel then
		return
	end
	local parts = {}
	for _, material in ipairs(NestPieces.MATERIAL_ORDER) do
		table.insert(parts, NestPieces.MATERIAL_ICONS[material] .. " " .. stockOf(model, material))
	end
	(stockLabel :: TextLabel).Text = "Stock du nid :  " .. table.concat(parts, "   ")
	refreshList()
end

refreshList = function()
	local model = nestModel
	local frame = list
	if not model or not frame then
		return
	end
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("TextButton") then
			local piece = NestPieces.Get(child.Name)
			if piece then
				local affordable = canAfford(model, piece)
				child.BackgroundTransparency = if selected == piece then 0.05 else (if affordable then 0.35 else 0.7)
				child.TextColor3 = if affordable then Colors.Text else Colors.Muted
			end
		end
	end
end

local function select(piece: NestPieces.Piece?)
	selected = piece
	deleting = false
	if deleteButton then
		deleteButton.Text = "🗑 Supprimer (X)"
	end
	if piece then
		makeGhost(piece)
	else
		clearGhost()
	end
	refreshList()
end

local function place()
	local piece = selected
	if not active or deleting or not piece or not ghostValid then
		return
	end
	Remotes.Get("RequestNestBuild"):FireServer("Place", piece.Id, ghostCFrame)
end

local function removeHovered()
	local target = hovered
	if active and deleting and target then
		Remotes.Get("RequestNestBuild"):FireServer("Remove", target)
	end
end

local function toggleDelete()
	deleting = not deleting
	if deleting then
		selected = nil
		clearGhost()
	end
	if deleteButton then
		deleteButton.Text = if deleting then "✖ Fin suppression (X)" else "🗑 Supprimer (X)"
	end
	refreshList()
end

local function button(parent: Instance, text: string, size: UDim2, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.BackgroundColor3 = PANEL_COLOR
	b.BackgroundTransparency = 0.35
	b.TextColor3 = Colors.Text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.Text = text
	b.AutoButtonColor = true
	UiTheme.Corner(b, 8)
	b.Parent = parent
	b.Activated:Connect(onClick)
	return b
end

local exit: () -> ()

local function buildGui(theme: string)
	local screen = Instance.new("ScreenGui")
	screen.Name = "BuildModeGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -12, 0.5, 0)
	panel.Size = UDim2.fromOffset(270, 420)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.15
	panel.Parent = screen
	UiTheme.StylePanel(panel, 12)
	UiTheme.Padding(panel, 10, 10)

	local title = UiTheme.Label(panel, Enum.Font.GothamBlack, 15, Colors.Text)
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Text = "🏗 Construction — " .. (NestPieces.THEME_NAMES[theme] or theme)

	local stock = UiTheme.Label(panel, Enum.Font.GothamBold, 12, Colors.Muted)
	stock.Position = UDim2.fromOffset(0, 22)
	stock.Size = UDim2.new(1, 0, 0, 16)
	stockLabel = stock

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(0, 44)
	scroll.Size = UDim2.new(1, 0, 1, -128)
	scroll.BackgroundTransparency = 1
	scroll.ScrollBarThickness = 4
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = scroll
	list = scroll

	for _, piece in ipairs(NestPieces.ForTheme(theme)) do
		local entry = button(scroll, string.format("%s   %s", piece.Name, costText(piece)), UDim2.new(1, -6, 0, 30), function()
			select(if selected == piece then nil else piece)
		end)
		entry.Name = piece.Id
		entry.TextXAlignment = Enum.TextXAlignment.Left
		UiTheme.Padding(entry, 8, 0)
	end

	local row = Instance.new("Frame")
	row.Position = UDim2.new(0, 0, 1, -78)
	row.Size = UDim2.new(1, 0, 0, 78)
	row.BackgroundTransparency = 1
	row.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.5, -3, 0, 34)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.Parent = row
	button(row, "✅ Poser", UDim2.new(), place)
	button(row, "⟳ Tourner (R)", UDim2.new(), function()
		yaw += ROTATE_STEP
	end)
	deleteButton = button(row, "🗑 Supprimer (X)", UDim2.new(), toggleDelete)
	button(row, "✖ Quitter (B)", UDim2.new(), function()
		exit()
	end)
	UiTheme.Pop(panel, 0.85, 0.25)
end

-- Chaque frame : aperçu au point visé (vert = posable, rouge = trop loin) ou pièce survolée à retirer.
local function onRender()
	local model = nestModel
	local camera = workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not model or not model.Parent or not camera or not root or not root:IsA("BasePart") then
		exit()
		return
	end
	local center = nestCenter(model)
	if (root.Position - center).Magnitude > REACH then
		exit()
		return
	end
	local ignore: { Instance } = { character :: Instance }
	if ghost then
		table.insert(ignore, ghost)
	end
	aimParams.FilterDescendantsInstances = ignore
	local start, direction = AimUtil.Ray(camera, root.Position)
	local hit = workspace:Raycast(start, direction * AIM_DISTANCE, aimParams)

	selection.Adornee = nil
	hovered = nil
	if deleting then
		local construction = model:FindFirstChild("Construction")
		local instance = hit and hit.Instance
		if construction and instance then
			local pieceModel = instance:FindFirstAncestorOfClass("Model")
			if pieceModel and pieceModel.Parent == construction then
				hovered = pieceModel
				selection.Adornee = pieceModel
				selection.Parent = gui
			end
		end
		return
	end

	local currentGhost = ghost
	if not currentGhost or not hit then
		ghostValid = false -- rien de visé : pas de pose avec un ancien emplacement
		return
	end
	local position = hit.Position
	local offset = position - center
	ghostValid = Vector2.new(offset.X, offset.Z).Magnitude <= BUILD_RADIUS and math.abs(offset.Y) <= 25
		and selected ~= nil and canAfford(model, selected :: NestPieces.Piece)
	ghostCFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	currentGhost:PivotTo(ghostCFrame)
	local tint = if ghostValid then Color3.fromRGB(120, 230, 130) else Color3.fromRGB(235, 90, 80)
	local highlight = currentGhost:FindFirstChildOfClass("Highlight")
	if not highlight then
		local created = Instance.new("Highlight")
		created.FillTransparency = 0.7
		created.OutlineTransparency = 0.2
		created.Parent = currentGhost
		highlight = created
	end
	(highlight :: Highlight).FillColor = tint;
	(highlight :: Highlight).OutlineColor = tint
end

local stockConns: { RBXScriptConnection } = {}

exit = function()
	if not active then
		return
	end
	active = false
	player:SetAttribute("BuildMode", nil) -- lu par AbilityController (pas de morsure au clic)
	select(nil)
	deleting = false
	hovered = nil
	selection.Adornee = nil
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	for _, conn in ipairs(stockConns) do
		conn:Disconnect()
	end
	table.clear(stockConns)
	ContextActionService:UnbindAction("MW_BuildRotate")
	ContextActionService:UnbindAction("MW_BuildDelete")
	ContextActionService:UnbindAction("MW_BuildExit")
	if gui then
		gui:Destroy()
		gui = nil
	end
	list, stockLabel, deleteButton = nil, nil, nil
	nestModel = nil
end

local function enter()
	local model = findNest()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not model then
		hint("Fondez ou rejoignez une colonie pour construire un nid.")
		return
	end
	if not root or not root:IsA("BasePart") or (root.Position - nestCenter(model)).Magnitude > REACH then
		hint("Approchez-vous de votre nid pour construire.")
		return
	end
	active = true
	nestModel = model
	player:SetAttribute("BuildMode", true)
	local theme = model:GetAttribute("BuildTheme")
	buildGui(if type(theme) == "string" then theme else "Feuillage")
	for _, material in ipairs(NestPieces.MATERIAL_ORDER) do
		table.insert(stockConns, model:GetAttributeChangedSignal("Stock_" .. material):Connect(refreshStock))
	end
	refreshStock()
	renderConn = RunService.RenderStepped:Connect(onRender)
	-- Priorité haute : R / X / Échap ne déclenchent pas les pouvoirs pendant la construction.
	ContextActionService:BindActionAtPriority("MW_BuildRotate", function(_, state)
		if state == Enum.UserInputState.Begin then
			yaw += ROTATE_STEP
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R, Enum.KeyCode.ButtonY)
	ContextActionService:BindActionAtPriority("MW_BuildDelete", function(_, state)
		if state == Enum.UserInputState.Begin then
			toggleDelete()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.X)
	ContextActionService:BindActionAtPriority("MW_BuildExit", function(_, state)
		if state == Enum.UserInputState.Begin then
			exit()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Escape)
end

function BuildModeController.Start()
	ContextActionService:BindAction("MW_BuildMode", function(_, state)
		if state == Enum.UserInputState.Begin then
			if active then
				exit()
			else
				enter()
			end
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.B)
	ContextActionService:SetTitle("MW_BuildMode", "Nid")
	ContextActionService:SetPosition("MW_BuildMode", UDim2.new(1, -170, 1, -290))

	-- Clic gauche (souris) : poser / supprimer. Les clics sur l'interface sont ignorés.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not active or gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			if deleting then
				removeHovered()
			else
				place()
			end
		end
	end)
	player.CharacterRemoving:Connect(function()
		exit()
	end)
end

return BuildModeController
