--!strict
-- CarcassService.luau
-- Système de carcasse & pourrissement (GDD section 7.B) : 4 étapes de décomposition partagées
-- par les insectes-joueurs ET les 5 animaux géants.
--
-- Contrat utilisé par PlayerLifecycleService et par l'IA des animaux (Phase C) :
--   CarcassService.SpawnCarcassFor(position, ownerName, isGiantAnimal, sizeScale, visualTemplate?)
-- visualTemplate est un Model optionnel (le cadavre "propre" déjà positionné, ex: le modèle
-- d'insecte procédural ou le modèle de l'animal) ; si absent, un simple bloc coloré est utilisé.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.shared.Remotes)

local CarcassService = {}

-- Durées en secondes, alignées sur le GDD (0-3min / 3-8min / 8-12min / 12min+).
local FRESH_SECONDS = 180
local PUTREFACTION_SECONDS = 300 -- cumulés: 180+300 = 8 min
local ADVANCED_SECONDS = 240 -- cumulés: 8min+240 = 12 min
local SKELETON_LIFETIME_SECONDS = 360 -- reste comme abri ~6 min de plus avant de s'effriter

local carcassesFolder: Folder? = nil

local function getCarcassesFolder(): Folder
	if carcassesFolder and carcassesFolder.Parent then
		return carcassesFolder
	end
	local folder = workspace:FindFirstChild("Carcasses")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Carcasses"
		folder.Parent = workspace
	end
	carcassesFolder = folder :: Folder
	return carcassesFolder :: Folder
end

local function buildFallbackVisual(ownerName: string, sizeScale: number): Model
	local model = Instance.new("Model")
	model.Name = "Carcasse_" .. ownerName

	local body = Instance.new("Part")
	body.Name = "CarcassBody"
	body.Size = Vector3.new(3, 1.4, 5) * math.clamp(sizeScale, 0.3, 12)
	body.Anchored = true
	body.CanCollide = true
	body.Material = Enum.Material.Mud
	body.Color = Color3.fromRGB(96, 74, 58)
	body.Parent = model

	model.PrimaryPart = body
	return model
end

local function spawnMushroomsAround(position: Vector3, count: number)
	local foliage = getCarcassesFolder()
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)

		local mushroom = Instance.new("Part")
		mushroom.Name = "FoodNode_Champignon"
		mushroom.Shape = Enum.PartType.Cylinder
		mushroom.Size = Vector3.new(0.6, 0.8, 0.8)
		mushroom.CFrame = CFrame.new(position + offset) * CFrame.Angles(0, 0, math.rad(90))
		mushroom.Anchored = true
		mushroom.CanCollide = false
		mushroom.Material = Enum.Material.Neon
		mushroom.Color = Color3.fromRGB(200, 120, 90)
		mushroom.Parent = foliage

		mushroom:SetAttribute("FoodType", "Champignon")
		CollectionService:AddTag(mushroom, "FoodNode")
		Debris:AddItem(mushroom, ADVANCED_SECONDS + SKELETON_LIFETIME_SECONDS)
	end
end

local function addOdorCloud(parent: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Name = "OdorAttachment"
	attachment.Parent = parent

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "OdorParticles"
	emitter.Color = ColorSequence.new(Color3.fromRGB(120, 200, 90))
	emitter.Lifetime = NumberRange.new(2, 3)
	emitter.Rate = 6
	emitter.Speed = NumberRange.new(1, 2)
	emitter.Size = NumberSequence.new(1.2)
	emitter.Transparency = NumberSequence.new(0.4, 1)
	emitter.Parent = attachment
end

function CarcassService.SpawnCarcassFor(
	position: Vector3,
	ownerName: string,
	isGiantAnimal: boolean,
	sizeScale: number?,
	visualTemplate: Model?
): Model
	local scale = sizeScale or 1

	local model: Model
	if visualTemplate then
		model = visualTemplate
		model.Name = "Carcasse_" .. ownerName
	else
		model = buildFallbackVisual(ownerName, scale)
	end

	model:SetAttribute("OwnerName", ownerName)
	model:SetAttribute("IsGiantAnimal", isGiantAnimal)
	model:SetAttribute("Stage", "Frais")
	model:SetAttribute("SpawnedAt", os.clock())
	model:SetAttribute("CarcassFoodType", "CarcasseFraiche")
	CollectionService:AddTag(model, "Carcass")

	model.Parent = getCarcassesFolder()
	if not model.PrimaryPart then
		local anyPart = model:FindFirstChildWhichIsA("BasePart")
		if anyPart then
			model.PrimaryPart = anyPart
		end
	end
	if model.PrimaryPart then
		model.PrimaryPart.CFrame = CFrame.new(position)
	end

	if isGiantAnimal then
		local kaijuEvent = Remotes.Get("KaijuFeastEvent")
		kaijuEvent:FireAllClients(ownerName, position)
	end

	task.delay(FRESH_SECONDS, function()
		if not model.Parent then
			return
		end
		model:SetAttribute("Stage", "Putrefaction")
		model:SetAttribute("CarcassFoodType", "CarcassePutride")
		if model.PrimaryPart then
			addOdorCloud(model.PrimaryPart)
		end
	end)

	task.delay(FRESH_SECONDS + PUTREFACTION_SECONDS, function()
		if not model.Parent then
			return
		end
		model:SetAttribute("Stage", "Pourrissement")
		model:SetAttribute("CarcassFoodType", nil)
		spawnMushroomsAround(position, if isGiantAnimal then 5 else 2)
	end)

	task.delay(FRESH_SECONDS + PUTREFACTION_SECONDS + ADVANCED_SECONDS, function()
		if not model.Parent then
			return
		end
		model:SetAttribute("Stage", "Squelette")
		CollectionService:AddTag(model, "Shelter")
		if model.PrimaryPart then
			model.PrimaryPart.Color = Color3.fromRGB(225, 220, 205)
			model.PrimaryPart.Material = Enum.Material.Limestone
		end
	end)

	task.delay(FRESH_SECONDS + PUTREFACTION_SECONDS + ADVANCED_SECONDS + SKELETON_LIFETIME_SECONDS, function()
		if model.Parent then
			model:Destroy()
		end
	end)

	return model
end

return CarcassService
