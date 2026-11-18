--!strict
-- ControlsHelpView.luau
-- Petit panneau d'aide des commandes, basculé par [H] (annoncé par la ligne d'infos du hotbar)
-- ou par un bouton "?" (indispensable en tactile, sans clavier). Glissement + fondu, aucun
-- travail par frame. Les lignes de vol/nage restent volontairement génériques : les contrôles de
-- mouvement fins appartiennent aux contrôleurs de personnage.

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
	{ "E · R · F", "Pouvoirs de l'espèce (adulte)" },
	{ "C (maintenir)", "Creuser" },
	{ "G", "Manger / boire" },
	{ "T", "Transporter la nourriture au nid" },
	{ "H", "Afficher / masquer cette aide" },
}

local PANEL_WIDTH = 330
local ROW_HEIGHT = 22
local PANEL_SHOWN = UDim2.new(1, -16, 0.5, 0)
local PANEL_HIDDEN = UDim2.new(1, 24, 0.5, 0)

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
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, 52 + #ROWS * ROW_HEIGHT)
	panel.BackgroundColor3 = Colors.Panel
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = screenGui
	UiTheme.Corner(panel, 12)
	UiTheme.Padding(panel, 14, 12)
	UiTheme.BindScale(panel, 760, 520, 0.6, 1.15)

	local title = UiTheme.Label(panel, Enum.Font.GothamBlack, 16, Colors.Text)
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Text = "Commandes"

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, 28)
	list.Size = UDim2.new(1, 0, 1, -28)
	list.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	for index, row in ipairs(ROWS) do
		local rowFrame = Instance.new("Frame")
		rowFrame.BackgroundTransparency = 1
		rowFrame.LayoutOrder = index
		rowFrame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		rowFrame.Parent = list

		local key = UiTheme.Label(rowFrame, Enum.Font.GothamBold, 12, Colors.Accent)
		key.Size = UDim2.new(0.38, 0, 1, 0)
		key.TextTruncate = Enum.TextTruncate.AtEnd
		key.Text = row[1]

		local action = UiTheme.Label(rowFrame, Enum.Font.Gotham, 12, Colors.Text)
		action.Position = UDim2.fromScale(0.38, 0)
		action.Size = UDim2.new(0.62, 0, 1, 0)
		action.TextTruncate = Enum.TextTruncate.AtEnd
		action.Text = row[2]
	end

	-- ---------- Bouton "?" (haut droite, sous le bloc de stats du hotbar) ----------
	local helpButton = Instance.new("TextButton")
	helpButton.Name = "HelpButton"
	helpButton.AnchorPoint = Vector2.new(1, 0)
	helpButton.Position = UDim2.new(1, -12, 0, 120)
	helpButton.Size = UDim2.fromOffset(34, 34)
	helpButton.BackgroundColor3 = Colors.Panel
	helpButton.BackgroundTransparency = 0.2
	helpButton.BorderSizePixel = 0
	helpButton.AutoButtonColor = true
	helpButton.Font = Enum.Font.GothamBlack
	helpButton.TextSize = 18
	helpButton.TextColor3 = Colors.Text
	helpButton.Text = "?"
	helpButton.Parent = screenGui
	UiTheme.Corner(helpButton, 17)
	local buttonStroke = UiTheme.Stroke(helpButton, Colors.Accent, 1.5, 0.7)

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
		UiTheme.Tween(buttonStroke, 0.2, { Transparency = if open then 0 else 0.7 })
		if open then
			panel.Visible = true
			UiTheme.Tween(panel, 0.3, { GroupTransparency = 0, Position = PANEL_SHOWN }, Enum.EasingStyle.Back)
		else
			local fade = UiTheme.Tween(panel, 0.2, { GroupTransparency = 1, Position = PANEL_HIDDEN })
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
		-- Ignore la saisie de texte (chat, recherche du menu de spawn).
		if input.KeyCode ~= Enum.KeyCode.H or gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		setOpen(not open)
	end)
end

return ControlsHelpView
