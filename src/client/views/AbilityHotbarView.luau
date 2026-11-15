--!strict
-- AbilityHotbarView.luau
-- Barre de pouvoirs en bas de l'écran : touches de l'espèce (Clic, E, R, F, C) avec voile de
-- recharge (balayage vertical tweené + décompte), retour visuel à l'appui, bouton "Fonder une
-- colonie" (adulte à 100%, GDD §2 étape 4), indicateur de transport, et Points d'Évolution /
-- Kills / Mutation en haut à droite.
-- Aucun RenderStepped : le balayage est un tween linéaire, le décompte une boucle à 10 Hz qui ne
-- tourne que pendant une recharge.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local UiTheme = require(script.Parent.UiTheme)

local AbilityHotbarView = {}

local Colors = UiTheme.Colors

-- Ordre d'affichage et libellé des touches.
local SLOTS = { "LeftClick", "E", "R", "F", "C" }
local KEY_LABELS: { [string]: string } = { LeftClick = "Clic", E = "E", R = "R", F = "F", C = "C" }
-- Touches (clavier + manette, alignées sur AbilityController) -> carte à faire réagir.
local KEY_TO_SLOT: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.E] = "E",
	[Enum.KeyCode.ButtonX] = "E",
	[Enum.KeyCode.R] = "R",
	[Enum.KeyCode.ButtonY] = "R",
	[Enum.KeyCode.F] = "F",
	[Enum.KeyCode.ButtonB] = "F",
	[Enum.KeyCode.C] = "C",
	[Enum.KeyCode.ButtonL2] = "C",
	[Enum.KeyCode.ButtonR2] = "LeftClick",
}
-- Doit rester aligné sur GameConstants.DIGGER_SPECIES (serveur, non répliqué).
local DIGGERS: { [string]: boolean } = {
	FourmiRousse = true, TermiteSoldat = true, ScorpionEmpereur = true, Cigale = true,
	ScarabeeHercule = true, ScarabeeBombardier = true, LucaneCerfVolant = true,
	VeuveNoire = true, AraigneeSauteuse = true, Ephemere = true,
}

-- Passifs qui ont un effet en jeu (les autres restent dans les données mais ne sont pas affichés).
local ACTIVE_PASSIVES: { [string]: boolean } = {
	ForceHerculeenne = true, CarapaceBlindee = true, BouclierChitine = true, FilDeRappel = true,
	Vision360 = true, EnfouissementSable = false, CreuserBois = true, SprintOndulant = true,
	MimetismeBrindille = true, ChaleurDeRuche = true, Vol360Stationnaire = true, AilesToxiques = true,
	DetectionThermique = true, LanterneBioluminescente = true, ReflexeEsquive = true, OdoratCharogne = true,
	CarapaceResistante = true, VolAcrobatique = true, PatinageSurface = true, RadarVibrationsEau = true,
	BulleOxygene = true, TubaRespiratoire = true, CamouflageFeuilleMorte = true, FourreauArmureCailloux = true,
	EnvolAdulte = true, ClocheDePlongeeToile = true, BranchiesAquatiques = true, SaisieGeante = true,
}

local CARD_WIDTH = 118
local CARD_HEIGHT = 64
local CARD_GAP = 6
local DOCK_WIDTH = #SLOTS * CARD_WIDTH + (#SLOTS - 1) * CARD_GAP
local DOCK_HEIGHT = 136

-- Tailles pré-allouées du voile de recharge (plein -> vide).
local COOLDOWN_FULL = UDim2.fromScale(1, 1)
local COOLDOWN_EMPTY = UDim2.fromScale(1, 0)
local PRESS_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local mounted = false

-- "JetAcideFormique" -> "Jet Acide Formique"
local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return spaced
end

type SlotCard = {
	Frame: Frame,
	Scale: UIScale,
	Stroke: UIStroke,
	Title: TextLabel,
	Cooldown: Frame,
	Timer: TextLabel,
	Press: Tween,
	CooldownEnd: number,
	Enabled: boolean,
}

function AbilityHotbarView.Mount(abilityCooldownSignal: BindableEvent?)
	if mounted then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AbilityHotbarView"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 3
	screenGui.Parent = playerGui

	-- ---------- Bloc bas-centre : bouton colonie, ligne d'infos, barre de pouvoirs ----------
	local dock = Instance.new("Frame")
	dock.Name = "Dock"
	dock.AnchorPoint = Vector2.new(0.5, 1)
	dock.Position = UDim2.new(0.5, 0, 1, -12)
	dock.Size = UDim2.fromOffset(DOCK_WIDTH, DOCK_HEIGHT)
	dock.BackgroundTransparency = 1
	dock.Parent = screenGui

	-- Petits écrans : tout le bloc rétrécit pour ne pas sortir de l'écran (aucun coût par frame).
	local dockScale = Instance.new("UIScale")
	dockScale.Parent = dock
	-- Tactile : la barre n'est qu'indicative (les boutons d'action sont ceux de ContextActionService)
	-- et doit tenir entre le stick virtuel (gauche) et les boutons d'action (droite).
	local touchOnly = UiTheme.IsTouchOnly()
	UiTheme.OnViewportChanged(function(size: Vector2)
		if touchOnly then
			dockScale.Scale = math.clamp(size.X / (DOCK_WIDTH * 2), 0.4, 0.8)
		else
			dockScale.Scale = math.clamp(size.X / (DOCK_WIDTH + 40), 0.5, 1.1)
		end
	end)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 1)
	bar.Size = UDim2.new(1, 0, 0, CARD_HEIGHT)
	bar.BackgroundTransparency = 1
	bar.Parent = dock

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, CARD_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar

	local cards: { [string]: SlotCard } = {}
	for index, slot in ipairs(SLOTS) do
		-- Emplacement fixe dans la rangée ; la carte à l'intérieur peut "rebondir" sans décaler
		-- ses voisines.
		local holder = Instance.new("Frame")
		holder.Name = slot
		holder.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
		holder.BackgroundTransparency = 1
		holder.LayoutOrder = index
		holder.Parent = bar

		local frame = Instance.new("Frame")
		frame.Name = "Card"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Colors.Card
		frame.BackgroundTransparency = 0.15
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.Parent = holder
		UiTheme.Corner(frame, 8)
		local stroke = UiTheme.Stroke(frame, Colors.Accent, 1.5, 0.8)

		local scale = Instance.new("UIScale")
		scale.Parent = frame

		local cooldown = Instance.new("Frame")
		cooldown.Name = "Cooldown"
		cooldown.AnchorPoint = Vector2.new(0, 1)
		cooldown.Position = UDim2.fromScale(0, 1)
		cooldown.Size = COOLDOWN_EMPTY
		cooldown.BackgroundColor3 = Color3.new(0, 0, 0)
		cooldown.BackgroundTransparency = 0.45
		cooldown.BorderSizePixel = 0
		cooldown.Parent = frame
		UiTheme.Corner(cooldown, 8)

		local key = UiTheme.Label(frame, Enum.Font.GothamBlack, 15, Colors.Accent)
		key.Name = "Key"
		key.Size = UDim2.new(1, -8, 0, 18)
		key.Position = UDim2.fromOffset(7, 4)
		key.Text = KEY_LABELS[slot]
		key.ZIndex = 2

		local timer = UiTheme.Label(frame, Enum.Font.GothamBold, 14, Colors.Text)
		timer.Name = "Timer"
		timer.Size = UDim2.new(1, -14, 0, 18)
		timer.Position = UDim2.fromOffset(7, 4)
		timer.TextXAlignment = Enum.TextXAlignment.Right
		timer.ZIndex = 2

		local title = UiTheme.Label(frame, Enum.Font.GothamMedium, 12, Colors.Text)
		title.Name = "Title"
		title.Size = UDim2.new(1, -12, 1, -26)
		title.Position = UDim2.fromOffset(7, 23)
		title.TextWrapped = true
		title.TextYAlignment = Enum.TextYAlignment.Top
		title.ZIndex = 2

		cards[slot] = {
			Frame = frame,
			Scale = scale,
			Stroke = stroke,
			Title = title,
			Cooldown = cooldown,
			Timer = timer,
			Press = TweenService:Create(scale, PRESS_INFO, { Scale = 1 }),
			CooldownEnd = 0,
			Enabled = true,
		}
	end

	-- ---------- Ligne d'infos au-dessus de la barre ----------
	local infoLabel = UiTheme.Label(dock, Enum.Font.GothamMedium, 13, Colors.Text)
	infoLabel.Name = "Info"
	infoLabel.AnchorPoint = Vector2.new(0.5, 1)
	infoLabel.Position = UDim2.new(0.5, 0, 1, -(CARD_HEIGHT + 6))
	infoLabel.Size = UDim2.new(1, 0, 0, 20)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Center
	infoLabel.TextTransparency = 0.15
	infoLabel.TextStrokeTransparency = 0.5
	infoLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local colonyButton = Instance.new("TextButton")
	colonyButton.Name = "FoundColony"
	colonyButton.AnchorPoint = Vector2.new(0.5, 1)
	colonyButton.Position = UDim2.new(0.5, 0, 1, -(CARD_HEIGHT + 32))
	colonyButton.Size = UDim2.fromOffset(250, 38)
	colonyButton.BackgroundColor3 = Colors.Accent
	colonyButton.BorderSizePixel = 0
	colonyButton.AutoButtonColor = true
	colonyButton.Font = Enum.Font.GothamBold
	colonyButton.TextSize = 16
	colonyButton.TextColor3 = Colors.AccentDark
	colonyButton.Text = "👑 Fonder une colonie"
	colonyButton.Visible = false
	colonyButton.Parent = dock
	UiTheme.Corner(colonyButton, 8)
	local colonyStroke = UiTheme.Stroke(colonyButton, Color3.new(1, 1, 1), 2, 1)
	-- Halo pulsant pour attirer l'oeil : un seul tween en boucle, joué seulement si le bouton est visible.
	local colonyPulse = TweenService:Create(
		colonyStroke,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.2 }
	)
	local colonyVisible = false
	colonyButton.MouseButton1Click:Connect(function()
		Remotes.Get("RequestCreateNest"):FireServer()
	end)

	-- ---------- Stats (haut droite) ----------
	local stats = UiTheme.Label(screenGui, Enum.Font.GothamMedium, 14, Colors.Text)
	stats.Name = "Stats"
	stats.AnchorPoint = Vector2.new(1, 0)
	stats.Position = UDim2.new(1, -12, 0, 48)
	stats.Size = UDim2.fromOffset(250, 56)
	stats.BackgroundColor3 = Colors.Panel
	stats.BackgroundTransparency = 0.2
	stats.TextXAlignment = Enum.TextXAlignment.Right
	stats.TextYAlignment = Enum.TextYAlignment.Center
	UiTheme.Corner(stats, 10)
	UiTheme.Stroke(stats, Color3.new(1, 1, 1), 1, 0.88)
	UiTheme.Padding(stats, 12, 0)
	UiTheme.BindScale(stats, 760, 560, 0.6, 1.1)

	-- ---------- Rafraîchissements ----------
	local function abilityForSlot(speciesId: string, slot: string): string?
		local species = InsectData[speciesId]
		if not species then
			return nil
		end
		for _, id in ipairs(species.Abilities) do
			local definition = AbilityCatalog[id]
			if definition and definition.Slot == slot then
				return id
			end
		end
		return nil
	end

	local function passiveList(speciesId: string): string
		local species = InsectData[speciesId]
		if not species then
			return ""
		end
		local names = {}
		for _, id in ipairs(species.Abilities) do
			local definition = AbilityCatalog[id]
			if definition and definition.Slot == "Passive" and ACTIVE_PASSIVES[id] then
				table.insert(names, prettify(id))
			end
		end
		return table.concat(names, ", ")
	end

	local function stringAttribute(name: string): string?
		local value = player:GetAttribute(name)
		return if typeof(value) == "string" then value else nil
	end

	local function numberAttribute(name: string): number
		local value = player:GetAttribute(name)
		return if typeof(value) == "number" then value else 0
	end

	local function refreshSlots()
		local speciesId = stringAttribute("Species") or ""
		local stage = player:GetAttribute("Stage")
		local isAdult = stage == "Adulte"
		for _, slot in ipairs(SLOTS) do
			local card = cards[slot]
			local text: string
			local enabled = true
			if slot == "LeftClick" then
				local special = abilityForSlot(speciesId, "LeftClick")
				text = if special then prettify(special) else "Morsure"
				enabled = stage ~= "Oeuf" and stage ~= "Cocon"
			elseif slot == "C" then
				enabled = DIGGERS[speciesId] == true and (isAdult or stage == "Larve")
				text = if DIGGERS[speciesId] then "Creuser (maintenir)" else "—"
			else
				local id = abilityForSlot(speciesId, slot)
				text = if id then prettify(id) else "—"
				enabled = id ~= nil and isAdult
				if id and not isAdult then
					text ..= "\n(adulte)"
				end
			end
			card.Enabled = enabled
			card.Title.Text = text
			card.Title.TextColor3 = if enabled then Colors.Text else Colors.Muted
			UiTheme.Tween(card.Frame, 0.2, { BackgroundTransparency = if enabled then 0.15 else 0.6 })
			UiTheme.Tween(card.Stroke, 0.2, { Transparency = if enabled then 0.8 else 1 })
		end
	end

	local function refreshInfo()
		local speciesId = stringAttribute("Species") or ""
		local parts = {}
		local carried = stringAttribute("CarriedFoodType")
		if carried then
			table.insert(parts, "🍃 Vous transportez : " .. carried .. " → ramenez-le au nid")
		end
		local passives = passiveList(speciesId)
		if passives ~= "" then
			table.insert(parts, "Passifs : " .. passives)
		end
		table.insert(parts, "[G] Manger/Boire  [T] Transporter  [H] Aide")
		infoLabel.Text = table.concat(parts, "   •   ")

		local showColony = player:GetAttribute("Stage") == "Adulte"
			and numberAttribute("Growth") >= 100
			and player:GetAttribute("IsMother") ~= true
		if showColony ~= colonyVisible then
			colonyVisible = showColony
			colonyButton.Visible = showColony
			if showColony then
				colonyPulse:Play()
			else
				colonyPulse:Cancel()
				colonyStroke.Transparency = 1
			end
		end
	end

	local lastPoints = numberAttribute("EvolutionPoints")
	local function refreshStats()
		local mutationId = stringAttribute("Mutation")
		local mutation = if mutationId then InsectBodyPlans.Mutations[mutationId] else nil
		local points = numberAttribute("EvolutionPoints")
		stats.Text = string.format(
			"PE : %d   •   Kills : %d\nMutation : %s",
			points,
			numberAttribute("Kills"),
			if mutation then "✨ " .. mutation.Name else "aucune"
		)
		-- Gain de Points d'Évolution : bref éclat vert du texte.
		if points > lastPoints then
			stats.TextColor3 = Colors.Accent
			UiTheme.Tween(stats, 0.8, { TextColor3 = Colors.Text })
		end
		lastPoints = points
	end

	for _, attribute in ipairs({ "Species", "Stage" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refreshSlots)
	end
	for _, attribute in ipairs({ "CarriedFoodType", "Growth", "Stage", "IsMother", "Species" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refreshInfo)
	end
	for _, attribute in ipairs({ "EvolutionPoints", "Kills", "Mutation" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refreshStats)
	end
	refreshSlots()
	refreshInfo()
	refreshStats()

	-- ---------- Retour visuel à l'appui ----------
	local function pressCard(slot: string)
		local card = cards[slot]
		if card and card.Enabled then
			card.Scale.Scale = 0.9
			card.Press:Play()
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not gameProcessed then
				pressCard("LeftClick")
			end
			return
		end
		-- Les touches liées par ContextActionService arrivent ici avec gameProcessed = true : on
		-- ne filtre donc que la saisie de texte (chat, recherche du menu).
		local slot = KEY_TO_SLOT[input.KeyCode]
		if slot and UserInputService:GetFocusedTextBox() == nil then
			pressCard(slot)
		end
	end)

	-- ---------- Recharges ----------
	local ticking = false
	local function tickCooldowns()
		ticking = true
		while true do
			local now = os.clock()
			local anyActive = false
			for _, card in pairs(cards) do
				if card.CooldownEnd > 0 then
					local remaining = card.CooldownEnd - now
					if remaining > 0 then
						anyActive = true
						card.Timer.Text = if remaining >= 10
							then string.format("%d", math.ceil(remaining))
							else string.format("%.1f", remaining)
					else
						-- Recharge terminée : éclat du contour "prêt".
						card.CooldownEnd = 0
						card.Timer.Text = ""
						card.Cooldown.Size = COOLDOWN_EMPTY
						if card.Enabled then
							card.Stroke.Transparency = 0
							UiTheme.Tween(card.Stroke, 0.5, { Transparency = 0.8 })
						end
					end
				end
			end
			if not anyActive then
				break
			end
			task.wait(0.1)
		end
		ticking = false
	end

	if abilityCooldownSignal then
		abilityCooldownSignal.Event:Connect(function(slot: string, seconds: number)
			local card = cards[slot]
			if card and typeof(seconds) == "number" and seconds > 0 then
				card.CooldownEnd = os.clock() + seconds
				-- Balayage : un seul tween linéaire du voile, du plein vers le vide.
				card.Cooldown.Size = COOLDOWN_FULL
				UiTheme.Tween(card.Cooldown, seconds, { Size = COOLDOWN_EMPTY }, Enum.EasingStyle.Linear)
				if not ticking then
					task.spawn(tickCooldowns)
				end
			end
		end)
	end
end

return AbilityHotbarView
