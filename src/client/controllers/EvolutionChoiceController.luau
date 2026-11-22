--!strict
-- EvolutionChoiceController.luau
-- Branches d'évolution (EvolutionTraits) : quand le serveur signale un choix en attente
-- (attribut "PendingTraitChoices", niveaux 5/10/15), affiche les 3 traits de la branche de
-- l'espèce ; un clic envoie RequestEvolutionChoice (le serveur valide). On peut fermer et
-- rouvrir plus tard avec [N].

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EvolutionTraits = require(ReplicatedStorage.shared.EvolutionTraits)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.Parent.views.UiTheme)
local SfxController = require(script.Parent.SfxController)

local EvolutionChoiceController = {}

local player = Players.LocalPlayer
local Colors = UiTheme.Colors
local PANEL_COLOR = Color3.fromRGB(26, 30, 26)

local gui: ScreenGui? = nil

local function pending(): number
	local value = player:GetAttribute("PendingTraitChoices")
	return if type(value) == "number" then value else 0
end

local function close()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

local function open()
	close()
	if pending() <= 0 then
		return
	end
	local speciesId = player:GetAttribute("Species")
	local branch = EvolutionTraits.BranchFor(if type(speciesId) == "string" then speciesId else "")

	local screen = Instance.new("ScreenGui")
	screen.Name = "EvolutionChoiceGui"
	screen.ResetOnSpawn = false
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.45)
	panel.Size = UDim2.fromOffset(520, 220)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.1
	panel.Parent = screen
	UiTheme.StylePanel(panel, 14)
	UiTheme.Padding(panel, 14, 12)
	UiTheme.BindScale(panel, 760, 560, 0.6, 1.1)

	local title = UiTheme.Label(panel, Enum.Font.GothamBlack, 18, Colors.Text)
	title.Size = UDim2.new(1, -30, 0, 24)
	title.Text = string.format("🧬 Choisissez une évolution (%d en attente)", pending())

	local closeButton = Instance.new("TextButton")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(26, 26)
	closeButton.BackgroundTransparency = 1
	closeButton.Text = "✖"
	closeButton.TextColor3 = Colors.Muted
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 16
	closeButton.Parent = panel
	closeButton.Activated:Connect(close)

	local row = Instance.new("Frame")
	row.Position = UDim2.fromOffset(0, 34)
	row.Size = UDim2.new(1, 0, 1, -54)
	row.BackgroundTransparency = 1
	row.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / 3, -8, 1, 0)
	grid.CellPadding = UDim2.fromOffset(12, 0)
	grid.Parent = row

	for _, t in ipairs(branch) do
		local rank = player:GetAttribute("Trait_" .. t.Id)
		local card = Instance.new("TextButton")
		card.Text = ""
		card.BackgroundColor3 = Color3.fromRGB(44, 52, 44)
		card.AutoButtonColor = true
		card.Parent = row
		UiTheme.Corner(card, 10)
		UiTheme.Padding(card, 8, 8)
		UiTheme.BindButtonFX(card, 1.04, 0.95)
		local label = UiTheme.Label(card, Enum.Font.GothamBold, 14, Colors.Text)
		label.Size = UDim2.fromScale(1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextWrapped = true
		label.RichText = true
		label.Text = string.format(
			'<font size="30">%s</font>\n<b>%s</b>%s\n<font size="12">%s</font>',
			t.Icon,
			t.Name,
			if type(rank) == "number" and rank > 0 then string.format(" (rang %d)", rank + 1) else "",
			t.Description
		)
		card.Activated:Connect(function()
			Remotes.Get("RequestEvolutionChoice"):FireServer(t.Id)
			SfxController.Play("Click")
			close()
		end)
	end

	local hint = UiTheme.Label(panel, Enum.Font.Gotham, 12, Colors.Muted)
	hint.Position = UDim2.new(0, 0, 1, -16)
	hint.Size = UDim2.new(1, 0, 0, 16)
	hint.Text = "Reprendre un trait le renforce. [N] pour rouvrir ce menu."
end

function EvolutionChoiceController.Start()
	-- Nouveau choix : ouverture auto ; plus rien en attente (choix fait / nouvelle vie) : fermeture.
	player:GetAttributeChangedSignal("PendingTraitChoices"):Connect(function()
		if pending() > 0 then
			open()
			SfxController.Play("Evolve")
		else
			close()
		end
	end)
	ContextActionService:BindAction("MW_EvolutionChoice", function(_, state)
		if state == Enum.UserInputState.Begin then
			if gui then
				close()
			else
				open()
			end
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.N)
	if pending() > 0 then
		open()
	end
end

return EvolutionChoiceController
