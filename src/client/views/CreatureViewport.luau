--!strict
-- CreatureViewport.luau
-- Constructeur et afficheur 3D procédural des 30 espèces d'insectes (à tous les stades : Œuf,
-- Larve, Mue, Cocon, Adulte + Mutations) dans des ViewportFrames côté client.
-- Produit des modèles légers (pièces ancrées, sans Weld ni physique) et gère le cadrage automatique
-- de la caméra ainsi que la rotation interactive (glisser pour tourner + plateau tournant fluide).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local InsectBodyPlans = require(ReplicatedStorage.shared.InsectBodyPlans)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local PlayableAnimals = require(ReplicatedStorage.shared.PlayableAnimals)
local UiTheme = require(script.Parent.UiTheme)

type BodyPlan = InsectBodyPlans.BodyPlan
type MutationInfo = InsectBodyPlans.MutationInfo
type Role = "Primary" | "Secondary" | "Accent" | "Eye" | "Wing" | "Dark" | "Larva" | "Raw" | "Shine"
type Shape = "Ellipsoid" | "Block" | "Cylinder" | "Ball"

type Ctx = {
	container: Model,
	plan: BodyPlan,
	s: number,
	groundY: number,
	mutation: MutationInfo?,
	partIndex: number,
	pale: number,
	rounded: boolean,
}

type Layout = {
	H: number,
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

export type ViewportHandle = {
	Viewport: ViewportFrame,
	Camera: Camera,
	SetCreature: (speciesId: string, stage: string?, mutationId: string?, withPedestal: boolean?) -> (),
	SpinOnce: () -> (),
	SetTurntableActive: (active: boolean) -> (),
	Destroy: () -> (),
}

local CreatureViewport = {}

local WHITE = Color3.new(1, 1, 1)
local DARK = Color3.fromRGB(20, 18, 16)
local SIDES = { -1, 1 }

-- ============================================================
-- Primitives 3D (ancrées, sans Weld, optimisées pour ViewportFrame)
-- ============================================================

local function paint(ctx: Ctx, role: Role, raw: Color3?): (Color3, Enum.Material, number)
	if role == "Shine" then
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
		elseif plan.Metallic and (role == "Primary" or role == "Secondary") then 0.22
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

local function addPart(ctx: Ctx, name: string, size: Vector3, localCf: CFrame, role: Role, shape: Shape, transparency: number?, raw: Color3?): Part
	ctx.partIndex += 1
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	if ctx.rounded then
		if shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		elseif shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif shape == "Ellipsoid" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
	end
	local color, material, reflectance = paint(ctx, role, raw)
	part.Color = color
	part.Material = if role == "Wing" then Enum.Material.Glass else material
	part.Reflectance = reflectance
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = localCf
	part.Parent = ctx.container
	return part
end

local function at(ctx: Ctx, x: number, y: number, z: number): Vector3
	return Vector3.new(x * ctx.s, ctx.groundY + y * ctx.s, z * ctx.s)
end

local function ellipsoid(ctx: Ctx, name: string, center: Vector3, size: Vector3, role: Role, rotation: CFrame?, transparency: number?, raw: Color3?): Part
	local cf = CFrame.new(center) * (rotation or CFrame.identity)
	return addPart(ctx, name, size * ctx.s, cf, role, "Ellipsoid", transparency, raw)
end

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

local function wing(ctx: Ctx, name: string, a: Vector3, b: Vector3, chord: number, role: Role, transparency: number, veins: number, normal: Vector3?, thickness: number?, raw: Color3?): CFrame
	local thick = thickness or 0.03
	local cf = CFrame.lookAt(a:Lerp(b, 0.5), b, normal or Vector3.yAxis)
	addPart(ctx, name, Vector3.new(chord * ctx.s, thick * ctx.s, (b - a).Magnitude), cf, role, "Ellipsoid", transparency, raw)
	if veins > 0 then
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
-- Squelette et constructeurs d'anatomie
-- ============================================================

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

local function withHead(L: Layout, H: number, headZ: number, headR: number): Layout
	local copy = table.clone(L)
	copy.H = H
	copy.headZ = headZ
	copy.headR = headR
	return copy
end

local function buildHead(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local r = L.headR
	local role = (plan.HeadColor :: any) :: Role
	if plan.HeadShape == "Triangle" then
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.12, L.headZ), Vector3.new(r * 2.5, r * 1.3, r * 1.3), role)
		ellipsoid(ctx, "Muzzle", at(ctx, 0, L.H + 0.12 - r * 0.6, L.headZ - r * 0.25), Vector3.new(r * 1.0, r * 1.3, r * 0.9), role)
	elseif plan.HeadShape == "Wide" then
		local z = L.headZ + r * 0.2
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.05, z), Vector3.new(r * 2.9, r * 1.5, r * 1.4), role)
		for i = -1, 1 do
			ellipsoid(ctx, "Ocellus", at(ctx, i * r * 0.28, L.H + 0.05 + r * 0.7, z - r * (0.3 - math.abs(i) * 0.15)), Vector3.one * 0.07, "Raw", nil, nil, Color3.fromRGB(200, 60, 40))
		end
	else
		ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.05, L.headZ), Vector3.new(r * 2, r * 1.8, r * 1.9), role)
		ellipsoid(ctx, "Clypeus", at(ctx, 0, L.H - r * 0.35, L.headZ - r * 0.62), Vector3.new(r * 1.1, r * 0.8, r * 0.7), "Secondary")
	end
end

local function buildEyes(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local r = 0.13 * plan.EyeSize * plan.HeadSize
	local eyeY = L.H + L.headR * 0.35
	if plan.Shape == "Spider" then
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
		if kind == "Elbowed" then
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
			limb(ctx, "Mandible", base, tip, 0.09, "Dark")
		end
	elseif plan.Jaws == "Stag" then
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * r * 0.55, mouthY + 0.05, frontZ + 0.05)
			local mid = at(ctx, side * r * 1.0, mouthY + 0.25, frontZ - 0.6)
			local tip = at(ctx, side * r * 0.25, mouthY + 0.3, frontZ - 1.15)
			limb(ctx, "StagJaw", base, mid, 0.16, "Secondary")
			limb(ctx, "StagJaw", mid, tip, 0.13, "Secondary")
			limb(ctx, "StagTooth", mid:Lerp(tip, 0.4), at(ctx, side * r * 0.35, mouthY + 0.2, frontZ - 0.75), 0.07, "Secondary")
			limb(ctx, "StagTooth", mid:Lerp(tip, 0.85), at(ctx, side * r * 0.75, mouthY + 0.38, frontZ - 1.3), 0.07, "Secondary")
		end
	elseif plan.Jaws == "Proboscis" then
		local len = plan.ProboscisLength
		local base = at(ctx, 0, mouthY, frontZ + 0.05)
		local tip = at(ctx, 0, math.max(0.04, mouthY - 0.35 * len), frontZ - 0.55 * len)
		limb(ctx, "Proboscis", base, tip, if len < 0.75 then 0.08 else 0.05, "Dark")
	elseif plan.Jaws == "Fangs" then
		local reach = math.min(1, mouthY / 0.42)
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * r * 0.3, mouthY + 0.05, frontZ + 0.1)
			local knuckle = base + Vector3.new(0, -0.2 * reach, -0.08) * s
			limb(ctx, "Chelicera", base, knuckle, 0.15, "Secondary")
			limb(ctx, "Fang", knuckle, knuckle + Vector3.new(-side * 0.06, -0.16 * reach, 0.02) * s, 0.06, "Dark")
			if plan.Shape == "Spider" then
				local palp = at(ctx, side * r * 0.62, mouthY + 0.08, frontZ + 0.15)
				limb(ctx, "Pedipalp", palp, palp + Vector3.new(side * 0.05, -0.1, -0.3) * s, 0.09, if plan.Fuzzy then "Accent" else "Primary")
			end
		end
	elseif plan.Jaws == "Rostrum" then
		limb(ctx, "Rostrum", at(ctx, 0, mouthY, frontZ + 0.1), at(ctx, 0, mouthY - 0.3, frontZ + 0.45), 0.06, "Dark")
	elseif plan.Jaws == "Nozzle" then
		limb(ctx, "GlueNozzle", at(ctx, 0, L.H + 0.1, L.headZ - r * 0.4), at(ctx, 0, L.H + 0.05, frontZ - 0.45), 0.16, "Secondary")
		ellipsoid(ctx, "GlueDrop", at(ctx, 0, L.H + 0.05, frontZ - 0.47), Vector3.one * 0.12, "Raw", nil, 0.2, Color3.fromRGB(235, 225, 170))
	end
end

local function buildHorn(ctx: Ctx, L: Layout)
	if not ctx.plan.Horn then
		return
	end
	local thoraxTop = at(ctx, 0, L.H + 0.35, L.thoraxZ - L.thoraxLen * 0.2)
	local mid = at(ctx, 0, L.H + 0.75, L.headZ - L.headR * 0.4)
	local tip = at(ctx, 0, L.H + 0.45, L.headZ - L.headR - 0.75)
	limb(ctx, "ThoraxHorn", thoraxTop, mid, 0.2, "Primary")
	limb(ctx, "ThoraxHorn", mid, tip, 0.15, "Primary")
	limb(ctx, "HornTooth", mid:Lerp(tip, 0.45), mid:Lerp(tip, 0.5) + Vector3.new(0, -0.16, 0) * ctx.s, 0.07, "Primary")
	local headBase = at(ctx, 0, L.H + 0.1, L.headZ - L.headR * 0.6)
	limb(ctx, "HeadHorn", headBase, at(ctx, 0, L.H + 0.3, L.headZ - L.headR - 0.55), 0.14, "Primary")
end

local function buildLegPair(ctx: Ctx, _L: Layout, index: number, pairCount: number, z: number, hipY: number, halfWidth: number)
	local plan = ctx.plan
	local style = plan.LegStyle
	local span = 0.95 * plan.LegLength
	local kneeUp = 0.35
	local spreadZ = (index - (pairCount + 1) / 2) * 0.35
	local d = if plan.Fuzzy then 0.12 else 0.09
	local isHind = index == pairCount
	local isFront = index == 1

	if style == "Long" then
		kneeUp = 0.65
		span *= 1.1
	elseif style == "Strider" then
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
		tibiaRole, tarsusRole = "Raw", "Raw"
	elseif legColor == "Thighs" then
		if index > 1 then
			femurRole = "Raw"
		end
	elseif legColor == "Striped" then
		tibiaRole = "Raw"
	end

	for _, side in ipairs(SIDES) do
		local hip = at(ctx, side * halfWidth, hipY, z)
		local knee: Vector3
		local ankle: Vector3
		if plan.Shape ~= "Stick" then
			ellipsoid(ctx, "LegCoxa", hip, Vector3.one * d * 1.7, femurRole, nil, nil, tint)
		end
		if style == "Jumper" and isHind then
			knee = at(ctx, side * (halfWidth + 0.3), hipY + 0.7, z + 0.6)
			ankle = at(ctx, side * (halfWidth + 0.42), 0.1, z + 0.95)
			limb(ctx, "LegFemur", hip, knee, d * 2.6, femurRole, tint)
			limb(ctx, "LegTibia", knee, ankle, d * 0.9, "Secondary")
			limb(ctx, "LegTarsus", ankle, at(ctx, side * (halfWidth + 0.45), 0.03, z + 0.55), d * 0.6, tarsusRole, tint)
		elseif style == "Oars" and isHind then
			local reach = plan.LegLength
			knee = at(ctx, side * (halfWidth + 0.4 * reach), hipY, z + 0.2)
			ankle = at(ctx, side * (halfWidth + 0.85 * reach), hipY - 0.05, z + 0.85 * reach)
			limb(ctx, "LegFemur", hip, knee, d * 1.2, femurRole, tint)
			wing(ctx, "LegTibia", knee, ankle, 0.2, "Secondary", 0, 0, nil, 0.06)
			wing(ctx, "LegTarsus", knee:Lerp(ankle, 0.35), ankle + (ankle - knee) * 0.25, 0.36, "Dark", 0.55, 0)
		else
			knee = at(ctx, side * (halfWidth + span * 0.45), hipY + kneeUp, z + spreadZ * 0.3)
			ankle = at(ctx, side * (halfWidth + span * 0.92), 0.12, z + spreadZ * 0.9)
			local toe = at(ctx, side * (halfWidth + span * 1.08), 0.03, z + spreadZ - 0.1)
			limb(ctx, "LegFemur", hip, knee, d * 1.15, femurRole, tint)
			limb(ctx, "LegTibia", knee, ankle, d * 0.8, tibiaRole, tint)
			limb(ctx, "LegTarsus", ankle, toe, d * 0.55, tarsusRole, tint)
		end
		if legColor == "Striped" then
			ellipsoid(ctx, "LegBand", hip:Lerp(knee, 0.55), Vector3.one * d * 1.9, "Raw", nil, nil, tint)
		end
		if plan.PollenBaskets and isHind then
			ellipsoid(ctx, "PollenBasket", knee:Lerp(ankle, 0.45), Vector3.new(0.2, 0.26, 0.2), "Raw", nil, nil, Color3.fromRGB(245, 200, 40))
		end
	end
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
		if kind == "Raptorial" then
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
			local elbow = at(ctx, side * (L.thoraxW * 0.5 + 0.45), L.H + 0.05, frontZ - 0.35)
			local hand = at(ctx, side * (L.thoraxW * 0.5 + 0.35), L.H + 0.05, frontZ - 0.9)
			limb(ctx, "PincerArm", shoulder, elbow, 0.13, "Primary")
			limb(ctx, "PincerArm", elbow, hand, 0.13, "Primary")
			ellipsoid(ctx, "PincerHand", hand, Vector3.new(0.38, 0.26, 0.5), "Primary")
			local fingerBase = hand + Vector3.new(0, 0, -0.18) * s
			limb(ctx, "PincerFinger", fingerBase + Vector3.new(side * 0.08, 0, 0) * s, fingerBase + Vector3.new(side * 0.1, 0, -0.42) * s, 0.1, "Secondary")
			limb(ctx, "PincerFinger", fingerBase + Vector3.new(-side * 0.08, 0, 0) * s, fingerBase + Vector3.new(-side * 0.02, 0, -0.4) * s, 0.08, "Secondary")
		elseif kind == "WaterGrabbers" then
			local elbow = at(ctx, side * (L.thoraxW * 0.5 + 0.25), L.H + 0.1, frontZ - 0.5)
			local claw = at(ctx, side * (L.thoraxW * 0.3), L.H - 0.05, frontZ - 0.85)
			limb(ctx, "GrabberFemur", shoulder, elbow, 0.18, "Primary")
			limb(ctx, "GrabberTibia", elbow, claw, 0.1, "Secondary")
			limb(ctx, "GrabberClaw", claw, claw + Vector3.new(-side * 0.12, -0.04, 0.12) * s, 0.05, "Dark")
		end
	end
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
		limb(ctx, "Stinger", base, at(ctx, 0, tailY - 0.08, tailZ + 0.3), 0.06, "Dark")
	elseif kind == "Spinnerets" then
		for _, side in ipairs(SIDES) do
			limb(ctx, "Spinneret", at(ctx, side * 0.07, tailY - 0.05, tailZ - 0.06), at(ctx, side * 0.1, tailY - 0.12, tailZ + 0.1), 0.09, "Secondary")
		end
	elseif kind == "ScorpionTail" then
		local previous = at(ctx, 0, tailY, tailZ - 0.1)
		for i = 1, 5 do
			local angle = i / 5 * math.pi * 0.85
			local point = at(ctx, 0, tailY + math.sin(angle) * 1.1, tailZ + math.cos(angle) * 0.75 - 0.1)
			limb(ctx, "TailSegment", previous, point, 0.26 - i * 0.02, "Primary")
			previous = point
		end
		ellipsoid(ctx, "Telson", previous, Vector3.new(0.28, 0.28, 0.36), "Secondary")
		limb(ctx, "Sting", previous, previous + Vector3.new(0, -0.18, -0.32) * ctx.s, 0.05, "Dark")
	elseif kind == "Siphon" then
		for _, side in ipairs(SIDES) do
			limb(ctx, "Siphon", at(ctx, side * 0.05, tailY, tailZ - 0.05), at(ctx, side * 0.07, tailY + 0.12 * len, tailZ + 0.95 * len), 0.045, "Dark")
		end
	elseif kind == "Cerci" then
		for i = -1, 1 do
			limb(ctx, "Cercus", base, at(ctx, i * 0.35 * len, tailY + 0.35, tailZ + 1.3 * len), 0.03, "Accent")
		end
	end
end

local function buildWings(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local kind = plan.Wings
	local s = ctx.s
	local topY = L.H + 0.05 + L.thoraxH * 0.45
	local rootZ = L.thoraxZ + L.thoraxLen * 0.1
	if kind == "Membrane" then
		local span = 1.1 + L.abdLen * 0.45
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.12, topY, rootZ)
			wing(ctx, "Wing", a, at(ctx, side * (0.12 + span * 0.38), topY + 0.12, rootZ + span * 0.92), 0.5, "Wing", 0.45, 3)
			local a2 = at(ctx, side * 0.14, topY - 0.03, rootZ + 0.18)
			wing(ctx, "Wing", a2, at(ctx, side * (0.14 + span * 0.42), topY + 0.04, rootZ + 0.18 + span * 0.6), 0.36, "Wing", 0.5, 1)
		end
	elseif kind == "Mosquito" or kind == "Fly" then
		local fly = kind == "Fly"
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.12, topY, rootZ)
			local b = if fly then at(ctx, side * 0.95, topY + 0.08, rootZ + 1.0) else at(ctx, side * 0.42, topY + 0.1, rootZ + 1.3)
			wing(ctx, "Wing", a, b, if fly then 0.58 else 0.3, "Wing", 0.45, if fly then 3 else 1)
		end
	elseif kind == "Dragonfly" then
		for pairIndex = 1, 2 do
			local z = rootZ - 0.15 + (pairIndex - 1) * 0.32
			local sweep = if pairIndex == 1 then -0.12 else 0.12
			for _, side in ipairs(SIDES) do
				local a = at(ctx, side * 0.1, topY, z)
				local b = at(ctx, side * 2.15, topY + 0.08, z + sweep)
				wing(ctx, "Wing", a, b, if pairIndex == 1 then 0.36 else 0.44, "Wing", 0.5, 1)
				ellipsoid(ctx, "Pterostigma", a:Lerp(b, 0.86) + Vector3.new(0, 0, -0.1) * s, Vector3.new(0.24, 0.05, 0.09), "Dark")
			end
		end
	elseif kind == "Butterfly" then
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
		for _, side in ipairs(SIDES) do
			local normal = Vector3.new(side, 0, 0)
			local a = at(ctx, side * 0.06, topY, rootZ)
			wing(ctx, "Wing", a, at(ctx, side * 0.24, topY + 1.45, rootZ + 0.55), 0.75, "Wing", 0.4, 3, normal)
			local a2 = at(ctx, side * 0.06, topY, rootZ + 0.3)
			wing(ctx, "Wing", a2, at(ctx, side * 0.2, topY + 0.6, rootZ + 0.72), 0.35, "Wing", 0.45, 0, normal)
		end
	elseif kind == "Elytra" then
		local role = (plan.ElytraColor :: any) :: Role
		local cy = L.H + L.abdH * 0.18
		local cz = L.abdZ - 0.03
		local rx, ry, rz = L.abdW * 0.3, L.abdH * 0.45, L.abdLen * 0.54
		for _, side in ipairs(SIDES) do
			local cx = side * L.abdW * 0.24
			local shell = ellipsoid(ctx, "Elytron", at(ctx, cx, cy, cz), Vector3.new(rx * 2, ry * 2, rz * 2), role)
			if plan.Metallic then
				shell.Reflectance = 0.32
			end
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
		ellipsoid(ctx, "ElytraSeam", at(ctx, 0, cy, cz), Vector3.new(0.035, ry * 1.2 + 0.03, rz * 1.2 + 0.03), "Dark")
		if plan.ElytraRim then
			ellipsoid(ctx, "ElytraRim", at(ctx, 0, L.H + L.abdH * 0.05, cz), Vector3.new(L.abdW * 1.2, L.abdH * 0.3, L.abdLen * 1.14), "Accent")
		end
	elseif kind == "Folded" then
		local top = L.H + L.abdH * 0.5 + 0.02
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * L.abdW * 0.18, top + side * 0.012, L.abdZ - L.abdLen * 0.55)
			wing(ctx, "Wing", a, at(ctx, side * L.abdW * 0.1, top + side * 0.012, L.abdZ + L.abdLen * 0.55), L.abdW * 0.66, "Wing", 0.15, 1, nil, 0.06)
		end
	elseif kind == "Tent" then
		local ridgeY = L.H + L.abdH * 0.5 + 0.12
		for _, side in ipairs(SIDES) do
			local a = at(ctx, side * 0.05, ridgeY, L.thoraxZ)
			wing(ctx, "Wing", a, at(ctx, side * L.abdW * 0.5, L.H + 0.02, L.abdZ + L.abdLen * 0.75), L.abdW * 0.85, "Wing", if plan.Fuzzy then 0.1 else 0.3, 3, Vector3.new(side * 0.62, 0.78, 0))
		end
	end
end

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
		local width = math.max(W * 1.2, L.abdW * 0.92)
		local shield = ellipsoid(ctx, "Pronotum", at(ctx, 0, L.H + 0.1, L.thoraxZ - L.thoraxLen * 0.05), Vector3.new(width, L.thoraxH * 0.95, L.thoraxLen * 1.05), (plan.PronotumColor :: any) :: Role)
		if plan.Metallic then
			shield.Reflectance = 0.32
		end
		if plan.ElytraRim then
			ellipsoid(ctx, "PronotumRim", at(ctx, 0, L.H + 0.03, L.thoraxZ - L.thoraxLen * 0.05), Vector3.new(width * 1.08, L.thoraxH * 0.28, L.thoraxLen * 1.1), "Accent")
		end
	elseif plan.Pronotum == "Saddle" then
		ellipsoid(ctx, "Pronotum", at(ctx, 0, L.H + 0.14, L.thoraxZ - L.thoraxLen * 0.15), Vector3.new(W * 1.05, L.thoraxH * 1.2, L.thoraxLen * 0.75), "Secondary")
	end
	if plan.Waist then
		ellipsoid(ctx, "Petiole", at(ctx, 0, L.H, L.thoraxZ + L.thoraxLen / 2 + 0.11), Vector3.new(0.2, 0.2, 0.26), "Secondary")
		if plan.Wings == "None" then
			ellipsoid(ctx, "PetioleNode", at(ctx, 0, L.H + 0.12, L.thoraxZ + L.thoraxLen / 2 + 0.11), Vector3.new(0.16, 0.24, 0.1), "Primary")
		end
	end
	if plan.Fuzzy then
		for i = 1, 5 do
			local a = (i - 3) * 0.6
			local z = L.thoraxZ + (if i % 2 == 0 then 0.14 else -0.1) * L.thoraxLen
			ellipsoid(ctx, "HairTuft", at(ctx, math.sin(a) * W * 0.42, L.H + 0.05 + math.cos(a) * L.thoraxH * 0.44, z), Vector3.new(0.3, 0.3, 0.38), "Primary")
		end
	end
end

local function buildAbdomen(ctx: Ctx, L: Layout, covered: boolean)
	local plan = ctx.plan
	if covered then
		ellipsoid(ctx, "Abdomen", at(ctx, 0, L.H - 0.02, L.abdZ), Vector3.new(L.abdW * 0.95, L.abdH * 0.9, L.abdLen), "Primary")
		return
	end
	local slender = plan.AbdomenLength > 1.4
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
		ellipsoid(ctx, "AbdomenSegment", at(ctx, 0, L.H - (1 - f) * L.abdH * 0.15, frontZ + (i - 0.5) * step), Vector3.new(L.abdW * f, L.abdH * f, step * 1.45), role)
	end
end

local function buildGlowAndBubble(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	if plan.Glow then
		local lantern = ellipsoid(ctx, "Lantern", at(ctx, 0, L.H - L.abdH * 0.22, L.abdZ + L.abdLen * 0.3), Vector3.new(L.abdW * 0.8, L.abdH * 0.75, L.abdLen * 0.48), "Accent")
		lantern.Material = Enum.Material.Neon
	end
	if plan.Bubble then
		local wasRounded = ctx.rounded
		ctx.rounded = true
		local bubble: Part
		if plan.Shape == "Spider" then
			bubble = ellipsoid(ctx, "AirBubble", at(ctx, 0, L.H + 0.05, L.abdZ + L.abdLen * 0.1), Vector3.new(L.abdW * 1.5, L.abdW * 1.3, L.abdLen * 1.25), "Raw", nil, 0.6, Color3.fromRGB(220, 235, 255))
		else
			bubble = ellipsoid(ctx, "AirBubble", at(ctx, 0, L.H, L.abdZ + L.abdLen * 0.52), Vector3.one * L.abdW * 0.6, "Raw", nil, 0.55, Color3.fromRGB(220, 235, 255))
		end
		bubble.Material = Enum.Material.Glass
		bubble.Reflectance = 0.3
		ctx.rounded = wasRounded
	end
end

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
	local cephZ = L.headZ + L.headR * 0.4
	ellipsoid(ctx, "Cephalothorax", at(ctx, 0, L.H + 0.05, cephZ), Vector3.new(0.85, 0.6, 1.0) * hs, "Primary")
	ellipsoid(ctx, "Head", at(ctx, 0, L.H + 0.14, cephZ - 0.28 * hs), Vector3.new(0.62, 0.5, 0.5) * hs, "Primary")

	local LA = table.clone(L)
	LA.H = L.H + 0.1
	LA.abdLen = L.abdLen * 0.95
	local abdY = L.H + 0.15
	local rx, ry, rz = L.abdW * 0.575, L.abdW * 0.475, LA.abdLen / 2
	local cephBack = cephZ + 0.5 * hs
	local abdFront = L.abdZ - rz
	ellipsoid(ctx, "Pedicel", at(ctx, 0, L.H + 0.08, (cephBack + abdFront) / 2), Vector3.new(0.3, 0.3, math.max(0.3, abdFront - cephBack + 0.3)), "Primary")

	local abdomen = ellipsoid(ctx, "Abdomen", at(ctx, 0, abdY, L.abdZ), Vector3.new(rx * 2, ry * 2, rz * 2), "Secondary")
	if plan.Metallic then
		abdomen.Reflectance = 0.3
	end
	if plan.Spots then
		for _, dz in ipairs({ -0.13, 0.13 }) do
			addPart(ctx, "Hourglass", Vector3.new(0.2, 0.06, 0.2) * ctx.s, CFrame.new(at(ctx, 0, abdY + ry - 0.015, L.abdZ + dz)) * CFrame.Angles(0, math.rad(45), 0), "Accent", "Block")
		end
	end
	if plan.Stripes then
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
	buildJaws(ctx, withHead(L, 0.3, startZ - 0.15, 0.3))
	for i = 1, count do
		local z = startZ + (i - 0.5) * segmentLength
		local wave = math.sin(i * 0.9) * 0.06
		local role: Role = if i % 2 == 0 then "Primary" else "Secondary"
		local center = at(ctx, wave, 0.3, z)
		ellipsoid(ctx, "Segment", center, Vector3.new(0.64, 0.26, segmentLength * 1.3), role)
		for _, side in ipairs(SIDES) do
			local hip = at(ctx, wave + side * 0.28, 0.28, z)
			local knee = at(ctx, wave + side * 0.6, 0.4, z + 0.05)
			local foot = at(ctx, wave + side * 0.88, 0.02, z + 0.12)
			limb(ctx, "LegFemur", hip, knee, 0.06, "Accent")
			limb(ctx, "LegTibia", knee, foot, 0.045, "Accent")
		end
	end
	local tailZ = startZ + totalLength
	for _, side in ipairs(SIDES) do
		local base = at(ctx, side * 0.15, 0.3, tailZ)
		limb(ctx, "TailLeg", base, at(ctx, side * 0.38, 0.22, tailZ + 0.65), 0.07, "Accent")
	end
end

local function buildStickBody(ctx: Ctx, L: Layout)
	local plan = ctx.plan
	local frontZ = L.headZ
	local tipZ = L.abdZ + L.abdLen / 2
	local thoraxEnd = at(ctx, 0, L.H, L.thoraxZ + L.thoraxLen / 2)
	ellipsoid(ctx, "Head", at(ctx, 0, L.H, frontZ), Vector3.new(0.26, 0.24, 0.36), "Primary")
	limb(ctx, "Thorax", at(ctx, 0, L.H, frontZ + 0.15), thoraxEnd, 0.2, "Primary")
	limb(ctx, "Abdomen", thoraxEnd, at(ctx, 0, L.H + 0.08, tipZ), 0.17, "Secondary")
	for i = 1, 3 do
		local base = at(ctx, 0, L.H + 0.08, L.abdZ - L.abdLen * 0.3 + i * L.abdLen * 0.2)
		limb(ctx, "Twig", base, base + Vector3.new(if i % 2 == 0 then 0.12 else -0.12, 0.15, 0.05) * ctx.s, 0.05, "Secondary")
	end
	for i = 1, 3 do
		local z = L.thoraxZ - L.thoraxLen * 0.4 + (i - 1) * L.thoraxLen * 0.4
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
end

-- ============================================================
-- Œuf, Larve, Cocon
-- ============================================================

local function larvaLegPair(ctx: Ctx, index: number, z: number, hipX: number, reach: number, role: Role)
	local sweep = (index - 2) * 0.15
	for _, side in ipairs(SIDES) do
		local hip = at(ctx, side * hipX, 0.24, z)
		local knee = at(ctx, side * (hipX + reach * 0.55), 0.34, z + sweep * 0.5)
		limb(ctx, "LegFemur", hip, knee, 0.06, role)
		limb(ctx, "LegTibia", knee, at(ctx, side * (hipX + reach), 0.02, z + sweep), 0.045, "Dark")
	end
end

local function buildEgg(ctx: Ctx)
	local plan = ctx.plan
	if plan.Shape == "Spider" then
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
		local jelly = ellipsoid(ctx, "EggJelly", center, Vector3.new(1.15, 1.3, 1.15), "Raw", nil, 0.7, Color3.fromRGB(200, 230, 240))
		jelly.Material = Enum.Material.Glass
		return
	end
	if plan.Larva == "Caterpillar" then
		for i = 1, 4 do
			ellipsoid(ctx, "EggRib", center, Vector3.new(0.78, 1.07, 0.05), "Raw", CFrame.Angles(0, i * math.pi / 4, 0), nil, color:Lerp(DARK, 0.2))
		end
	else
		local speckle = plan.LarvaColor:Lerp(DARK, 0.4)
		for k = 1, 3 do
			local dy = (k - 2) * 0.2
			local ring = 0.375 * math.sqrt(1 - (dy / 0.525) ^ 2)
			ellipsoid(ctx, "EggSpeckle", at(ctx, math.cos(k * 2.1) * ring, 0.55 + dy, math.sin(k * 2.1) * ring), Vector3.one * 0.1, "Raw", nil, nil, speckle)
		end
	end
	ellipsoid(ctx, "EggPad", at(ctx, 0, 0.04, 0), Vector3.new(1.3, 0.08, 1.5), "Raw", nil, nil, Color3.fromRGB(110, 150, 70))
end

local function buildCocoon(ctx: Ctx)
	local plan = ctx.plan
	if plan.Wings == "Butterfly" then
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
		local pale = plan.LarvaColor:Lerp(Color3.fromRGB(240, 225, 190), 0.7)
		local pad = pale:Lerp(plan.Secondary, 0.3)
		ellipsoid(ctx, "PupaHead", at(ctx, 0, 0.36, -0.64), Vector3.new(0.45, 0.42, 0.4), "Raw", nil, nil, pale)
		ellipsoid(ctx, "PupaThorax", at(ctx, 0, 0.5, -0.3), Vector3.new(0.72, 0.62, 0.62), "Raw", nil, nil, pale)
		for i = 1, 4 do
			local width = 0.74 - i * 0.09
			ellipsoid(ctx, "PupaSegment", at(ctx, 0, 0.44 - i * 0.02, 0.02 + (i - 1) * 0.24), Vector3.new(width, width * 0.8, 0.34), "Raw", nil, nil, pale)
		end
		for _, side in ipairs(SIDES) do
			ellipsoid(ctx, "PupaWingPad", at(ctx, side * 0.34, 0.36, -0.05), Vector3.new(0.14, 0.4, 0.62), "Raw", CFrame.Angles(0.35, 0, 0), nil, pad)
			limb(ctx, "PupaLeg", at(ctx, side * 0.2, 0.3, -0.48), at(ctx, side * 0.12, 0.2, -0.08), 0.07, "Raw", pad)
		end
		if plan.Horn or plan.Jaws == "Stag" then
			limb(ctx, "PupaHorn", at(ctx, 0, 0.42, -0.78), at(ctx, 0, 0.16, -1.15), 0.12, "Raw", pad)
		end
		return
	end
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
	local count = 8
	local radius = 0.5
	for i = 1, count do
		local angle = math.rad(-115 + (i - 1) * 230 / (count - 1))
		local size = 0.4 + math.sin(i / (count + 1) * math.pi) * 0.16
		local center = at(ctx, -math.cos(angle) * radius, 0.05 + size * 0.45, math.sin(angle) * radius)
		ellipsoid(ctx, "GrubSegment", center, Vector3.new(size, size * 0.9, 0.36), "Larva", CFrame.Angles(0, angle, 0))
		if i <= 3 then
			limb(ctx, "GrubLeg", center, at(ctx, -math.cos(angle) * radius * 0.4, 0.03, math.sin(angle) * radius * 0.4), 0.05, "Raw", Color3.fromRGB(150, 100, 50))
		end
	end
	local headAngle = math.rad(-143)
	local hx, hz = -math.cos(headAngle) * radius, math.sin(headAngle) * radius
	local brown = Color3.fromRGB(150, 100, 50)
	ellipsoid(ctx, "GrubHead", at(ctx, hx, 0.22, hz), Vector3.new(0.34, 0.3, 0.3), "Raw", nil, nil, brown)
	for _, side in ipairs(SIDES) do
		limb(ctx, "Mandible", at(ctx, hx + 0.1, 0.18, hz + side * 0.07), at(ctx, hx + 0.26, 0.14, hz + side * 0.02), 0.05, "Dark")
	end
end

local function buildCrawler(ctx: Ctx)
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
		local part = ellipsoid(ctx, "LarvaSegment", at(ctx, 0, 0.24, z), Vector3.new(width, 0.26, 0.28), if glowing then "Accent" else "Larva")
		if glowing then
			part.Material = Enum.Material.Neon
		end
		if i == 2 or i == 5 then
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
	local count = 9
	local bands = { ctx.plan.LarvaColor, DARK, WHITE }
	for i = 1, count do
		local z = -1.0 + (i - 1) * 0.25
		local size = if i == 1 then 0.38 else 0.42
		ellipsoid(ctx, "CaterpillarSegment", at(ctx, 0, 0.27, z), Vector3.new(size, size, 0.3), "Raw", nil, nil, bands[(i % 3) + 1])
		for _, side in ipairs(SIDES) do
			if i <= 2 then
				ellipsoid(ctx, "TrueLeg", at(ctx, side * 0.12, 0.05, z), Vector3.new(0.07, 0.12, 0.07), "Dark")
			elseif i < count - 1 and i % 2 == 0 then
				ellipsoid(ctx, "Proleg", at(ctx, side * 0.15, 0.05, z), Vector3.one * 0.11, "Dark")
			end
		end
	end
	ellipsoid(ctx, "CaterpillarHead", at(ctx, 0, 0.24, -1.2), Vector3.new(0.32, 0.32, 0.26), "Dark")
	for _, z in ipairs({ -1.0, 1.0 }) do
		for _, side in ipairs(SIDES) do
			local base = at(ctx, side * 0.08, 0.45, z)
			limb(ctx, "Filament", base, base + Vector3.new(side * 0.1, 0.3, z * 0.15) * ctx.s, 0.04, "Dark")
		end
	end
end

local function buildAquaticNymph(ctx: Ctx)
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
		ellipsoid(ctx, "NymphSegment", at(ctx, 0, 0.28, z), Vector3.new(width, 0.26, 0.3), "Larva")
		if mayfly and i <= 3 then
			for _, side in ipairs(SIDES) do
				flatPanel(ctx, "Gill", at(ctx, side * (width * 0.5 + 0.08), 0.3, z), Vector3.new(0.22, 0.03, 0.14), CFrame.Angles(0, 0, side * 0.4), "Larva", 0.3)
			end
		end
	end
	local tailBase = at(ctx, 0, 0.28, 1.0)
	if mayfly then
		for i = -1, 1 do
			limb(ctx, "Cercus", tailBase, at(ctx, i * 0.3, 0.3, 1.7), 0.03, "Larva")
		end
	elseif plan.Wings == "Elytra" then
		for _, side in ipairs(SIDES) do
			limb(ctx, "Mandible", at(ctx, side * 0.2, 0.28, -0.92), at(ctx, side * 0.05, 0.26, -1.25), 0.06, "Dark")
			limb(ctx, "Cercus", tailBase, at(ctx, side * 0.12, 0.34, 1.35), 0.04, "Larva")
		end
	else
		limb(ctx, "Mask", at(ctx, 0, 0.15, -0.55), at(ctx, 0, 0.12, -1.05), 0.1, "Dark")
		for i = -1, 1 do
			limb(ctx, "AnalSpine", tailBase, at(ctx, i * 0.1, 0.28, 1.25), 0.05, "Dark")
		end
	end
	for i = 1, 3 do
		larvaLegPair(ctx, i, -0.45 + (i - 1) * 0.2, 0.22, 0.55, "Larva")
	end
end

local function buildWiggler(ctx: Ctx)
	for i = 1, 8 do
		local z = -0.7 + (i - 1) * 0.18
		local size = if i == 1 then 0.3 elseif i == 2 then 0.42 else 0.22
		ellipsoid(ctx, "WigglerSegment", at(ctx, math.sin(i * 0.8) * 0.05, 0.35, z), Vector3.new(size, size, 0.2), "Larva")
	end
	for _, side in ipairs(SIDES) do
		ellipsoid(ctx, "Eye", at(ctx, side * 0.13, 0.38, -0.72), Vector3.one * 0.08, "Dark")
		limb(ctx, "MouthBrush", at(ctx, side * 0.06, 0.33, -0.82), at(ctx, side * 0.14, 0.3, -0.98), 0.05, "Dark")
		limb(ctx, "Bristle", at(ctx, side * 0.18, 0.37, -0.52), at(ctx, side * 0.42, 0.42, -0.5), 0.025, "Dark")
	end
	limb(ctx, "Siphon", at(ctx, 0, 0.35, 0.55), at(ctx, 0, 0.62, 0.82), 0.07, "Dark")
	limb(ctx, "AnalGill", at(ctx, 0, 0.33, 0.57), at(ctx, 0, 0.22, 0.78), 0.06, "Larva")
end

local function buildCaseLarva(ctx: Ctx)
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
	if molting then
		ellipsoid(ctx, "Exuviae", at(ctx, 0.9, 0.2, 0.4), Vector3.new(0.5, 0.3, 0.9), "Raw", nil, 0.5, Color3.fromRGB(200, 180, 140))
	end
end

-- Mini socle diorama adapté au biome de l'espèce (Terrestre = mousse/feuille, Volant = écorce/fleur, Aquatique = mare/nénuphar).
local function buildPedestal(container: Model, category: string)
	local function addSoclePart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?, transparency: number?)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		if shape then
			p.Shape = shape
		end
		p.Transparency = transparency or 0
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Parent = container
	end

	-- Socle cylindrique principal (axe X = hauteur d'un cylindre Roblox).
	local upCyl = CFrame.Angles(0, 0, math.rad(90))
	if category == "Aquatique" then
		addSoclePart("PedestalBase", Vector3.new(0.32, 3.8, 3.8), CFrame.new(0, -0.32, 0) * upCyl, Color3.fromRGB(58, 52, 42), Enum.Material.Slate, Enum.PartType.Cylinder)
		addSoclePart("PedestalWater", Vector3.new(0.22, 3.55, 3.55), CFrame.new(0, -0.11, 0) * upCyl, Color3.fromRGB(52, 138, 175), Enum.Material.Glass, Enum.PartType.Cylinder, 0.32)
		addSoclePart("LilyPad", Vector3.new(0.06, 1.9, 1.9), CFrame.new(0.15, 0.01, 0.1) * upCyl, Color3.fromRGB(76, 152, 68), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		addSoclePart("Pebble", Vector3.new(0.45, 0.25, 0.38), CFrame.new(-0.95, 0.02, 0.65) * CFrame.Angles(0.1, 0.5, 0), Color3.fromRGB(115, 118, 122), Enum.Material.Slate)
	elseif category == "Volant" then
		addSoclePart("PedestalBark", Vector3.new(0.36, 3.6, 3.6), CFrame.new(0, -0.22, 0) * upCyl, Color3.fromRGB(84, 56, 36), Enum.Material.Wood, Enum.PartType.Cylinder)
		addSoclePart("PedestalMoss", Vector3.new(0.14, 3.3, 3.3), CFrame.new(0, -0.05, 0) * upCyl, Color3.fromRGB(92, 154, 72), Enum.Material.Grass, Enum.PartType.Cylinder)
		addSoclePart("AmberDrop", Vector3.new(0.28, 0.24, 0.28), CFrame.new(1.05, 0.1, -0.65), Color3.fromRGB(245, 185, 55), Enum.Material.Neon, Enum.PartType.Ball, 0.15)
	else
		addSoclePart("PedestalEarth", Vector3.new(0.34, 3.7, 3.7), CFrame.new(0, -0.22, 0) * upCyl, Color3.fromRGB(68, 48, 34), Enum.Material.Slate, Enum.PartType.Cylinder)
		addSoclePart("PedestalMoss", Vector3.new(0.14, 3.45, 3.45), CFrame.new(0, -0.05, 0) * upCyl, Color3.fromRGB(78, 138, 64), Enum.Material.Grass, Enum.PartType.Cylinder)
		addSoclePart("TwigDecor", Vector3.new(0.18, 0.16, 1.15), CFrame.new(-0.95, 0.06, 0.55) * CFrame.Angles(0, 0.65, 0.08), Color3.fromRGB(102, 72, 44), Enum.Material.Wood)
	end
end

-- Construit un Model 3D autonome d'une espèce à un stade donné.
function CreatureViewport.BuildModel(speciesId: string, stage: string?, mutationId: string?, withPedestal: boolean?): Model
	-- Animal jouable : son modèle d'IA réduit à la taille du socle, posé dessus.
	local entry = PlayableAnimals.Get(speciesId)
	local animal = if entry then PlayableAnimals.BuildScaled(speciesId, 3.2 / entry.Length) else nil
	if animal then
		animal.Name = "Preview_" .. speciesId
		for _, descendant in ipairs(animal:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
		local center, size = animal:GetBoundingBox()
		animal:PivotTo(animal:GetPivot() + Vector3.new(-center.X, size.Y * 0.5 - center.Y, -center.Z))
		if withPedestal then
			buildPedestal(animal, "Terrestre")
		end
		return animal
	end
	local actualStage = stage or "Adulte"
	local plan = InsectBodyPlans.Get(speciesId)
	local info = InsectData[speciesId]
	local container = Instance.new("Model")
	container.Name = "Preview_" .. speciesId .. "_" .. actualStage

	local ctx: Ctx = {
		container = container,
		plan = plan,
		s = plan.Length,
		groundY = 0,
		mutation = if mutationId then InsectBodyPlans.Mutations[mutationId] else nil,
		partIndex = 0,
		pale = 0,
		rounded = actualStage == "Oeuf" or actualStage == "Cocon",
	}

	if actualStage == "Oeuf" then
		ctx.s = 1.15
		buildEgg(ctx)
	elseif actualStage == "Cocon" then
		ctx.s = 1.05
		buildCocoon(ctx)
	elseif actualStage == "Mue" then
		ctx.pale = 0.45
		ctx.s = plan.Length * 0.95
		buildLarva(ctx, true)
	elseif actualStage == "Larve" then
		ctx.s = plan.Length * 0.95
		buildLarva(ctx, false)
	else
		local wingsUnlocked = plan.Wings ~= "None"
		buildAdult(ctx, wingsUnlocked)
	end

	if withPedestal then
		buildPedestal(container, if info then info.Category else "Terrestre")
	end

	return container
end

-- Calcule la position de la caméra pour cadrer parfaitement le modèle sous un angle donné.
local function positionCamera(camera: Camera, center: Vector3, extents: Vector3, yaw: number, pitch: number, zoomFactor: number)
	local maxDim = math.max(extents.X, extents.Y * 1.15, extents.Z, 1.1)
	local fovRad = math.rad(camera.FieldOfView)
	local distance = (maxDim * 0.54 / math.tan(fovRad * 0.5)) * zoomFactor
	local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local camPos = center + (rot * Vector3.new(0, 0, distance))
	camera.CFrame = CFrame.lookAt(camPos, center)
end

-- Crée un ViewportFrame géré (miniature statique ou vitrine 3D interactive avec rotation au glisser).
function CreatureViewport.Create(parent: Instance, interactive: boolean, zoomFactor: number?): ViewportHandle
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "CreatureViewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(165, 182, 168)
	viewport.LightColor = Color3.fromRGB(255, 246, 222)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.5)
	viewport.Parent = parent

	local camera = Instance.new("Camera")
	camera.FieldOfView = 36
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local currentModel: Model? = nil
	local modelCenter = Vector3.new(0, 0.5, 0)
	local modelExtents = Vector3.new(2, 1.5, 2)
	local baseYaw = math.rad(145) -- 3/4 avant-gauche (la tête de l'insecte regarde -Z)
	local basePitch = math.rad(-20)
	local yaw = baseYaw
	local pitch = basePitch
	local zoom = zoomFactor or 1.05
	local turntableConn: RBXScriptConnection? = nil
	local burstConn: RBXScriptConnection? = nil
	local inputEndedConn: RBXScriptConnection? = nil
	local dragging = false
	local lastMousePos = Vector2.zero
	local spinBoost = 0

	local function updateCamera(bobOffset: number?)
		local targetCenter = if bobOffset then modelCenter + Vector3.new(0, bobOffset, 0) else modelCenter
		positionCamera(camera, targetCenter, modelExtents, yaw, pitch, zoom)
	end

	local function setCreature(speciesId: string, stage: string?, mutationId: string?, withPedestal: boolean?)
		if currentModel then
			currentModel:Destroy()
			currentModel = nil
		end
		local ok, built = pcall(CreatureViewport.BuildModel, speciesId, stage, mutationId, withPedestal)
		if not ok or not built then
			return
		end
		local model = built :: Model
		model.Parent = viewport
		currentModel = model

		local boxCf, boxSize = model:GetBoundingBox()
		modelCenter = boxCf.Position
		modelExtents = boxSize
		updateCamera(0)
	end

	local function spinOnce()
		UiTheme.Pop(viewport, 0.84, 0.34)
		if turntableConn then
			spinBoost = math.rad(360)
			return
		end
		if burstConn then
			burstConn:Disconnect()
			burstConn = nil
		end
		local startYaw = yaw
		local elapsed = 0
		local duration = 0.55
		burstConn = RunService.RenderStepped:Connect(function(dt: number)
			elapsed += dt
			local t = math.clamp(elapsed / duration, 0, 1)
			local eased = 1 - (1 - t) ^ 3
			yaw = startYaw + eased * math.rad(360)
			updateCamera(math.sin(t * math.pi) * 0.08)
			if t >= 1 then
				yaw = baseYaw
				updateCamera(0)
				if burstConn then
					burstConn:Disconnect()
					burstConn = nil
				end
			end
		end)
	end

	local function setTurntableActive(active: boolean)
		if not active then
			if turntableConn then
				turntableConn:Disconnect()
				turntableConn = nil
			end
			dragging = false
			return
		end
		if turntableConn then
			return
		end
		local clock = 0
		turntableConn = RunService.RenderStepped:Connect(function(dt: number)
			clock += dt
			if not dragging then
				yaw += dt * 0.48
			end
			if spinBoost > 0.01 then
				local step = math.min(spinBoost, dt * 10 + spinBoost * dt * 8)
				yaw += step
				spinBoost -= step
			else
				spinBoost = 0
			end
			local bob = math.sin(clock * 2.4) * 0.035
			updateCamera(bob)
		end)
	end

	if interactive then
		viewport.Active = true
		viewport.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				lastMousePos = Vector2.new(input.Position.X, input.Position.Y)
			end
		end)
		viewport.InputChanged:Connect(function(input: InputObject)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local pos = Vector2.new(input.Position.X, input.Position.Y)
				local delta = pos - lastMousePos
				lastMousePos = pos
				yaw -= delta.X * 0.012
				pitch = math.clamp(pitch - delta.Y * 0.008, math.rad(-52), math.rad(-4))
				updateCamera(0)
			end
		end)
		inputEndedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end

	local function destroy()
		setTurntableActive(false)
		if burstConn then
			burstConn:Disconnect()
			burstConn = nil
		end
		if inputEndedConn then
			inputEndedConn:Disconnect()
			inputEndedConn = nil
		end
		if currentModel then
			currentModel:Destroy()
			currentModel = nil
		end
		viewport:Destroy()
	end

	return {
		Viewport = viewport,
		Camera = camera,
		SetCreature = setCreature,
		SpinOnce = spinOnce,
		SetTurntableActive = setTurntableActive,
		Destroy = destroy,
	}
end

return CreatureViewport
