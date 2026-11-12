--!strict
-- InsectVisualService.luau
-- Habille un personnage joueur d'un corps d'insecte procédural (GDD section 8 : "insectes, pas
-- des humains") à la place de l'avatar Roblox par défaut, piloté uniquement par InsectData.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InsectData = require(ReplicatedStorage.shared.InsectData)
local GameConstants = require(ServerScriptService.constant.GameConstants)

local InsectVisualService = {}

local CONTAINER_NAME = "InsectVisual"
local HOOKED_ATTRIBUTE = "InsectVisualHooked"

-- Hauteur approximative (avant bodyScale) du thorax au-dessus du sol : les pattes descendent
-- depuis ce niveau, les ailes montent au-dessus.
local STAND_HEIGHT = 0.5

-- Palettes déterministes par catégorie : pas besoin de couleurs exactes par espèce (GDD).
local PALETTES: { [string]: { Color3 } } = {
	Terrestre = {
		Color3.fromRGB(92, 64, 40),
		Color3.fromRGB(64, 92, 40),
		Color3.fromRGB(110, 80, 50),
	},
	Volant = {
		Color3.fromRGB(230, 200, 40),
		Color3.fromRGB(25, 25, 25),
		Color3.fromRGB(180, 90, 200),
	},
	Aquatique = {
		Color3.fromRGB(30, 80, 85),
		Color3.fromRGB(60, 70, 75),
		Color3.fromRGB(40, 100, 95),
	},
}

-- Hash simple et stable de l'id d'espèce -> index de palette (pas besoin de PRNG, juste déterministe).
local function pickColor(speciesId: string, category: string): Color3
	local palette = PALETTES[category] or PALETTES.Terrestre
	local sum = 0
	for i = 1, #speciesId do
		sum += string.byte(speciesId, i)
	end
	return palette[(sum % #palette) + 1]
end

local function isOwnVisualPart(descendant: Instance): boolean
	return descendant:FindFirstAncestor(CONTAINER_NAME) ~= nil
end

-- Rend invisible/non-solide une part ou un decal de l'avatar par défaut (jamais nos propres parts).
local function hideIfDefaultAvatarPiece(descendant: Instance, rootPart: BasePart)
	if descendant:IsA("BasePart") then
		if descendant ~= rootPart and not isOwnVisualPart(descendant) then
			descendant.Transparency = 1
			descendant.CanCollide = false
		end
	elseif descendant:IsA("Decal") then
		if not isOwnVisualPart(descendant) then
			descendant.Transparency = 1
		end
	end
end

-- Rend invisibles/non-solides toutes les parts de l'avatar par défaut (R6 ou R15) sauf le
-- HumanoidRootPart, qui doit rester intact pour la physique/mouvement.
local function hideDefaultAvatar(character: Model, rootPart: BasePart)
	for _, descendant in ipairs(character:GetDescendants()) do
		hideIfDefaultAvatarPiece(descendant, rootPart)
	end
end

-- Les accessoires (chapeaux, vêtements) du personnage Roblox peuvent se charger APRÈS ce premier
-- passage (CharacterAppearanceLoaded est asynchrone) : on les intercepte au fil de l'eau, une
-- seule fois par personnage (gardé par un attribut, pour rester idempotent si ApplyVisual est
-- rappelé plus tard sur le même Model).
local function hookLateAvatarPieces(character: Model, rootPart: BasePart)
	if character:GetAttribute(HOOKED_ATTRIBUTE) then
		return
	end
	character:SetAttribute(HOOKED_ATTRIBUTE, true)
	character.DescendantAdded:Connect(function(descendant)
		hideIfDefaultAvatarPiece(descendant, rootPart)
	end)
end

-- Décalage vertical (dans l'espace local du HumanoidRootPart) du point le plus bas du personnage,
-- càd le "sol" sous ses pieds. Sans ça, le corps procédural flotte à hauteur du bassin/torse.
local function computeGroundOffsetY(character: Model, root: BasePart): number
	local boundingCFrame, boundingSize = character:GetBoundingBox()
	local groundWorldPosition = (boundingCFrame * CFrame.new(0, -boundingSize.Y / 2, 0)).Position
	return root.CFrame:PointToObjectSpace(groundWorldPosition).Y
end

-- Construit une part du corps, la positionne relativement au HumanoidRootPart, et la soude dessus.
local function attachPart(
	root: BasePart,
	container: Instance,
	name: string,
	size: Vector3,
	localOffset: CFrame,
	shape: Enum.PartType,
	color: Color3,
	transparency: number?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Shape = shape
	part.Color = color
	part.Transparency = transparency or 0
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false -- ne doit jamais perturber les raycasts d'escalade/visée d'un autre système
	part.Massless = true
	part.CFrame = root.CFrame * localOffset -- calculé AVANT le parent/weld pour un offset correct
	part.Parent = container

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part

	return part
end

-- Oeuf : une Part "Ball" force une sphère parfaite (diamètre = plus petite dimension), donc pour
-- un vrai ovale on utilise un Block + SpecialMesh sphérique à l'échelle non-uniforme.
local function buildEgg(root: BasePart, container: Instance, color: Color3, groundY: number)
	local eggColor = color:Lerp(Color3.new(1, 1, 1), 0.55)
	local size = Vector3.new(0.6, 0.85, 0.6)

	local part = Instance.new("Part")
	part.Name = "Egg"
	part.Size = size
	part.Color = eggColor
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.Massless = true
	part.CFrame = root.CFrame * CFrame.new(0, groundY + size.Y / 2, 0)
	part.Parent = container

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

local function buildCocoon(root: BasePart, container: Instance, color: Color3, groundY: number)
	local cocoonColor = color:Lerp(Color3.new(0.9, 0.85, 0.7), 0.6)
	-- Sur une Part Cylinder, la LONGUEUR est toujours Size.X ; Size.Y/Size.Z donnent le diamètre.
	-- On veut la longueur orientée avant/arrière : taille (1.6, 0.9, 0.9) puis rotation 90° en Y.
	local size = Vector3.new(1.6, 0.9, 0.9)
	local offset = CFrame.new(0, groundY + size.Y / 2, 0) * CFrame.Angles(0, math.rad(90), 0)
	attachPart(root, container, "Cocoon", size, offset, Enum.PartType.Cylinder, cocoonColor)
end

-- Tête + thorax + 3 segments d'abdomen, communs à Larve/Mue/Adulte. bodyScale rétrécit tout
-- l'ensemble (Larve/Mue plus petits que l'Adulte) sans dépendre de character:ScaleTo.
local function buildSegments(root: BasePart, container: Instance, color: Color3, bodyScale: number, groundY: number)
	local baseY = groundY + STAND_HEIGHT * bodyScale

	attachPart(
		root,
		container,
		"Head",
		Vector3.new(0.9, 0.9, 0.9) * bodyScale,
		CFrame.new(0, baseY + 0.25 * bodyScale, -1.2 * bodyScale),
		Enum.PartType.Ball,
		color
	)
	attachPart(
		root,
		container,
		"Thorax",
		Vector3.new(1.3, 1.0, 1.1) * bodyScale,
		CFrame.new(0, baseY + 0.15 * bodyScale, -0.3 * bodyScale),
		Enum.PartType.Block,
		color
	)

	local abdomenSizes = { Vector3.new(1.2, 0.95, 1.1), Vector3.new(1.0, 0.85, 1.0), Vector3.new(0.75, 0.7, 0.85) }
	local abdomenZ = { 0.55, 1.05, 1.5 }
	for i, size in ipairs(abdomenSizes) do
		attachPart(
			root,
			container,
			"Abdomen" .. i,
			size * bodyScale,
			CFrame.new(0, baseY + (0.05 - i * 0.03) * bodyScale, abdomenZ[i] * bodyScale),
			Enum.PartType.Block,
			color
		)
	end
end

-- 6 pattes statiques (3 par côté), pas d'IK pour cette première passe. Sur une Part Cylinder la
-- longueur est Size.X : la patte doit donc être longue en X, fine en Y/Z, puis inclinée vers le
-- bas et vers l'extérieur (le signe de la rotation est inversé par côté pour un effet miroir).
local function buildLegs(root: BasePart, container: Instance, color: Color3, bodyScale: number, groundY: number)
	local hipY = groundY + (STAND_HEIGHT - 0.1) * bodyScale
	local legZ = { -0.3, 0.2, 0.65 }
	for i, z in ipairs(legZ) do
		for _, side in ipairs({ -1, 1 }) do
			local legName = string.format("Leg_%s_%d", if side < 0 then "L" else "R", i)
			local offset = CFrame.new(side * 0.75 * bodyScale, hipY, z * bodyScale)
				* CFrame.Angles(0, 0, -side * math.rad(45))
			attachPart(root, container, legName, Vector3.new(1.0, 0.18, 0.18) * bodyScale, offset, Enum.PartType.Cylinder, color)
		end
	end
end

-- 4 ailes fines (2 paires), seulement pour les espèces CanFly au stade Adulte.
local function buildWings(root: BasePart, container: Instance, color: Color3, bodyScale: number, groundY: number)
	local wingColor = color:Lerp(Color3.new(1, 1, 1), 0.3)
	local wingY = groundY + (STAND_HEIGHT + 0.55) * bodyScale
	local wingZ = { -0.25, 0.35 }
	for i, z in ipairs(wingZ) do
		for _, side in ipairs({ -1, 1 }) do
			local wingName = string.format("Wing_%s_%d", if side < 0 then "L" else "R", i)
			local offset = CFrame.new(side * 0.55 * bodyScale, wingY, z * bodyScale)
				* CFrame.Angles(0, side * math.rad(20), 0)
			attachPart(
				root,
				container,
				wingName,
				Vector3.new(1.4, 0.05, 0.7) * bodyScale,
				offset,
				Enum.PartType.Block,
				wingColor,
				0.35
			)
		end
	end
end

function InsectVisualService.ApplyVisual(character: Model, speciesId: string, stage: string)
	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	local root = rootPart :: BasePart

	local existing = character:FindFirstChild(CONTAINER_NAME)
	if existing then
		existing:Destroy()
	end

	hideDefaultAvatar(character, root)
	hookLateAvatarPieces(character, root)

	local species = InsectData[speciesId] or InsectData[GameConstants.DEFAULT_SPECIES]
	local color = pickColor(speciesId, species.Category)
	local groundY = computeGroundOffsetY(character, root)

	local container = Instance.new("Model")
	container.Name = CONTAINER_NAME
	container.Parent = character

	if stage == "Oeuf" then
		buildEgg(root, container, color, groundY)
	elseif stage == "Cocon" then
		buildCocoon(root, container, color, groundY)
	elseif stage == "Adulte" then
		buildSegments(root, container, color, 1.0, groundY)
		buildLegs(root, container, color, 1.0, groundY)
		if species.CanFly then
			buildWings(root, container, color, 1.0, groundY)
		end
	else
		-- "Larve" et "Mue" : corps seul, sans pattes ni ailes, à échelle réduite.
		buildSegments(root, container, color, 0.55, groundY)
	end
end

return InsectVisualService
