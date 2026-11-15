--!strict
-- AnimalModels.luau
-- Modèles 3D procéduraux des 5 animaux géants (GDD §6) + alevins + nids/hottes, à l'échelle
-- "kaiju" (un insecte adulte fait ~3.5 studs, un oiseau ~30).
--
-- Chaque modèle : une PrimaryPart "Root" ancrée et invisible (c'est elle que l'IA déplace via
-- PivotTo), toutes les autres parts soudées dessus (non ancrées, sans collision, sans requête),
-- une part nommée "Head" (affichage nom/vie du Humanoid) et un Humanoid pour la vie.
-- Repère : -Z = avant (tête), Y = haut.
--
-- CONVENTION D'ANIMATION (pour le code qui anime, côté client de préférence) :
--   * Les parts statiques sont soudées par WeldConstraint (enfant de la part).
--   * Les parts animables sont soudées par un Weld nommé "AnimWeld", ENFANT DE "Root"
--     (Part0 = Root, Part1 = la part). Toutes les parts d'un même membre partagent le même
--     pivot : weld.C0 = pivot du membre dans le repère de Root (rotation identité, donc axes =
--     axes de Root), weld.C1 = ce même pivot dans le repère de la part.
--     => pour animer un membre entier : weld.C0 = RestC0 * CFrame.Angles(...) sur chacun de ses
--     welds ; la rotation se fait autour de l'articulation (épaule, hanche, base de queue...).
--   * Attributs posés sur chaque part animable :
--       "Anim"   : "Wing" | "Leg" | "Tail" | "Fin" | "Claw" | "Head" | "Eye"
--       "Side"   : -1 (gauche, -X) | 1 (droite, +X) | 0 (membre central)
--       "Index"  : numéro du membre dans sa catégorie (voir chaque animal)
--       "RestC0" : CFrame de repos du weld (= pivot)
--     Membre porté par un autre (oeil du caméléon sur la tête, doigt mobile de la pince sur le
--     bras) : en plus "ParentAnim", "ParentSide", "ParentIndex". Il n'y a PAS de hiérarchie de
--     welds : pour qu'il suive son parent, composer
--       C0 = parentRest * parentDelta * parentRest:Inverse() * RestC0 * delta.

local AnimalModels = {}

type Group = {
	Kind: string,
	Side: number,
	Index: number,
	Pivot: CFrame,
	Parent: Group?,
}

type Builder = {
	Model: Model,
	Root: Part,
	Group: Group?, -- membre animable en cours de construction (nil = parts statiques)
}

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local EYE_BLACK = Color3.fromRGB(15, 15, 15)
local SIDES = { -1, 1 }

local function shade(color: Color3, amount: number): Color3
	return color:Lerp(BLACK, amount)
end

local function tint(color: Color3, amount: number): Color3
	return color:Lerp(WHITE, amount)
end

local function newBuilder(name: string, rootSize: Vector3): Builder
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = rootSize
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.CFrame = CFrame.identity
	root.Parent = model
	model.PrimaryPart = root
	return { Model = model, Root = root }
end

local function newGroup(kind: string, side: number, index: number, pivot: Vector3, parent: Group?): Group
	return { Kind = kind, Side = side, Index = index, Pivot = CFrame.new(pivot), Parent = parent }
end

-- La Root est à l'identité pendant la construction : part.CFrame est donc déjà exprimé dans le
-- repère de la Root.
local function weldTo(b: Builder, part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = b.Model
	local group = b.Group
	if group then
		part:SetAttribute("Anim", group.Kind)
		part:SetAttribute("Side", group.Side)
		part:SetAttribute("Index", group.Index)
		part:SetAttribute("RestC0", group.Pivot)
		local parent = group.Parent
		if parent then
			part:SetAttribute("ParentAnim", parent.Kind)
			part:SetAttribute("ParentSide", parent.Side)
			part:SetAttribute("ParentIndex", parent.Index)
		end
		local weld = Instance.new("Weld")
		weld.Name = "AnimWeld"
		weld.Part0 = b.Root
		weld.Part1 = part
		weld.C0 = group.Pivot
		weld.C1 = part.CFrame:Inverse() * group.Pivot
		-- Sous la Root (pas sous la part) : la carcasse clone les parts sans embarquer de weld.
		weld.Parent = b.Root
	else
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = b.Root
		weld.Part1 = part
		weld.Parent = part
	end
end

local function ellipsoid(b: Builder, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	weldTo(b, part)
	return part
end

local function block(b: Builder, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	weldTo(b, part)
	return part
end

-- Cylindre entre deux points (axe X d'un cylindre Roblox -> tourné sur la direction a->b).
local function limb(b: Builder, name: string, a: Vector3, c: Vector3, diameter: number, color: Color3, material: Enum.Material?): Part?
	local delta = c - a
	if delta.Magnitude < 0.05 then
		return nil
	end
	local up = if math.abs(delta.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(delta.Magnitude, diameter, diameter)
	part.CFrame = CFrame.lookAt(a:Lerp(c, 0.5), c, up) * CFrame.Angles(0, math.rad(90), 0)
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	weldTo(b, part)
	return part
end

-- CFrame au milieu de a->c, axe Z le long du segment, axe Y au plus près de "up".
local function along(a: Vector3, c: Vector3, up: Vector3?): CFrame
	local direction = (c - a).Unit
	local upVector = up or Vector3.yAxis
	if math.abs(direction:Dot(upVector)) > 0.98 then
		upVector = if math.abs(direction.Z) > 0.9 then Vector3.xAxis else Vector3.zAxis
	end
	return CFrame.lookAt(a:Lerp(c, 0.5), c, upVector)
end

-- Fuseau (ellipsoïde étiré) de a vers c : plume, épine, griffe, mèche de poils, rayon de
-- nageoire... "thick" est l'épaisseur le long de "up", "width" la largeur perpendiculaire.
local function strand(b: Builder, name: string, a: Vector3, c: Vector3, width: number, thick: number, color: Color3, material: Enum.Material?, up: Vector3?): Part
	return ellipsoid(b, name, Vector3.new(width, thick, (c - a).Magnitude), along(a, c, up), color, material)
end

-- Point et normale sortante d'un ellipsoïde (centre, demi-axes) dans une direction donnée.
local function onSurface(center: Vector3, radii: Vector3, direction: Vector3): (Vector3, Vector3)
	local unit = direction.Unit
	return center + unit * radii, (unit / radii).Unit
end

-- CFrame posé sur un point, axe Z le long de la normale.
local function facing(point: Vector3, normal: Vector3): CFrame
	local up = if math.abs(normal.Y) > 0.98 then Vector3.zAxis else Vector3.yAxis
	return CFrame.lookAt(point, point + normal, up)
end

-- Relief (écaille, tubercule) plaqué sur un ellipsoïde ; size.Z = épaisseur le long de la normale.
local function bump(b: Builder, name: string, center: Vector3, radii: Vector3, direction: Vector3, size: Vector3, color: Color3): Part
	local point, normal = onSurface(center, radii, direction)
	return ellipsoid(b, name, size, facing(point, normal), color)
end

local function eye(b: Builder, position: Vector3, radius: number, irisColor: Color3?)
	ellipsoid(b, "Eye", Vector3.one * radius * 2, CFrame.new(position), EYE_BLACK)
	ellipsoid(b, "EyeShine", Vector3.one * radius * 0.6, CFrame.new(position + Vector3.new(0, radius * 0.4, -radius * 0.7)), irisColor or WHITE)
end

-- Oeil latéral posé sur la surface d'une tête ellipsoïdale, cerclé d'un anneau clair.
local function ringedEye(b: Builder, center: Vector3, radii: Vector3, direction: Vector3, radius: number, ringColor: Color3)
	local point, normal = onSurface(center, radii, direction)
	ellipsoid(b, "EyeRing", Vector3.new(radius * 2.7, radius * 2.7, radius * 0.5), facing(point, normal), ringColor)
	local position = point + normal * radius * 0.2
	ellipsoid(b, "Eye", Vector3.one * radius * 2, CFrame.new(position), EYE_BLACK)
	ellipsoid(b, "EyeShine", Vector3.one * radius * 0.6, CFrame.new(position + normal * radius * 0.6 + Vector3.new(0, radius * 0.4, -radius * 0.4)), WHITE)
end

local function addHumanoid(b: Builder, maxHealth: number, displayName: string)
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayName = displayName
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = 160
	humanoid.HealthDisplayDistance = 160
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.Parent = b.Model
end

-- ============================================================
-- 1. Oiseau (Rouge-Gorge)
-- Membres : Head(0,1) | Wing(±1,1) | Tail(0,1) | Leg(±1,1). Pattes 11 studs sous la Root.
-- ============================================================
function AnimalModels.BuildBird(maxHealth: number): Model
	local b = newBuilder("Oiseau", Vector3.new(6, 6, 6))
	local brown = Color3.fromRGB(120, 90, 60)
	local olive = Color3.fromRGB(104, 84, 52)
	local belly = Color3.fromRGB(235, 230, 220)
	local breastTop = Color3.fromRGB(212, 82, 34)
	local breastMid = Color3.fromRGB(234, 116, 46)
	local breastLow = Color3.fromRGB(244, 160, 92)
	local grey = Color3.fromRGB(150, 155, 160)
	local beak = Color3.fromRGB(58, 48, 40)
	local skin = Color3.fromRGB(150, 105, 85)
	local claw = Color3.fromRGB(40, 32, 28)
	local wingDark = shade(brown, 0.2)
	local wingDarker = shade(brown, 0.38)

	-- Corps : dos brun-olive, plastron en dégradé rouge-orangé -> orange -> pêche -> ventre blanc.
	ellipsoid(b, "Body", Vector3.new(14, 13, 22), CFrame.new(0, 0, 0), brown)
	ellipsoid(b, "Mantle", Vector3.new(11, 5, 18), CFrame.new(0, 4.2, 1.5), olive)
	ellipsoid(b, "Breast", Vector3.new(12.4, 10.5, 11.5), CFrame.new(0, -0.8, -5.4), breastTop)
	ellipsoid(b, "BreastMid", Vector3.new(11.4, 8.5, 10.5), CFrame.new(0, -2.7, -5.2), breastMid)
	ellipsoid(b, "BreastLow", Vector3.new(10.2, 7, 10), CFrame.new(0, -4.4, -4.6), breastLow)
	ellipsoid(b, "Belly", Vector3.new(10, 8, 12), CFrame.new(0, -4, 1.5), belly)
	ellipsoid(b, "Undertail", Vector3.new(6, 4, 8), CFrame.new(0, -2.2, 8.5), belly)

	-- Tête : calotte sombre, face rouge-orangé, bec fin, oeil cerclé.
	local headCenter = Vector3.new(0, 5, -10)
	local headRadii = Vector3.new(5, 5, 5)
	b.Group = newGroup("Head", 0, 1, Vector3.new(0, 2.5, -7.5))
	ellipsoid(b, "Head", Vector3.new(10, 10, 10), CFrame.new(headCenter), brown)
	ellipsoid(b, "Cap", Vector3.new(8.8, 4.5, 9), CFrame.new(0, 8, -9.4), olive)
	ellipsoid(b, "Face", Vector3.new(8.6, 7.2, 6.4), CFrame.new(0, 3.6, -12.4), breastTop)
	ellipsoid(b, "Throat", Vector3.new(7.6, 5.5, 6.5), CFrame.new(0, 1.4, -10.6), breastTop)
	ellipsoid(b, "BeakTop", Vector3.new(2.2, 1.5, 6.6), CFrame.new(0, 4.7, -16.1) * CFrame.Angles(math.rad(-6), 0, 0), beak)
	ellipsoid(b, "BeakBottom", Vector3.new(1.9, 1.1, 5.4), CFrame.new(0, 3.8, -15.7), tint(beak, 0.12))
	for _, side in ipairs(SIDES) do
		ringedEye(b, headCenter, headRadii, Vector3.new(side * 4.2, 1.2, -2.5), 1.2, Color3.fromRGB(205, 190, 165))
	end

	for _, side in ipairs(SIDES) do
		b.Group = nil
		-- Liseré gris-bleu entre le plastron et le brun.
		ellipsoid(b, "FlankBand", Vector3.new(1.2, 5, 9), CFrame.new(side * 5.9, -2.6, -3.5), grey)

		-- Aile repliée : base + couvertures + rémiges superposées vers l'arrière.
		b.Group = newGroup("Wing", side, 1, Vector3.new(side * 6, 3.5, -4))
		ellipsoid(b, "Wing", Vector3.new(2, 8.5, 12), CFrame.new(side * 6.3, 1.6, -0.5) * CFrame.Angles(0, 0, side * math.rad(-10)), wingDark)
		for i = 1, 6 do
			local t = (i - 1) / 5
			local base = Vector3.new(side * (7.7 - 0.2 * t), 4.2 - 5.2 * t, -2 + 2 * t)
			local tip = Vector3.new(side * (7 - 1.8 * t), 3.6 - 2.8 * t, 8 + 8 * t)
			strand(b, "Feather", base, tip, 3, 0.5, if i % 2 == 0 then wingDark else wingDarker, nil, Vector3.xAxis)
		end
		for j = 1, 4 do
			local base = Vector3.new(side * 7.5, 3.6 - 1.4 * (j - 1), -3.5)
			local tip = Vector3.new(side * 7.7, 3.2 - 1.3 * (j - 1), 3)
			strand(b, "Covert", base, tip, 2.6, 0.5, if j % 2 == 0 then brown else olive, nil, Vector3.xAxis)
		end

		-- Patte : cuisse emplumée, tarse écailleux, 3 doigts avant + 1 arrière, griffes.
		b.Group = newGroup("Leg", side, 1, Vector3.new(side * 3, -5, 1))
		ellipsoid(b, "Thigh", Vector3.new(3.6, 4.6, 4), CFrame.new(side * 3, -5.6, 1), belly)
		local knee = Vector3.new(side * 3, -6.2, 1)
		local foot = Vector3.new(side * 3, -10.6, 0.2)
		local legAxis = (foot - knee).Unit
		limb(b, "Leg", knee, foot, 0.8, skin)
		for ring = 1, 3 do
			local point = knee:Lerp(foot, 0.3 + ring * 0.2)
			limb(b, "LegScale", point, point + legAxis * 0.3, 1.05, shade(skin, 0.2))
		end
		for toe = -1, 1 do
			local toeEnd = foot + Vector3.new(toe * 1.6, -0.1, -2.8)
			limb(b, "Toe", foot, toeEnd, 0.55, skin)
			strand(b, "Claw", toeEnd, toeEnd + Vector3.new(toe * 0.3, -0.1, -1.1), 0.4, 0.4, claw)
		end
		local backToe = foot + Vector3.new(0, -0.1, 2.2)
		limb(b, "Toe", foot, backToe, 0.55, skin)
		strand(b, "Claw", backToe, backToe + Vector3.new(0, -0.1, 0.9), 0.4, 0.4, claw)
	end

	-- Queue : croupion + 7 rectrices en éventail.
	b.Group = newGroup("Tail", 0, 1, Vector3.new(0, 2, 10))
	ellipsoid(b, "Rump", Vector3.new(6.5, 5, 8), CFrame.new(0, 1.8, 10), brown)
	for k = -3, 3 do
		local a = math.abs(k)
		local layer = (3 - a) * 0.15 -- les plumes centrales passent au-dessus
		strand(b, "TailFeather", Vector3.new(k * 0.5, 2.2 + layer, 10), Vector3.new(k * 1.8, 4.8 - a * 0.3 + layer, 22 - a * 0.7), 2.4, 0.4, if a % 2 == 0 then wingDarker else wingDark)
	end
	b.Group = nil

	addHumanoid(b, maxHealth, "Rouge-Gorge")
	return b.Model
end

-- ============================================================
-- 2. Caméléon
-- Membres : Head(0,1) | Eye(±1,1, parent Head) | Leg(±1, 1 = avant / 2 = arrière) | Tail(0,1).
-- Bouche en (0,0,-16), pattes ~8.5 studs sous la Root.
-- ============================================================
function AnimalModels.BuildChameleon(maxHealth: number): Model
	local b = newBuilder("Cameleon", Vector3.new(6, 6, 6))
	local green = Color3.fromRGB(90, 170, 70)
	local darker = Color3.fromRGB(60, 120, 50)
	local pale = Color3.fromRGB(160, 200, 110)
	local yellow = Color3.fromRGB(190, 205, 90)
	local clawColor = Color3.fromRGB(60, 70, 45)
	local bodyRadii = Vector3.new(4, 5.5, 10)

	ellipsoid(b, "Body", Vector3.new(8, 11, 20), CFrame.new(0, 0, 0), green)
	ellipsoid(b, "Belly", Vector3.new(6.2, 6, 17), CFrame.new(0, -2.9, 0), pale)
	-- Crête dorsale : plaques pointues de la nuque à la base de la queue.
	for i = 0, 10 do
		local z = -8 + i * 1.65
		local top = 5.5 * math.sqrt(1 - (z / 10) ^ 2)
		strand(b, "Spike", Vector3.new(0, top - 0.5, z), Vector3.new(0, top + 2.6 - i * 0.1, z + 0.7), 0.8, 1.7, darker, nil, -Vector3.zAxis)
	end
	-- Écailles granuleuses : 3 rangées par flanc, teintes alternées.
	for _, side in ipairs(SIDES) do
		for row = 1, 3 do
			local elevation = math.rad(38 - (row - 1) * 34)
			for col = 1, 5 do
				local u = -0.62 + (col - 1) * 0.3 + (row % 2) * 0.08
				local ring = math.sqrt(1 - u * u)
				local direction = Vector3.new(side * math.cos(elevation) * ring, math.sin(elevation) * ring, u)
				bump(b, "Scale", Vector3.zero, bodyRadii, direction, Vector3.new(1.5, 1.5, 0.6), if (row + col) % 2 == 0 then yellow else darker)
			end
		end
	end

	-- Tête : museau, mâchoire claire, casque incliné vers l'arrière, arcades, épines gulaires.
	local head = newGroup("Head", 0, 1, Vector3.new(0, 1, -8.5))
	b.Group = head
	ellipsoid(b, "Head", Vector3.new(7, 8, 9), CFrame.new(0, 1.5, -12), green)
	ellipsoid(b, "Snout", Vector3.new(5, 4.4, 6), CFrame.new(0, 1.2, -14.6), green)
	ellipsoid(b, "Jaw", Vector3.new(6, 3, 6.6), CFrame.new(0, -1.5, -13.9), pale)
	local casqueCFrame = CFrame.new(0, 5.4, -9.8) * CFrame.Angles(math.rad(25), 0, 0)
	ellipsoid(b, "Casque", Vector3.new(3.4, 7, 7.5), casqueCFrame, green)
	ellipsoid(b, "CasqueRidge", Vector3.new(1, 7.8, 8.3), casqueCFrame, darker)
	for i = 0, 3 do
		local z = -16 + i * 1.5
		strand(b, "Spike", Vector3.new(0, -2.4, z), Vector3.new(0, -3.9, z + 0.4), 0.6, 1.1, darker, nil, -Vector3.zAxis)
	end
	for _, side in ipairs(SIDES) do
		b.Group = head
		strand(b, "Brow", Vector3.new(side * 2.2, 4.6, -10.5), Vector3.new(side * 1.3, 2.6, -17), 1.1, 1.1, darker)
		-- Oeil en tourelle : pivote indépendamment autour de son centre.
		local eyeCenter = Vector3.new(side * 3.5, 3, -13.4)
		local outward = Vector3.new(side * 0.92, 0.05, -0.38).Unit
		b.Group = newGroup("Eye", side, 1, eyeCenter, head)
		ellipsoid(b, "EyeTurret", Vector3.one * 3.6, CFrame.new(eyeCenter), green)
		ellipsoid(b, "EyeLid", Vector3.one * 2.3, CFrame.new(eyeCenter + outward), darker)
		ellipsoid(b, "Pupil", Vector3.one * 1.1, CFrame.new(eyeCenter + outward * 1.75), EYE_BLACK)
		ellipsoid(b, "EyeShine", Vector3.one * 0.35, CFrame.new(eyeCenter + outward * 2.15 + Vector3.new(0, 0.25, 0)), WHITE)

		-- 4 pattes à pieds zygodactyles (deux faisceaux de doigts opposés en pince).
		for index, z in ipairs({ -6, 6 }) do
			local shoulder = Vector3.new(side * 3.3, -2, z)
			local elbow = Vector3.new(side * 6.5, -3.6, z - 1)
			local hand = Vector3.new(side * 6, -7.5, z - 2)
			b.Group = newGroup("Leg", side, index, shoulder)
			ellipsoid(b, "Shoulder", Vector3.one * 2.6, CFrame.new(shoulder), green)
			limb(b, "Leg", shoulder, elbow, 1.8, green)
			ellipsoid(b, "Elbow", Vector3.one * 2, CFrame.new(elbow), green)
			limb(b, "Leg", elbow, hand, 1.5, green)
			for _, grip in ipairs(SIDES) do
				local padEnd = hand + Vector3.new(grip * 1.5, -0.5, -0.5)
				strand(b, "Toe", hand - Vector3.new(grip * 0.4, 0, 0), padEnd, 1.3, 1.1, darker)
				strand(b, "Claw", padEnd, padEnd + Vector3.new(-grip * 0.3, -0.7, -0.2), 0.4, 0.4, clawColor)
			end
		end
	end

	-- Queue préhensile enroulée en spirale (segments + rotules pour un enroulement lisse).
	b.Group = newGroup("Tail", 0, 1, Vector3.new(0, -1, 9.5))
	local previous = Vector3.new(0, -1, 9)
	for i = 1, 12 do
		local angle = i * 0.55
		local radius = 5 - i * 0.3
		local point = Vector3.new(0, -2 - math.sin(angle) * radius, 13 + math.cos(angle) * radius * 0.8 + i * 0.4)
		local thickness = math.max(0.8, 2.8 - i * 0.16)
		local color = if i % 3 == 0 then darker else green
		limb(b, "Tail", previous, point, thickness, color)
		ellipsoid(b, "TailJoint", Vector3.one * thickness, CFrame.new(point), color)
		previous = point
	end
	b.Group = nil

	-- Ancrage de la langue (l'IA crée une part ancrée qui s'étire depuis ce point).
	local mouth = Instance.new("Attachment")
	mouth.Name = "MouthAttachment"
	mouth.Position = Vector3.new(0, 0, -16)
	mouth.Parent = b.Root

	addHumanoid(b, maxHealth, "Caméléon")
	return b.Model
end

-- ============================================================
-- 3. Poisson Rouge + alevins
-- Membres : Head(0,1) | Tail(0,1) | Fin(±1,1) pectorales | Fin(±1,2) pelviennes |
-- Fin(0,3) dorsale | Fin(0,4) anale. L'alevin (scale < 0.5) n'a que Head, Tail, Fin 1 et 3
-- (~10 parts : ils sont nombreux).
-- ============================================================
function AnimalModels.BuildGoldfish(maxHealth: number, scale: number, displayName: string): Model
	local isFry = scale < 0.5
	local b = newBuilder(if isFry then "Alevin" else "PoissonRouge", Vector3.new(4, 4, 4) * math.max(scale, 0.25))
	local orange = if isFry then Color3.fromRGB(200, 150, 90) else Color3.fromRGB(245, 120, 30)
	local finColor = tint(orange, 0.3)
	local s = scale
	local bodyRadii = Vector3.new(3.5, 5.5, 10) * s

	local function P(x: number, y: number, z: number): Vector3
		return Vector3.new(x, y, z) * s
	end
	-- Rayon de nageoire : voile translucide, mince latéralement.
	local function fin(name: string, a: Vector3, c: Vector3, width: number)
		local part = strand(b, name, a, c, width * s, 0.4 * s, finColor, nil, Vector3.xAxis)
		part.Transparency = 0.3
	end

	ellipsoid(b, "Body", Vector3.new(7, 11, 20) * s, CFrame.new(0, 0, 0), orange)
	if not isFry then
		ellipsoid(b, "Belly", Vector3.new(5.8, 6, 16) * s, CFrame.new(P(0, -3, -0.5)), Color3.fromRGB(250, 215, 160))
		ellipsoid(b, "Back", Vector3.new(4.5, 4, 17) * s, CFrame.new(P(0, 4.2, 0)), Color3.fromRGB(215, 80, 20))
		-- Rangées d'écailles à reflets dorés sur les flancs.
		local gold = orange:Lerp(Color3.fromRGB(255, 200, 80), 0.5)
		local deep = shade(orange, 0.12)
		for _, side in ipairs(SIDES) do
			for row = 1, 3 do
				local elevation = math.rad(32 - (row - 1) * 30)
				for col = 1, 6 do
					local u = -0.3 + (col - 1) * 0.2 + (row % 2) * 0.1
					local ring = math.sqrt(1 - u * u)
					local direction = Vector3.new(side * math.cos(elevation) * ring, math.sin(elevation) * ring, u)
					local part = bump(b, "Scale", Vector3.zero, bodyRadii, direction, Vector3.new(2.4, 2.4, 0.5) * s, if (row + col) % 2 == 0 then gold else deep)
					part.Reflectance = 0.12
				end
			end
		end
	end

	-- Tête.
	local headCenter = P(0, 0.3, -8)
	b.Group = newGroup("Head", 0, 1, P(0, 0, -6))
	ellipsoid(b, "Head", Vector3.new(6.4, 8.5, 7) * s, CFrame.new(headCenter), orange)
	local lipColor = Color3.fromRGB(190, 80, 40)
	if isFry then
		ellipsoid(b, "Mouth", Vector3.new(2.4, 2, 1.4) * s, CFrame.new(P(0, -0.6, -11.3)), lipColor)
		for _, side in ipairs(SIDES) do
			ellipsoid(b, "Eye", Vector3.one * 2.6 * s, CFrame.new(P(side * 2.6, 1.8, -9)), EYE_BLACK)
		end
	else
		ellipsoid(b, "Mouth", Vector3.new(2.6, 1.2, 1.6) * s, CFrame.new(P(0, -0.2, -11.2)), lipColor)
		ellipsoid(b, "Lip", Vector3.new(2.3, 1.1, 1.4) * s, CFrame.new(P(0, -1.1, -11)), lipColor)
		local barbel = tint(orange, 0.4)
		for _, side in ipairs(SIDES) do
			ringedEye(b, headCenter, Vector3.new(3.2, 4.25, 3.5) * s, Vector3.new(side * 3, 1.5, -1), 1.3 * s, Color3.fromRGB(255, 220, 120))
			-- Opercule + ouïe.
			ellipsoid(b, "GillPlate", Vector3.new(0.8, 6.2, 4.6) * s, CFrame.new(P(side * 2.75, -0.2, -6.2)), shade(orange, 0.12))
			ellipsoid(b, "GillSlit", Vector3.new(0.5, 5.6, 0.9) * s, CFrame.new(P(side * 3.1, -0.2, -4.2)), Color3.fromRGB(150, 50, 30))
			-- Barbillons.
			limb(b, "Barbel", P(side * 1.1, -1.3, -10.9), P(side * 2, -3.6, -11.4), 0.3 * s, barbel)
			limb(b, "Barbel", P(side * 0.7, -1.5, -11.1), P(side * 1, -3, -12.2), 0.25 * s, barbel)
		end
	end

	-- Queue : pédoncule + caudale fourchue en voile.
	b.Group = newGroup("Tail", 0, 1, P(0, 0, 9))
	ellipsoid(b, "Peduncle", Vector3.new(3.4, 5.5, 7) * s, CFrame.new(P(0, 0, 10.5)), orange)
	for _, lobe in ipairs(SIDES) do
		for ray = 1, if isFry then 1 else 4 do
			local angle = math.rad(if isFry then 30 else 8 + ray * 13)
			local length = if isFry then 8 else 10 - (ray - 2.5) ^ 2 * 0.7
			fin("TailFin", P(0, lobe * 0.6, 12), P(0, lobe * math.sin(angle) * length, 12.5 + math.cos(angle) * length), if isFry then 5 else 3.2)
		end
	end

	-- Dorsale.
	b.Group = newGroup("Fin", 0, 3, P(0, 5, 0))
	if isFry then
		fin("DorsalFin", P(0, 4.8, 0), P(0, 8.5, 3), 5)
	else
		for ray = 1, 6 do
			local z = -5 + ray * 1.9
			local top = 5.5 * math.sqrt(1 - (z / 10) ^ 2) - 0.6
			fin("DorsalFin", P(0, top, z), P(0, top + 5.2 - ray * 0.45, z + 2.2), 2.6)
		end
		-- Anale.
		b.Group = newGroup("Fin", 0, 4, P(0, -4.3, 6))
		fin("AnalFin", P(0, -4, 6), P(0, -7.2, 8.5), 2)
		fin("AnalFin", P(0, -4, 6), P(0, -6.2, 10.2), 2)
	end

	for _, side in ipairs(SIDES) do
		-- Pectorales.
		local pectoral = P(side * 3.1, -2, -4.5)
		b.Group = newGroup("Fin", side, 1, pectoral)
		if isFry then
			fin("PectoralFin", pectoral, pectoral + P(side * 2.6, -1.2, 3.6), 3)
		else
			for ray = 1, 3 do
				fin("PectoralFin", pectoral, pectoral + P(side * 2.6, -1.2 - (ray - 2) * 1.6, 3.6 - math.abs(ray - 2) * 0.5), 1.9)
			end
			-- Pelviennes.
			local pelvic = P(side * 1.6, -4.6, 0.5)
			b.Group = newGroup("Fin", side, 2, pelvic)
			fin("PelvicFin", pelvic, pelvic + P(side * 1.2, -3, 2.5), 1.8)
			fin("PelvicFin", pelvic, pelvic + P(side * 0.6, -2.2, 4.2), 1.8)
		end
	end
	b.Group = nil

	addHumanoid(b, maxHealth, displayName)
	return b.Model
end

-- ============================================================
-- 4. Crabe de rivière
-- Membres : Eye(±1,1) pédoncules | Claw(±1,1) bras + pince entière | Claw(±1,2) doigt mobile
-- (parent Claw 1) | Leg(±1, 1..4 d'avant en arrière). Pince droite (+X) broyeuse, plus grosse.
-- Pattes 5 studs sous la Root.
-- ============================================================
function AnimalModels.BuildCrab(maxHealth: number): Model
	local b = newBuilder("Crabe", Vector3.new(6, 6, 6))
	local shell = Color3.fromRGB(130, 55, 35)
	local shellDark = shade(shell, 0.3)
	local shellLight = Color3.fromRGB(165, 80, 45)
	local underside = Color3.fromRGB(200, 150, 110)
	local clawColor = Color3.fromRGB(150, 60, 35)
	local fingerColor = Color3.fromRGB(60, 30, 20)
	local toothColor = Color3.fromRGB(235, 225, 205)
	local carapaceCenter = Vector3.new(0, 2, 0)
	local carapaceRadii = Vector3.new(13, 4, 9.5)

	-- Hauteur du dôme central de la carapace en (x, z).
	local function domePoint(x: number, z: number): Vector3
		local k = 1 - (x / 9.5) ^ 2 - ((z - 0.8) / 6.75) ^ 2
		return Vector3.new(x, 4.2 + 2.5 * math.sqrt(math.max(k, 0)), z)
	end

	ellipsoid(b, "Carapace", Vector3.new(26, 8, 19), CFrame.new(carapaceCenter), shell)
	ellipsoid(b, "CarapaceDome", Vector3.new(19, 5, 13.5), CFrame.new(0, 4, 0.8), shellLight)
	ellipsoid(b, "Underside", Vector3.new(22, 4, 16), CFrame.new(0, -0.8, 0), underside)
	ellipsoid(b, "Abdomen", Vector3.new(8, 1.6, 9), CFrame.new(0, -2.5, 3), shade(underside, 0.1))
	local head = ellipsoid(b, "Head", Vector3.new(8, 4, 4), CFrame.new(0, 2, -9), shell)
	head.Name = "Head"
	-- Relief de la carapace : arêtes en H sur le dôme + couronne de tubercules.
	strand(b, "Ridge", domePoint(-2.5, 0.8), domePoint(2.5, 0.8), 0.8, 1.2, shellDark)
	for i = 1, 10 do
		local angle = i / 10 * math.pi * 2 + 0.3
		bump(b, "Tubercle", carapaceCenter, carapaceRadii, Vector3.new(math.cos(angle) * 0.8, 0.6, math.sin(angle) * 0.8), Vector3.new(1.6, 1.6, 1), shellDark)
	end

	for _, side in ipairs(SIDES) do
		b.Group = nil
		strand(b, "Ridge", domePoint(side * 2.2, -3), domePoint(side * 2.8, 4.5), 0.8, 1.2, shellDark)
		-- Dents du bord antéro-latéral + dents frontales.
		for i = 1, 4 do
			local theta = math.rad(28 + i * 14)
			local rim = Vector3.new(side * 13 * math.sin(theta), 2, -9.5 * math.cos(theta))
			local outward = Vector3.new(side * math.sin(theta), 0.05, -math.cos(theta) - 0.25).Unit
			strand(b, "Spine", rim - outward * 0.8, rim + outward * 2, 1.4, 1, shellDark)
		end
		strand(b, "Spine", Vector3.new(side * 1.2, 2.4, -9.6), Vector3.new(side * 1.4, 2.3, -12.4), 1.2, 1, shellDark)
		-- Pièces buccales : maxillipèdes, palpes, antennes.
		ellipsoid(b, "Maxilliped", Vector3.new(1.9, 3, 1.2), CFrame.new(side * 1.05, 0.3, -10.3), underside)
		limb(b, "Palp", Vector3.new(side * 1.9, 1, -10.4), Vector3.new(side * 2.6, -0.6, -11.4), 0.4, underside)
		limb(b, "Antenna", Vector3.new(side * 1.4, 3.2, -10.6), Vector3.new(side * 2.2, 4.6, -13.2), 0.25, shellDark)

		-- Yeux pédonculés.
		local stalkBase = Vector3.new(side * 2.6, 3.6, -9.2)
		b.Group = newGroup("Eye", side, 1, stalkBase)
		limb(b, "EyeStalk", stalkBase, Vector3.new(side * 3.1, 7.4, -10), 0.9, shell)
		eye(b, Vector3.new(side * 3.1, 8, -10), 1)

		-- Pinces asymétriques : bras articulé, paume, doigt fixe denté, doigt mobile.
		local k = if side == 1 then 1.3 else 0.85
		local shoulder = Vector3.new(side * 9, 1, -6)
		local elbow = Vector3.new(side * 14, 3, -11)
		local wrist = Vector3.new(side * 10, 3, -16)
		local arm = newGroup("Claw", side, 1, shoulder)
		b.Group = arm
		ellipsoid(b, "ClawJoint", Vector3.one * 3.6 * k, CFrame.new(shoulder), clawColor)
		limb(b, "ClawArm", shoulder, elbow, 3 * k, clawColor)
		ellipsoid(b, "ClawJoint", Vector3.one * 3.4 * k, CFrame.new(elbow), clawColor)
		limb(b, "ClawArm", elbow, wrist, 2.8 * k, clawColor)
		strand(b, "Spine", elbow, elbow + Vector3.new(side * 2.4 * k, 1.2 * k, -0.5), 1.1 * k, 1.1 * k, shellDark)
		ellipsoid(b, "ClawPalm", Vector3.new(6, 5, 8) * k, CFrame.new(wrist + Vector3.new(0, 0, -3 * k)), clawColor)
		local fixedBase = wrist + Vector3.new(side * 0.4, -1.2 * k, -5 * k)
		local fixedTip = wrist + Vector3.new(side * -0.5, -1.6 * k, -11 * k)
		strand(b, "ClawFinger", fixedBase, fixedTip, 2.2 * k, 1.7 * k, fingerColor)
		for tooth = 1, 2 do
			ellipsoid(b, "ClawTooth", Vector3.one * 0.8 * k, CFrame.new(fixedBase:Lerp(fixedTip, 0.35 + tooth * 0.2) + Vector3.new(0, 0.75 * k, 0)), toothColor)
		end
		local hinge = wrist + Vector3.new(side * 0.4, 1.2 * k, -5.5 * k)
		b.Group = newGroup("Claw", side, 2, hinge, arm)
		strand(b, "ClawFinger", hinge + Vector3.new(0, 0, 0.8 * k), wrist + Vector3.new(side * -0.5, 2.4 * k, -11.5 * k), 2 * k, 1.6 * k, fingerColor)

		-- 4 pattes de marche segmentées par côté, en éventail, pointe sombre.
		for i = 1, 4 do
			local z = -3 + (i - 1) * 3.2
			local fan = (i - 2.5) * 1.3
			local reach = if i == 4 then 0.9 else 1
			local hip = Vector3.new(side * 11, 0, z)
			local knee = Vector3.new(side * (11 + 6 * reach), 4, z + 1 + fan)
			local ankle = Vector3.new(side * (11 + 7.6 * reach), -1.2, z + 1.6 + fan * 1.4)
			local foot = Vector3.new(side * (11 + 8 * reach), -5, z + 2 + fan * 1.6)
			b.Group = newGroup("Leg", side, i, hip)
			limb(b, "Leg", hip, knee, 1.6, shell)
			ellipsoid(b, "LegJoint", Vector3.one * 1.9, CFrame.new(knee), shellLight)
			limb(b, "Leg", knee, ankle, 1.3, shell)
			strand(b, "LegTip", ankle + Vector3.new(0, 0.6, 0), foot, 1.2, 1.2, fingerColor)
		end
	end
	b.Group = nil

	addHumanoid(b, maxHealth, "Crabe de Rivière")
	return b.Model
end

-- ============================================================
-- 5. Écureuil roux
-- Membres : Head(0,1) | Leg(±1, 1 = avant / 2 = arrière) | Tail(0,1). Assis, buste relevé,
-- noisette (statique) entre les pattes avant. Pattes 9 studs sous la Root.
-- ============================================================
local TUFT_SPREAD = {
	Vector2.new(1, 0.1), Vector2.new(-1, 0.1), Vector2.new(0, 1),
	Vector2.new(0.72, 0.72), Vector2.new(-0.72, 0.72),
}

function AnimalModels.BuildSquirrel(maxHealth: number): Model
	local b = newBuilder("Ecureuil", Vector3.new(6, 6, 6))
	local red = Color3.fromRGB(190, 85, 35)
	local white = Color3.fromRGB(240, 230, 215)
	local dark = Color3.fromRGB(150, 60, 25)
	local light = Color3.fromRGB(215, 120, 60)
	local pink = Color3.fromRGB(215, 150, 130)
	local black = Color3.fromRGB(40, 25, 20)
	local fur = Enum.Material.Fabric
	local tilt = CFrame.Angles(math.rad(20), 0, 0) -- buste relevé vers l'avant

	ellipsoid(b, "Body", Vector3.new(12, 14, 20), tilt, red)
	ellipsoid(b, "BackFur", Vector3.new(7.5, 5.6, 17), tilt * CFrame.new(0, 4.4, 1), dark, fur)
	ellipsoid(b, "Belly", Vector3.new(9, 10, 14), tilt * CFrame.new(0, -3, -3.5), white)
	-- Mèches de poils du poitrail.
	for k = -2, 2 do
		local a = math.abs(k)
		strand(b, "ChestTuft", Vector3.new(k * 1.3, 2.2 - a * 0.3, -9.6), Vector3.new(k * 1.6, -0.6 - a * 0.2, -11.4), 1.8, 1.2, tint(white, 0.3), fur)
	end
	ellipsoid(b, "Hazelnut", Vector3.new(2.6, 2.6, 2.6), CFrame.new(0, -3.2, -12.6), Color3.fromRGB(150, 100, 50))
	ellipsoid(b, "HazelnutCap", Vector3.new(2.3, 1.1, 2.3), CFrame.new(0, -2.2, -12.6), Color3.fromRGB(95, 65, 35))

	-- Tête : joues, museau, incisives, moustaches, oreilles à pinceaux.
	local headCenter = Vector3.new(0, 7, -9)
	b.Group = newGroup("Head", 0, 1, Vector3.new(0, 4.5, -7))
	local head = ellipsoid(b, "Head", Vector3.new(9, 9, 10), CFrame.new(headCenter), red)
	head.Name = "Head"
	ellipsoid(b, "Muzzle", Vector3.new(5, 4.5, 4), CFrame.new(0, 5.6, -13.6), white)
	ellipsoid(b, "Nose", Vector3.new(1.4, 1.2, 1), CFrame.new(0, 6.2, -15.6), black)
	ellipsoid(b, "Chin", Vector3.new(3.2, 2.2, 3), CFrame.new(0, 4, -13), white)
	block(b, "Teeth", Vector3.new(0.9, 1.1, 0.4), CFrame.new(0, 3.9, -15), WHITE)
	for _, side in ipairs(SIDES) do
		ellipsoid(b, "Cheek", Vector3.new(4.2, 4, 4.6), CFrame.new(side * 2.9, 5.3, -11.3), light, fur)
		ringedEye(b, headCenter, Vector3.new(4.5, 4.5, 5), Vector3.new(side * 3.3, 1.5, -3.5), 1.3, white)
		for j = -1, 1 do
			limb(b, "Whisker", Vector3.new(side * 1.6, 5.3, -14.6), Vector3.new(side * 6.8, 5.3 + j * 1.3, -15.2 + math.abs(j) * 0.4), 0.14, WHITE)
		end
		local earTilt = CFrame.Angles(0, 0, side * math.rad(-12))
		ellipsoid(b, "Ear", Vector3.new(3.2, 5, 1.3), CFrame.new(side * 3, 12.2, -8) * earTilt, red)
		ellipsoid(b, "EarInner", Vector3.new(2, 3.6, 0.6), CFrame.new(side * 3, 12.3, -8.55) * earTilt, pink)
		for d = -1, 1 do
			strand(b, "EarTuft", Vector3.new(side * 3.4, 13.8, -8), Vector3.new(side * 3.7 + d * 0.9, 17.3 - math.abs(d) * 0.5, -7.7), 0.8, 0.8, dark, fur)
		end
	end

	for _, side in ipairs(SIDES) do
		-- Patte avant : bras, avant-bras, main à doigts griffus (tient la noisette).
		local shoulder = Vector3.new(side * 3.8, 1.5, -8)
		local elbow = Vector3.new(side * 3.6, -2.2, -9.2)
		local paw = Vector3.new(side * 1.7, -3, -12)
		b.Group = newGroup("Leg", side, 1, shoulder)
		limb(b, "FrontLeg", shoulder, elbow, 2.2, red)
		limb(b, "FrontLeg", elbow, paw, 1.7, red)
		ellipsoid(b, "Paw", Vector3.new(1.7, 1.4, 2), CFrame.new(paw), dark)
		for toe = -1, 1 do
			strand(b, "PawToe", paw, paw + Vector3.new(toe * 0.5 - side * 0.3, -0.5, -1.1), 0.4, 0.4, black)
		end

		-- Patte arrière : cuisse puissante, jarret, long pied à 4 doigts.
		b.Group = newGroup("Leg", side, 2, Vector3.new(side * 4.8, -2, 5))
		ellipsoid(b, "Haunch", Vector3.new(5.5, 8.5, 9.5), CFrame.new(side * 4.6, -3, 4.5), red)
		limb(b, "HindLeg", Vector3.new(side * 5, -5, 4), Vector3.new(side * 5.5, -8, 2.5), 3, red)
		ellipsoid(b, "HindFoot", Vector3.new(2.8, 1.6, 6.5), CFrame.new(side * 5.5, -8.5, 0.3), dark)
		for _, toe in ipairs({ -1.5, -0.5, 0.5, 1.5 }) do
			strand(b, "HindToe", Vector3.new(side * 5.5 + toe * 0.6, -8.6, -2.2), Vector3.new(side * 5.5 + toe * 0.8, -8.9, -4), 0.5, 0.5, black)
		end
	end

	-- Queue en panache : coeur volumineux + mèches ébouriffées tout du long.
	b.Group = newGroup("Tail", 0, 1, Vector3.new(0, -3, 9.5))
	local tailPoints = {
		Vector3.new(0, -3.5, 10.5), Vector3.new(0, 1.5, 14.5), Vector3.new(0, 8, 16),
		Vector3.new(0, 14, 14.5), Vector3.new(0, 17.5, 10.5), Vector3.new(0, 18, 6),
	}
	for i, point in ipairs(tailPoints) do
		local tangent = (tailPoints[math.min(i + 1, #tailPoints)] - tailPoints[math.max(i - 1, 1)]).Unit
		local outer = Vector3.new(0, -tangent.Z, tangent.Y) -- côté opposé au dos
		local radius = 3.4 + i * 0.3
		ellipsoid(b, "Tail", Vector3.new(radius * 2, radius * 2, radius * 1.9), CFrame.new(point), if i % 2 == 0 then red else dark, fur)
		for t, spread in ipairs(TUFT_SPREAD) do
			local offset = Vector3.xAxis * spread.X + outer * spread.Y
			strand(b, "TailTuft", point + offset * radius * 0.45, point + offset * radius * 1.05 + tangent * radius * 0.7, radius * 0.85, radius * 0.85, if (i + t) % 2 == 0 then light else red, fur)
		end
	end
	b.Group = nil

	addHumanoid(b, maxHealth, "Écureuil Roux")
	return b.Model
end

-- ============================================================
-- Nids des grands animaux (mini-biomes en hauteur, GDD §7.A)
-- ============================================================

local function staticPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	if shape then
		part.Shape = shape
	end
	part.Parent = parent
	return part
end

-- Décor pur : ni collision, ni requête, ni toucher.
local function decorPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local part = staticPart(parent, name, size, cf, color, material, shape)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function sphereMesh(part: Part)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
end

local TWIG_COLORS = { Color3.fromRGB(105, 80, 50), Color3.fromRGB(125, 95, 60), Color3.fromRGB(88, 66, 42) }
local LEAF_COLORS = {
	Color3.fromRGB(120, 130, 55), Color3.fromRGB(165, 120, 50),
	Color3.fromRGB(195, 110, 45), Color3.fromRGB(140, 95, 45),
}
local FLAT = CFrame.Angles(0, 0, math.rad(90)) -- cylindre couché (axe X -> vertical)

-- Nid d'oiseau : coupe de brindilles tressées + mousse + duvet + plumes + 3 oeufs bleus
-- mouchetés. Solide (on peut y marcher) : retourne la part "Fond" pour les tags Shelter/WarmSpot.
function AnimalModels.BuildBirdNest(center: Vector3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "NidOiseau"
	local floor = staticPart(model, "Fond", Vector3.new(2, 24, 24), CFrame.new(center) * FLAT, Color3.fromRGB(95, 120, 70), Enum.Material.Grass, Enum.PartType.Cylinder)
	decorPart(model, "Duvet", Vector3.new(0.6, 17, 17), CFrame.new(center + Vector3.new(0, 1.05, 0)) * FLAT, Color3.fromRGB(225, 215, 195), Enum.Material.Fabric, Enum.PartType.Cylinder)
	-- Paroi : 3 couronnes de brindilles croisées (la 3e, la plus haute, est décorative).
	for ring = 1, 3 do
		for i = 1, 16 do
			local angle = i / 16 * math.pi * 2 + ring * 0.3
			local radius = 11 + ring * 1.5
			local thickness = 1.2 + (i % 2) * 0.4
			local cf = CFrame.new(center + Vector3.new(math.cos(angle) * radius, ring * 2.2, math.sin(angle) * radius))
				* CFrame.Angles(0, -angle + math.rad(90 + (i % 3 - 1) * 8), math.rad(if (i + ring) % 2 == 0 then 12 else -12))
			local twig = staticPart(model, "Brindille", Vector3.new(8.5 + (i % 3) * 1.5, thickness, thickness), cf, TWIG_COLORS[(i + ring) % 3 + 1], Enum.Material.Wood, Enum.PartType.Cylinder)
			if ring == 3 then
				twig.CanCollide = false
			end
		end
	end
	-- Brindilles folles qui dépassent + coussins de mousse sur le rebord.
	for i = 1, 8 do
		local angle = i * 0.785 + 0.2
		local cf = CFrame.new(center + Vector3.new(math.cos(angle) * 14.5, 2.5 + i % 3, math.sin(angle) * 14.5)) * CFrame.Angles(0, -angle, 0) * CFrame.Angles(0, 0, math.rad(20))
		decorPart(model, "Brindille", Vector3.new(7, 0.8, 0.8), cf, TWIG_COLORS[i % 3 + 1], Enum.Material.Wood, Enum.PartType.Cylinder)
	end
	for i = 1, 6 do
		local angle = i / 6 * math.pi * 2 + 0.5
		decorPart(model, "Mousse", Vector3.new(3.5, 3.5, 3.5), CFrame.new(center + Vector3.new(math.cos(angle) * 12.5, 4.9, math.sin(angle) * 12.5)), Color3.fromRGB(85, 130, 60), Enum.Material.Grass, Enum.PartType.Ball)
	end
	-- Oeufs mouchetés.
	for i = 1, 3 do
		local angle = i / 3 * math.pi * 2
		local eggCenter = center + Vector3.new(math.cos(angle) * 3.5, 3.2, math.sin(angle) * 3.5)
		local egg = staticPart(model, "OeufOiseau", Vector3.new(4, 5, 4), CFrame.new(eggCenter), Color3.fromRGB(140, 200, 220), Enum.Material.SmoothPlastic)
		sphereMesh(egg)
		for speck = 1, 3 do
			local speckAngle = angle + speck * 2.1
			local point = onSurface(eggCenter, Vector3.new(2, 2.5, 2), Vector3.new(math.cos(speckAngle), 0.9 - speck * 0.3, math.sin(speckAngle)))
			decorPart(model, "Tache", Vector3.one * 0.6, CFrame.new(point), Color3.fromRGB(110, 85, 70), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		end
	end
	for i = 1, 5 do
		local angle = i * 1.7
		local feather = decorPart(model, "Plume", Vector3.new(0.3, 1.8, 6.5), CFrame.new(center + Vector3.new(math.cos(angle) * 8, 1.7, math.sin(angle) * 8)) * CFrame.Angles(0, angle, math.rad(20)), if i % 2 == 0 then Color3.fromRGB(120, 90, 60) else Color3.fromRGB(230, 120, 60), Enum.Material.Fabric)
		sphereMesh(feather)
	end
	model.PrimaryPart = floor
	return model, floor
end

-- Direction n°i (sur count) d'une spirale de Fibonacci sur la sphère.
local function spiralDirection(i: number, count: number, phase: number): Vector3
	local theta = (i * 2.399 + phase) % (math.pi * 2)
	local phi = math.acos(1 - 2 * (i - 0.5) / count)
	return Vector3.new(math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta))
end

local function isDreyEntrance(direction: Vector3): boolean
	return direction.Z < -0.6 and math.abs(direction.Y) < 0.5
end

-- Hotte (nid sphérique de feuilles) de l'écureuil, creuse avec une entrée côté -Z. Seul le
-- plancher est solide.
function AnimalModels.BuildDrey(center: Vector3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "HotteEcureuil"
	local floor = staticPart(model, "Plancher", Vector3.new(1.5, 16, 16), CFrame.new(center + Vector3.new(0, -6, 0)) * FLAT, Color3.fromRGB(110, 85, 55), Enum.Material.Wood, Enum.PartType.Cylinder)
	decorPart(model, "Mousse", Vector3.new(0.6, 13, 13), CFrame.new(center + Vector3.new(0, -5.1, 0)) * FLAT, Color3.fromRGB(95, 125, 65), Enum.Material.Grass, Enum.PartType.Cylinder)
	-- Coque intérieure : plaques de litière tangentes à la sphère.
	for i = 1, 26 do
		local direction = spiralDirection(i, 26, 0)
		if not isDreyEntrance(direction) then
			decorPart(model, "Litiere", Vector3.new(7.5, 7.5, 0.6), CFrame.lookAt(center + direction * 8, center + direction * 9), TWIG_COLORS[i % 3 + 1], Enum.Material.Wood)
		end
	end
	-- Couche extérieure : feuilles ovales ébouriffées + brindilles qui dépassent.
	for i = 1, 24 do
		local direction = spiralDirection(i, 24, 1.2)
		if not isDreyEntrance(direction) then
			local leaf = decorPart(model, "Feuille", Vector3.new(7, 6, 0.8), CFrame.lookAt(center + direction * 8.7, center + direction * 9.7) * CFrame.Angles(math.rad(18), 0, i * 0.7), LEAF_COLORS[i % 4 + 1], Enum.Material.Grass)
			sphereMesh(leaf)
		end
	end
	for i = 1, 8 do
		local direction = spiralDirection(i, 8, 2.5)
		if not isDreyEntrance(direction) then
			decorPart(model, "Brindille", Vector3.new(6, 0.6, 0.6), CFrame.lookAt(center + direction * 9, center + direction * 10) * CFrame.Angles(0, math.rad(90), 0), TWIG_COLORS[i % 3 + 1], Enum.Material.Wood, Enum.PartType.Cylinder)
		end
	end
	-- Cadre de brindilles autour de l'entrée.
	for i = 1, 6 do
		local angle = i / 6 * math.pi * 2
		decorPart(model, "Brindille", Vector3.new(4.6, 0.9, 0.9), CFrame.new(center + Vector3.new(math.cos(angle) * 4.2, math.sin(angle) * 3.8, -7.4)) * CFrame.Angles(0, 0, angle + math.rad(90)), TWIG_COLORS[i % 3 + 1], Enum.Material.Wood, Enum.PartType.Cylinder)
	end
	model.PrimaryPart = floor
	return model, floor
end

return AnimalModels
