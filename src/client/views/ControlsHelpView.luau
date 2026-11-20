--!strict
-- ControlsHelpView.luau
-- Panneau d'aide des commandes au style organique « Micro Wild », basculé par [H] ou par le
-- bouton "?" en haut à droite. Glissement élastique + fondu, aucun travail par frame.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UiTheme = require(script.Parent.UiTheme)

local ControlsHelpView = {}

local mounted = false

local Colors = UiTheme.Colors

local ROWS: { { string } } = {
	{ "ZQSD / WASD", "Se déplacer" },
	{ "Espace", "Sauter / voler (adultes ailés)" },
	{ "Q / Ctrl", "Descendre (vol, nage)" },
	{ "Contre un mur", "Grimper (espèces grimpeuses)" },
	{ "Clic", "Mordre" },
	{ "E · R · F", "Pouvoirs de l'espèce (adulte), visés à la souris" },
	{ "F (maintenir)", "Araignées : fil de soie, se balancer (Espace = remonter)" },
	{ "C (maintenir)", "Creuser (vise avec la souris)" },
	{ "V", "Force du creusement (1 · 2 · 3)" },
	{ "G", "Manger / boire / ramasser feuilles, brindilles, cailloux" },
	{ "T", "Transporter la nourriture au nid" },
	{ "B (près du nid)", "Construire son nid : R tourner, clic poser, X supprimer" },
	{ "H", "Afficher / masquer cette aide" },
}

local PANEL_WIDTH = 342
local ROW_HEIGHT = 24
local PANEL_SHOWN = UDim2.new(1, -16, 0.5, 0)
local PANEL_HIDDEN = UDim2.new(1, 28, 0.5, 0)

function ControlsHelpView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ControlsHelpView"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 8
	screenGui.Parent = playerGui

	-- ---------- Panneau (bord droit, centré verticalement) ----------
	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = PANEL_HIDDEN
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 56 + #ROWS * ROW_HEIGHT)
	panel.BackgroundTransparency = 0.06
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = screenGui
	UiTheme.StylePanel(panel, 14, Colors.Border, 0.4)
	UiTheme.Padding(panel, 14, 12)
	UiTheme.BindScale(panel, 760, 520, 0.6, 1.15)

	local title = UiTheme.Label(panel, Enum.Font.GothamBlack, 16, Colors.Accent)
	title.Size = UDim2.new(1, 0, 0, 22)
	title.Text = "🌿 Commandes de survie"

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, 30)
	list.Size = UDim2.new(1, 0, 1, -30)
	list.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = list

	for index, row in ipairs(ROWS) do
		local rowFrame = Instance.new("Frame")
		rowFrame.BackgroundTransparency = 1
		rowFrame.LayoutOrder = index
		rowFrame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 2)
		rowFrame.Parent = list

		local keyBadge = UiTheme.Label(rowFrame, Enum.Font.GothamBold, 11, Colors.Accent)
		keyBadge.Size = UDim2.new(0.36, -6, 1, -2)
		keyBadge.Position = UDim2.fromOffset(0, 1)
		keyBadge.BackgroundTransparency = 0
		keyBadge.BackgroundColor3 = Colors.Card
		keyBadge.TextXAlignment = Enum.TextXAlignment.Center
		keyBadge.TextTruncate = Enum.TextTruncate.AtEnd
		keyBadge.Text = row[1]
		UiTheme.Corner(keyBadge, 6)
		UiTheme.Stroke(keyBadge, Colors.Border, 1, 0.72)

		local action = UiTheme.Label(rowFrame, Enum.Font.GothamMedium, 12, Colors.Text)
		action.Position = UDim2.fromScale(0.38, 0)
		action.Size = UDim2.new(0.62, 0, 1, 0)
		action.TextTruncate = Enum.TextTruncate.AtEnd
		action.Text = row[2]
	end

	-- ---------- Bouton "?" (haut droite, sous le bloc de stats du hotbar) ----------
	local helpButton = Instance.new("TextButton")
	helpButton.Name = "HelpButton"
	helpButton.AnchorPoint = Vector2.new(1, 0)
	helpButton.Position = UDim2.new(1, -12, 0, 116)
	helpButton.Size = UDim2.fromOffset(36, 36)
	helpButton.BackgroundColor3 = Colors.Card
	helpButton.BackgroundTransparency = 0.12
	helpButton.BorderSizePixel = 0
	helpButton.AutoButtonColor = false
	helpButton.Font = Enum.Font.GothamBlack
	helpButton.TextSize = 18
	helpButton.TextColor3 = Colors.Accent
	helpButton.Text = "?"
	helpButton.Parent = screenGui
	UiTheme.Corner(helpButton, 18)
	local buttonStroke = UiTheme.Stroke(helpButton, Colors.Accent, 1.5, 0.55)
	UiTheme.BindButtonFX(helpButton, 1.08, 0.92)

	-- ---------- Bascule ----------
	local open = false
	local sequence = 0
	local function setOpen(value: boolean)
		if value == open then
			return
		end
		open = value
		sequence += 1
		local mySequence = sequence
		UiTheme.Tween(buttonStroke, 0.2, { Transparency = if open then 0 else 0.55 })
		UiTheme.Tween(helpButton, 0.2, {
			BackgroundColor3 = if open then Colors.Accent else Colors.Card,
			TextColor3 = if open then Colors.AccentDark else Colors.Accent,
		})
		if open then
			panel.Visible = true
			UiTheme.Tween(panel, 0.32, { GroupTransparency = 0, Position = PANEL_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		else
			local fade = UiTheme.Tween(panel, 0.22, { GroupTransparency = 1, Position = PANEL_HIDDEN })
			fade.Completed:Once(function()
				if sequence == mySequence then
					panel.Visible = false
				end
			end)
		end
	end

	helpButton.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.KeyCode ~= Enum.KeyCode.H or gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		setOpen(not open)
	end)
end

return ControlsHelpView
