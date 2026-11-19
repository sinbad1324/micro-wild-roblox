--!strict
-- AdminPanelView.luau
-- Petit panneau de test visible seulement si le serveur a posé l'attribut IsAdmin (AdminService).
-- Touche ` (au-dessus de Tab) ou bouton "ADMIN" pour l'ouvrir/fermer. Les commandes sont
-- revérifiées côté serveur : ce panneau n'a aucun pouvoir par lui-même.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local AdminPanelView = {}

local mounted = false

local ACTIONS = {
	{ Label = "Grandir +10%", Command = "Grow", Amount = 10 },
	{ Label = "Grandir +25%", Command = "Grow", Amount = 25 },
	{ Label = "Adulte 100%", Command = "Adult", Amount = 0 },
	{ Label = "Remplir stats", Command = "Fill", Amount = 0 },
}

function AdminPanelView.Mount()
	if mounted then
		return
	end
	mounted = true
	local player = Players.LocalPlayer

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AdminPanelView"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 20
	screenGui.Enabled = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 8, 0.5, 0)
	toggle.Size = UDim2.fromOffset(64, 26)
	toggle.BackgroundColor3 = UiTheme.Colors.Danger
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 13
	toggle.TextColor3 = UiTheme.Colors.Text
	toggle.Text = "ADMIN"
	toggle.Parent = screenGui
	UiTheme.Corner(toggle, 6)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 80, 0.5, 0)
	panel.Size = UDim2.fromOffset(150, #ACTIONS * 36 + 8)
	panel.BackgroundColor3 = UiTheme.Colors.Panel
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = screenGui
	UiTheme.Corner(panel, 8)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = panel

	local remote = Remotes.Get("AdminCommand")
	for index, action in ipairs(ACTIONS) do
		local button = Instance.new("TextButton")
		button.LayoutOrder = index
		button.Size = UDim2.new(1, -8, 0, 32)
		button.BackgroundColor3 = UiTheme.Colors.Card
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 14
		button.TextColor3 = UiTheme.Colors.Text
		button.Text = action.Label
		button.Parent = panel
		UiTheme.Corner(button, 6)
		button.MouseButton1Click:Connect(function()
			remote:FireServer(action.Command, action.Amount)
		end)
	end

	local function togglePanel()
		panel.Visible = not panel.Visible
	end
	toggle.MouseButton1Click:Connect(togglePanel)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and screenGui.Enabled and input.KeyCode == Enum.KeyCode.Backquote then
			togglePanel()
		end
	end)

	local function refresh()
		screenGui.Enabled = player:GetAttribute("IsAdmin") == true
	end
	player:GetAttributeChangedSignal("IsAdmin"):Connect(refresh)
	refresh()
end

return AdminPanelView
