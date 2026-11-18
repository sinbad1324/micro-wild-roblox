--!strict
-- InsectVisualService.luau
-- Habille un personnage joueur d'un corps d'insecte 3D procédural (30 espèces, GDD §5) à la place
-- de l'avatar Roblox. Toute la morphologie vient de shared/InsectBodyPlans : ce module ne contient
-- que des "constructeurs" génériques (corps, pattes, ailes, mâchoires, queue, larves...).
--
-- Repère local (relatif au HumanoidRootPart) : -Z = avant (tête), +X = droite, Y = haut.
-- Toutes les longueurs des constructeurs sont en "unités insecte" multipliées par ctx.s.
--
-- CONVENTION D'ANIMATION (pour le code d'animation, client ou serveur)
-- Chaque Part du conteneur "InsectVisual" porte un Weld nommé "Weld" (Part0 = HumanoidRootPart,
-- Part1 = la part). Les parts animables portent en plus les attributs :
--   Anim   (string) : "Leg" | "Wing" | "Elytron" | "Antenna" | "Abdomen" | "Tail" | "Jaw" | "Claw" | "Segment"
--   Side   (number) : -1 = gauche, 1 = droite, 0 = médian
--   Index  (number) : n° de paire (pattes, 1 = avant ; ailes, 1 = antérieure) ou n° de segment (1 = base)
--   RestC0 (CFrame) : C0 de repos du Weld = CFrame.new(pivot), SANS rotation (axes = ceux du root)
-- Le pivot est l'articulation : hanche (Leg), racine de l'aile (Wing), charnière d'épaule (Elytron),
-- base (Antenna/Jaw), épaule (Claw), jonction thorax-abdomen (Abdomen), base de la queue (Tail),
-- centre du segment (Segment : larves, scolopendre). Pour animer :
--   weld.C0 = RestC0 * CFrame.Angles(rx, ry, rz)      -- rotation autour de l'articulation
-- avec ry = balancement avant/arrière, rz = levée/battement (multiplier par Side), rx = tangage.
-- Toutes les parts d'un même membre (LegCoxa + LegFemur + LegTibia + LegTarsus d'une patte, aile + nervures,
-- tous les segments d'abdomen) partagent le même pivot : appliquer la même rotation à toutes les
-- parts de même (Anim, Side, Index) fait bouger le membre d'un bloc ; pour "Abdomen" et "Tail",
-- appliquer la même rotation quel que soit Index (Index sert à déphaser si on veut onduler).
-- Les parts non animables gardent C0 = offset complet et n'ont pas d'attribut Anim.
-- Le conteneur porte "AnimScale" (number) : échelle du personnage à la construction. Après un
-- ScaleTo, utiliser RestC0.Position * (character:GetScale() / AnimScale).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)

type BodyPlan = InsectBodyPlans.BodyPlan
type MutationInfo = InsectBodyPlans.MutationInfo
type Role = "Primary" | "Secondary" | "Accent" | "Eye" | "Wing" | "Dark" | "Larva" | "Raw" | "Shine"
type Shape = "Ellipsoid" | "Block" | "Cylinder" | "Ball"

type Ctx = {
	root: BasePart,
	container: Model,
	plan: BodyPlan,
	s: number,
	groundY: number,
	mutation: MutationInfo?,
	partIndex: number,
	pale: number, -- 0..1 : éclaircit tout (carapace molle juste après la mue)
	-- Étiquette d'animation posée sur les prochaines parts créées (voir setAnim).
	animKind: string?,
	animSide: number,
	animIndex: number,
	animPivot: Vector3,
}

local InsectVisualService = {}

local CONTAINER_NAME = "InsectVisual"
local HOOKED_ATTRIBUTE = "InsectVisualHooked"
local BASE_TRANSPARENCY_ATTRIBUTE = "BaseTransparency"
local WHITE = Color3.new(1, 1, 1)
local DARK = Color3.fromRGB(20, 18, 16)
local SIDES = { -1, 1 }

-- ============================================================
-- Primitives
-- ============================================================

local function paint(ctx: Ctx, role: Role, raw: Color3?): (Color3, Enum.Material, number)
	if role == "Shine" then
		-- Reflets des yeux / fils de soie : toujours blancs (ni mutation ni mue).
		return WHITE, Enum.Material.SmoothPlastic, 0.2
	end
	local plan = ctx.plan
	local color: Color3 = raw or plan.Primary
	if role == "Primary" then
		color = plan.Primary
	elseif role == "Secondary" then
		color = plan.Secondary
	elseif role == "Accent" then
		color = plan.Accent
	elseif role == "Eye" then
		color = plan.EyeColor
	elseif role == "Wing" then
		color = plan.WingColor
	elseif role == "Dark" then
		color = DARK
	elseif role == "Larva" then
		color = plan.LarvaColor
	end

	local material = if plan.Fuzzy and (role == "Primary" or role == "Secondary" or role == "Larva")
		then Enum.Material.Fabric
		else Enum.Material.SmoothPlastic
	local reflectance = if role == "Eye"
		then 0.25
		elseif plan.Metallic and (role == "Primary" or role == "Secondary") then 0.2
		else 0

	local mutation = ctx.mutation
	if mutation and role ~= "Eye" then
		if mutation.Rainbow then
			color = Color3.fromHSV((ctx.partIndex * 0.07) % 1, 0.75, 1)
		elseif role == "Primary" or role == "Larva" then
			color = mutation.Primary or color
		elseif role == "Secondary" or role == "Dark" then
			color = mutation.Secondary or color
		elseif role == "Wing" and mutation.Primary then
			color = color:Lerp(mutation.Primary, 0.5)
		end
		if mutation.Material and role ~= "Wing" then
			material = mutation.Material
		end
	end

	if ctx.pale > 0 and role ~= "Eye" then
		color = color:Lerp(WHITE, ctx.pale)
	end
	return color, material, reflectance
end

-- Les parts créées ensuite sont étiquetées (Anim/Side/Index/RestC0) et soudées autour de `pivot`
-- (point local en studs, déjà converti par at()). setAnim(ctx, nil) arrête l'étiquetage.
local function setAnim(ctx: Ctx, kind: string?, side: number?, index: number?, pivot: Vector3?)
	ctx.animKind = kind
	ctx.animSide = side or 0
	ctx.animIndex = index or 0
	ctx.animPivot = pivot or Vector3.zero
end

local function addPart(ctx: Ctx, name: string, size: Vector3, localCf: CFrame, role: Role, shape: Shape, transparency: number?, raw: Color3?): Part
	ctx.partIndex += 1
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	if shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	elseif shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	end
	local color, material, reflectance = paint(ctx, role, raw)
	part.Color = color
	part.Material = if role == "Wing" then Enum.Material.Glass else material
	part.Reflectance = reflectance
	part.Transparency = transparency or 0
	part:SetAttribute(BASE_TRANSPARENCY_ATTRIBUTE, part.Transparency)
	part.CanCollide = false
	part.CanQuery = false -- ne doit jamais perturber les raycasts d'escalade/visée
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = size.Magnitude > 0.6
	part.CFrame = ctx.root.CFrame * localCf -- calculé AVANT le weld pour un offset correct
	part.Parent = ctx.container

	if shape == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end

	-- Weld avec offset explicite (C0) : indépendant de la position répliquée du root, qui peut
	-- différer côté serveur/client pendant que le joueur bouge.
	local weld = Instance.new("Weld")
	weld.Part0 = ctx.root
	weld.Part1 = part
	local kind = ctx.animKind
	if kind then
		-- Part animable : C0 = articulation (sans rotation), C1 = articulation vue depuis la part.
		-- part = root * C0 * C1^-1 = root * localCf au repos ; tourner C0 fait pivoter la part.
		local pivot = CFrame.new(ctx.animPivot)
		weld.C0 = pivot
		weld.C1 = localCf:Inverse() * pivot
		part:SetAttribute("Anim", kind)
		part:SetAttribute("Side", ctx.animSide)
		part:SetAttribute("Index", ctx.animIndex)
		part:SetAttribute("RestC0", pivot)
	else
		weld.C0 = localCf
		weld.C1 = CFrame.identity
	end
	weld.Parent = part
	return part
end

-- Point local (unités insecte -> studs) : y est mesuré depuis le sol sous le personnage.
local function at(ctx: Ctx, x: number, y: number, z: number): Vector3
	return Vector3.new(x * ctx.s, ctx.groundY + y * ctx.s, z * ctx.s)
end

local function ellipsoid(ctx: Ctx, name: string, center: Vector3, size: Vector3, role: Role, rotation: CFrame?, transparency: number?, raw: Color3?): Part
	local cf = CFrame.new(center) * (rotation or CFrame.identity)
	return addPart(ctx, name, size * ctx.s, cf, role, "Ellipsoid", transparency, raw)
end

-- Cylindre reliant deux points locaux déjà convertis (via at()). L'axe d'un cylindre Roblox est
-- son X local : lookAt aligne -Z sur la direction, puis 90° en Y ramène X sur cet axe.
local function limb(ctx: Ctx, name: string, a: Vector3, b: Vector3, diameter: number, role: Role, raw: Color3?): Part?
	local delta = b - a
	local length = delta.Magnitude
	if length < 0.01 then
		return nil
	end
	local up = if math.abs(delta.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	local cf = CFrame.lookAt(a:Lerp(b, 0.5), b, up) * CFrame.Angles(0, math.rad(90), 0)
	local d = diameter * ctx.s
	return addPart(ctx, name, Vector3.new(length, d, d), cf, role, "Cylinder", nil, raw)
end

local function flatPanel(ctx: Ctx, name: string, center: Vector3, size: Vector3, rotation: CFrame, role: Role, transparency: number?, raw: Color3?): Part
	return addPart(ctx, name, size * ctx.s, CFrame.new(center) * rotation, role, "Ellipsoid", transparency, raw)
end

-- Panneau ovale plat tendu de la racine `a` à la pointe `b` (points locaux en studs) : ailes,
-- rames. `chord` = largeur, `normal` = direction approximative de la face (Y par défaut),
-- `veins` = nombre de nervures sombres rayonnant depuis la racine. Renvoie le CFrame du panneau.
local function wing(ctx: Ctx, name: string, a: Vector3, b: Vector3, chord: number, role: Role, transparency: number, veins: number, normal: Vector3?, thickness: number?, raw: Color3?): CFrame
	local thick = thickness or 0.03
	local cf = CFrame.lookAt(a:Lerp(b, 0.5), b, normal or Vector3.yAxis)
	addPart(ctx, name, Vector3.new(chord * ctx.s, thick * ctx.s, (b - a).Magnitude), cf, role, "Ellipsoid", transparency, raw)
	if veins > 0 then
		-- Un peu plus épaisses que le panneau pour dépasser des deux faces.
		local right = cf.RightVector * (chord * ctx.s)
		limb(ctx, "WingVein", a, a:Lerp(b, 0.92), thick + 0.025, "Dark")
		for k = 2, veins do
			local offset = if k % 2 == 0 then 0.3 else -0.3
			limb(ctx, "WingVein", a, a:Lerp(b, 0.7) + right * offset, thick + 0.02, "Dark")
		end
	end
	return cf
end

-- ============================================================
-- Squelette commun : positions clés du corps adulte
-- ============================================================

type Layout = {
	H: number, -- hauteur du centre du corps
	headZ: number,
	headR: number,
	thoraxZ: number,
	thoraxLen: number,
	thoraxW: number,
	thoraxH: number,
	abdZ: number,
	abdLen: number,
	abdW: number,
	abdH: number,
}

local function computeLayout(plan: BodyPlan): Layout
	local H = if plan.Shape == "Flat" then 0.32 elseif plan.Shape == "Stick" then 0.6 else 0.5
	if plan.LegStyle == "Long" or plan.LegStyle == "Strider" then
		H += 0.15
	end
	local headR = 0.4 * plan.HeadSize
	local thoraxLen = 0.8 * plan.ThoraxLength
	local thoraxW = if plan.Shape == "Flat" then 1.0 else 0.75
	local abdLen = 1.2 * plan.AbdomenLength
	local abdW = 0.85 * plan.AbdomenWidth * (if plan.Shape == "Flat" then 1.25 else 1)
	local abdH = abdW * (if plan.Shape == "Flat" then 0.45 else 0.75)
	if plan.Shape == "Stick" then
		abdW = 0.22 * plan.AbdomenWidth / 0.4
		abdH = abdW
		thoraxW = 0.22
	end

	local thoraxZ = 0
	local headZ = -(thoraxLen / 2 + headR * 0.85)
	local gap = if plan.Waist then 0.22 else 0.02
	local abdZ = thoraxLen / 2 + gap + abdLen / 2

	-- Recentre le corps sur le HumanoidRootPart (sinon l'insecte paraît décalé vers l'arrière).
	local front = headZ - headR
	local back = abdZ + abdLen / 2
	local shift = -(front + back) / 2
	return {
		H = H,
		headZ = headZ + shift,
		headR = headR,
		thoraxZ = thoraxZ + shift,
		thoraxLen = thoraxLen,
		thoraxW = thoraxW,
		thoraxH = thoraxW * (if plan.Shape == "Flat" then 0.5 else 0.9),
		abdZ = abdZ + shift,
		abdLen = abdLen,
		abdW = abdW,
		abdH = abdH,
	}
end

-- Variante d'un Layout avec une tête déplacée (araignée, coccinelle, scolopendre, phasme).
local function withHead(L: Layout, H: number, headZ: number, headR: number): Layout
	local copy = table.clone(L)
	copy.H = H
	copy.headZ = headZ
	copy.headR = headR
	return copy
end

-- Articulation thorax-abdomen : pivot commun de TOUTES les parts étiquetées "Abdomen".
local function abdomenPivot(ctx: Ctx, L: Layout): Vector3
	return at(ctx, 0, L.H, L.abdZ - L.abdLen / 2)
end

-- ============================================================
-- Constructeurs de parties
-- ============================================================

local function buildHead(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local r = L.headR
	local role = (plan.HeadColor :: any) :: Role
	if plan.HeadShape == "Triangle" then
		-- Mante : tête triangulaire (large en haut, museau pointu vers le bas).
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.12, L.headZ), Vector3.new(r * 2.5, r * 1.3, r * 1.3), role)
		ellipsoid(ctx, "Muzzle", at(ctx, 0, L.H + 0.12 - r * 0.6, L.headZ - r * 0.25), Vector3.new(r * 1.0, r * 1.3, r * 0.9), role)
	elseif plan.HeadShape == "Wide" then
		-- Cigale : tête très large et courte, 3 ocelles rouges sur le front.
		local z = L.headZ + r * 0.2
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.05, z), Vector3.new(r * 2.9, r * 1.5, r * 1.4), role)
		for i = -1, 1 do
			ellipsoid(ctx, "Ocellus", at(ctx, i * r * 0.28, L.H + 0.05 + r * 0.7, z - r * (0.3 - math.abs(i) * 0.15)), Vector3.one * 0.07, "Raw", nil, nil, Color3.fromRGB(200, 60, 40))
		end
	else
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.05, L.headZ), Vector3.new(r * 2, r * 1.8, r * 1.9), role)
		-- Clypéus : plaque de la "bouche" qui donne du relief au visage.
		ellipsoid(ctx, "Clypeus", at(ctx, 0, L.H - r * 0.35, L.headZ - r * 0.62), Vector3.new(r * 1.1, r * 0.8, r * 0.7), "Secondary")
	end
end

local function buildEyes(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local r = 0.13 * plan.EyeSize * plan.HeadSize
	local eyeY = L.H + L.headR * 0.35
	if plan.Shape == "Spider" then
		-- Araignées : 2 gros yeux frontaux + 2 petits (l'araignée sauteuse a des yeux énormes).
		for _, side in ipairs(SIDES) do
			local main = at(ctx, side * L.headR * 0.45, eyeY, L.headZ - L.headR * 0.85)
			ellipsoid(ctx, "EyeMain", main, Vector3.one * r * 1.5, "Eye")
			ellipsoid(ctx, "EyeShine", main + Vector3.new(side * r * 0.2, r * 0.4, -r * 0.5) * ctx.s, Vector3.one * r * 0.45, "Shine")
			ellipsoid(ctx, "EyeSide", at(ctx, side * L.headR * 0.85, eyeY + 0.08, L.headZ - L.headR * 0.5), Vector3.one * r * 0.8, "Eye")
		end
		return
	end
	local x, y, z = L.headR * 0.72, eyeY, L.headZ - L.headR * 0.35
	if plan.HeadShape == "Triangle" then
		x, y, z = L.headR * 1.1, L.H + 0.12 + L.headR * 0.15, L.headZ - L.headR * 0.2
	elseif plan.HeadShape == "Wide" then
		x, y, z = L.headR * 1.35, L.H + 0.1, L.headZ + L.headR * 0.05
	end
	for _, side in ipairs(SIDES) do
		local center = at(ctx, side * x, y, z)
		-- Oeil composé + reflet blanc.
		ellipsoid(ctx, "Eye", center, Vector3.new(r * 1.6, r * 2, r * 2), "Eye")
		ellipsoid(ctx, "EyeShine", center + Vector3.new(side * r * 0.3, r * 0.55, -r * 0.55) * ctx.s, Vector3.one * r * 0.55, "Shine")
	end
end

local function buildAntennae(ctx: Ctx, L: Layout)
	local kind = ctx.plan.Antennae
	if kind == "None" then
		return
	end
	local s = ctx.s
	for _, side in ipairs(SIDES) do
		local base = at(ctx, side * L.headR * 0.35, L.H + L.headR * 0.7, L.headZ - L.headR * 0.6)
		setAnim(ctx, "Antenna", side, 1, base)
		if kind == "Elbowed" then
			-- Fourmi / abeille : scape dressé puis funicule coudé vers l'avant.
			local elbow = base + Vector3.new(side * 0.22, 0.4, -0.12) * s
			local tip = elbow + Vector3.new(side * 0.22, -0.05, -0.6) * s
			limb(ctx, "Antenna", base, elbow, 0.06, "Dark")
			limb(ctx, "Antenna", elbow, tip, 0.045, "Dark")
		elseif kind == "Short" then
			limb(ctx, "Antenna", base, base + Vector3.new(side * 0.12, 0.2, -0.28) * s, 0.045, "Dark")
		else
			local length = if kind == "Long" then 1.2 elseif kind == "Feathery" then 0.6 else 0.8
			local mid = base + Vector3.new(side * 0.2, 0.35, -0.3) * s * length
			local tip = mid + Vector3.new(side * 0.25, 0.25, -0.45) * s * length
			limb(ctx, "Antenna", base, mid, 0.05, "Dark")
			limb(ctx, "Antenna", mid, tip, 0.04, "Dark")
			if kind == "Clubbed" then
				ellipsoid(ctx, "AntennaClub", tip, Vector3.new(0.13, 0.13, 0.2), "Dark")
			elseif kind == "Feathery" then
				flatPanel(ctx, "AntennaPlume", mid:Lerp(tip, 0.4), Vector3.new(0.22, 0.04, 0.5), CFrame.Angles(0.5, side * 0.4, 0), "Secondary", 0.2)
			end
		end
	end
	setAnim(ctx, nil)
end

local function buildJaws(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local s = ctx.s
	local r = L.headR
	local frontZ = L.headZ - r * 0.9
	local mouthY = L.H - r * 0.25
	if plan.Jaws == "Mandibles" then
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * r * 0.4, mouthY, frontZ + 0.05)
			local tip = at(ctx, side * r * 0.08, mouthY - 0.05, frontZ - 0.32)
			setAnim(ctx, "Jaw", side, 1, base)
			limb(ctx, "Mandible", base, tip, 0.09, "Dark")
		end
	elseif plan.Jaws == "Stag" then
		-- Lucane : immenses mandibules en bois de cerf (dent intérieure + pointe fourchue).
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * r * 0.55, mouthY + 0.05, frontZ + 0.05)
			local mid = at(ctx, side * r * 1.0, mouthY + 0.25, frontZ - 0.6)
			local tip = at(ctx, side * r * 0.25, mouthY + 0.3, frontZ - 1.15)
			setAnim(ctx, "Jaw", side, 1, base)
			limb(ctx, "StagJaw", base, mid, 0.16, "Secondary")
			limb(ctx, "StagJaw", mid, tip, 0.13, "Secondary")
			limb(ctx, "StagTooth", mid:Lerp(tip, 0.4), at(ctx, side * r * 0.35, mouthY + 0.2, frontZ - 0.75), 0.07, "Secondary")
			limb(ctx, "StagTooth", mid:Lerp(tip, 0.85), at(ctx, side * r * 0.75, mouthY + 0.38, frontZ - 1.3), 0.07, "Secondary")
		end
	elseif plan.Jaws == "Proboscis" then
		-- Trompe (longue et fine chez le moustique, courte chez l'abeille et le taon).
		local len = plan.ProboscisLength
		local base = at(ctx, 0, mouthY, frontZ + 0.05)
		local tip = at(ctx, 0, math.max(0.04, mouthY - 0.35 * len), frontZ - 0.55 * len)
		limb(ctx, "Proboscis", base, tip, if len < 0.75 then 0.08 else 0.05, "Dark")
	elseif plan.Jaws == "Fangs" then
		-- Chélicères + crochets ; raccourcis si la tête est basse (scolopendre) pour rester hors du sol.
		local reach = math.min(1, mouthY / 0.42)
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * r * 0.3, mouthY + 0.05, frontZ + 0.1)
			local knuckle = base + Vector3.new(0, -0.2 * reach, -0.08) * s
			setAnim(ctx, "Jaw", side, 1, base)
			limb(ctx, "Chelicera", base, knuckle, 0.15, "Secondary")
			limb(ctx, "Fang", knuckle, knuckle + Vector3.new(-side * 0.06, -0.16 * reach, 0.02) * s, 0.06, "Dark")
			if plan.Shape == "Spider" then
				setAnim(ctx, nil)
				local palp = at(ctx, side * r * 0.62, mouthY + 0.08, frontZ + 0.15)
				limb(ctx, "Pedipalp", palp, palp + Vector3.new(side * 0.05, -0.1, -0.3) * s, 0.09, if plan.Fuzzy then "Accent" else "Primary")
			end
		end
	elseif plan.Jaws == "Rostrum" then
		limb(ctx, "Rostrum", at(ctx, 0, mouthY, frontZ + 0.1), at(ctx, 0, mouthY - 0.3, frontZ + 0.45), 0.06, "Dark")
	elseif plan.Jaws == "Nozzle" then
		-- Termite soldat : "canon frontal à glu".
		limb(ctx, "GlueNozzle", at(ctx, 0, L.H + 0.1, L.headZ - r * 0.4), at(ctx, 0, L.H + 0.05, frontZ - 0.45), 0.16, "Secondary")
		ellipsoid(ctx, "GlueDrop", at(ctx, 0, L.H + 0.05, frontZ - 0.47), Vector3.one * 0.12, "Raw", nil, 0.2, Color3.fromRGB(235, 225, 170))
	end
	setAnim(ctx, nil)
end

local function buildHorn(ctx: Ctx, L: Layout)
	if not ctx.plan.Horn then
		return
	end
	-- Scarabée Hercule : grande corne thoracique recourbée + corne céphalique sous elle (pince).
	local thoraxTop = at(ctx, 0, L.H + 0.35, L.thoraxZ - L.thoraxLen * 0.2)
	local mid = at(ctx, 0, L.H + 0.75, L.headZ - L.headR * 0.4)
	local tip = at(ctx, 0, L.H + 0.45, L.headZ - L.headR - 0.75)
	limb(ctx, "ThoraxHorn", thoraxTop, mid, 0.2, "Primary")
	limb(ctx, "ThoraxHorn", mid, tip, 0.15, "Primary")
	limb(ctx, "HornTooth", mid:Lerp(tip, 0.45), mid:Lerp(tip, 0.5) + Vector3.new(0, -0.16, 0) * ctx.s, 0.07, "Primary")
	local headBase = at(ctx, 0, L.H + 0.1, L.headZ - L.headR * 0.6)
	limb(ctx, "HeadHorn", headBase, at(ctx, 0, L.H + 0.3, L.headZ - L.headR - 0.55), 0.14, "Primary")
end

-- Une paire de pattes articulées : LegCoxa (rotule de hanche) -> LegFemur -> LegTibia -> LegTarsus.
-- Toutes les parts d'une patte partagent le pivot de la hanche (Anim = "Leg", Side, Index = n° de paire).
local function buildLegPair(ctx: Ctx, L: Layout, index: number, pairCount: number, z: number, hipY: number, halfWidth: number)
	local plan = ctx.plan
	local style = plan.LegStyle
	local span = 0.95 * plan.LegLength
	local kneeUp = 0.35
	local spreadZ = (index - (pairCount + 1) / 2) * 0.35 -- pattes avant vers l'avant, arrière vers l'arrière
	local d = if plan.Fuzzy then 0.12 else 0.09
	local isHind = index == pairCount
	local isFront = index == 1

	if style == "Long" then
		kneeUp = 0.65
		span *= 1.1
	elseif style == "Strider" then
		-- Gerris : pattes médianes/arrière démesurées, posées à plat sur l'eau.
		kneeUp = 0.25
		if not isFront then
			span *= 1.4
			spreadZ *= 2.2
		else
			span *= 0.45
		end
	end

	local femurRole: Role, tibiaRole: Role, tarsusRole: Role = "Primary", "Primary", "Dark"
	local tint = plan.LegTint
	local legColor = plan.LegColor
	if legColor == "Dark" then
		femurRole, tibiaRole = "Dark", "Dark"
	elseif legColor == "Tipped" then
		tibiaRole, tarsusRole = "Raw", "Raw" -- frelon "à pattes jaunes"
	elseif legColor == "Thighs" then
		if index > 1 then
			femurRole = "Raw" -- guêpe émeraude : fémurs rouges
		end
	elseif legColor == "Striped" then
		tibiaRole = "Raw" -- moustique tigre : pattes annelées
	end

	for _, side in ipairs(SIDES) do
		local hip = at(ctx, side * halfWidth, hipY, z)
		local knee: Vector3
		local ankle: Vector3
		setAnim(ctx, "Leg", side, index, hip)
		if plan.Shape ~= "Stick" then
			-- Coxa : rotule visible à l'insertion de la patte (cachée dans la brindille du phasme).
			ellipsoid(ctx, "LegCoxa", hip, Vector3.one * d * 1.7, femurRole, nil, nil, tint)
		end
		if style == "Jumper" and isHind then
			-- Sauterelle : fémur arrière massif replié vers le haut, tibia qui redescend, tarse au sol.
			knee = at(ctx, side * (halfWidth + 0.3), hipY + 0.7, z + 0.6)
			ankle = at(ctx, side * (halfWidth + 0.42), 0.1, z + 0.95)
			limb(ctx, "LegFemur", hip, knee, d * 2.6, femurRole, tint)
			limb(ctx, "LegTibia", knee, ankle, d * 0.9, "Secondary")
			limb(ctx, "LegTarsus", ankle, at(ctx, side * (halfWidth + 0.45), 0.03, z + 0.55), d * 0.6, tarsusRole, tint)
		elseif style == "Oars" and isHind then
			-- Dytique/Notonecte/Punaise : tibia en rame aplatie + frange de soies natatoires.
			local reach = plan.LegLength
			knee = at(ctx, side * (halfWidth + 0.4 * reach), hipY, z + 0.2)
			ankle = at(ctx, side * (halfWidth + 0.85 * reach), hipY - 0.05, z + 0.85 * reach)
			limb(ctx, "LegFemur", hip, knee, d * 1.2, femurRole, tint)
			wing(ctx, "LegTibia", knee, ankle, 0.2, "Secondary", 0, 0, nil, 0.06)
			wing(ctx, "LegTarsus", knee:Lerp(ankle, 0.35), ankle + (ankle - knee) * 0.25, 0.36, "Dark", 0.55, 0)
		else
			knee = at(ctx, side * (halfWidth + span * 0.45), hipY + kneeUp, z + spreadZ * 0.3)
			ankle = at(ctx, side * (halfWidth + span * 0.92), 0.12, z + spreadZ * 0.9)
			limb(ctx, "LegFemur", hip, knee, d * 1.15, femurRole, tint)
			limb(ctx, "LegTibia", knee, ankle, d * 0.8, tibiaRole, tint)
			limb(ctx, "LegTarsus", ankle, at(ctx, side * (halfWidth + span * 1.08), 0.03, z + spreadZ - 0.1), d * 0.55, tarsusRole, tint)
		end
		if legColor == "Striped" then
			ellipsoid(ctx, "LegBand", hip:Lerp(knee, 0.55), Vector3.one * d * 1.9, "Raw", nil, nil, tint)
		end
		if plan.PollenBaskets and isHind then
			ellipsoid(ctx, "PollenBasket", knee:Lerp(ankle, 0.45), Vector3.new(0.2, 0.26, 0.2), "Raw", nil, nil, Color3.fromRGB(245, 200, 40))
		end
	end
	setAnim(ctx, nil)
end

local function buildFrontLimbs(ctx: Ctx, L: Layout)
	local kind = ctx.plan.FrontLimbs
	if kind == "None" then
		return
	end
	local s = ctx.s
	local frontZ = L.thoraxZ - L.thoraxLen / 2
	for _, side in ipairs(SIDES) do
		local shoulder = at(ctx, side * L.thoraxW * 0.4, L.H + 0.05, frontZ + 0.1)
		setAnim(ctx, "Claw", side, 1, shoulder)
		if kind == "Raptorial" then
			-- Mante : pattes ravisseuses repliées "en prière", tibia garni d'épines.
			local elbow = at(ctx, side * L.thoraxW * 0.45, L.H + 0.45, frontZ - 0.55)
			local wrist = at(ctx, side * L.thoraxW * 0.35, L.H - 0.15, frontZ - 0.35)
			limb(ctx, "RaptorFemur", shoulder, elbow, 0.16, "Primary")
			limb(ctx, "RaptorTibia", elbow, wrist, 0.1, "Secondary")
			limb(ctx, "RaptorHook", wrist, wrist + Vector3.new(0, -0.05, 0.2) * s, 0.05, "Dark")
			for i = 1, 3 do
				local spikeBase = elbow:Lerp(wrist, i / 4)
				limb(ctx, "RaptorSpike", spikeBase, spikeBase + Vector3.new(0, -0.04, 0.12) * s, 0.03, "Dark")
			end
		elseif kind == "Pincers" then
			-- Scorpion : bras + grosse pince à deux doigts.
			local elbow = at(ctx, side * (L.thoraxW * 0.5 + 0.45), L.H + 0.05, frontZ - 0.35)
			local hand = at(ctx, side * (L.thoraxW * 0.5 + 0.35), L.H + 0.05, frontZ - 0.9)
			limb(ctx, "PincerArm", shoulder, elbow, 0.13, "Primary")
			limb(ctx, "PincerArm", elbow, hand, 0.13, "Primary")
			ellipsoid(ctx, "PincerHand", hand, Vector3.new(0.38, 0.26, 0.5), "Primary")
			local fingerBase = hand + Vector3.new(0, 0, -0.18) * s
			limb(ctx, "PincerFinger", fingerBase + Vector3.new(side * 0.08, 0, 0) * s, fingerBase + Vector3.new(side * 0.1, 0, -0.42) * s, 0.1, "Secondary")
			limb(ctx, "PincerFinger", fingerBase + Vector3.new(-side * 0.08, 0, 0) * s, fingerBase + Vector3.new(-side * 0.02, 0, -0.4) * s, 0.08, "Secondary")
		elseif kind == "WaterGrabbers" then
			-- Nèpe / Punaise d'eau : pattes avant épaisses en piège à loup.
			local elbow = at(ctx, side * (L.thoraxW * 0.5 + 0.25), L.H + 0.1, frontZ - 0.5)
			local claw = at(ctx, side * (L.thoraxW * 0.3), L.H - 0.05, frontZ - 0.85)
			limb(ctx, "GrabberFemur", shoulder, elbow, 0.18, "Primary")
			limb(ctx, "GrabberTibia", elbow, claw, 0.1, "Secondary")
			limb(ctx, "GrabberClaw", claw, claw + Vector3.new(-side * 0.12, -0.04, 0.12) * s, 0.05, "Dark")
		end
	end
	setAnim(ctx, nil)
end

local function buildTail(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local kind = plan.Tail
	if kind == "None" then
		return
	end
	local tailZ = L.abdZ + L.abdLen / 2
	local tailY = L.H
	local len = plan.TailLength
	local base = at(ctx, 0, tailY, tailZ - 0.05)
	if kind == "Stinger" then
		-- Petites pièces solidaires de l'abdomen : même étiquette et même pivot que lui.
		setAnim(ctx, "Abdomen", 0, 8, abdomenPivot(ctx, L))
		limb(ctx, "Stinger", base, at(ctx, 0, tailY - 0.08, tailZ + 0.3), 0.06, "Dark")
	elseif kind == "Spinnerets" then
		setAnim(ctx, "Abdomen", 0, 8, abdomenPivot(ctx, L))
		for _, side in ipairs(SIDES) do
			limb(ctx, "Spinneret", at(ctx, side * 0.07, tailY - 0.05, tailZ - 0.06), at(ctx, side * 0.1, tailY - 0.12, tailZ + 0.1), 0.09, "Secondary")
		end
	elseif kind == "ScorpionTail" then
		-- Queue segmentée qui remonte en arc au-dessus du dos, terminée par le dard.
		local previous = at(ctx, 0, tailY, tailZ - 0.1)
		for i = 1, 5 do
			local angle = i / 5 * math.pi * 0.85
			local point = at(ctx, 0, tailY + math.sin(angle) * 1.1, tailZ + math.cos(angle) * 0.75 - 0.1)
			setAnim(ctx, "Tail", 0, i, base)
			limb(ctx, "TailSegment", previous, point, 0.26 - i * 0.02, "Primary")
			previous = point
		end
		setAnim(ctx, "Tail", 0, 6, base)
		ellipsoid(ctx, "Telson", previous, Vector3.new(0.28, 0.28, 0.36), "Secondary")
		limb(ctx, "Sting", previous, previous + Vector3.new(0, -0.18, -0.32) * ctx.s, 0.05, "Dark")
	elseif kind == "Siphon" then
		-- Tuba respiratoire : très long chez la nèpe, court chez la punaise d'eau géante.
		for _, side in ipairs(SIDES) do
			setAnim(ctx, "Tail", side, 1, base)
			limb(ctx, "Siphon", at(ctx, side * 0.05, tailY, tailZ - 0.05), at(ctx, side * 0.07, tailY + 0.12 * len, tailZ + 0.95 * len), 0.045, "Dark")
		end
	elseif kind == "Cerci" then
		-- Éphémère : 3 longs filaments.
		for i = -1, 1 do
			setAnim(ctx, "Tail", i, 1, base)
			limb(ctx, "Cercus", base, at(ctx, i * 0.35 * len, tailY + 0.35, tailZ + 1.3 * len), 0.03, "Accent")
		end
	end
	setAnim(ctx, nil)
end

local function buildWings(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local kind = plan.Wings
	local s = ctx.s
	local topY = L.H + 0.05 + L.thoraxH * 0.45
	local rootZ = L.thoraxZ + L.thoraxLen * 0.1
	if kind == "Membrane" then
		-- Hyménoptères : 2 paires d'ailes nervurées, repliées en arrière au-dessus de l'abdomen.
		local span = 1.1 + L.abdLen * 0.45
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.12, topY, rootZ)
			setAnim(ctx, "Wing", side, 1, a)
			wing(ctx, "Wing", a, at(ctx, side * (0.12 + span * 0.38), topY + 0.12, rootZ + span * 0.92), 0.5, "Wing", 0.45, 3)
			local a2 = at(ctx, side * 0.14, topY - 0.03, rootZ + 0.18)
			setAnim(ctx, "Wing", side, 2, a2)
			wing(ctx, "Wing", a2, at(ctx, side * (0.14 + span * 0.42), topY + 0.04, rootZ + 0.18 + span * 0.6), 0.36, "Wing", 0.5, 1)
		end
	elseif kind == "Mosquito" or kind == "Fly" then
		-- Diptères : une seule paire. Étroite et repliée (moustique) ou large en delta (taon).
		local fly = kind == "Fly"
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.12, topY, rootZ)
			local b = if fly then at(ctx, side * 0.95, topY + 0.08, rootZ + 1.0) else at(ctx, side * 0.42, topY + 0.1, rootZ + 1.3)
			setAnim(ctx, "Wing", side, 1, a)
			wing(ctx, "Wing", a, b, if fly then 0.58 else 0.3, "Wing", 0.45, if fly then 3 else 1)
		end
	elseif kind == "Dragonfly" then
		-- 4 longues ailes horizontales : nervure costale + ptérostigma sombre près de la pointe.
		for pairIndex = 1, 2 do
			local z = rootZ - 0.15 + (pairIndex - 1) * 0.32
			local sweep = if pairIndex == 1 then -0.12 else 0.12
			for _, side in ipairs(SIDES) do
				local a = at(ctx, side * 0.1, topY, z)
				local b = at(ctx, side * 2.15, topY + 0.08, z + sweep)
				setAnim(ctx, "Wing", side, pairIndex, a)
				wing(ctx, "Wing", a, b, if pairIndex == 1 then 0.36 else 0.44, "Wing", 0.5, 1)
				ellipsoid(ctx, "Pterostigma", a:Lerp(b, 0.86) + Vector3.new(0, 0, -0.1) * s, Vector3.new(0.24, 0.05, 0.09), "Dark")
			end
		end
	elseif kind == "Butterfly" then
		-- Monarque : ailes en V, bordure noire, panneau orange, nervures noires, points blancs.
		local dihedral = math.rad(35)
		for pairIndex = 1, 2 do
			local fore = pairIndex == 1
			local span = if fore then 1.65 else 1.2
			local chord = if fore then 1.1 else 0.95
			local z = rootZ + (if fore then -0.1 else 0.5)
			local sweep = if fore then -0.3 else 0.35
			local dots = if fore then 3 else 2
			for _, side in ipairs(SIDES) do
				local a = at(ctx, side * 0.08, topY, z)
				local b = a + Vector3.new(side * math.cos(dihedral) * span, math.sin(dihedral) * span, sweep) * s
				setAnim(ctx, "Wing", side, pairIndex, a)
				local cf = wing(ctx, "WingBorder", a, b, chord * 1.1, "Dark", 0, 0, nil, 0.035)
				wing(ctx, "Wing", a:Lerp(b, 0.03), a:Lerp(b, 0.93), chord * 0.92, "Wing", 0, dots, nil, 0.05)
				for k = 1, dots do
					local u = (k - (dots + 1) / 2) * 0.3
					local along = 0.965 - math.abs(u) / 0.3 * 0.095
					ellipsoid(ctx, "WingDot", a:Lerp(b, along) + cf.RightVector * (u * chord * s), Vector3.one * 0.11, "Accent")
				end
			end
		end
	elseif kind == "Mayfly" then
		-- Éphémère : grandes ailes antérieures dressées à la verticale + minuscules postérieures.
		for _, side in ipairs(SIDES) do
			local normal = Vector3.new(side, 0, 0)
			local a = at(ctx, side * 0.06, topY, rootZ)
			setAnim(ctx, "Wing", side, 1, a)
			wing(ctx, "Wing", a, at(ctx, side * 0.24, topY + 1.45, rootZ + 0.55), 0.75, "Wing", 0.4, 3, normal)
			local a2 = at(ctx, side * 0.06, topY, rootZ + 0.3)
			setAnim(ctx, "Wing", side, 2, a2)
			wing(ctx, "Wing", a2, at(ctx, side * 0.2, topY + 0.6, rootZ + 0.72), 0.35, "Wing", 0.45, 0, normal)
		end
	elseif kind == "Elytra" then
		-- Coléoptères : deux demi-coques rigides et brillantes sur l'abdomen, strie + suture.
		local role = (plan.ElytraColor :: any) :: Role
		local frontZ = L.abdZ - L.abdLen / 2
		local cy = L.H + L.abdH * 0.18
		local cz = L.abdZ - 0.03
		local rx, ry, rz = L.abdW * 0.3, L.abdH * 0.45, L.abdLen * 0.54
		for _, side in ipairs(SIDES) do
			local cx = side * L.abdW * 0.24
			setAnim(ctx, "Elytron", side, 1, at(ctx, side * L.abdW * 0.2, L.H + L.abdH * 0.35, frontZ))
			local shell = ellipsoid(ctx, "Elytron", at(ctx, cx, cy, cz), Vector3.new(rx * 2, ry * 2, rz * 2), role)
			if plan.Metallic then
				shell.Reflectance = 0.32 -- carapace vernie
			end
			-- Strie : tranche fine épousant la coupe de l'élytre (dépasse à peine de sa surface).
			ellipsoid(ctx, "ElytronStria", at(ctx, cx + side * rx * 0.33, cy, cz), Vector3.new(0.03, ry * 1.886 + 0.02, rz * 1.886 + 0.02), "Dark")
			if plan.Spots then
				for k = 1, 3 do
					local dx = if k == 2 then -0.05 else 0.1
					local dz = (k - 2) * 0.28
					local h = math.sqrt(math.max(0.05, 1 - (dx * L.abdW / rx) ^ 2 - (dz * L.abdLen / rz) ^ 2))
					ellipsoid(ctx, "Spot", at(ctx, cx + side * dx * L.abdW, cy + ry * h - 0.02, cz + dz * L.abdLen), Vector3.new(0.16, 0.1, 0.16), "Accent")
				end
			end
		end
		setAnim(ctx, "Abdomen", 0, 8, abdomenPivot(ctx, L))
		ellipsoid(ctx, "ElytraSeam", at(ctx, 0, cy, cz), Vector3.new(0.035, ry * 1.2 + 0.03, rz * 1.2 + 0.03), "Dark")
		if plan.ElytraRim then
			-- Liseré clair qui dépasse sous le bord des élytres (dytique bordé, luciole).
			ellipsoid(ctx, "ElytraRim", at(ctx, 0, L.H + L.abdH * 0.05, cz), Vector3.new(L.abdW * 1.2, L.abdH * 0.3, L.abdLen * 1.14), "Accent")
		end
	elseif kind == "Folded" then
		-- Ailes repliées à plat sur le dos, l'une chevauchant l'autre (mante, sauterelle, punaises).
		local top = L.H + L.abdH * 0.5 + 0.02
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * L.abdW * 0.18, top + side * 0.012, L.abdZ - L.abdLen * 0.55)
			setAnim(ctx, "Wing", side, 1, a)
			wing(ctx, "Wing", a, at(ctx, side * L.abdW * 0.1, top + side * 0.012, L.abdZ + L.abdLen * 0.55), L.abdW * 0.66, "Wing", 0.15, 1, nil, 0.06)
		end
	elseif kind == "Tent" then
		-- Ailes en toit au-dessus de l'abdomen (cigale nervurée, phrygane velue et opaque).
		local ridgeY = L.H + L.abdH * 0.5 + 0.12
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.05, ridgeY, L.thoraxZ)
			setAnim(ctx, "Wing", side, 1, a)
			wing(ctx, "Wing", a, at(ctx, side * L.abdW * 0.5, L.H + 0.02, L.abdZ + L.abdLen * 0.75), L.abdW * 0.85, "Wing", if plan.Fuzzy then 0.1 else 0.3, 3, Vector3.new(side * 0.62, 0.78, 0))
		end
	end
	setAnim(ctx, nil)
end

-- Nymphes d'espèces ailées : simples fourreaux alaires sur le thorax.
local function buildWingBuds(ctx: Ctx, L: Layout)
	if ctx.plan.Wings == "None" then
		return
	end
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "WingBud", at(ctx, side * L.thoraxW * 0.3, L.H + 0.05 + L.thoraxH * 0.42, L.thoraxZ + L.thoraxLen * 0.35), Vector3.new(0.24, 0.08, 0.42), "Secondary")
	end
end

local function buildThorax(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local W = L.thoraxW
	ellipsoid(ctx, "Thorax", at(ctx, 0, L.H + 0.05, L.thoraxZ), Vector3.new(W, L.thoraxH, L.thoraxLen), "Primary")
	if plan.Pronotum == "Shield" then
		-- Coléoptères : large bouclier bombé qui recouvre le thorax.
		local width = math.max(W * 1.2, L.abdW * 0.92)
		local shield = ellipsoid(ctx, "Pronotum", at(ctx, 0, L.H + 0.1, L.thoraxZ - L.thoraxLen * 0.05), Vector3.new(width, L.thoraxH * 0.95, L.thoraxLen * 1.05), (plan.PronotumColor :: any) :: Role)
		if plan.Metallic then
			shield.Reflectance = 0.32
		end
		if plan.ElytraRim then
			ellipsoid(ctx, "PronotumRim", at(ctx, 0, L.H + 0.03, L.thoraxZ - L.thoraxLen * 0.05), Vector3.new(width * 1.08, L.thoraxH * 0.28, L.thoraxLen * 1.1), "Accent")
		end
	elseif plan.Pronotum == "Saddle" then
		-- Sauterelle : pronotum en selle, haut et étroit.
		ellipsoid(ctx, "Pronotum", at(ctx, 0, L.H + 0.14, L.thoraxZ - L.thoraxLen * 0.15), Vector3.new(W * 1.05, L.thoraxH * 1.2, L.thoraxLen * 0.75), "Secondary")
	end
	if plan.Waist then
		ellipsoid(ctx, "Petiole", at(ctx, 0, L.H, L.thoraxZ + L.thoraxLen / 2 + 0.11), Vector3.new(0.2, 0.2, 0.26), "Secondary")
		if plan.Wings == "None" then
			-- Fourmi : écaille dressée sur le pétiole.
			ellipsoid(ctx, "PetioleNode", at(ctx, 0, L.H + 0.12, L.thoraxZ + L.thoraxLen / 2 + 0.11), Vector3.new(0.16, 0.24, 0.1), "Primary")
		end
	end
	if plan.Fuzzy then
		-- Touffes de poils en éventail sur le dos du thorax.
		for i = 1, 5 do
			local a = (i - 3) * 0.6
			local z = L.thoraxZ + (if i % 2 == 0 then 0.14 else -0.1) * L.thoraxLen
			ellipsoid(ctx, "HairTuft", at(ctx, math.sin(a) * W * 0.42, L.H + 0.05 + math.cos(a) * L.thoraxH * 0.44, z), Vector3.new(0.3, 0.3, 0.38), "Primary")
		end
	end
end

-- Abdomen segmenté : tergites ovales qui se chevauchent (rayures = couleur alternée des segments).
-- `covered` = caché sous des élytres : un seul volume suffit.
local function buildAbdomen(ctx: Ctx, L: Layout, covered: boolean)
	local plan = ctx.plan
	local pivot = abdomenPivot(ctx, L)
	if covered then
		setAnim(ctx, "Abdomen", 0, 1, pivot)
		ellipsoid(ctx, "Abdomen", at(ctx, 0, L.H - 0.02, L.abdZ), Vector3.new(L.abdW * 0.95, L.abdH * 0.9, L.abdLen), "Primary")
		setAnim(ctx, nil)
		return
	end
	local slender = plan.AbdomenLength > 1.4 -- libellule, éphémère : baguette qui s'affine
	local count = if plan.AbdomenLength >= 2 then 7 else 5
	local alternate = plan.Stripes and plan.StripeStyle == "Alternate"
	local rearBand = plan.Stripes and plan.StripeStyle == "RearBand"
	local baseRole: Role = if alternate then "Primary" elseif plan.Waist then "Secondary" else "Primary"
	local frontZ = L.abdZ - L.abdLen / 2
	local step = L.abdLen / count
	for i = 1, count do
		local t = (i - 0.5) / count
		local f = if slender then 1 - 0.35 * t else math.sin(math.pi * (0.12 + 0.8 * t)) ^ 0.6
		local role = baseRole
		if (alternate and i % 2 == 0) or (rearBand and i == count - 1) then
			role = "Accent"
		end
		setAnim(ctx, "Abdomen", 0, i, pivot)
		ellipsoid(ctx, "AbdomenSegment", at(ctx, 0, L.H - (1 - f) * L.abdH * 0.15, frontZ + (i - 0.5) * step), Vector3.new(L.abdW * f, L.abdH * f, step * 1.45), role)
	end
	setAnim(ctx, nil)
end

local function buildGlowAndBubble(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	if not plan.Glow and not plan.Bubble then
		return
	end
	setAnim(ctx, "Abdomen", 0, 8, abdomenPivot(ctx, L))
	if plan.Glow then
		-- Luciole : lanterne sous l'arrière de l'abdomen.
		local lantern = ellipsoid(ctx, "Lantern", at(ctx, 0, L.H - L.abdH * 0.22, L.abdZ + L.abdLen * 0.3), Vector3.new(L.abdW * 0.8, L.abdH * 0.75, L.abdLen * 0.48), "Accent")
		lantern.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Color = plan.Accent
		light.Range = 16
		light.Brightness = 1.6
		light.Shadows = false
		light.Parent = lantern
	end
	if plan.Bubble then
		local bubble: Part
		if plan.Shape == "Spider" then
			-- Argyronète : cloche d'air argentée qui enveloppe l'abdomen.
			bubble = ellipsoid(ctx, "AirBubble", at(ctx, 0, L.H + 0.05, L.abdZ + L.abdLen * 0.1), Vector3.new(L.abdW * 1.5, L.abdW * 1.3, L.abdLen * 1.25), "Raw", nil, 0.6, Color3.fromRGB(220, 235, 255))
		else
			-- Dytique : bulle d'air accrochée au bout de l'abdomen.
			bubble = ellipsoid(ctx, "AirBubble", at(ctx, 0, L.H, L.abdZ + L.abdLen * 0.52), Vector3.one * L.abdW * 0.6, "Raw", nil, 0.55, Color3.fromRGB(220, 235, 255))
		end
		bubble.Material = Enum.Material.Glass
		bubble.Reflectance = 0.3
	end
	setAnim(ctx, nil)
end

-- ============================================================
-- Corps par forme
-- ============================================================

local function buildInsectBody(ctx: Ctx, L: Layout, withWings: boolean)
	local plan = ctx.plan
	buildHead(ctx, L)
	buildThorax(ctx, L)
	buildAbdomen(ctx, L, withWings and plan.Wings == "Elytra")

	local pairCount = math.max(1, math.floor(plan.Legs / 2))
	local firstPair = if plan.FrontLimbs ~= "None" and plan.Legs == 6 then 2 else 1
	for i = firstPair, pairCount do
		local t = if pairCount == 1 then 0.5 else (i - 1) / (pairCount - 1)
		local z = L.thoraxZ - L.thoraxLen * 0.35 + t * L.thoraxLen * 0.7
		buildLegPair(ctx, L, i, pairCount, z, L.H - 0.1, L.thoraxW * 0.4)
	end

	buildFrontLimbs(ctx, L)
	buildEyes(ctx, L)
	buildAntennae(ctx, L)
	buildJaws(ctx, L)
	buildHorn(ctx, L)
	buildTail(ctx, L)
	if withWings then
		buildWings(ctx, L)
	else
		buildWingBuds(ctx, L)
	end
	buildGlowAndBubble(ctx, L)
end

local function buildSpiderBody(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local hs = plan.HeadSize
	-- Céphalothorax (porte les 8 pattes) + région des yeux surélevée + gros abdomen arrondi.
	local cephZ = L.headZ + L.headR * 0.4
	ellipsoid(ctx, "Cephalothorax", at(ctx, 0, L.H + 0.05, cephZ), Vector3.new(0.85, 0.6, 1.0) * hs, "Primary")
	ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.14, cephZ - 0.28 * hs), Vector3.new(0.62, 0.5, 0.5) * hs, "Primary")

	-- Layout de l'abdomen (un peu plus haut et plus court) : sert aussi de pivot commun.
	local LA = table.clone(L)
	LA.H = L.H + 0.1
	LA.abdLen = L.abdLen * 0.95
	local abdY = L.H + 0.15
	local rx, ry, rz = L.abdW * 0.575, L.abdW * 0.475, LA.abdLen / 2
	-- Pédicelle : relie le céphalothorax à l'abdomen (sinon un vide est visible entre les deux).
	local cephBack = cephZ + 0.5 * hs
	local abdFront = L.abdZ - rz
	ellipsoid(ctx, "Pedicel", at(ctx, 0, L.H + 0.08, (cephBack + abdFront) / 2), Vector3.new(0.3, 0.3, math.max(0.3, abdFront - cephBack + 0.3)), "Primary")

	setAnim(ctx, "Abdomen", 0, 1, abdomenPivot(ctx, LA))
	local abdomen = ellipsoid(ctx, "Abdomen", at(ctx, 0, abdY, L.abdZ), Vector3.new(rx * 2, ry * 2, rz * 2), "Secondary")
	if plan.Metallic then
		abdomen.Reflectance = 0.3 -- veuve noire : abdomen laqué
	end
	if plan.Spots then
		-- Veuve noire : sablier rouge (deux losanges pointe contre pointe).
		for _, dz in ipairs({ -0.13, 0.13 }) do
			addPart(ctx, "Hourglass", Vector3.new(0.2, 0.06, 0.2) * ctx.s, CFrame.new(at(ctx, 0, abdY + ry - 0.015, L.abdZ + dz)) * CFrame.Angles(0, math.rad(45), 0), "Accent", "Block")
		end
	end
	if plan.Stripes then
		-- Araignée sauteuse : bandes claires (tranches épousant la coupe de l'abdomen).
		for _, t in ipairs({ -0.4, 0.3 }) do
			local f = math.sqrt(1 - t * t)
			ellipsoid(ctx, "Band", at(ctx, 0, abdY, L.abdZ + t * rz), Vector3.new(rx * 2 * f + 0.03, ry * 2 * f + 0.03, 0.1), "Accent")
		end
	end
	if plan.Fuzzy then
		for i = 1, 4 do
			local side = if i % 2 == 0 then 1 else -1
			local t = if i <= 2 then 0.15 else 0.55
			ellipsoid(ctx, "HairTuft", at(ctx, side * rx * 0.4, abdY + ry * 0.7, L.abdZ + t * rz), Vector3.new(0.28, 0.28, 0.34), "Secondary")
		end
	end
	setAnim(ctx, nil)

	for i = 1, 4 do
		local z = cephZ - 0.35 + (i - 1) * 0.23
		buildLegPair(ctx, L, i, 4, z, L.H, 0.3)
	end
	buildEyes(ctx, withHead(L, L.H, cephZ - 0.1, 0.42 * hs))
	buildJaws(ctx, withHead(L, L.H, cephZ, 0.5 * hs))
	buildTail(ctx, LA)
	buildGlowAndBubble(ctx, LA)
end

local function buildDomeBody(ctx: Ctx, L: Layout, withWings: boolean)
	-- Coccinelle : petite tête sombre, pronotum à taches blanches, dôme de deux élytres à 7 points.
	local plan = ctx.plan
	local domeZ = L.thoraxZ + 0.2
	local baseY = L.H + 0.1
	ellipsoid(ctx, "Head", at(ctx, 0, L.H - 0.05, domeZ - 0.85), Vector3.new(0.5, 0.35, 0.4), "Dark")
	ellipsoid(ctx, "Pronotum", at(ctx, 0, L.H + 0.02, domeZ - 0.62), Vector3.new(0.75, 0.4, 0.4), "Dark")
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "PronotumSpot", at(ctx, side * 0.24, L.H + 0.12, domeZ - 0.62), Vector3.new(0.18, 0.12, 0.16), "Raw", nil, nil, WHITE)
	end
	ellipsoid(ctx, "Abdomen", at(ctx, 0, L.H - 0.08, domeZ), Vector3.new(1.15, 0.5, 1.2), "Dark")

	local shellRole: Role = if withWings then "Primary" else "Larva"
	local rx, ry, rz = 0.45, 0.475, 0.675
	local spots = { { 0.42, -0.22 }, { 0.2, 0.08 }, { 0.38, 0.38 } }
	for _, side in ipairs(SIDES) do
		setAnim(ctx, "Elytron", side, 1, at(ctx, side * 0.15, baseY + 0.3, domeZ - 0.6))
		local shell = ellipsoid(ctx, "Elytron", at(ctx, side * 0.2, baseY, domeZ), Vector3.new(rx * 2, ry * 2, rz * 2), shellRole)
		if plan.Metallic then
			shell.Reflectance = 0.32
		end
		if plan.Spots then
			for _, offset in ipairs(spots) do
				local h = math.sqrt(math.max(0.05, 1 - ((offset[1] - 0.2) / rx) ^ 2 - (offset[2] / rz) ^ 2))
				ellipsoid(ctx, "Spot", at(ctx, side * offset[1], baseY + ry * h - 0.02, domeZ + offset[2]), Vector3.new(0.2, 0.12, 0.2), "Accent")
			end
		end
	end
	setAnim(ctx, nil)
	-- Suture entre les élytres + 7e point "scutellaire" à cheval sur la suture, à l'avant.
	ellipsoid(ctx, "Seam", at(ctx, 0, baseY, domeZ), Vector3.new(0.035, ry * 1.792 + 0.02, rz * 1.792 + 0.02), "Dark")
	if plan.Spots then
		ellipsoid(ctx, "Spot", at(ctx, 0, baseY + 0.23, domeZ - 0.5), Vector3.new(0.24, 0.12, 0.2), "Accent")
	end

	for i = 1, 3 do
		buildLegPair(ctx, L, i, 3, domeZ - 0.4 + (i - 1) * 0.3, L.H - 0.15, 0.35)
	end
	buildAntennae(ctx, withHead(L, L.H - 0.15, domeZ - 0.85, 0.25))
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.17, L.H, domeZ - 1.0), Vector3.one * 0.1, "Shine")
	end
end

local function buildCentipedeBody(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local count = math.max(6, plan.Segments)
	local segmentLength = 0.32
	local totalLength = count * segmentLength
	local startZ = -totalLength / 2
	ellipsoid(ctx, "Head", at(ctx, 0, 0.3, startZ - 0.2), Vector3.new(0.6, 0.3, 0.45), "Primary")
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.24, 0.36, startZ - 0.3), Vector3.one * 0.09, "Eye")
	end
	buildAntennae(ctx, withHead(L, 0.15, startZ - 0.2, 0.25))
	buildJaws(ctx, withHead(L, 0.3, startZ - 0.15, 0.3)) -- forcipules venimeuses
	for i = 1, count do
		local z = startZ + (i - 0.5) * segmentLength
		local wave = math.sin(i * 0.9) * 0.06 -- légère ondulation ("course sinueuse")
		local role: Role = if i % 2 == 0 then "Primary" else "Secondary"
		local center = at(ctx, wave, 0.3, z)
		-- Tergite : plaque dorsale aplatie qui chevauche la suivante.
		setAnim(ctx, "Segment", 0, i, center)
		ellipsoid(ctx, "Segment", center, Vector3.new(0.64, 0.26, segmentLength * 1.3), role)
		for _, side in ipairs(SIDES) do
			local hip = at(ctx, wave + side * 0.28, 0.28, z)
			local knee = at(ctx, wave + side * 0.6, 0.4, z + 0.05)
			local foot = at(ctx, wave + side * 0.88, 0.02, z + 0.12)
			setAnim(ctx, "Leg", side, i, hip)
			limb(ctx, "LegFemur", hip, knee, 0.06, "Accent")
			limb(ctx, "LegTibia", knee, foot, 0.045, "Accent")
		end
	end
	-- Dernière paire de pattes, traînante, tournée vers l'arrière.
	local tailZ = startZ + totalLength
	for _, side in ipairs(SIDES) do
		local base = at(ctx, side * 0.15, 0.3, tailZ)
		setAnim(ctx, "Tail", side, 1, base)
		limb(ctx, "TailLeg", base, at(ctx, side * 0.38, 0.22, tailZ + 0.65), 0.07, "Accent")
	end
	setAnim(ctx, nil)
end

local function buildStickBody(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local frontZ = L.headZ
	local tipZ = L.abdZ + L.abdLen / 2
	local thoraxEnd = at(ctx, 0, L.H, L.thoraxZ + L.thoraxLen / 2)
	ellipsoid(ctx, "Head", at(ctx, 0, L.H, frontZ), Vector3.new(0.26, 0.24, 0.36), "Primary")
	limb(ctx, "Thorax", at(ctx, 0, L.H, frontZ + 0.15), thoraxEnd, 0.2, "Primary")
	setAnim(ctx, "Abdomen", 0, 1, thoraxEnd)
	limb(ctx, "Abdomen", thoraxEnd, at(ctx, 0, L.H + 0.08, tipZ), 0.17, "Secondary")
	-- Petites excroissances "bourgeons" qui complètent le mimétisme de brindille.
	for i = 1, 3 do
		local base = at(ctx, 0, L.H + 0.08, L.abdZ - L.abdLen * 0.3 + i * L.abdLen * 0.2)
		limb(ctx, "Twig", base, base + Vector3.new(if i % 2 == 0 then 0.12 else -0.12, 0.15, 0.05) * ctx.s, 0.05, "Secondary")
	end
	setAnim(ctx, nil)
	for i = 1, 3 do
		local z = L.thoraxZ - L.thoraxLen * 0.4 + (i - 1) * L.thoraxLen * 0.4
		-- Noeud de "brindille" à chaque insertion de pattes.
		ellipsoid(ctx, "Node", at(ctx, 0, L.H, z), Vector3.new(0.27, 0.27, 0.2), "Secondary")
		buildLegPair(ctx, L, i, 3, z, L.H, 0.08)
	end
	buildAntennae(ctx, withHead(L, L.H - 0.1, frontZ, 0.15))
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.11, L.H + 0.04, frontZ - 0.05), Vector3.one * 0.08, "Eye")
	end
	if plan.Tail ~= "None" then
		buildTail(ctx, L)
	end
end

local function buildAdult(ctx: Ctx, withWings: boolean)
	local plan = ctx.plan
	local L = computeLayout(plan)
	if plan.Shape == "Spider" then
		buildSpiderBody(ctx, L)
	elseif plan.Shape == "Centipede" then
		buildCentipedeBody(ctx, L)
	elseif plan.Shape == "Stick" then
		buildStickBody(ctx, L)
	elseif plan.Shape == "Dome" then
		buildDomeBody(ctx, L, withWings)
	else
		buildInsectBody(ctx, L, withWings)
	end
	setAnim(ctx, nil)
end

-- ============================================================
-- Oeuf, larves, cocon
-- ============================================================

-- Segment de larve : étiqueté "Segment" avec son propre centre pour pivot (ondulation).
local function segment(ctx: Ctx, name: string, index: number, center: Vector3, size: Vector3, role: Role, rotation: CFrame?, raw: Color3?): Part
	setAnim(ctx, "Segment", 0, index, center)
	return ellipsoid(ctx, name, center, size, role, rotation, nil, raw)
end

-- Paire de petites pattes de larve (2 segments), étiquetée "Leg".
local function larvaLegPair(ctx: Ctx, index: number, z: number, hipX: number, reach: number, role: Role)
	local sweep = (index - 2) * 0.15
	for _, side in ipairs(SIDES) do
		local hip = at(ctx, side * hipX, 0.24, z)
		local knee = at(ctx, side * (hipX + reach * 0.55), 0.34, z + sweep * 0.5)
		setAnim(ctx, "Leg", side, index, hip)
		limb(ctx, "LegFemur", hip, knee, 0.06, role)
		limb(ctx, "LegTibia", knee, at(ctx, side * (hipX + reach), 0.02, z + sweep), 0.045, "Dark")
	end
	setAnim(ctx, nil)
end

local function buildEgg(ctx: Ctx)
	local plan = ctx.plan
	if plan.Shape == "Spider" then
		-- Cocon ovigère : boule de soie retenue par quelques fils.
		local sac = ellipsoid(ctx, "Egg", at(ctx, 0, 0.6, 0), Vector3.one * 1.0, "Raw", nil, nil, Color3.fromRGB(240, 236, 225))
		sac.Material = Enum.Material.Fabric
		for i = 1, 4 do
			local angle = i * math.pi / 2 + 0.4
			limb(ctx, "SilkThread", at(ctx, math.cos(angle) * 0.4, 0.6, math.sin(angle) * 0.4), at(ctx, math.cos(angle) * 1.0, 0.02, math.sin(angle) * 1.0), 0.03, "Shine")
		end
		return
	end
	local color = plan.LarvaColor:Lerp(WHITE, 0.55)
	local center = at(ctx, 0, 0.55, 0)
	ellipsoid(ctx, "Egg", center, Vector3.new(0.75, 1.05, 0.75), "Raw", nil, nil, color)
	ellipsoid(ctx, "EggShine", at(ctx, 0.15, 0.8, -0.2), Vector3.new(0.15, 0.25, 0.1), "Shine", nil, 0.4)
	if plan.Larva == "AquaticNymph" or plan.Larva == "Wiggler" or plan.Larva == "CaseLarva" then
		-- Ponte aquatique : oeuf pris dans une gangue de gelée.
		local jelly = ellipsoid(ctx, "EggJelly", center, Vector3.new(1.15, 1.3, 1.15), "Raw", nil, 0.7, Color3.fromRGB(200, 230, 240))
		jelly.Material = Enum.Material.Glass
		return
	end
	if plan.Larva == "Caterpillar" then
		-- Oeuf de papillon : côtes verticales.
		for i = 1, 4 do
			ellipsoid(ctx, "EggRib", center, Vector3.new(0.78, 1.07, 0.05), "Raw", CFrame.Angles(0, i * math.pi / 4, 0), nil, color:Lerp(DARK, 0.2))
		end
	else
		-- Mouchetures.
		local speckle = plan.LarvaColor:Lerp(DARK, 0.4)
		for k = 1, 3 do
			local dy = (k - 2) * 0.2
			local ring = 0.375 * math.sqrt(1 - (dy / 0.525) ^ 2)
			ellipsoid(ctx, "EggSpeckle", at(ctx, math.cos(k * 2.1) * ring, 0.55 + dy, math.sin(k * 2.1) * ring), Vector3.one * 0.1, "Raw", nil, nil, speckle)
		end
	end
	-- Feuille sur laquelle l'oeuf est pondu.
	ellipsoid(ctx, "EggPad", at(ctx, 0, 0.04, 0), Vector3.new(1.3, 0.08, 1.5), "Raw", nil, nil, Color3.fromRGB(110, 150, 70))
end

local function buildCocoon(ctx: Ctx)
	local plan = ctx.plan
	if plan.Wings == "Butterfly" then
		-- Chrysalide verte du Monarque : couronne dorée, points dorés, crémaster noir.
		local gold = Color3.fromRGB(240, 200, 60)
		ellipsoid(ctx, "Chrysalis", at(ctx, 0, 0.75, 0), Vector3.new(0.75, 1.4, 0.75), "Raw", nil, nil, Color3.fromRGB(110, 190, 120))
		ellipsoid(ctx, "GoldBand", at(ctx, 0, 1.15, 0), Vector3.new(0.65, 0.05, 0.65), "Raw", nil, nil, gold)
		for i = 1, 4 do
			local angle = i * math.pi / 2
			ellipsoid(ctx, "GoldDot", at(ctx, math.cos(angle) * 0.36, 0.7, math.sin(angle) * 0.36), Vector3.one * 0.09, "Raw", nil, nil, gold)
		end
		limb(ctx, "Cremaster", at(ctx, 0, 1.42, 0), at(ctx, 0, 1.75, 0), 0.08, "Dark")
		return
	end
	if plan.Wings == "Elytra" or plan.Shape == "Dome" then
		-- Nymphe libre de coléoptère : corps pâle, tête repliée, fourreaux alaires, pattes collées.
		local pale = plan.LarvaColor:Lerp(Color3.fromRGB(240, 225, 190), 0.7)
		local pad = pale:Lerp(plan.Secondary, 0.3)
		ellipsoid(ctx, "PupaHead", at(ctx, 0, 0.36, -0.64), Vector3.new(0.45, 0.42, 0.4), "Raw", nil, nil, pale)
		ellipsoid(ctx, "PupaThorax", at(ctx, 0, 0.5, -0.3), Vector3.new(0.72, 0.62, 0.62), "Raw", nil, nil, pale)
		for i = 1, 4 do
			local width = 0.74 - i * 0.09
			segment(ctx, "PupaSegment", i, at(ctx, 0, 0.44 - i * 0.02, 0.02 + (i - 1) * 0.24), Vector3.new(width, width * 0.8, 0.34), "Raw", nil, pale)
		end
		setAnim(ctx, nil)
		for _, side in ipairs(SIDES) do
			ellipsoid(ctx, "PupaWingPad", at(ctx, side * 0.34, 0.36, -0.05), Vector3.new(0.14, 0.4, 0.62), "Raw", CFrame.Angles(0.35, 0, 0), nil, pad)
			limb(ctx, "PupaLeg", at(ctx, side * 0.2, 0.3, -0.48), at(ctx, side * 0.12, 0.2, -0.08), 0.07, "Raw", pad)
		end
		if plan.Horn or plan.Jaws == "Stag" then
			limb(ctx, "PupaHorn", at(ctx, 0, 0.42, -0.78), at(ctx, 0, 0.16, -1.15), 0.12, "Raw", pad)
		end
		return
	end
	-- Cocon de soie : bandes, calotte tissée plus dense, fils d'ancrage.
	local silk = plan.LarvaColor:Lerp(Color3.fromRGB(235, 225, 195), 0.65)
	local cocoon = ellipsoid(ctx, "Cocoon", at(ctx, 0, 0.5, 0), Vector3.new(0.95, 0.9, 1.7), "Raw", nil, nil, silk)
	cocoon.Material = Enum.Material.Fabric
	for i = 1, 4 do
		local t = (-0.6 + i * 0.25) / 0.85
		local f = math.sqrt(1 - t * t)
		ellipsoid(ctx, "SilkBand", at(ctx, 0, 0.5, -0.6 + i * 0.25), Vector3.new(0.95 * f + 0.04, 0.9 * f + 0.04, 0.07), "Shine", nil, 0.3)
	end
	ellipsoid(ctx, "CocoonCap", at(ctx, 0, 0.5, -0.72), Vector3.new(0.5, 0.48, 0.3), "Raw", nil, nil, silk:Lerp(DARK, 0.25))
	for i = 1, 4 do
		local side = if i % 2 == 0 then 1 else -1
		local z = if i <= 2 then -0.5 else 0.5
		limb(ctx, "SilkThread", at(ctx, side * 0.35, 0.5, z), at(ctx, side * 0.95, 0.02, z * 1.6), 0.03, "Shine")
	end
end

local function buildGrub(ctx: Ctx)
	-- Larve en "C" couchée sur le flanc (abeille, fourmi, mouche, lucane...) : segments dodus
	-- enroulés, capsule céphalique brune à mandibules, 3 petites pattes thoraciques.
	local count = 8
	local radius = 0.5
	for i = 1, count do
		local angle = math.rad(-115 + (i - 1) * 230 / (count - 1))
		local size = 0.4 + math.sin(i / (count + 1) * math.pi) * 0.16
		local center = at(ctx, -math.cos(angle) * radius, 0.05 + size * 0.45, math.sin(angle) * radius)
		segment(ctx, "GrubSegment", i, center, Vector3.new(size, size * 0.9, 0.36), "Larva", CFrame.Angles(0, angle, 0))
		if i <= 3 then
			-- Patte tournée vers l'intérieur du "C".
			limb(ctx, "GrubLeg", center, at(ctx, -math.cos(angle) * radius * 0.4, 0.03, math.sin(angle) * radius * 0.4), 0.05, "Raw", Color3.fromRGB(150, 100, 50))
		end
	end
	setAnim(ctx, nil)
	local headAngle = math.rad(-143)
	local hx, hz = -math.cos(headAngle) * radius, math.sin(headAngle) * radius
	local brown = Color3.fromRGB(150, 100, 50)
	ellipsoid(ctx, "GrubHead", at(ctx, hx, 0.22, hz), Vector3.new(0.34, 0.3, 0.3), "Raw", nil, nil, brown)
	for _, side in ipairs(SIDES) do
		limb(ctx, "Mandible", at(ctx, hx + 0.1, 0.18, hz + side * 0.07), at(ctx, hx + 0.26, 0.14, hz + side * 0.02), 0.05, "Dark")
	end
end

local function buildCrawler(ctx: Ctx)
	-- Larve coureuse aplatie (coccinelle, luciole, bombardier) : plaques dorsales, 6 pattes.
	local plan = ctx.plan
	ellipsoid(ctx, "LarvaHead", at(ctx, 0, 0.22, -0.84), Vector3.new(0.34, 0.2, 0.3), "Dark")
	for _, side in ipairs(SIDES) do
		limb(ctx, "Mandible", at(ctx, side * 0.1, 0.2, -0.95), at(ctx, side * 0.03, 0.18, -1.1), 0.04, "Dark")
	end
	local count = 8
	for i = 1, count do
		local z = -0.6 + (i - 1) * 0.2
		local width = 0.6 - math.abs(i - 3) * 0.055
		local glowing = plan.Glow and i == count
		local part = segment(ctx, "LarvaSegment", i, at(ctx, 0, 0.24, z), Vector3.new(width, 0.26, 0.28), if glowing then "Accent" else "Larva")
		if glowing then
			part.Material = Enum.Material.Neon -- la larve de luciole brille déjà
		end
		if i == 2 or i == 5 then
			-- Taches vives sur les flancs (orange chez la coccinelle).
			for _, side in ipairs(SIDES) do
				ellipsoid(ctx, "LarvaSpot", at(ctx, side * width * 0.36, 0.34, z), Vector3.new(0.14, 0.1, 0.14), "Primary")
			end
		end
	end
	for i = 1, 3 do
		larvaLegPair(ctx, i, -0.6 + (i - 1) * 0.2, 0.2, 0.42, "Dark")
	end
end

local function buildCaterpillar(ctx: Ctx)
	-- Chenille de Monarque : anneaux jaune / noir / blanc + filaments noirs aux deux bouts.
	local count = 9
	local bands = { ctx.plan.LarvaColor, DARK, WHITE }
	for i = 1, count do
		local z = -1.0 + (i - 1) * 0.25
		local size = if i == 1 then 0.38 else 0.42
		segment(ctx, "CaterpillarSegment", i, at(ctx, 0, 0.27, z), Vector3.new(size, size, 0.3), "Raw", nil, bands[(i % 3) + 1])
		for _, side in ipairs(SIDES) do
			if i <= 2 then
				ellipsoid(ctx, "TrueLeg", at(ctx, side * 0.12, 0.05, z), Vector3.new(0.07, 0.12, 0.07), "Dark")
			elseif i < count - 1 and i % 2 == 0 then
				ellipsoid(ctx, "Proleg", at(ctx, side * 0.15, 0.05, z), Vector3.one * 0.11, "Dark")
			end
		end
	end
	setAnim(ctx, nil)
	ellipsoid(ctx, "CaterpillarHead", at(ctx, 0, 0.24, -1.2), Vector3.new(0.32, 0.32, 0.26), "Dark")
	for _, z in ipairs({ -1.0, 1.0 }) do
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * 0.08, 0.45, z)
			setAnim(ctx, "Antenna", side, if z < 0 then 1 else 2, base)
			limb(ctx, "Filament", base, base + Vector3.new(side * 0.1, 0.3, z * 0.15) * ctx.s, 0.04, "Dark")
		end
	end
	setAnim(ctx, nil)
end

local function buildAquaticNymph(ctx: Ctx)
	-- Larve aquatique (libellule, éphémère, dytique) : corps plat allongé, 6 pattes, fourreaux
	-- alaires ; branchies + 3 filaments (éphémère), masque (libellule) ou crocs (dytique).
	local plan = ctx.plan
	ellipsoid(ctx, "NymphHead", at(ctx, 0, 0.3, -0.75), Vector3.new(0.55, 0.3, 0.45), "Larva")
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.24, 0.38, -0.82), Vector3.one * 0.14, "Eye")
		ellipsoid(ctx, "WingBud", at(ctx, side * 0.14, 0.45, -0.12), Vector3.new(0.18, 0.06, 0.34), "Dark")
	end
	ellipsoid(ctx, "NymphThorax", at(ctx, 0, 0.3, -0.3), Vector3.new(0.6, 0.32, 0.55), "Larva")
	local mayfly = plan.Tail == "Cerci"
	for i = 1, 5 do
		local z = 0.05 + (i - 1) * 0.22
		local width = 0.62 - i * 0.07
		segment(ctx, "NymphSegment", i, at(ctx, 0, 0.28, z), Vector3.new(width, 0.26, 0.3), "Larva")
		if mayfly and i <= 3 then
			-- Branchies en lamelles sur les flancs.
			for _, side in ipairs(SIDES) do
				flatPanel(ctx, "Gill", at(ctx, side * (width * 0.5 + 0.08), 0.3, z), Vector3.new(0.22, 0.03, 0.14), CFrame.Angles(0, 0, side * 0.4), "Larva", 0.3)
			end
		end
	end
	setAnim(ctx, nil)
	local tailBase = at(ctx, 0, 0.28, 1.0)
	if mayfly then
		for i = -1, 1 do
			setAnim(ctx, "Tail", i, 1, tailBase)
			limb(ctx, "Cercus", tailBase, at(ctx, i * 0.3, 0.3, 1.7), 0.03, "Larva")
		end
	elseif plan.Wings == "Elytra" then
		-- Larve de dytique ("tigre d'eau") : mandibules en faucille + 2 filaments respiratoires.
		for _, side in ipairs(SIDES) do
			setAnim(ctx, "Jaw", side, 1, at(ctx, side * 0.2, 0.28, -0.92))
			limb(ctx, "Mandible", at(ctx, side * 0.2, 0.28, -0.92), at(ctx, side * 0.05, 0.26, -1.25), 0.06, "Dark")
			setAnim(ctx, "Tail", side, 1, tailBase)
			limb(ctx, "Cercus", tailBase, at(ctx, side * 0.12, 0.34, 1.35), 0.04, "Larva")
		end
	else
		-- "Masque" préhensile replié sous la tête (larve de libellule) + pyramide anale.
		limb(ctx, "Mask", at(ctx, 0, 0.15, -0.55), at(ctx, 0, 0.12, -1.05), 0.1, "Dark")
		for i = -1, 1 do
			limb(ctx, "AnalSpine", tailBase, at(ctx, i * 0.1, 0.28, 1.25), 0.05, "Dark")
		end
	end
	setAnim(ctx, nil)
	for i = 1, 3 do
		larvaLegPair(ctx, i, -0.45 + (i - 1) * 0.2, 0.22, 0.55, "Larva")
	end
end

local function buildWiggler(ctx: Ctx)
	-- Larve de moustique : tête à brosses, thorax renflé, abdomen fin segmenté, siphon respiratoire.
	for i = 1, 8 do
		local z = -0.7 + (i - 1) * 0.18
		local size = if i == 1 then 0.3 elseif i == 2 then 0.42 else 0.22
		segment(ctx, "WigglerSegment", i, at(ctx, math.sin(i * 0.8) * 0.05, 0.35, z), Vector3.new(size, size, 0.2), "Larva")
	end
	setAnim(ctx, nil)
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.13, 0.38, -0.72), Vector3.one * 0.08, "Dark")
		limb(ctx, "MouthBrush", at(ctx, side * 0.06, 0.33, -0.82), at(ctx, side * 0.14, 0.3, -0.98), 0.05, "Dark")
		limb(ctx, "Bristle", at(ctx, side * 0.18, 0.37, -0.52), at(ctx, side * 0.42, 0.42, -0.5), 0.025, "Dark")
	end
	limb(ctx, "Siphon", at(ctx, 0, 0.35, 0.55), at(ctx, 0, 0.62, 0.82), 0.07, "Dark")
	limb(ctx, "AnalGill", at(ctx, 0, 0.33, 0.57), at(ctx, 0, 0.22, 0.78), 0.06, "Larva")
end

local function buildCaseLarva(ctx: Ctx)
	-- Larve de phrygane : fourreau-armure en petits cailloux / brindilles (GDD : +80% défense).
	local stones = { Color3.fromRGB(120, 115, 105), Color3.fromRGB(95, 85, 70), Color3.fromRGB(140, 130, 110), Color3.fromRGB(80, 100, 60) }
	local index = 0
	for ring = 1, 5 do
		local z = -0.3 + (ring - 1) * 0.28
		for k = 1, 5 do
			index += 1
			local angle = k / 5 * math.pi * 2 + ring * 0.6
			local radius = 0.33 - ring * 0.025
			local center = at(ctx, math.cos(angle) * radius, 0.4 + math.sin(angle) * radius, z)
			addPart(ctx, "CaseStone", Vector3.new(0.2, 0.17, 0.22) * ctx.s, CFrame.new(center) * CFrame.Angles(angle, angle * 0.5, 0), "Raw", "Block", nil, stones[(index % #stones) + 1])
		end
	end
	-- Brindilles plus longues prises dans le fourreau.
	local twig = Color3.fromRGB(105, 80, 50)
	limb(ctx, "CaseTwig", at(ctx, 0.3, 0.62, -0.25), at(ctx, 0.2, 0.7, 0.95), 0.08, "Raw", twig)
	limb(ctx, "CaseTwig", at(ctx, -0.32, 0.5, -0.1), at(ctx, -0.18, 0.42, 1.05), 0.07, "Raw", twig)
	local brown = Color3.fromRGB(110, 80, 40)
	ellipsoid(ctx, "LarvaThorax", at(ctx, 0, 0.36, -0.45), Vector3.new(0.3, 0.26, 0.3), "Larva")
	ellipsoid(ctx, "LarvaHead", at(ctx, 0, 0.34, -0.66), Vector3.new(0.28, 0.24, 0.28), "Raw", nil, nil, brown)
	for i = 1, 3 do
		larvaLegPair(ctx, i, -0.62 + (i - 1) * 0.1, 0.1, 0.32, "Dark")
	end
end

local function buildLarva(ctx: Ctx, molting: boolean)
	local plan = ctx.plan
	local kind = plan.Larva
	if kind == "Grub" then
		buildGrub(ctx)
	elseif kind == "Crawler" then
		buildCrawler(ctx)
	elseif kind == "Caterpillar" then
		buildCaterpillar(ctx)
	elseif kind == "AquaticNymph" then
		buildAquaticNymph(ctx)
	elseif kind == "Wiggler" then
		buildWiggler(ctx)
	elseif kind == "CaseLarva" then
		buildCaseLarva(ctx)
	else
		-- "Nymph" : réplique sans ailes de l'adulte (hémimétaboles, arachnides), teintée larve,
		-- avec des proportions juvéniles (grosse tête, abdomen court, fourreaux alaires).
		local nymphPlan = table.clone(plan) :: any
		nymphPlan.Primary = plan.Primary:Lerp(plan.LarvaColor, 0.5)
		nymphPlan.Secondary = plan.Secondary:Lerp(plan.LarvaColor, 0.5)
		nymphPlan.HeadSize = plan.HeadSize * 1.15
		nymphPlan.AbdomenLength = plan.AbdomenLength * 0.85
		local previousPlan = ctx.plan
		ctx.plan = nymphPlan :: BodyPlan
		buildAdult(ctx, false)
		ctx.plan = previousPlan
	end
	setAnim(ctx, nil)
	if molting then
		-- Exuvie (ancienne peau) abandonnée à côté : signal visuel de la carapace molle.
		ellipsoid(ctx, "Exuviae", at(ctx, 0.9, 0.2, 0.4), Vector3.new(0.5, 0.3, 0.9), "Raw", nil, 0.5, Color3.fromRGB(200, 180, 140))
	end
end

-- ============================================================
-- Avatar Roblox par défaut
-- ============================================================

local function isOwnVisualPart(descendant: Instance): boolean
	return descendant:FindFirstAncestor(CONTAINER_NAME) ~= nil
end

local function hideIfDefaultAvatarPiece(descendant: Instance, rootPart: BasePart)
	if descendant:GetAttribute("KeepVisible") == true then
		return -- ex: nourriture transportée (FoodService), effets de jeu
	end
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

local function hideDefaultAvatar(character: Model, rootPart: BasePart)
	for _, descendant in ipairs(character:GetDescendants()) do
		hideIfDefaultAvatarPiece(descendant, rootPart)
	end
end

-- Les accessoires peuvent se charger APRÈS le premier passage : interceptés au fil de l'eau,
-- une seule fois par personnage (attribut garde-fou).
local function hookLateAvatarPieces(character: Model, rootPart: BasePart)
	if character:GetAttribute(HOOKED_ATTRIBUTE) then
		return
	end
	character:SetAttribute(HOOKED_ATTRIBUTE, true)
	character.DescendantAdded:Connect(function(descendant)
		hideIfDefaultAvatarPiece(descendant, rootPart)
	end)
end

-- Décalage vertical (espace local du root) du point le plus bas du personnage = le sol.
local function computeGroundOffsetY(character: Model, root: BasePart): number
	-- R15 : le Humanoid maintient le root à HipHeight + demi-hauteur au-dessus du sol, quelle que
	-- soit la pose (saut, chute, nage) au moment du changement de stade.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.HipHeight > 0 then
		return -(humanoid.HipHeight + root.Size.Y / 2)
	end
	-- R6 (HipHeight = 0) : repli sur la boîte englobante de l'avatar.
	local boundingCFrame, boundingSize = character:GetBoundingBox()
	local groundWorldPosition = (boundingCFrame * CFrame.new(0, -boundingSize.Y / 2, 0)).Position
	return root.CFrame:PointToObjectSpace(groundWorldPosition).Y
end

-- ============================================================
-- API publique
-- ============================================================

function InsectVisualService.ApplyVisual(character: Model, speciesId: string, stage: string, mutationId: string?)
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

	local plan = InsectBodyPlans.Get(speciesId)
	local container = Instance.new("Model")
	container.Name = CONTAINER_NAME
	-- Échelle à laquelle les RestC0 sont exprimés (ScaleTo ne met pas les attributs à l'échelle).
	container:SetAttribute("AnimScale", character:GetScale())
	-- Stade du corps réellement affiché (le Stage du joueur change ~0,9 s avant le nouveau corps).
	container:SetAttribute("Stage", stage)

	local ctx: Ctx = {
		root = root,
		container = container,
		plan = plan,
		-- Suit l'échelle du personnage (ScaleTo par stade) : un oeuf/une larve reste petit.
		s = character:GetScale() * plan.Length,
		groundY = computeGroundOffsetY(character, root),
		mutation = if mutationId then InsectBodyPlans.Mutations[mutationId] else nil,
		partIndex = 0,
		pale = 0,
		animKind = nil,
		animSide = 0,
		animIndex = 0,
		animPivot = Vector3.zero,
	}

	if stage == "Oeuf" then
		ctx.s = character:GetScale() * 1.6
		buildEgg(ctx)
	elseif stage == "Cocon" then
		ctx.s = character:GetScale() * 1.3
		buildCocoon(ctx)
	elseif stage == "Adulte" then
		local wingsUnlocked = plan.Wings ~= "None"
		buildAdult(ctx, wingsUnlocked)
	elseif stage == "Mue" then
		ctx.pale = 0.45 -- carapace molle, encore claire
		ctx.s = character:GetScale() * plan.Length * 1.5
		buildLarva(ctx, true)
	else
		ctx.s = character:GetScale() * plan.Length * 1.5
		buildLarva(ctx, false)
	end
	-- Parenté en une fois : un seul recalcul d'assemblage et une seule réplication du corps complet.
	container.Parent = character

	InsectVisualService.SetCamouflage(character, (character:GetAttribute("CamouflageLevel") :: number?) or 0)
end

-- level : 0 = visible, 1 = invisible. Appliqué par-dessus la transparence d'origine de chaque part.
function InsectVisualService.SetCamouflage(character: Model, level: number)
	character:SetAttribute("CamouflageLevel", if level > 0 then level else nil)
	-- Le nom/la barre de vie au-dessus de la tête trahiraient un insecte camouflé.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = if level > 0.5 then Enum.HumanoidDisplayDistanceType.None else Enum.HumanoidDisplayDistanceType.Viewer
	end
	local container = character:FindFirstChild(CONTAINER_NAME)
	if not container then
		return
	end
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local base = (descendant:GetAttribute(BASE_TRANSPARENCY_ATTRIBUTE) :: number?) or 0
			descendant.Transparency = base + (1 - base) * math.clamp(level, 0, 1)
		elseif descendant:IsA("PointLight") then
			descendant.Enabled = level < 0.5
		end
	end
end

-- Copie figée du corps 3D (pour la carcasse) : ancrée, sans soudures, assombrie, pattes en l'air.
function InsectVisualService.BuildCarcassTemplate(character: Model): Model?
	local container = character:FindFirstChild(CONTAINER_NAME)
	if not container or not container:IsA("Model") then
		return nil
	end
	local copy = container:Clone()
	copy.Name = "InsectCarcass"
	local firstPart: BasePart? = nil
	for _, descendant in ipairs(copy:GetDescendants()) do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") or descendant:IsA("PointLight") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Transparency = (descendant:GetAttribute(BASE_TRANSPARENCY_ATTRIBUTE) :: number?) or 0
			descendant.Color = descendant.Color:Lerp(Color3.fromRGB(70, 55, 40), 0.35)
			descendant.CanQuery = true -- la carcasse doit être "trouvable" (proximité, abri)
			descendant:SetAttribute("Anim", nil) -- une carcasse ne s'anime plus
			if descendant.Material == Enum.Material.Neon then
				descendant.Material = Enum.Material.SmoothPlastic
			end
			if not firstPart then
				firstPart = descendant
			end
		end
	end
	if not firstPart then
		copy:Destroy()
		return nil
	end
	copy.PrimaryPart = (copy:FindFirstChild("Head") :: BasePart?) or firstPart
	-- Pattes en l'air : retournement autour du centre de la boîte englobante, selon l'axe du corps
	-- (orientation du HumanoidRootPart, pas celle d'une part quelconque).
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local boxCenter = copy:GetBoundingBox().Position
	local boxCFrame = if rootPart then CFrame.new(boxCenter) * rootPart.CFrame.Rotation else CFrame.new(boxCenter)
	local flip = boxCFrame * CFrame.Angles(0, 0, math.pi) * boxCFrame:Inverse()
	for _, descendant in ipairs(copy:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = flip * descendant.CFrame
		end
	end
	return copy
end

return InsectVisualService
