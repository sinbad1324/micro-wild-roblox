--!strict
-- FoodService.luau
-- Manger, boire, transporter (GDD §3 Faim/Soif, §7.B carcasses, §8.2 nid qui partage sa réserve).
-- Interaction via ProximityPrompt créés côté serveur (PC, mobile, manette sans code client) :
--   [G] Manger / Boire     [T] Transporter vers le nid (adultes)
-- La touche par défaut d'un ProximityPrompt est E, réservée aux pouvoirs (GDD §8.3) : on la change.
--
-- Contrat monde :
--   tag "FoodNode"    + attribut FoodType (FoodData), optionnels Uses / NoRespawn
--   tag "DrinkSource" + optionnels Uses / NoRespawn (rosée, flaques, berge de la mare)
--   tag "Carcass"     + attributs CarcassFoodType / MeatLeft (CarcassService)
--   tag "AINest"      : nid protégé par une IA, nourrit doucement les larves à proximité

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FoodData = require(ReplicatedStorage.shared.FoodData)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local GameConstants = require(ServerScriptService.constant.GameConstants)
local GrowthAndNestService = require(ServerScriptService.services.GrowthAndNestService)
local StatusEffectService = require(ServerScriptService.services.StatusEffectService)
local ProgressionService = require(ServerScriptService.services.ProgressionService)

local FoodService = {}

local EAT_KEY = Enum.KeyCode.G
local CARRY_KEY = Enum.KeyCode.T
local PROMPT_DISTANCE = 9
local SERVER_DISTANCE_TOLERANCE = 8 -- marge pour la latence / l'échelle du personnage
local DRINK_VALUE = 35
local CARCASS_BITE = 20
local NEST_TICK_SECONDS = 2
local NEST_FEED_COST = 10
local AI_NEST_TICK_SECONDS = 8
-- Repas "canalisé" : on maintient la touche un court instant, le noeud rétrécit à chaque bouchée.
local EAT_HOLD_SECONDS = 0.5
local MIN_BITE_SCALE = 0.4 -- taille d'un noeud presque vide (fraction de BaseSize)
local VANISH_STEPS = 4
local VANISH_STEP_SECONDS = 0.06
local REGROW_STEPS = 5
local REGROW_STEP_SECONDS = 0.08
local NIBBLE_FX_SECONDS = 0.25
local WATER_FX_COLOR = Color3.fromRGB(150, 200, 240)

local FOOD_DISPLAY_NAMES: { [string]: string } = {
	Feuille = "Feuille",
	Pollen = "Pollen",
	Nectar = "Nectar",
	Seve = "Sève",
	Bois = "Bois pourri",
	Insecte = "Insecte",
	Larve = "Larve",
	Poisson = "Poisson",
	Sang = "Sang",
	Fruit = "Fruit",
	Graine = "Graine",
	Miette = "Miettes",
	Champignon = "Champignon",
	CarcasseFraiche = "Carcasse fraîche",
	CarcassePutride = "Carcasse putride",
	OeufsPoisson = "Oeufs de poisson",
}

local lastAction: { [Player]: number } = {}
-- Un émetteur de miettes par joueur, déplacé et allumé brièvement (même principe que DigService).
local nibbleFxParts: { [Player]: Part } = {}
local nibbleFxStopAt: { [Player]: number } = {}
-- Anti-spam du toast "réserve du nid vide" (1 par minute et par bébé).
local emptyNestNotifiedAt: { [Player]: number } = {}

local function notify(player: Player, message: string, kind: string)
	Remotes.Get("NotifyClient"):FireClient(player, message, kind)
end

-- Anti-spam : 1 action de repas par 0.4s et par joueur (le prompt a déjà un HoldDuration).
local function throttle(player: Player): boolean
	local now = os.clock()
	if lastAction[player] and now - lastAction[player] < 0.4 then
		return false
	end
	lastAction[player] = now
	return true
end

-- Retourne la racine du joueur s'il est vivant, éveillé (pas Oeuf/Cocon) et pas agrippé.
local function getActiveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or humanoid.Health <= 0 or not root then
		return nil
	end
	local stage = player:GetAttribute("Stage")
	if stage == "Oeuf" or stage == "Cocon" or player:GetAttribute("IsGrabbed") == true then
		return nil
	end
	return root
end

local function isInRange(root: BasePart, target: BasePart): boolean
	local maxDistance = PROMPT_DISTANCE + SERVER_DISTANCE_TOLERANCE + math.max(target.Size.X, target.Size.Z) / 2
	return (root.Position - target.Position).Magnitude <= maxDistance
end

local function getDiet(player: Player): FoodData.DietType
	local species = InsectData[(player:GetAttribute("Species") :: string?) or GameConstants.DEFAULT_SPECIES]
	return if species then species.Diet else "Omnivore"
end

local function feed(player: Player, value: number)
	local hunger = (player:GetAttribute("Hunger") :: number?) or 0
	local newHunger = math.min(100, hunger + value)
	player:SetAttribute("Hunger", newHunger)
	-- PE seulement pour la faim réellement comblée (pas de farm en mangeant le ventre plein).
	local restored = newHunger - hunger
	if restored > 0 then
		ProgressionService.AddEvolutionPoints(player, math.ceil(restored / 5))
	end
end

local function hydrate(player: Player, value: number)
	local thirst = (player:GetAttribute("Thirst") :: number?) or 0
	player:SetAttribute("Thirst", math.min(100, thirst + value))
end

-- Miettes (ou gouttelettes) qui jaillissent du noeud à chaque bouchée : retour visuel du repas.
local function playNibbleFx(player: Player, position: Vector3, color: Color3)
	local part = nibbleFxParts[player]
	if not part or not part.Parent then
		part = Instance.new("Part")
		part.Name = "NibbleFx"
		part.Size = Vector3.one
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Crumbs"
		emitter.Enabled = false
		emitter.Size = NumberSequence.new(0.35, 0.05)
		emitter.Lifetime = NumberRange.new(0.3, 0.6)
		emitter.Rate = 40
		emitter.Speed = NumberRange.new(4, 8)
		emitter.SpreadAngle = Vector2.new(70, 70)
		emitter.Acceleration = Vector3.new(0, -30, 0)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Parent = part
		part.Parent = workspace
		nibbleFxParts[player] = part
	end
	local emitter = part:FindFirstChild("Crumbs")
	if not emitter or not emitter:IsA("ParticleEmitter") then
		return
	end
	part.CFrame = CFrame.new(position)
	emitter.Color = ColorSequence.new(color)
	emitter.Enabled = true
	local stopAt = os.clock() + NIBBLE_FX_SECONDS
	nibbleFxStopAt[player] = stopAt
	task.delay(NIBBLE_FX_SECONDS, function()
		-- Une bouchée plus récente a prolongé l'effet : c'est elle qui l'éteindra.
		if nibbleFxStopAt[player] == stopAt then
			emitter.Enabled = false
		end
	end)
end

-- Hauteur monde d'une part (rotation comprise) : sert à garder sa base posée en la redimensionnant.
local function worldHeight(cf: CFrame, size: Vector3): number
	return math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z
end

-- Taille d'origine du noeud (posée au setup ; repli sur la taille actuelle pour un noeud inconnu).
local function getBaseSize(part: BasePart): Vector3
	local base = part:GetAttribute("BaseSize") :: Vector3?
	if base then
		return base
	end
	part:SetAttribute("BaseSize", part.Size)
	return part.Size
end

-- Redimensionne à une fraction de BaseSize sans faire flotter un fruit posé au sol.
local function setNodeScale(part: BasePart, fraction: number)
	local cf = part.CFrame
	local newSize = getBaseSize(part) * fraction
	local drop = (worldHeight(cf, part.Size) - worldHeight(cf, newSize)) / 2
	part.Size = newSize
	part.CFrame = cf - Vector3.new(0, drop, 0)
end

local function setPromptsEnabled(part: BasePart, enabled: boolean)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("ProximityPrompt") then
			child.Enabled = enabled
		end
	end
end

-- Consomme un usage d'une source : elle rétrécit à chaque bouchée, puis disparaît en se ratatinant
-- et repousse doucement (ou est détruite si NoRespawn).
local function consumeUse(part: BasePart)
	local uses = (part:GetAttribute("Uses") :: number?) or 1
	uses -= 1
	local maxUses = math.max((part:GetAttribute("MaxUses") :: number?) or 1, 1)
	if uses > 0 then
		part:SetAttribute("Uses", uses)
		setNodeScale(part, MIN_BITE_SCALE + (1 - MIN_BITE_SCALE) * math.min(uses / maxUses, 1))
		return
	end
	-- Plus de bouchée possible tout de suite ; l'animation de disparition suit.
	part:SetAttribute("Depleted", true)
	setPromptsEnabled(part, false)
	local originalTransparency = part.Transparency
	task.spawn(function()
		local startScale = part.Size.Magnitude / math.max(getBaseSize(part).Magnitude, 0.01)
		for step = 1, VANISH_STEPS do
			if not part.Parent then
				return
			end
			setNodeScale(part, startScale * (1 - step / (VANISH_STEPS + 1)))
			part.Transparency = originalTransparency + (1 - originalTransparency) * step / VANISH_STEPS
			task.wait(VANISH_STEP_SECONDS)
		end
		if not part.Parent then
			return
		end
		if part:GetAttribute("NoRespawn") == true then
			part:Destroy()
			return
		end
		task.wait(GameConstants.FOOD_RESPAWN_SECONDS)
		if not part.Parent then
			return
		end
		-- Repousse : de petit et transparent à la taille d'origine, puis de nouveau mangeable.
		for step = 1, REGROW_STEPS do
			if not part.Parent then
				return
			end
			local alpha = step / REGROW_STEPS
			setNodeScale(part, 0.2 + 0.8 * alpha)
			part.Transparency = 1 + (originalTransparency - 1) * alpha
			task.wait(REGROW_STEP_SECONDS)
		end
		if not part.Parent then
			return
		end
		part:SetAttribute("Uses", maxUses)
		part:SetAttribute("Depleted", nil)
		setPromptsEnabled(part, true)
	end)
end

local function makePrompt(parent: BasePart, name: string, actionText: string, objectText: string, key: Enum.KeyCode, gamepadKey: Enum.KeyCode): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.KeyboardKeyCode = key
	prompt.GamepadKeyCode = gamepadKey
	prompt.HoldDuration = EAT_HOLD_SECONDS
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false -- sous l'eau, dans l'herbe, dans une carcasse...
	prompt.Parent = parent
	return prompt
end

-- ============================================================
-- Transport vers le nid
-- ============================================================

local function attachCarriedVisual(player: Player, color: Color3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	local existing = character:FindFirstChild("CarriedFoodVisual")
	if existing then
		existing:Destroy()
	end
	local ball = Instance.new("Part")
	ball.Name = "CarriedFoodVisual"
	ball:SetAttribute("KeepVisible", true) -- sinon masqué comme une pièce d'avatar
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * 0.9 * character:GetScale()
	ball.Color = color
	ball.Material = Enum.Material.SmoothPlastic
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Massless = true
	ball.CFrame = root.CFrame * CFrame.new(0, 0.2, -2.2 * character:GetScale())
	ball.Parent = character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = ball
	weld.Parent = ball
end

local function clearCarried(player: Player)
	player:SetAttribute("CarriedFood", nil)
	player:SetAttribute("CarriedFoodType", nil)
	local character = player.Character
	local visual = character and character:FindFirstChild("CarriedFoodVisual")
	if visual then
		visual:Destroy()
	end
end

local function startCarrying(player: Player, foodType: string, value: number, color: Color3): boolean
	if player:GetAttribute("Stage") ~= "Adulte" then
		notify(player, "Seuls les adultes peuvent transporter de la nourriture.", "warning")
		return false
	end
	if player:GetAttribute("CarriedFood") ~= nil then
		notify(player, "Vous portez déjà quelque chose.", "warning")
		return false
	end
	if player:GetAttribute("FamilyId") == nil then
		notify(player, "Rejoignez ou fondez une colonie pour ravitailler un nid.", "warning")
		return false
	end
	-- Passif "Force herculéenne" (Fourmi) : rapporte une charge bien plus lourde au nid.
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	if species and table.find(species.Abilities, "ForceHerculeenne") then
		value *= 2
	end
	player:SetAttribute("CarriedFood", value)
	player:SetAttribute("CarriedFoodType", foodType)
	attachCarriedVisual(player, color)
	notify(player, "Rapportez " .. (FOOD_DISPLAY_NAMES[foodType] or foodType) .. " au nid !", "info")
	return true
end

-- ============================================================
-- Noeuds de nourriture
-- ============================================================

local function onEatNode(player: Player, node: BasePart)
	if not throttle(player) or node:GetAttribute("Depleted") == true then
		return
	end
	local root = getActiveRoot(player)
	if not root or not isInRange(root, node) then
		return
	end
	local foodType = node:GetAttribute("FoodType") :: string?
	local info = foodType and FoodData.Get(foodType)
	if not foodType or not info then
		return
	end
	local diet = getDiet(player)
	if not FoodData.CanEat(diet, foodType) then
		notify(player, string.format("Votre régime (%s) ne permet pas de manger : %s.", diet, FOOD_DISPLAY_NAMES[foodType] or foodType), "warning")
		return
	end
	feed(player, info.NutritionValue)
	playNibbleFx(player, node.Position, node.Color)
	consumeUse(node)
end

local function onCarryNode(player: Player, node: BasePart)
	if not throttle(player) or node:GetAttribute("Depleted") == true then
		return
	end
	local root = getActiveRoot(player)
	if not root or not isInRange(root, node) then
		return
	end
	local foodType = node:GetAttribute("FoodType") :: string?
	local info = foodType and FoodData.Get(foodType)
	if not foodType or not info then
		return
	end
	if startCarrying(player, foodType, info.NutritionValue, node.Color) then
		playNibbleFx(player, node.Position, node.Color)
		consumeUse(node)
	end
end

local function setupFoodNode(instance: Instance)
	if not instance:IsA("BasePart") or instance:FindFirstChild("EatPrompt") then
		return
	end
	local node = instance :: BasePart
	local foodType = (node:GetAttribute("FoodType") :: string?) or "?"
	if node:GetAttribute("MaxUses") == nil then
		node:SetAttribute("MaxUses", (node:GetAttribute("Uses") :: number?) or 1)
	end
	getBaseSize(node)
	local displayName = FOOD_DISPLAY_NAMES[foodType] or foodType
	makePrompt(node, "EatPrompt", "Manger", displayName, EAT_KEY, Enum.KeyCode.ButtonL1).Triggered:Connect(function(player)
		onEatNode(player, node)
	end)
	local carryPrompt = makePrompt(node, "CarryPrompt", "Transporter", displayName, CARRY_KEY, Enum.KeyCode.ButtonR1)
	carryPrompt.UIOffset = Vector2.new(0, 60)
	carryPrompt.Triggered:Connect(function(player)
		onCarryNode(player, node)
	end)
end

-- ============================================================
-- Eau
-- ============================================================

local function onDrink(player: Player, source: BasePart)
	if not throttle(player) or source:GetAttribute("Depleted") == true then
		return
	end
	local root = getActiveRoot(player)
	if not root or not isInRange(root, source) then
		return
	end
	if workspace:GetAttribute("PondFrozenNow") == true and source:GetAttribute("IsPondEdge") == true then
		notify(player, "La mare est gelée ! Cherchez de la neige fondue ou une autre source.", "warning")
		return
	end
	hydrate(player, DRINK_VALUE)
	playNibbleFx(player, source.Position, WATER_FX_COLOR)
	if source:GetAttribute("Uses") ~= nil or source:GetAttribute("NoRespawn") == true then
		consumeUse(source)
	end
end

local function setupDrinkSource(instance: Instance)
	if not instance:IsA("BasePart") or instance:FindFirstChild("DrinkPrompt") then
		return
	end
	local source = instance :: BasePart
	local objectText = (source:GetAttribute("DisplayName") :: string?) or "Eau"
	-- Flaques et rosée rétrécissent elles aussi gorgée après gorgée (MaxUses = usages de départ).
	local initialUses = source:GetAttribute("Uses") :: number?
	if source:GetAttribute("MaxUses") == nil and initialUses then
		source:SetAttribute("MaxUses", initialUses)
	end
	getBaseSize(source)
	makePrompt(source, "DrinkPrompt", "Boire", objectText, EAT_KEY, Enum.KeyCode.ButtonL1).Triggered:Connect(function(player)
		onDrink(player, source)
	end)
end

-- Points d'eau invisibles le long des berges de chaque zone de mare (la mare est du Terrain, qui
-- ne peut pas porter de ProximityPrompt).
local function createPondEdgeSources()
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevel then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "PondDrinkPoints"
	folder.Parent = workspace:FindFirstChild("GeneratedWorld") or workspace
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if not zone:IsA("BasePart") then
			continue
		end
		local half = zone.Size * 0.5
		-- Un point tous les 16 studs sur tout le périmètre : toujours un "Boire" à portée de berge.
		local edgeOffsets: { Vector3 } = {}
		for x = -half.X + 1, half.X - 1, 16 do
			table.insert(edgeOffsets, Vector3.new(x, 0, half.Z - 1))
			table.insert(edgeOffsets, Vector3.new(x, 0, -half.Z + 1))
		end
		for z = -half.Z + 1, half.Z - 1, 16 do
			table.insert(edgeOffsets, Vector3.new(half.X - 1, 0, z))
			table.insert(edgeOffsets, Vector3.new(-half.X + 1, 0, z))
		end
		for _, offset in ipairs(edgeOffsets) do
			local worldPosition = zone.CFrame:PointToWorldSpace(offset)
			local anchor = Instance.new("Part")
			anchor.Name = "PondDrinkPoint"
			anchor.Size = Vector3.new(2, 1, 2)
			anchor.CFrame = CFrame.new(worldPosition.X, waterLevel + 0.5, worldPosition.Z)
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Transparency = 1
			anchor:SetAttribute("IsPondEdge", true)
			anchor:SetAttribute("DisplayName", "Mare")
			anchor.Parent = folder
			CollectionService:AddTag(anchor, "DrinkSource")
		end
	end
end

-- ============================================================
-- Carcasses
-- ============================================================

local function onEatCarcass(player: Player, carcass: Model, anchor: BasePart, carry: boolean)
	if not throttle(player) then
		return
	end
	local root = getActiveRoot(player)
	if not root or not isInRange(root, anchor) then
		-- Carcasse géante : la distance au point d'ancrage peut être grande, on tolère la taille du modèle.
		if not root or (root.Position - anchor.Position).Magnitude > PROMPT_DISTANCE + carcass:GetExtentsSize().Magnitude / 2 then
			return
		end
	end
	local foodType = carcass:GetAttribute("CarcassFoodType") :: string?
	local meatLeft = (carcass:GetAttribute("MeatLeft") :: number?) or 0
	if not foodType or meatLeft <= 0 then
		notify(player, "Il ne reste plus rien de comestible ici.", "warning")
		return
	end
	local info = FoodData.Get(foodType)
	if not info then
		return
	end
	local diet = getDiet(player)
	local value = math.min(CARCASS_BITE, meatLeft)
	-- Valeur nutritive proportionnelle à la viande réellement prélevée.
	local nutrition = info.NutritionValue * value / CARCASS_BITE
	local sickening = false
	if not FoodData.CanEat(diet, foodType) then
		-- Viande putride : toxique pour les carnivores stricts (GDD §7.B) mais pas interdite.
		if foodType == "CarcassePutride" and diet == "Carnivore" then
			sickening = true
		else
			notify(player, string.format("Votre régime (%s) ne permet pas de manger cette carcasse.", diet), "warning")
			return
		end
	end

	if carry then
		if not startCarrying(player, foodType, nutrition, Color3.fromRGB(150, 40, 40)) then
			return
		end
	else
		feed(player, nutrition * (if sickening then 0.5 else 1))
		if sickening and player.Character then
			StatusEffectService.Apply(player.Character, "Poison", 6, 0.4)
			notify(player, "Cette viande pourrie vous rend malade !", "warning")
		end
	end
	playNibbleFx(player, anchor.Position, Color3.fromRGB(150, 40, 40))
	meatLeft -= value
	carcass:SetAttribute("MeatLeft", meatLeft)
	if meatLeft <= 0 then
		carcass:SetAttribute("CarcassFoodType", nil)
	end
end

local function setupCarcass(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local carcass = instance :: Model
	-- La PrimaryPart peut être posée juste après le tag : on attend un tour de moteur.
	task.defer(function()
		local anchor = carcass.PrimaryPart or carcass:FindFirstChildWhichIsA("BasePart", true)
		if not anchor or anchor:FindFirstChild("EatPrompt") then
			return
		end
		local isGiant = carcass:GetAttribute("IsGiantAnimal") == true
		local objectText = "Carcasse de " .. tostring(carcass:GetAttribute("OwnerName") or "?")
		local eatPrompt = makePrompt(anchor, "EatPrompt", "Manger", objectText, EAT_KEY, Enum.KeyCode.ButtonL1)
		local carryPrompt = makePrompt(anchor, "CarryPrompt", "Découper un morceau", objectText, CARRY_KEY, Enum.KeyCode.ButtonR1)
		carryPrompt.UIOffset = Vector2.new(0, 60)
		if isGiant then
			eatPrompt.MaxActivationDistance = 40
			carryPrompt.MaxActivationDistance = 40
		end
		eatPrompt.Triggered:Connect(function(player)
			onEatCarcass(player, carcass, anchor, false)
		end)
		carryPrompt.Triggered:Connect(function(player)
			onEatCarcass(player, carcass, anchor, true)
		end)
		local function refresh()
			local hasFood = carcass:GetAttribute("CarcassFoodType") ~= nil
			eatPrompt.Enabled = hasFood
			carryPrompt.Enabled = hasFood
		end
		carcass:GetAttributeChangedSignal("CarcassFoodType"):Connect(refresh)
		refresh()
	end)
end

-- ============================================================
-- Nids : dépôt de nourriture transportée + nourrissage des larves
-- ============================================================

local function isBaby(player: Player): boolean
	local stage = player:GetAttribute("Stage")
	return stage == "Oeuf" or stage == "Larve" or stage == "Mue" or stage == "Cocon"
end

local function getRootPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

local function nestTick()
	for ownerUserId, nest in pairs(GrowthAndNestService.ActiveNests) do
		for _, player in ipairs(Players:GetPlayers()) do
			if player:GetAttribute("FamilyId") ~= nest.FamilyId then
				continue
			end
			local position = getRootPosition(player)
			if not position or (position - nest.Position).Magnitude > GameConstants.NEST_RADIUS then
				continue
			end
			-- Dépôt de la nourriture transportée.
			local carried = player:GetAttribute("CarriedFood") :: number?
			if carried then
				nest.StoredFood = math.min(nest.StoredFood + carried, 500)
				clearCarried(player)
				ProgressionService.AddEvolutionPoints(player, 5)
				notify(player, string.format("Nourriture déposée au nid (réserve : %d).", nest.StoredFood), "info")
			end
			-- Les bébés de la famille mangent dans la réserve et grandissent plus vite.
			if isBaby(player) then
				local hunger = (player:GetAttribute("Hunger") :: number?) or 0
				local thirst = (player:GetAttribute("Thirst") :: number?) or 0
				if hunger < 75 or thirst < 75 then
					local now = os.clock()
					-- Seules les larves (et mues) profitent du bonus et peuvent rapporter de la nourriture.
					local stage = player:GetAttribute("Stage")
					local canBoost = stage == "Larve" or stage == "Mue"
					if nest.StoredFood >= NEST_FEED_COST then
						nest.StoredFood -= NEST_FEED_COST
						player:SetAttribute("Hunger", math.min(100, hunger + 25))
						player:SetAttribute("Thirst", math.min(100, thirst + 20))
						-- Toast seulement à l'ouverture de la fenêtre (au plus 1 toutes les 30 s).
						local prev = player:GetAttribute("NestFedUntil") :: number?
						if canBoost and (not prev or prev <= now) then
							local who = if nest.IsNpc
								then (if nest.MotherAlive == false then "Le nid" else (nest.DisplayName or "Maman"))
								else "Maman"
							notify(player, who .. " vous nourrit : croissance x1.5 pendant 30 s", "info")
						end
						player:SetAttribute("NestFedUntil", now + 30)
					elseif canBoost and now - (emptyNestNotifiedAt[player] or -math.huge) > 60 then
						emptyNestNotifiedAt[player] = now
						notify(player, "Réserve du nid vide : rapportez de la nourriture", "warning")
					end
				end
			end
			-- Un adulte affamé peut aussi se servir dans la réserve commune (GDD §8.2).
			if not isBaby(player) and nest.StoredFood >= NEST_FEED_COST * 2 then
				local hunger = (player:GetAttribute("Hunger") :: number?) or 0
				if hunger < 30 then
					nest.StoredFood -= NEST_FEED_COST * 2
					player:SetAttribute("Hunger", math.min(100, hunger + 30))
				end
			end
		end
		GrowthAndNestService.RefreshNestDisplay(ownerUserId)
	end
end

-- Nid IA (spawn par défaut, mare) : nourrit lentement les bébés sans famille qui restent près de lui.
local function aiNestTick()
	local nests = CollectionService:GetTagged("AINest")
	for _, player in ipairs(Players:GetPlayers()) do
		if not isBaby(player) or player:GetAttribute("FamilyId") ~= nil then
			continue
		end
		local position = getRootPosition(player)
		if not position then
			continue
		end
		for _, nest in ipairs(nests) do
			if nest:IsA("BasePart") and (nest.Position - position).Magnitude <= GameConstants.NEST_RADIUS then
				local hunger = (player:GetAttribute("Hunger") :: number?) or 0
				local thirst = (player:GetAttribute("Thirst") :: number?) or 0
				if hunger < 60 then
					player:SetAttribute("Hunger", math.min(100, hunger + 12))
				end
				if thirst < 60 then
					player:SetAttribute("Thirst", math.min(100, thirst + 12))
				end
				break
			end
		end
	end
end

function FoodService.Start()
	for _, node in ipairs(CollectionService:GetTagged("FoodNode")) do
		setupFoodNode(node)
	end
	CollectionService:GetInstanceAddedSignal("FoodNode"):Connect(setupFoodNode)

	createPondEdgeSources()
	for _, source in ipairs(CollectionService:GetTagged("DrinkSource")) do
		setupDrinkSource(source)
	end
	CollectionService:GetInstanceAddedSignal("DrinkSource"):Connect(setupDrinkSource)

	for _, carcass in ipairs(CollectionService:GetTagged("Carcass")) do
		setupCarcass(carcass)
	end
	CollectionService:GetInstanceAddedSignal("Carcass"):Connect(setupCarcass)

	Players.PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
		nibbleFxStopAt[player] = nil
		emptyNestNotifiedAt[player] = nil
		local fxPart = nibbleFxParts[player]
		nibbleFxParts[player] = nil
		if fxPart then
			fxPart:Destroy()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(NEST_TICK_SECONDS)
			local ok, err = pcall(nestTick)
			if not ok then
				warn("[FoodService] nestTick : " .. tostring(err))
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(AI_NEST_TICK_SECONDS)
			local ok, err = pcall(aiNestTick)
			if not ok then
				warn("[FoodService] aiNestTick : " .. tostring(err))
			end
		end
	end)
end

FoodService.ClearCarried = clearCarried

-- Repas d'un PNJ (Maman PNJ) sur un noeud "FoodNode" : consomme un usage (rétrécit/repousse comme
-- pour un joueur) et retourne la valeur nutritive, ou nil si le noeud est vide / hors régime.
function FoodService.ConsumeNode(node: BasePart, diet: FoodData.DietType): number?
	if not node.Parent or node:GetAttribute("Depleted") == true then
		return nil
	end
	local foodType = node:GetAttribute("FoodType") :: string?
	local info = foodType and FoodData.Get(foodType)
	if not foodType or not info or not FoodData.CanEat(diet, foodType) then
		return nil
	end
	consumeUse(node)
	return info.NutritionValue
end

return FoodService
