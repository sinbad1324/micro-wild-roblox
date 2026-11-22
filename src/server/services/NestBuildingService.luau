--!strict
-- NestBuildingService.luau
-- Construction du nid : on ramasse des matériaux dans le monde (feuilles, brindilles, cailloux) ou
-- on creuse la terre (DigService), puis on les rapporte au nid de sa famille pour le bâtir.
--
--   * Matériaux : noeuds tagués "BuildMaterial" (attribut Material) semés autour des biomes,
--     ramassés via ProximityPrompt [G] (comme la nourriture), réapparition après un délai.
--     Inventaire = attributs joueur "Mat_<Matériau>" (plafonnés), lus par le HUD.
--   * Terre : chaque coup de pioche réussi (DigService) en donne, à cadence limitée.
--   * Dépôt automatique dans le rayon du nid de SA famille : les matériaux remplissent le STOCK du
--     nid (attributs "Stock_<Matériau>" sur le modèle du nid, lus par le mode construction).
--   * Mode construction (BuildModeController, remote RequestNestBuild) : la famille place
--     LIBREMENT des pièces du catalogue de son espèce (NestPieces : fourmilière, ruche, soie,
--     aquatique, nid d'oiseau, drey, feuillage + pièces communes), payées sur le stock ;
--     suppression = remboursement de moitié. Tout est validé ici (famille, distance, coût, limite).
--   * Chaque espèce bâtit à sa manière : l'abeille SÉCRÈTE la cire, l'araignée la soie (si nourrie),
--     guêpes / frelons mâchent leurs brindilles en papier au dépôt, la fourmi creuse la terre.
--     Les blocs unitaires (Piece.Brick) se posent un par un pour donner au nid la forme voulue.
--   * Bonus : plus on a investi de matériaux, plus la famille se soigne au nid (niveaux 1..4).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local NestPieces = require(ReplicatedStorage.shared.NestPieces)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local WorldLayout = require(ReplicatedStorage.shared.WorldLayout)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local NestBuildingService = {}

local TAG = "BuildMaterial"
local NODE_COUNT = 170
local NODE_RESPAWN_SECONDS = 45
local PROMPT_DISTANCE = 9
local SERVER_DISTANCE_TOLERANCE = 8
local MAX_PER_MATERIAL = 15
local DIRT_PER_SECONDS = 0.6 -- creuser : au plus 1 terre toutes les 0.6 s
local TICK_SECONDS = 1
local HEAL_TICK_SECONDS = 2
local HEAL_PER_LEVEL = 0.015 -- part de la vie max rendue par tick et par niveau
local HEAL_COMBAT_GRACE = 5 -- pas de soin juste après un coup reçu
-- Points cumulés pour atteindre chaque niveau.
local LEVEL_THRESHOLDS = { 10, 30, 60, 100 }
local MAX_PIECES = 60 -- grandes pièces, par nid
local MAX_BRICKS = 400 -- blocs unitaires, par nid (1 à 3 parts chacun)
local SECRETE_SECONDS = 5 -- 1 cire / soie produite toutes les 5 s...
local SECRETE_MIN_HUNGER = 40 -- ...si l'animal est assez nourri...
local SECRETE_HUNGER_COST = 2 -- ...et ça lui coûte un peu de faim.
local BUILD_RADIUS_FACTOR = 1.6 -- pièces posées jusqu'à NEST_RADIUS * ceci du centre du nid
local BUILD_MAX_HEIGHT = 25
local BUILDER_REACH_FACTOR = 2.5 -- le constructeur doit être près de son nid
local BUILD_REQUEST_COOLDOWN = 0.2
local REFUND_RATIO = 0.5

type MaterialInfo = { Name: string, Points: number, Color: Color3, Material: Enum.Material }
local MATERIALS: { [string]: MaterialInfo } = {
	Feuille = { Name = "Feuille", Points = 1, Color = Color3.fromRGB(96, 150, 62), Material = Enum.Material.LeafyGrass },
	Brindille = { Name = "Brindille", Points = 2, Color = Color3.fromRGB(120, 84, 52), Material = Enum.Material.Wood },
	Caillou = { Name = "Caillou", Points = 3, Color = Color3.fromRGB(128, 126, 120), Material = Enum.Material.Slate },
	Terre = { Name = "Terre", Points = 1, Color = Color3.fromRGB(105, 78, 52), Material = Enum.Material.Ground },
	Cire = { Name = "Cire", Points = 2, Color = Color3.fromRGB(236, 186, 64), Material = Enum.Material.SmoothPlastic },
	Soie = { Name = "Soie", Points = 2, Color = Color3.fromRGB(242, 242, 248), Material = Enum.Material.Fabric },
	Papier = { Name = "Papier", Points = 2, Color = Color3.fromRGB(196, 176, 140), Material = Enum.Material.Fabric },
}
-- Matière sécrétée par le corps selon le thème de l'espèce (comme dans la nature).
local SECRETION: { [string]: string } = { Ruche = "Cire", Soie = "Soie" }
local GATHERABLE = { "Feuille", "Feuille", "Brindille", "Brindille", "Caillou" } -- tirage pondéré

local lastDirtAt: { [Player]: number } = {}
local lastPrompt: { [Player]: number } = {}
local lastBuild: { [Player]: number } = {}
local nodeFolder: Folder? = nil

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

local function attributeName(material: string): string
	return "Mat_" .. material
end

local function getActiveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function canGather(player: Player): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Adulte" or stage == "Larve" or stage == "Mue"
end

-- Ajoute un matériau à l'inventaire (plafonné). Renvoie faux si l'inventaire est plein.
function NestBuildingService.AddMaterial(player: Player, material: string, amount: number): boolean
	if not MATERIALS[material] then
		return false
	end
	local name = attributeName(material)
	local current = (player:GetAttribute(name) :: number?) or 0
	if current >= MAX_PER_MATERIAL then
		return false
	end
	player:SetAttribute(name, math.min(MAX_PER_MATERIAL, current + amount))
	return true
end

-- Appelé par DigService à chaque sculpture réussie : de la terre, à cadence limitée.
function NestBuildingService.OnDig(player: Player)
	local now = os.clock()
	if now - (lastDirtAt[player] or 0) < DIRT_PER_SECONDS then
		return
	end
	lastDirtAt[player] = now
	NestBuildingService.AddMaterial(player, "Terre", 1)
end

-- ============================================================
-- Noeuds de matériaux
-- ============================================================

local function getFolder(): Folder
	if nodeFolder and nodeFolder.Parent then
		return nodeFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "BuildMaterials"
	folder.Parent = workspace
	nodeFolder = folder
	return folder
end

local function makeNode(material: string, ground: Vector3, normal: Vector3, rng: Random): BasePart
	local info = MATERIALS[material]
	local part = Instance.new("Part")
	part.Name = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Color = info.Color:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.15))
	part.Material = info.Material
	local yaw = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	-- Posé sur le sol, légèrement incliné selon la pente.
	local up = if normal.Y > 0.2 then normal else Vector3.yAxis
	local tilt = CFrame.lookAt(Vector3.zero, Vector3.zero + up:Cross(Vector3.xAxis).Unit, up)
	if material == "Feuille" then
		part.Size = Vector3.new(rng:NextNumber(2.2, 3.2), 0.18, rng:NextNumber(1.4, 2))
		part.CFrame = CFrame.new(ground + up * 0.1) * tilt * yaw * CFrame.Angles(rng:NextNumber(-0.15, 0.15), 0, 0)
	elseif material == "Brindille" then
		part.Size = Vector3.new(rng:NextNumber(2.6, 3.8), 0.32, 0.32)
		part.CFrame = CFrame.new(ground + up * 0.18) * tilt * yaw
	else
		local s = rng:NextNumber(0.9, 1.4)
		part.Size = Vector3.new(s, s * 0.7, s * 0.9)
		part.CFrame = CFrame.new(ground + up * s * 0.3) * tilt * yaw * CFrame.Angles(0, 0, rng:NextNumber(-0.3, 0.3))
	end
	part:SetAttribute("Material", material)
	part.Parent = getFolder()
	return part
end

local function setNodeAvailable(node: BasePart, available: boolean)
	node.Transparency = if available then 0 else 1
	local prompt = node:FindFirstChild("GatherPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = available
	end
	node:SetAttribute("Depleted", if available then nil else true)
end

local function onGather(player: Player, node: BasePart)
	local now = os.clock()
	if now - (lastPrompt[player] or 0) < 0.3 or node:GetAttribute("Depleted") == true then
		return
	end
	lastPrompt[player] = now
	local root = getActiveRoot(player)
	if not root or (root.Position - node.Position).Magnitude > PROMPT_DISTANCE + SERVER_DISTANCE_TOLERANCE then
		return
	end
	if not canGather(player) then
		notify(player, "Trop petit pour ramasser des matériaux.", "warning")
		return
	end
	local material = node:GetAttribute("Material")
	if type(material) ~= "string" or not MATERIALS[material] then
		return
	end
	if not NestBuildingService.AddMaterial(player, material, 1) then
		notify(player, "Vous ne pouvez plus porter de " .. MATERIALS[material].Name .. " : rapportez-les au nid.", "warning")
		return
	end
	ProgressionService.ActionHook(player, "Ramasser", 1)
	if player:GetAttribute("FamilyId") == nil then
		notify(player, MATERIALS[material].Name .. " ramassée. Fondez ou rejoignez une colonie pour bâtir un nid.", "info")
	end
	setNodeAvailable(node, false)
	task.delay(NODE_RESPAWN_SECONDS, function()
		if node.Parent then
			setNodeAvailable(node, true)
		end
	end)
end

local function setupNode(node: BasePart)
	local material = node:GetAttribute("Material")
	local info = if type(material) == "string" then MATERIALS[material] else nil
	if not info then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GatherPrompt"
	prompt.ActionText = "Ramasser"
	prompt.ObjectText = info.Name .. " (nid)"
	prompt.KeyboardKeyCode = Enum.KeyCode.G -- E est réservé aux pouvoirs (comme FoodService)
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonL1
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = node
	prompt.Triggered:Connect(function(player)
		onGather(player, node)
	end)
end

local function scatterNodes()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { getFolder() }
	params.IgnoreWater = false
	local rng = Random.new(1120)
	local biomes = { WorldLayout.STUMP_CENTER, WorldLayout.PRAIRIE_CENTER, WorldLayout.ROCKS_CENTER, WorldLayout.OAK_CENTER, WorldLayout.POND_CENTER, WorldLayout.SPAWN_POSITION }
	local limit = WorldLayout.MAP_HALF - 30
	local placed = 0
	for _ = 1, NODE_COUNT * 3 do
		if placed >= NODE_COUNT then
			break
		end
		local center = biomes[rng:NextInteger(1, #biomes)]
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(12, 230)
		local x = math.clamp(center.X + math.cos(angle) * radius, -limit, limit)
		local z = math.clamp(center.Z + math.sin(angle) * radius, -limit, limit)
		local hit = workspace:Raycast(Vector3.new(x, WorldLayout.GROUND_TOP_Y + 150, z), Vector3.new(0, -300, 0), params)
		if not hit or hit.Material == Enum.Material.Water or hit.Normal.Y < 0.6 then
			continue
		end
		local material = GATHERABLE[rng:NextInteger(1, #GATHERABLE)]
		local node = makeNode(material, hit.Position, hit.Normal, rng)
		CollectionService:AddTag(node, TAG)
		placed += 1
	end
end

-- ============================================================
-- Construction du nid
-- ============================================================

local function levelFor(points: number): number
	local level = 0
	for i, threshold in ipairs(LEVEL_THRESHOLDS) do
		if points >= threshold then
			level = i
		end
	end
	return level
end

local function familyNest(familyId: string): (number?, any)
	for ownerUserId, nest in pairs(GrowthAndNestService.ActiveNests) do
		if nest.FamilyId == familyId then
			return ownerUserId, nest
		end
	end
	return nil, nil
end

-- Stock du nid publié sur son modèle (répliqué) : le mode construction affiche ce qu'on peut payer.
local function publishStock(nest: any)
	local model: Model? = nest.Model
	if not model then
		return
	end
	local stock = nest.Materials or {}
	for material in pairs(MATERIALS) do
		model:SetAttribute("Stock_" .. material, stock[material] or 0)
	end
	model:SetAttribute("FamilyId", nest.FamilyId)
	model:SetAttribute("BuildTheme", NestPieces.ThemeFor(nest.SpeciesId, (InsectData[nest.SpeciesId] or {} :: any).Category))
	model:SetAttribute("BuildCenter", nest.Position - Vector3.new(0, 2, 0))
end

local function constructionOf(nest: any): Instance?
	local model: Model? = nest.Model
	if not model then
		return nil
	end
	local container = model:FindFirstChild("Construction")
	if not container then
		local created = Instance.new("Model")
		created.Name = "Construction"
		created.Parent = model
		container = created
	end
	return container
end

-- Niveau de soin = matériaux investis (dépôts) : notifie la famille à chaque nouveau palier.
local function updateLevel(ownerUserId: number, nest: any)
	local target = levelFor((nest.BuildPoints :: number?) or 0)
	if target <= ((nest.BuildLevel :: number?) or 0) then
		return
	end
	nest.BuildLevel = target
	GrowthAndNestService.RefreshNestDisplay(ownerUserId)
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("FamilyId") == nest.FamilyId then
			notify(player, string.format("Nid niveau %d : soins renforcés au nid ! [B] pour construire.", target), "info")
		end
	end
end

-- Dépôt automatique : tout membre de la famille qui entre dans le rayon de son nid y vide ses matériaux.
local function depositTick()
	for _, player in ipairs(Players:GetPlayers()) do
		local familyId = player:GetAttribute("FamilyId")
		if type(familyId) ~= "string" then
			continue
		end
		local points, carried = 0, 0
		for material, info in pairs(MATERIALS) do
			local count = (player:GetAttribute(attributeName(material)) :: number?) or 0
			points += count * info.Points
			carried += count
		end
		if carried == 0 then
			continue
		end
		local root = getActiveRoot(player)
		local ownerUserId, nest = familyNest(familyId)
		if not root or not ownerUserId or not nest or (root.Position - nest.Position).Magnitude > GameConstants.NEST_RADIUS then
			continue
		end
		local stock = nest.Materials or {}
		nest.Materials = stock
		local chewsPaper = NestPieces.ThemeFor(nest.SpeciesId, (InsectData[nest.SpeciesId] or {} :: any).Category) == "Papier"
		for material in pairs(MATERIALS) do
			local count = (player:GetAttribute(attributeName(material)) :: number?) or 0
			-- Guêpes / frelons : les brindilles sont mâchées en pâte à papier.
			local into = if chewsPaper and material == "Brindille" then "Papier" else material
			stock[into] = (stock[into] or 0) + count
			player:SetAttribute(attributeName(material), nil)
		end
		publishStock(nest)
		nest.BuildPoints = ((nest.BuildPoints :: number?) or 0) + points
		ProgressionService.AddEvolutionPoints(player, math.ceil(points / 2))
		ProgressionService.AddExperience(player, points * 1.5, "Travail")
		local level = levelFor(nest.BuildPoints)
		local nextThreshold = LEVEL_THRESHOLDS[level + 1]
		notify(
			player,
			if nextThreshold
				then string.format("%d matériau(x) déposé(s) au stock du nid (niveau %d/%d pts). [B] pour construire.", carried, nest.BuildPoints, nextThreshold)
				else string.format("%d matériau(x) déposé(s) au stock du nid. [B] pour construire.", carried),
			"info"
		)
		updateLevel(ownerUserId, nest)
		GrowthAndNestService.RefreshNestDisplay(ownerUserId)
	end
end

-- ============================================================
-- Mode construction : pose / retrait de pièces (validé ici)
-- ============================================================

local function isFiniteCFrame(cf: CFrame): boolean
	for _, c in ipairs({ cf:GetComponents() }) do
		if c ~= c or math.abs(c) == math.huge then
			return false
		end
	end
	return true
end

local function onBuildRequest(player: Player, action: unknown, a: unknown, b: unknown)
	local now = os.clock()
	if now - (lastBuild[player] or 0) < BUILD_REQUEST_COOLDOWN then
		return
	end
	lastBuild[player] = now
	local familyId = player:GetAttribute("FamilyId")
	local root = getActiveRoot(player)
	if type(familyId) ~= "string" or not root then
		return
	end
	local ownerUserId, nest = familyNest(familyId)
	if not ownerUserId or not nest or not nest.Model then
		notify(player, "Pas de nid à construire : fondez ou rejoignez une colonie.", "warning")
		return
	end
	if (root.Position - nest.Position).Magnitude > GameConstants.NEST_RADIUS * BUILDER_REACH_FACTOR then
		notify(player, "Approchez-vous de votre nid pour construire.", "warning")
		return
	end
	local container = constructionOf(nest)
	if not container then
		return
	end
	local stock = nest.Materials or {}
	nest.Materials = stock

	if action == "Place" then
		if type(a) ~= "string" or typeof(b) ~= "CFrame" or not isFiniteCFrame(b :: CFrame) then
			return
		end
		local piece = NestPieces.Get(a :: string)
		local theme = NestPieces.ThemeFor(nest.SpeciesId, (InsectData[nest.SpeciesId] or {} :: any).Category)
		if not piece or (piece.Theme ~= theme and piece.Theme ~= "Commun") then
			return
		end
		local bricks = 0
		for _, child in ipairs(container:GetChildren()) do
			if child:GetAttribute("Brick") then
				bricks += 1
			end
		end
		local count = if piece.Brick then bricks else #container:GetChildren() - bricks
		local limit = if piece.Brick then MAX_BRICKS else MAX_PIECES
		if count >= limit then
			notify(player, string.format("Limite atteinte (%d max) : retirez-en.", limit), "warning")
			return
		end
		-- Seuls la position et le cap comptent (pas d'inclinaison envoyée par le client).
		local requested = b :: CFrame
		local center = nest.Position - Vector3.new(0, 2, 0)
		local offset = requested.Position - center
		if Vector2.new(offset.X, offset.Z).Magnitude > GameConstants.NEST_RADIUS * BUILD_RADIUS_FACTOR or math.abs(offset.Y) > BUILD_MAX_HEIGHT then
			notify(player, "Trop loin du nid pour construire ici.", "warning")
			return
		end
		-- Bloc : case déjà occupée = refus (sinon on paye deux fois la même place).
		local brickSize = piece.Brick
		if brickSize then
			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Include
			overlap.FilterDescendantsInstances = { container }
			if #workspace:GetPartBoundsInBox(CFrame.new(requested.Position), Vector3.one * brickSize * 0.6, overlap) > 0 then
				return
			end
		end
		for material, amount in pairs(piece.Cost) do
			if (stock[material] or 0) < (amount :: number) then
				notify(player, "Pas assez de matériaux au stock du nid.", "warning")
				return
			end
		end
		for material, amount in pairs(piece.Cost) do
			stock[material] -= amount :: number
		end
		local look = requested.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		local built = NestPieces.Build(piece, CFrame.new(requested.Position) * CFrame.Angles(0, yaw, 0))
		built:SetAttribute("PieceId", piece.Id)
		built:SetAttribute("PlacedBy", player.UserId)
		built:SetAttribute("Brick", if piece.Brick then true else nil)
		built.Parent = container
		ProgressionService.ActionHook(player, "Batir", 1)
		publishStock(nest)
	elseif action == "Remove" then
		if typeof(a) ~= "Instance" or (a :: Instance).Parent ~= container then
			return
		end
		local target = a :: Instance
		local pieceId = target:GetAttribute("PieceId")
		local piece = if type(pieceId) == "string" then NestPieces.Get(pieceId) else nil
		if piece then
			for material, amount in pairs(piece.Cost) do
				stock[material] = (stock[material] or 0) + math.floor((amount :: number) * REFUND_RATIO)
			end
		end
		target:Destroy()
		publishStock(nest)
	end
end

-- Sécrétion : abeilles (cire) et araignées (soie) fabriquent elles-mêmes leur matériau, si nourries.
local function secreteTick()
	for _, player in ipairs(Players:GetPlayers()) do
		local speciesId = player:GetAttribute("Species")
		if type(speciesId) ~= "string" or not canGather(player) or not getActiveRoot(player) then
			continue
		end
		local material = SECRETION[NestPieces.ThemeFor(speciesId, (InsectData[speciesId] or {} :: any).Category)]
		local hunger = (player:GetAttribute("Hunger") :: number?) or 0
		if material and hunger >= SECRETE_MIN_HUNGER and NestBuildingService.AddMaterial(player, material, 1) then
			player:SetAttribute("Hunger", hunger - SECRETE_HUNGER_COST)
		end
	end
end

-- Soin au nid construit : plus le nid est bâti, plus la famille récupère vite (hors combat).
local function healTick()
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		local familyId = player:GetAttribute("FamilyId")
		if type(familyId) ~= "string" then
			continue
		end
		local _, nest = familyNest(familyId)
		local level = if nest then ((nest.BuildLevel :: number?) or 0) else 0
		if level <= 0 then
			continue
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = getActiveRoot(player)
		if not character or not humanoid or not root or (root.Position - nest.Position).Magnitude > GameConstants.NEST_RADIUS then
			continue
		end
		local lastHit = character:GetAttribute("LastAttackAt")
		if type(lastHit) == "number" and now - lastHit < HEAL_COMBAT_GRACE then
			continue
		end
		if humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * HEAL_PER_LEVEL * level)
		end
	end
end

function NestBuildingService.Start()
	for _, node in ipairs(CollectionService:GetTagged(TAG)) do
		if node:IsA("BasePart") then
			setupNode(node)
		end
	end
	Remotes.Get("RequestNestBuild").OnServerEvent:Connect(onBuildRequest)
	-- Nouveaux nids : leur stock (vide) et leur thème sont publiés pour le mode construction.
	task.spawn(function()
		while true do
			task.wait(3)
			for _, nest in pairs(GrowthAndNestService.ActiveNests) do
				if nest.Model and nest.Model:GetAttribute("FamilyId") == nil then
					publishStock(nest)
				end
			end
		end
	end)
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(instance)
		if instance:IsA("BasePart") then
			setupNode(instance)
		end
	end)
	-- Le terrain est généré avant : semis après un court délai de sécurité.
	task.delay(2, function()
		local ok, err = pcall(scatterNodes)
		if not ok then
			warn("[NestBuildingService] semis : " .. tostring(err))
		end
	end)
	task.spawn(function()
		local healAcc, secreteAcc = 0, 0
		while true do
			task.wait(TICK_SECONDS)
			secreteAcc += TICK_SECONDS
			if secreteAcc >= SECRETE_SECONDS then
				secreteAcc = 0
				local ok, err = pcall(secreteTick)
				if not ok then
					warn("[NestBuildingService] sécrétion : " .. tostring(err))
				end
			end
			local ok, err = pcall(depositTick)
			if not ok then
				warn("[NestBuildingService] dépôt : " .. tostring(err))
			end
			healAcc += TICK_SECONDS
			if healAcc >= HEAL_TICK_SECONDS then
				healAcc = 0
				local healed, healErr = pcall(healTick)
				if not healed then
					warn("[NestBuildingService] soin : " .. tostring(healErr))
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastDirtAt[player] = nil
		lastPrompt[player] = nil
		lastBuild[player] = nil
	end)
end

return NestBuildingService
