--!strict
-- DeathScreenView.luau
-- Écran de mort / renaissance : explique le "retour à l'œuf" (GDD §2) entre Humanoid.Died et la
-- réapparition. Le serveur (PlayerLifecycleService.resetToEgg) remet Stage=Oeuf et
-- HasConfirmedSpawn=false dès la mort : le menu de spawn s'ouvre donc sous cet écran, qui se
-- retire en fondu à la réapparition (CharacterAdded) pour le dévoiler.
-- Aucun travail par frame : tweens + décompte à 1 Hz pendant la mort uniquement.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local UiTheme = require(script.Parent.UiTheme)

local DeathScreenView = {}

local mounted = false

local Colors = UiTheme.Colors

-- Doit rester aligné sur PlayerLifecycleService.KILL_CREDIT_SECONDS.
local KILL_CREDIT_SECONDS = 15

local STAGE_NAMES: { [string]: string } = {
	Oeuf = "Œuf",
	Larve = "Larve",
	Cocon = "Cocon",
	Adulte = "Adulte",
}

local PANEL_SHOWN = UDim2.fromScale(0.5, 0.5)
local PANEL_HIDDEN = UDim2.new(0.5, 0, 0.5, 30)

function DeathScreenView.Mount()
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DeathScreenView"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	-- Au-dessus du menu de spawn (10), sous les toasts (20) et le prompt d'agrippement (30).
	screenGui.DisplayOrder = 15
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	local root = Instance.new("CanvasGroup")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(20, 6, 6)
	root.BackgroundTransparency = 0.25
	root.BorderSizePixel = 0
	root.GroupTransparency = 1
	root.Active = true -- absorbe les clics : le menu de spawn rouvert dessous ne doit pas les recevoir
	root.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_SHOWN
	panel.Size = UDim2.fromOffset(440, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Colors.Panel
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = root
	UiTheme.Corner(panel, 14)
	UiTheme.Stroke(panel, Colors.Danger, 1.5, 0.4)
	UiTheme.Padding(panel, 18, 16)
	UiTheme.BindScale(panel, 500, 420, 0.6, 1.3)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = panel

	local function line(order: number, font: Enum.Font, size: number, color: Color3): TextLabel
		local label = UiTheme.Label(panel, font, size, color)
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Center
		return label
	end

	local title = line(1, Enum.Font.GothamBlack, 28, Colors.Danger)
	title.Text = "Vous êtes mort"

	local causeLabel = line(2, Enum.Font.GothamBold, 15, Colors.Text)

	local explain = line(3, Enum.Font.Gotham, 13, Colors.Muted)
	explain.Text = "Retour à l'œuf : chaque vie recommence sous forme d'œuf. Votre ancien corps reste "
		.. "sur place comme carcasse, que d'autres insectes pourront dévorer. Choisissez une nouvelle "
		.. "espèce ou naissez dans le nid d'une Maman."

	local keptBox = Instance.new("Frame")
	keptBox.Name = "Kept"
	keptBox.LayoutOrder = 4
	keptBox.Size = UDim2.new(1, 0, 0, 0)
	keptBox.AutomaticSize = Enum.AutomaticSize.Y
	keptBox.BackgroundColor3 = Colors.Card
	keptBox.BorderSizePixel = 0
	keptBox.Parent = panel
	UiTheme.Corner(keptBox, 10)
	UiTheme.Padding(keptBox, 12, 8)

	local keptLabel = UiTheme.Label(keptBox, Enum.Font.GothamMedium, 12, Colors.Text)
	keptLabel.Size = UDim2.new(1, 0, 0, 0)
	keptLabel.AutomaticSize = Enum.AutomaticSize.Y
	keptLabel.TextWrapped = true
	keptLabel.TextXAlignment = Enum.TextXAlignment.Center

	local countdown = line(5, Enum.Font.GothamBold, 14, Colors.Accent)

	-- ---------- Suivi de la vie en cours (le serveur remet Stage=Oeuf AVANT le Died client) ----------
	local lifeStage = "Oeuf"
	player:GetAttributeChangedSignal("Stage"):Connect(function()
		local stage = player:GetAttribute("Stage")
		if typeof(stage) == "string" and stage ~= "Oeuf" then
			lifeStage = stage
		end
	end)

	local lastHitClock = -math.huge
	local function numberAttribute(name: string, fallback: number): number
		local value = player:GetAttribute(name)
		return if typeof(value) == "number" then value else fallback
	end

	local function deathCause(character: Model): string
		local attackerId = character:GetAttribute("LastAttackerUserId")
		if typeof(attackerId) == "number" and os.clock() - lastHitClock <= KILL_CREDIT_SECONDS then
			local attacker = Players:GetPlayerByUserId(attackerId)
			return "Tué par " .. (if attacker then attacker.DisplayName else "un autre insecte")
		end
		if numberAttribute("Oxygen", 100) <= 0 then
			return "Noyé : plus d'oxygène"
		end
		if numberAttribute("Hunger", 100) <= 0 then
			return "Mort de faim"
		end
		if numberAttribute("Thirst", 100) <= 0 then
			return "Mort de soif"
		end
		local speciesId = player:GetAttribute("Species")
		local info = if typeof(speciesId) == "string" then InsectData[speciesId] else nil
		if info and numberAttribute("BodyTemperature", 22) < info.IdealTempMin then
			return "Mort de froid"
		end
		return "Votre insecte a succombé"
	end

	-- ---------- Affichage ----------
	local sequence = 0
	local function show(character: Model)
		sequence += 1
		local mySequence = sequence
		causeLabel.Text = string.format("%s  ·  stade atteint : %s", deathCause(character), STAGE_NAMES[lifeStage] or lifeStage)
		keptLabel.Text = string.format(
			"Conservés : Points d'Évolution (%d), Kills, mutations débloquées\nPerdus : stade, croissance et mutation de cette vie",
			math.floor(numberAttribute("EvolutionPoints", 0))
		)
		screenGui.Enabled = true
		root.GroupTransparency = 1
		panel.Position = PANEL_HIDDEN
		UiTheme.Tween(root, 0.6, { GroupTransparency = 0 })
		UiTheme.Tween(panel, 0.5, { Position = PANEL_SHOWN }, Enum.EasingStyle.Back)

		-- Décompte jusqu'à la réapparition (Players.RespawnTime, défaut Roblox si non réglé).
		task.spawn(function()
			local respawnAt = os.clock() + Players.RespawnTime
			while sequence == mySequence do
				local remaining = math.ceil(respawnAt - os.clock())
				countdown.Text = if remaining > 0
					then string.format("Éclosion dans %d s…", remaining)
					else "Éclosion…"
				task.wait(1)
			end
		end)
	end

	local function hide()
		if not screenGui.Enabled then
			return
		end
		sequence += 1
		local mySequence = sequence
		local fade = UiTheme.Tween(root, 0.5, { GroupTransparency = 1 })
		fade.Completed:Once(function()
			if sequence == mySequence then
				screenGui.Enabled = false
			end
		end)
	end

	local function onCharacterAdded(character: Model)
		hide()
		local stage = player:GetAttribute("Stage")
		lifeStage = if typeof(stage) == "string" then stage else "Oeuf"
		lastHitClock = -math.huge
		character:GetAttributeChangedSignal("LastAttackAt"):Connect(function()
			lastHitClock = os.clock()
		end)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				if player.Character == character then
					show(character)
				end
			end)
		end
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
end

return DeathScreenView
