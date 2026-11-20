--!strict
-- AbilityHotbarView.luau
-- Barre de pouvoirs en bas de l'écran au style organique « Micro Wild » :
--   * Cartes de compétences (Clic, E, R, F, C) avec badge de touche, dégradé chitineux, voile de
--     recharge balayé et rebond élastique à l'appui
--   * Bandeau d'informations (transport de nourriture, passifs, raccourcis)
--   * Bouton « 👑 Fonder une colonie » doré avec halo pulsant et rebond d'apparition
--   * Panneau de progression en haut à droite (PE, Kills, Mutation) avec animation lors des gains
-- Aucun RenderStepped : tout repose sur TweenService et une boucle à 10 Hz uniquement pendant une recharge.

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

local SLOTS = { "LeftClick", "E", "R", "F", "C" }
local KEY_LABELS: { [string]: string } = { LeftClick = "Clic", E = "E", R = "R", F = "F", C = "C" }
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

local DIGGERS: { [string]: boolean } = {
	FourmiRousse = true, TermiteSoldat = true, ScorpionEmpereur = true, Cigale = true,
	ScarabeeHercule = true, ScarabeeBombardier = true, LucaneCerfVolant = true,
	VeuveNoire = true, AraigneeSauteuse = true, Ephemere = true,
}

local ACTIVE_PASSIVES: { [string]: boolean } = {
	ForceHerculeenne = true, CarapaceBlindee = true, BouclierChitine = true,
	Vision360 = true, EnfouissementSable = false, CreuserBois = true, SprintOndulant = true,
	MimetismeBrindille = true, ChaleurDeRuche = true, Vol360Stationnaire = true, AilesToxiques = true,
	DetectionThermique = true, LanterneBioluminescente = true, ReflexeEsquive = true, OdoratCharogne = true,
	CarapaceResistante = true, VolAcrobatique = true, PatinageSurface = true, RadarVibrationsEau = true,
	BulleOxygene = true, TubaRespiratoire = true, CamouflageFeuilleMorte = true, FourreauArmureCailloux = true,
	EnvolAdulte = true, ClocheDePlongeeToile = true, BranchiesAquatiques = true, SaisieGeante = true,
}

local CARD_WIDTH = 122
local CARD_HEIGHT = 66
local CARD_GAP = 7
local DOCK_WIDTH = #SLOTS * CARD_WIDTH + (#SLOTS - 1) * CARD_GAP
local DOCK_HEIGHT = 142

local COOLDOWN_FULL = UDim2.fromScale(1, 1)
local COOLDOWN_EMPTY = UDim2.fromScale(1, 0)
local PRESS_INFO = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local mounted = false

local function prettify(id: string): string
	local spaced = string.gsub(id, "(%l)(%u)", "%1 %2")
	return spaced
end

type SlotCard = {
	Frame: Frame,
	Scale: UIScale,
	Stroke: UIStroke,
	KeyBadge: TextLabel,
	Title: TextLabel,
	Cooldown: Frame,
	Timer: TextLabel,
	Press: Tween,
	CooldownStart: number,
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

	local dockScale = Instance.new("UIScale")
	dockScale.Parent = dock
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
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = 0.08
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.Parent = holder
		UiTheme.Corner(frame, 10)
		UiTheme.Gradient(frame, Colors.CardTop, Colors.PanelDeep, 95)
		local stroke = UiTheme.Stroke(frame, Colors.Accent, 1.5, 0.55)

		local scale = Instance.new("UIScale")
		scale.Parent = frame

		local cooldown = Instance.new("Frame")
		cooldown.Name = "Cooldown"
		cooldown.AnchorPoint = Vector2.new(0, 1)
		cooldown.Position = UDim2.fromScale(0, 1)
		cooldown.Size = COOLDOWN_EMPTY
		cooldown.BackgroundColor3 = Color3.fromRGB(6, 12, 8)
		cooldown.BackgroundTransparency = 0.35
		cooldown.BorderSizePixel = 0
		cooldown.Parent = frame
		UiTheme.Corner(cooldown, 10)

		-- Badge de touche stylisé en pilule
		local keyBadge = UiTheme.Label(frame, Enum.Font.GothamBlack, 12, Colors.AccentDark)
		keyBadge.Name = "Key"
		keyBadge.Position = UDim2.fromOffset(7, 6)
		keyBadge.Size = UDim2.fromOffset(if slot == "LeftClick" then 36 else 22, 18)
		keyBadge.BackgroundTransparency = 0
		keyBadge.BackgroundColor3 = Colors.Accent
		keyBadge.TextXAlignment = Enum.TextXAlignment.Center
		keyBadge.Text = KEY_LABELS[slot]
		keyBadge.ZIndex = 2
		UiTheme.Corner(keyBadge, 5)

		local timer = UiTheme.Label(frame, Enum.Font.GothamBlack, 13, Colors.Warning)
		timer.Name = "Timer"
		timer.Size = UDim2.new(1, -14, 0, 18)
		timer.Position = UDim2.fromOffset(7, 6)
		timer.TextXAlignment = Enum.TextXAlignment.Right
		timer.ZIndex = 2

		local title = UiTheme.Label(frame, Enum.Font.GothamBold, 11, Colors.Text)
		title.Name = "Title"
		title.Size = UDim2.new(1, -14, 1, -29)
		title.Position = UDim2.fromOffset(7, 27)
		title.TextWrapped = true
		title.TextYAlignment = Enum.TextYAlignment.Top
		title.ZIndex = 2

		cards[slot] = {
			Frame = frame,
			Scale = scale,
			Stroke = stroke,
			KeyBadge = keyBadge,
			Title = title,
			Cooldown = cooldown,
			Timer = timer,
			Press = TweenService:Create(scale, PRESS_INFO, { Scale = 1 }),
			CooldownStart = 0,
			CooldownEnd = 0,
			Enabled = true,
		}
	end

	-- ---------- Ligne d'infos au-dessus de la barre ----------
	local infoBar = Instance.new("Frame")
	infoBar.Name = "InfoBar"
	infoBar.AnchorPoint = Vector2.new(0.5, 1)
	infoBar.Position = UDim2.new(0.5, 0, 1, -(CARD_HEIGHT + 7))
	infoBar.Size = UDim2.new(1, 0, 0, 22)
	infoBar.BackgroundColor3 = Colors.PanelDeep
	infoBar.BackgroundTransparency = 0.35
	infoBar.BorderSizePixel = 0
	infoBar.Parent = dock
	UiTheme.Corner(infoBar, 7)
	UiTheme.Stroke(infoBar, Colors.Border, 1, 0.78)
	UiTheme.Padding(infoBar, 10, 0)

	local infoLabel = UiTheme.Label(infoBar, Enum.Font.GothamMedium, 12, Colors.Text)
	infoLabel.Name = "Info"
	infoLabel.Size = UDim2.fromScale(1, 1)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Center
	infoLabel.TextTransparency = 0.1
	infoLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local colonyButton = Instance.new("TextButton")
	colonyButton.Name = "FoundColony"
	colonyButton.AnchorPoint = Vector2.new(0.5, 1)
	colonyButton.Position = UDim2.new(0.5, 0, 1, -(CARD_HEIGHT + 34))
	colonyButton.Size = UDim2.fromOffset(256, 38)
	colonyButton.BackgroundColor3 = Colors.Gold
	colonyButton.BorderSizePixel = 0
	colonyButton.AutoButtonColor = false
	colonyButton.Font = Enum.Font.GothamBlack
	colonyButton.TextSize = 15
	colonyButton.TextColor3 = Colors.GoldDark
	colonyButton.Text = "👑 Fonder une colonie"
	colonyButton.Visible = false
	colonyButton.Parent = dock
	UiTheme.Corner(colonyButton, 10)
	local colonyStroke = UiTheme.Stroke(colonyButton, Color3.new(1, 1, 1), 2, 1)
	UiTheme.BindButtonFX(colonyButton, 1.04, 0.94)

	local colonyPulse = TweenService:Create(
		colonyStroke,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.15 }
	)
	local colonyVisible = false
	colonyButton.MouseButton1Click:Connect(function()
		Remotes.Get("RequestCreateNest"):FireServer()
	end)

	-- ---------- Stats (haut droite) ----------
	local statsCard = Instance.new("Frame")
	statsCard.Name = "StatsCard"
	statsCard.AnchorPoint = Vector2.new(1, 0)
	statsCard.Position = UDim2.new(1, -12, 0, 48)
	statsCard.Size = UDim2.fromOffset(258, 58)
	statsCard.BackgroundTransparency = 0.12
	statsCard.Parent = screenGui
	local statsStroke = UiTheme.StylePanel(statsCard, 12, Colors.Border, 0.45)
	UiTheme.Padding(statsCard, 12, 6)
	UiTheme.BindScale(statsCard, 760, 560, 0.6, 1.1)

	local stats = UiTheme.Label(statsCard, Enum.Font.GothamBold, 13, Colors.Text)
	stats.Name = "Stats"
	stats.Size = UDim2.fromScale(1, 1)
	stats.TextXAlignment = Enum.TextXAlignment.Right
	stats.TextYAlignment = Enum.TextYAlignment.Center

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
				local strength = player:GetAttribute("DigStrength")
				text = if DIGGERS[speciesId]
					then string.format("Creuser · force %d (V)", if type(strength) == "number" then strength else 2)
					else "—"
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
			UiTheme.Tween(card.KeyBadge, 0.2, {
				BackgroundColor3 = if enabled then Colors.Accent else Colors.Track,
				TextColor3 = if enabled then Colors.AccentDark else Colors.Muted,
			})
			UiTheme.Tween(card.Frame, 0.2, { BackgroundTransparency = if enabled then 0.08 else 0.52 })
			UiTheme.Tween(card.Stroke, 0.2, { Transparency = if enabled then 0.55 else 0.88 })
		end
	end

	local function refreshInfo()
		local speciesId = stringAttribute("Species") or ""
		local parts = {}
		local carried = stringAttribute("CarriedFoodType")
		if carried then
			table.insert(parts, "🍃 Transport : " .. carried .. " → ramenez-le au nid")
		end
		-- Matériaux de construction portés (NestBuildingService) : déposés en entrant dans le nid.
		local materials = {}
		for _, entry in ipairs({ { "Feuille", "🍂" }, { "Brindille", "🪵" }, { "Caillou", "🪨" }, { "Terre", "🟫" } }) do
			local count = numberAttribute("Mat_" .. entry[1])
			if count > 0 then
				table.insert(materials, entry[2] .. count)
			end
		end
		if #materials > 0 then
			table.insert(parts, "🧱 " .. table.concat(materials, " ") .. " → ramenez-les au nid")
		end
		local passives = passiveList(speciesId)
		if passives ~= "" then
			table.insert(parts, "✨ Passifs : " .. passives)
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
				UiTheme.Pop(colonyButton, 0.82, 0.32)
				colonyPulse:Play()
			else
				colonyPulse:Cancel()
				colonyStroke.Transparency = 1
			end
		end
	end

	local lastPoints = numberAttribute("EvolutionPoints")
	local lastKills = numberAttribute("Kills")
	local function refreshStats()
		local mutationId = stringAttribute("Mutation")
		local mutation = if mutationId then InsectBodyPlans.Mutations[mutationId] else nil
		local points = numberAttribute("EvolutionPoints")
		local kills = numberAttribute("Kills")
		stats.Text = string.format(
			"🧬 PE : %d   •   ⚔️ Kills : %d\n✨ Mutation : %s",
			points,
			kills,
			if mutation then mutation.Name else "aucune"
		)
		if points > lastPoints or kills > lastKills then
			stats.TextColor3 = Colors.AccentBright
			statsStroke.Color = Colors.AccentBright
			statsStroke.Transparency = 0.05
			UiTheme.Tween(stats, 0.8, { TextColor3 = Colors.Text })
			UiTheme.Tween(statsStroke, 0.8, { Color = Colors.Border, Transparency = 0.45 })
		end
		lastPoints = points
		lastKills = kills
	end

	for _, attribute in ipairs({ "Species", "Stage", "DigStrength" }) do
		player:GetAttributeChangedSignal(attribute):Connect(refreshSlots)
	end
	for _, attribute in ipairs({ "CarriedFoodType", "Growth", "Stage", "IsMother", "Species", "Mat_Feuille", "Mat_Brindille", "Mat_Caillou", "Mat_Terre" }) do
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
			card.Scale.Scale = 0.88
			card.Press:Play()
			local now = os.clock()
			if card.CooldownEnd > now and now - card.CooldownStart > 0.15 then
				card.Stroke.Color = Colors.Danger
				card.Stroke.Transparency = 0
				UiTheme.Tween(card.Stroke, 0.35, { Transparency = 0.55 })
			else
				card.Stroke.Color = Colors.AccentBright
				card.Stroke.Transparency = 0.05
				UiTheme.Tween(card.Stroke, 0.3, { Color = Colors.Accent, Transparency = 0.55 })
			end
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not gameProcessed then
				pressCard("LeftClick")
			end
			return
		end
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
							then string.format("%ds", math.ceil(remaining))
							else string.format("%.1fs", remaining)
					else
						card.CooldownEnd = 0
						card.Timer.Text = ""
						card.Cooldown.Size = COOLDOWN_EMPTY
						card.Stroke.Color = Colors.AccentBright
						if card.Enabled then
							card.Stroke.Transparency = 0
							UiTheme.Pop(card.Frame, 0.93, 0.24)
							UiTheme.Tween(card.Stroke, 0.55, { Color = Colors.Accent, Transparency = 0.55 })
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
				card.CooldownStart = os.clock()
				card.CooldownEnd = card.CooldownStart + seconds
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
