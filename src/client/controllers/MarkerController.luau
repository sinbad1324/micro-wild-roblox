--!strict
-- MarkerController.luau
-- Repères visuels locaux (BillboardGui côté client uniquement) :
--   * icône au-dessus des membres de sa famille et de sa Maman (GDD §8.2 Coopération)
--   * nuage d'odeur des carcasses en putréfaction, visible de loin par les nécrophages (GDD §7.B)
--   * balise "Festin de Kaiju" quand un des 5 animaux géants meurt (GDD §7.B)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)

-- Portée des marqueurs de famille : une demi-carte, pour qu'une larve retrouve sa Mère et sa colonie.
local FAMILY_MARKER_DISTANCE = WorldLayout.MAP_SIZE * 0.5

local MarkerController = {}

local player = Players.LocalPlayer
local started = false

local SCAVENGER_ABILITY = "OdoratCharogne"
local KAIJU_MARKER_SECONDS = 180

-- Clé : Player, ou Model "NpcMother" (Maman PNJ de la famille).
local familyMarkers: { [Instance]: BillboardGui } = {}
-- Repère du nid (HomePosition) : ancre locale invisible, visible tant que le joueur est un bébé.
local homeAnchor: Part? = nil
local homeMarker: BillboardGui? = nil
local FAMILY_COLOR = Color3.fromRGB(255, 225, 120)
local threatMarkers: { [Player]: BillboardGui } = {}

-- Passifs de détection (portée en studs = Power dans AbilityCatalog).
local DETECTION_PASSIVES: { [string]: number } = {
	Vision360 = 20, -- Araignée sauteuse : menaces dans toutes les directions
	DetectionThermique = 25, -- Moustique : chaleur corporelle à travers le feuillage
	RadarVibrationsEau = 30, -- Gerris : insectes tombés à l'eau
}
local carcassMarkers: { [Instance]: BillboardGui } = {}

local function makeBillboard(name: string, text: string, color: Color3, adornee: Instance, offsetY: number, alwaysOnTop: boolean, maxDistance: number): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = name
	billboard.Size = UDim2.fromOffset(160, 34)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	billboard.AlwaysOnTop = alwaysOnTop
	billboard.MaxDistance = maxDistance
	billboard.Adornee = adornee
	billboard.ResetOnSpawn = false

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.Parent = billboard

	billboard.Parent = player:WaitForChild("PlayerGui")
	return billboard
end

local function refreshFamilyMarkers()
	local myFamily = player:GetAttribute("FamilyId")
	for _, other in ipairs(Players:GetPlayers()) do
		if other == player then
			continue
		end
		local root = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
		local isFamily = myFamily ~= nil and other:GetAttribute("FamilyId") == myFamily and root ~= nil
		local marker = familyMarkers[other]
		if isFamily and root then
			local text = if other:GetAttribute("IsMother") == true then "👑 Maman " .. other.Name else "💛 " .. other.Name
			if not marker or marker.Adornee ~= root then
				if marker then
					marker:Destroy()
				end
				marker = makeBillboard("FamilyMarker", text, FAMILY_COLOR, root, 4, false, FAMILY_MARKER_DISTANCE)
				familyMarkers[other] = marker
			end
			local label = (marker :: BillboardGui):FindFirstChild("Text") :: TextLabel?
			if label then
				label.Text = text
			end
		elseif marker then
			marker:Destroy()
			familyMarkers[other] = nil
		end
	end
	-- Maman PNJ de la famille (bébé né dans un nid PNJ).
	for _, model in ipairs(CollectionService:GetTagged("NpcMother")) do
		local primary = if model:IsA("Model") then (model :: Model).PrimaryPart else nil
		local marker = familyMarkers[model]
		if myFamily ~= nil and primary and model:GetAttribute("FamilyId") == myFamily then
			if not marker or marker.Adornee ~= primary then
				if marker then
					marker:Destroy()
				end
				familyMarkers[model] = makeBillboard("FamilyMarker", "👑 " .. model.Name, FAMILY_COLOR, primary, 5, false, FAMILY_MARKER_DISTANCE)
			end
		elseif marker then
			marker:Destroy()
			familyMarkers[model] = nil
		end
	end
	for other, marker in pairs(familyMarkers) do
		if not other.Parent then
			marker:Destroy()
			familyMarkers[other] = nil
		end
	end
end

local function refreshHomeMarker()
	local home = player:GetAttribute("HomePosition")
	if typeof(home) ~= "Vector3" then
		if homeMarker then
			homeMarker:Destroy()
			homeMarker = nil
		end
		if homeAnchor then
			homeAnchor:Destroy()
			homeAnchor = nil
		end
		return
	end
	local anchor = homeAnchor
	if not anchor or not anchor.Parent then
		local newAnchor = Instance.new("Part")
		newAnchor.Name = "HomeNestAnchor"
		newAnchor.Anchored = true
		newAnchor.CanCollide = false
		newAnchor.CanQuery = false
		newAnchor.CanTouch = false
		newAnchor.Transparency = 1
		newAnchor.Size = Vector3.one
		newAnchor.Parent = workspace.CurrentCamera
		anchor = newAnchor
		homeAnchor = newAnchor
	end
	local part = anchor :: Part
	local homePosition = home :: Vector3
	if part.Position ~= homePosition then
		part.Position = homePosition
	end
	local marker = homeMarker
	if not marker or not marker.Parent then
		local created = makeBillboard("HomeNestMarker", "🏠 Nid", FAMILY_COLOR, part, 4, true, FAMILY_MARKER_DISTANCE)
		homeMarker = created
		marker = created
	end
	-- L'ancre a pu être recréée (caméra remplacée) : on re-pointe le marqueur.
	if marker and marker.Adornee ~= part then
		marker.Adornee = part
	end
	local stage = player:GetAttribute("Stage")
	if marker then
		marker.Enabled = stage == "Oeuf" or stage == "Larve" or stage == "Mue" or stage == "Cocon"
	end
end

-- Nécrophages : espèces omnivores ou avec "Odorat de charogne" (Mouche).
local function isScavenger(): boolean
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	if not species then
		return false
	end
	return species.Diet == "Omnivore" or table.find(species.Abilities, SCAVENGER_ABILITY) ~= nil
end

local function refreshCarcassMarkers()
	local scavenger = isScavenger()
	local alive: { [Instance]: boolean } = {}
	for _, carcass in ipairs(CollectionService:GetTagged("Carcass")) do
		if not carcass:IsA("Model") or not carcass.PrimaryPart then
			continue
		end
		local stage = carcass:GetAttribute("Stage")
		local wanted = scavenger and (stage == "Putrefaction" or (stage == "Frais" and carcass:GetAttribute("IsGiantAnimal") == true))
		if wanted then
			alive[carcass] = true
			if not carcassMarkers[carcass] then
				carcassMarkers[carcass] = makeBillboard("OdorMarker", "🦴 Odeur de charogne", Color3.fromRGB(150, 230, 110), carcass.PrimaryPart, 6, true, 600)
			end
		end
	end
	for carcass, marker in pairs(carcassMarkers) do
		if not alive[carcass] then
			marker:Destroy()
			carcassMarkers[carcass] = nil
		end
	end
end

local function refreshThreatMarkers()
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	local range = 0
	local waterOnly = false
	if species and player:GetAttribute("Stage") == "Adulte" then
		for _, id in ipairs(species.Abilities) do
			if DETECTION_PASSIVES[id] then
				range = DETECTION_PASSIVES[id]
				waterOnly = id == "RadarVibrationsEau"
			end
		end
	end
	local myRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local myFamily = player:GetAttribute("FamilyId")
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	for _, other in ipairs(Players:GetPlayers()) do
		local root = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local detected = false
		if other ~= player and range > 0 and myRoot and root and (myFamily == nil or other:GetAttribute("FamilyId") ~= myFamily) then
			detected = (root.Position - myRoot.Position).Magnitude <= range
			if waterOnly then
				detected = detected and waterLevel ~= nil and root.Position.Y < (waterLevel :: number) + 1
			end
		end
		local marker = threatMarkers[other]
		if detected and root then
			if not marker or marker.Adornee ~= root then
				if marker then
					marker:Destroy()
				end
				threatMarkers[other] = makeBillboard("ThreatMarker", "⚠ " .. other.Name, Color3.fromRGB(255, 90, 80), root, 3, true, range + 10)
			end
		elseif marker then
			marker:Destroy()
			threatMarkers[other] = nil
		end
	end
	for other, marker in pairs(threatMarkers) do
		if not other.Parent then
			marker:Destroy()
			threatMarkers[other] = nil
		end
	end
end

local function onKaijuFeast(animalName: unknown, position: unknown)
	if typeof(animalName) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "KaijuFeastAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position :: Vector3
	anchor.Parent = workspace.CurrentCamera
	local marker = makeBillboard("KaijuFeastMarker", "🍖 FESTIN DE KAIJU : " .. (animalName :: string), Color3.fromRGB(255, 110, 80), anchor, 25, true, 5000)
	marker.Size = UDim2.fromOffset(260, 44)
	task.delay(KAIJU_MARKER_SECONDS, function()
		marker:Destroy()
		anchor:Destroy()
	end)
end

function MarkerController.Start()
	if started then
		return
	end
	started = true
	Remotes.Get("KaijuFeastEvent").OnClientEvent:Connect(onKaijuFeast)
	task.spawn(function()
		while true do
			refreshFamilyMarkers()
			refreshHomeMarker()
			refreshCarcassMarkers()
			refreshThreatMarkers()
			task.wait(1)
		end
	end)
end

return MarkerController
