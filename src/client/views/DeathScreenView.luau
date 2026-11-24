--!strict
-- DeathScreenView.luau
-- Écran de mort / renaissance au style organique « Micro Wild » :
--   * Vitrine 3D illustrant le « Retour à l'œuf » de l'espèce du joueur sur son socle de biome
--   * Cause de la mort, stade atteint, bilan des acquis conservés (PE, Kills, mutations)
--   * Apparition fluide en fondu + rebond Back et décompte jusqu'à la réapparition
-- Aucun travail par frame hors la brève pirouette 3D d'entrée.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local UiTheme = require(script.Parent.UiTheme)
local CreatureViewport = require(script.Parent.CreatureViewport)

local DeathScreenView = {}

local mounted = false

local Colors = UiTheme.Colors

local KILL_CREDIT_SECONDS = 15

local STAGE_NAMES: { [string]: string } = {
	Oeuf = "🥚 Œuf",
	Larve = "🐛 Larve",
	Mue = "🦎 Mue",
	Cocon = "🐚 Cocon",
	Adulte = "🪲 Adulte",
}

local PANEL_SHOWN = UDim2.fromScale(0.5, 0.5)
local PANEL_HIDDEN = UDim2.new(0.5, 0, 0.5, 34)

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
	screenGui.DisplayOrder = 15
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	local root = Instance.new("CanvasGroup")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(16, 6, 6)
	root.BackgroundTransparency = 0.22
	root.BorderSizePixel = 0
	root.GroupTransparency = 1
	root.Active = true
	root.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_SHOWN
	panel.Size = UDim2.fromOffset(450, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundTransparency = 0.04
	panel.Parent = root
	UiTheme.StylePanel(panel, 16, Colors.Danger, 0.35)
	UiTheme.Padding(panel, 20, 18)
	UiTheme.BindScale(panel, 500, 460, 0.6, 1.3)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 9)
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

	-- Vitrine 3D "Retour à l'œuf"
	local previewBox = Instance.new("Frame")
	previewBox.Name = "EggPreview3D"
	previewBox.LayoutOrder = 0
	previewBox.Size = UDim2.fromOffset(118, 96)
	previewBox.BackgroundColor3 = Colors.PanelDeep
	previewBox.BorderSizePixel = 0
	previewBox.Parent = panel
	UiTheme.Corner(previewBox, 12)
	UiTheme.Stroke(previewBox, Colors.Danger, 1.5, 0.45)

	local eggPreview3D = CreatureViewport.Create(previewBox, false, 1.05)

	local title = line(1, Enum.Font.GothamBlack, 26, Colors.Danger)
	title.Text = "💀 CYCLE INTERROMPU"

	local causeLabel = line(2, Enum.Font.GothamBold, 15, Colors.Text)

	local explain = line(3, Enum.Font.Gotham, 13, Colors.Muted)
	explain.Text = "Retour à l'œuf : chaque vie recommence dans un œuf. Votre ancien corps demeure "
		.. "sur place comme carcasse, nourrissant l'écosystème. Choisissez une nouvelle "
		.. "espèce ou rejoignez le nid d'une Maman."

	local keptBox = Instance.new("Frame")
	keptBox.Name = "Kept"
	keptBox.LayoutOrder = 4
	keptBox.Size = UDim2.new(1, 0, 0, 0)
	keptBox.AutomaticSize = Enum.AutomaticSize.Y
	keptBox.Parent = panel
	UiTheme.StyleCard(keptBox, 10, Colors.Border, 0.65)
	UiTheme.Padding(keptBox, 12, 9)

	local keptLabel = UiTheme.Label(keptBox, Enum.Font.GothamMedium, 12, Colors.Text)
	keptLabel.Size = UDim2.new(1, 0, 0, 0)
	keptLabel.AutomaticSize = Enum.AutomaticSize.Y
	keptLabel.TextWrapped = true
	keptLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- Bilan de la vie et records (attribut "LastLife", posé par ProgressionService à la mort).
	local recordLabel = line(5, Enum.Font.GothamBold, 13, Colors.Gold)
	recordLabel.RichText = true
	local function refreshRecords()
		local raw = player:GetAttribute("LastLife")
		local ok, life = pcall(function()
			return if type(raw) == "string" then HttpService:JSONDecode(raw) else nil
		end)
		if not ok or type(life) ~= "table" then
			recordLabel.Text = ""
			return
		end
		local seconds = tonumber(life.Seconds) or 0
		local text = string.format(
			"Cette vie : niveau %d  ·  %d min %02d s  ·  %d proie(s)\n🏆 Records : niveau %d  ·  %d min  ·  %d proies",
			tonumber(life.Level) or 1, seconds // 60, seconds % 60, tonumber(life.Kills) or 0,
			tonumber(life.BestLevel) or 0, (tonumber(life.BestSeconds) or 0) // 60, tonumber(life.BestKills) or 0
		)
		if type(life.Records) == "table" and #life.Records > 0 then
			text = "<font size=\"18\">🎉 NOUVEAU RECORD : " .. table.concat(life.Records, ", ") .. " !</font>\n" .. text
		else
			text ..= "\nPresque ! Battez vos records à la prochaine vie."
		end
		recordLabel.Text = text
	end
	player:GetAttributeChangedSignal("LastLife"):Connect(refreshRecords)

	local countdown = line(6, Enum.Font.GothamBlack, 15, Colors.Accent)

	-- Jauge d'incubation : se remplit pendant le délai de réapparition (un seul tween linéaire).
	local respawnTrack = Instance.new("Frame")
	respawnTrack.Name = "RespawnTrack"
	respawnTrack.LayoutOrder = 7
	respawnTrack.Size = UDim2.new(0.7, 0, 0, 6)
	respawnTrack.BackgroundColor3 = Colors.Track
	respawnTrack.BorderSizePixel = 0
	respawnTrack.Parent = panel
	UiTheme.Corner(respawnTrack, 3)

	local respawnFill = Instance.new("Frame")
	respawnFill.Name = "Fill"
	respawnFill.Size = UDim2.fromScale(0, 1)
	respawnFill.BackgroundColor3 = Colors.Accent
	respawnFill.BorderSizePixel = 0
	respawnFill.Parent = respawnTrack
	UiTheme.Corner(respawnFill, 3)

	-- ---------- Suivi de la vie en cours ----------
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
			return "⚔️ Tué par " .. (if attacker then attacker.DisplayName else "un autre insecte")
		end
		if numberAttribute("Oxygen", 100) <= 0 then
			return "🫧 Noyé : plus d'oxygène"
		end
		if numberAttribute("Hunger", 100) <= 0 then
			return "🍖 Mort de faim"
		end
		if numberAttribute("Thirst", 100) <= 0 then
			return "💧 Mort de soif"
		end
		local speciesId = player:GetAttribute("Species")
		local info = if typeof(speciesId) == "string" then InsectData[speciesId] else nil
		if info and numberAttribute("BodyTemperature", 22) < info.IdealTempMin then
			return "❄️ Mort d'hypothermie"
		end
		return "🍂 Votre insecte a succombé"
	end

	-- ---------- Affichage ----------
	local sequence = 0
	local function show(character: Model)
		sequence += 1
		local mySequence = sequence
		local speciesId = player:GetAttribute("Species")
		local actualSpecies = if typeof(speciesId) == "string" and InsectData[speciesId] then speciesId else "FourmiRousse"
		eggPreview3D.SetCreature(actualSpecies, "Oeuf", nil, true)

		causeLabel.Text = string.format("%s  ·  stade atteint : %s", deathCause(character), STAGE_NAMES[lifeStage] or lifeStage)
		keptLabel.Text = string.format(
			"🧬 Conservés : Points d'Évolution (%d), Kills, mutations débloquées\n🍂 Perdus : stade, croissance et mutation de cette vie",
			math.floor(numberAttribute("EvolutionPoints", 0))
		)
		refreshRecords()
		screenGui.Enabled = true
		root.GroupTransparency = 1
		panel.Position = PANEL_HIDDEN
		UiTheme.Tween(root, 0.55, { GroupTransparency = 0 })
		UiTheme.Tween(panel, 0.5, { Position = PANEL_SHOWN }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		eggPreview3D.SpinOnce()
		respawnFill.Size = UDim2.fromScale(0, 1)
		UiTheme.Tween(respawnFill, math.max(Players.RespawnTime, 0.1), { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Linear)

		task.spawn(function()
			local respawnAt = os.clock() + Players.RespawnTime
			while sequence == mySequence do
				local remaining = math.ceil(respawnAt - os.clock())
				countdown.Text = if remaining > 0
					then string.format("🥚 Nouvelle éclosion dans %d s…", remaining)
					else "🥚 Éclosion imminente…"
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
		local fade = UiTheme.Tween(root, 0.45, { GroupTransparency = 1 })
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
