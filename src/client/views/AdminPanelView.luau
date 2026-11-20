--!strict
-- AdminPanelView.luau
-- Panneau de test visible seulement si le serveur a posé l'attribut IsAdmin (AdminService),
-- habillé au thème organique « Micro Wild » avec transitions fluides.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local AdminPanelView = {}

local mounted = false

local ACTIONS = {
	{ Label = "🌱 Grandir +10%", Command = "Grow", Amount = 10 },
	{ Label = "🌿 Grandir +25%", Command = "Grow", Amount = 25 },
	{ Label = "🪲 Adulte 100%", Command = "Adult", Amount = 0 },
	{ Label = "🍖 Remplir stats", Command = "Fill", Amount = 0 },
	{ Label = "🍂 Saison suivante", Command = "NextSeason", Amount = 0 },
	{ Label = "🌧️ Pluie (Météo)", Command = "Rain", Amount = 0 },
}

local PANEL_SHOWN = UDim2.new(0, 84, 0.5, 0)
local PANEL_HIDDEN = UDim2.new(0, 62, 0.5, 0)

function AdminPanelView.Mount()
	if mounted then
		return
	end
	mounted = true
	local player = Players.LocalPlayer
	local Colors = UiTheme.Colors

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AdminPanelView"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 20
	screenGui.Enabled = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 10, 0.5, 0)
	toggle.Size = UDim2.fromOffset(66, 28)
	toggle.BackgroundColor3 = Colors.Danger
	toggle.BorderSizePixel = 0
	toggle.AutoButtonColor = false
	toggle.Font = Enum.Font.GothamBlack
	toggle.TextSize = 12
	toggle.TextColor3 = Colors.Text
	toggle.Text = "ADMIN"
	toggle.Parent = screenGui
	UiTheme.Corner(toggle, 8)
	UiTheme.Stroke(toggle, Color3.new(1, 1, 1), 1, 0.65)
	UiTheme.BindButtonFX(toggle, 1.06, 0.92)

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = PANEL_HIDDEN
	panel.Size = UDim2.fromOffset(166, #ACTIONS * 36 + 16)
	panel.BackgroundTransparency = 0.08
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = screenGui
	UiTheme.StylePanel(panel, 12, Colors.Danger, 0.45)
	UiTheme.Padding(panel, 8, 8)

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
		button.Size = UDim2.new(1, 0, 0, 32)
		button.BackgroundColor3 = Colors.Card
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Font = Enum.Font.GothamBold
		button.TextSize = 12
		button.TextColor3 = Colors.Text
		button.Text = action.Label
		button.Parent = panel
		UiTheme.Corner(button, 8)
		UiTheme.Stroke(button, Colors.Border, 1, 0.72)
		UiTheme.BindButtonFX(button, 1.03, 0.94)
		button.MouseEnter:Connect(function()
			UiTheme.Tween(button, 0.14, { BackgroundColor3 = Colors.CardHover })
		end)
		button.MouseLeave:Connect(function()
			UiTheme.Tween(button, 0.14, { BackgroundColor3 = Colors.Card })
		end)
		button.MouseButton1Click:Connect(function()
			remote:FireServer(action.Command, action.Amount)
		end)
	end

	local open = false
	local sequence = 0
	local function togglePanel()
		open = not open
		sequence += 1
		local mySeq = sequence
		if open then
			panel.Visible = true
			UiTheme.Tween(panel, 0.25, { GroupTransparency = 0, Position = PANEL_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		else
			local fade = UiTheme.Tween(panel, 0.18, { GroupTransparency = 1, Position = PANEL_HIDDEN })
			fade.Completed:Once(function()
				if sequence == mySeq then
					panel.Visible = false
				end
			end)
		end
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
