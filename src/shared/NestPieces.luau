--!strict
-- NestPieces.luau
-- Catalogue des pièces de nid à placer librement (mode construction, NestBuildingService /
-- BuildModeController). Chaque espèce a un THÈME qui lui donne ses pièces propres (fourmilière,
-- ruche, toile, nid d'oiseau, drey, nid aquatique, feuillage), en plus des pièces communes.
-- Toutes les pièces sont en blocs (style du jeu), construites autour d'une origine posée au sol
-- (-Z = avant de la pièce). Utilisé par le serveur (vraie pièce) et le client (aperçu fantôme).

export type Cost = { Feuille: number?, Brindille: number?, Caillou: number?, Terre: number?, Cire: number?, Soie: number?, Papier: number? }
export type Piece = {
	Id: string,
	Name: string,
	Theme: string, -- "Commun" ou un thème d'espèce
	Cost: Cost,
	Solid: boolean, -- murs, dômes : on ne passe pas au travers
	Brick: number?, -- bloc unitaire (taille de grille) : centré sur l'origine, s'empile librement
	Build: (model: Model, origin: CFrame) -> (),
}

local NestPieces = {}

-- Cire / Soie sont sécrétées par l'animal lui-même ; Papier = brindilles mâchées (guêpes, frelons).
NestPieces.MATERIAL_ORDER = { "Feuille", "Brindille", "Caillou", "Terre", "Cire", "Soie", "Papier" }
NestPieces.MATERIAL_ICONS = { Feuille = "🍂", Brindille = "🪵", Caillou = "🪨", Terre = "🟫", Cire = "🍯", Soie = "🕸", Papier = "📜" }
NestPieces.THEME_NAMES = {
	Commun = "Commun",
	Terre = "Fourmilière / Terrier",
	Ruche = "Ruche de cire",
	Papier = "Nid de papier",
	Soie = "Soie",
	Aquatique = "Aquatique",
	Oiseau = "Nid d'oiseau",
	Ecureuil = "Drey d'écureuil",
	Feuillage = "Feuillage",
}

local LEAF = Color3.fromRGB(96, 150, 62)
local LEAF_DRY = Color3.fromRGB(160, 132, 62)
local TWIG = Color3.fromRGB(120, 84, 52)
local STONE = Color3.fromRGB(128, 126, 120)
local EARTH = Color3.fromRGB(105, 78, 52)
local WAX = Color3.fromRGB(236, 186, 64)
local PAPER = Color3.fromRGB(196, 176, 140)
local SILK = Color3.fromRGB(242, 242, 248)
local SAND = Color3.fromRGB(196, 178, 132)
local REED = Color3.fromRGB(110, 140, 70)

local function add(model: Model, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number?)
	local part = Instance.new("Part")
	part.Name = "PiecePart"
	part.Anchored = true
	part.CanTouch = false
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	if math.min(size.X, size.Y, size.Z) < 0.5 then
		part.CastShadow = false
	end
	part.Parent = model
end

-- Bâton de a vers b (coordonnées locales à l'origine).
local function stick(model: Model, origin: CFrame, a: Vector3, b: Vector3, thickness: number, color: Color3, material: Enum.Material?)
	local delta = b - a
	if delta.Magnitude < 0.05 then
		return
	end
	add(model, Vector3.new(thickness, thickness, delta.Magnitude), origin * CFrame.lookAt(a:Lerp(b, 0.5), b), color, material or Enum.Material.Wood)
end

-- Anneau de blocs (dômes, murets circulaires). `gap` = angle laissé ouvert à l'avant (entrée).
local function ring(model: Model, origin: CFrame, radius: number, y: number, count: number, size: Vector3, color: Color3, material: Enum.Material, gap: number?)
	for i = 0, count - 1 do
		local angle = i / count * math.pi * 2
		local front = math.abs(((angle + math.pi) % (math.pi * 2)) - math.pi) -- 0 = avant (-Z)
		if gap and front < gap then
			continue
		end
		local position = Vector3.new(math.sin(angle) * radius, y, -math.cos(angle) * radius)
		add(model, size, origin * CFrame.new(position) * CFrame.Angles(0, -angle, 0), color, material)
	end
end

-- Bloc unitaire d'une espèce : une seule matière, posé grain par grain pour donner SA forme au nid.
local function brick(id: string, name: string, theme: string, cost: Cost, size: number, build: (model: Model, origin: CFrame) -> ()): Piece
	return { Id = id, Name = "▣ " .. name, Theme = theme, Cost = cost, Solid = true, Brick = size, Build = build }
end

local function cube(size: Vector3, color: Color3, material: Enum.Material, transparency: number?): (Model, CFrame) -> ()
	return function(model, origin)
		add(model, size, origin, color, material, transparency)
	end
end

local PIECES: { Piece } = {
	-- ================= Blocs (construction libre, 1 matériau = 1 bloc) =================
	brick("BlocTerre", "Boulette de terre", "Terre", { Terre = 1 }, 1.6, cube(Vector3.one * 1.6, EARTH, Enum.Material.Ground)),
	-- Alvéole hexagonale (3 blocs tournés de 60°) : la cire est sécrétée par l'abeille, cellule par cellule.
	brick("Alveole", "Alvéole de cire", "Ruche", { Cire = 1 }, 1.6, function(model, origin)
		for i = 0, 2 do
			add(model, Vector3.new(0.92, 1.6, 1.6), origin * CFrame.Angles(0, 0, i * math.pi / 3), WAX, Enum.Material.SmoothPlastic)
		end
	end),
	brick("FeuillePapier", "Feuille de papier mâché", "Papier", { Papier = 1 }, 1.6, cube(Vector3.new(1.6, 1.6, 1.6), PAPER, Enum.Material.Fabric)),
	brick("NappeSoie", "Nappe de soie", "Soie", { Soie = 1 }, 1.6, cube(Vector3.new(1.6, 1.6, 1.6), SILK, Enum.Material.Fabric, 0.35)),
	brick("BrindilleTressee", "Brindilles tressées", "Oiseau", { Brindille = 1 }, 1.6, cube(Vector3.new(1.6, 1.6, 1.6), TWIG, Enum.Material.Wood)),
	brick("PaquetFeuilles", "Paquet de feuilles", "Ecureuil", { Feuille = 1 }, 1.6, cube(Vector3.one * 1.6, LEAF_DRY, Enum.Material.LeafyGrass)),
	brick("Galet", "Galet", "Aquatique", { Caillou = 1 }, 1.6, cube(Vector3.one * 1.6, SAND, Enum.Material.Sand)),
	brick("BlocFeuille", "Bloc de feuille", "Feuillage", { Feuille = 1 }, 1.6, cube(Vector3.one * 1.6, LEAF, Enum.Material.LeafyGrass)),

	-- ================= Communes =================
	{
		Id = "TapisFeuilles", Name = "Tapis de feuilles", Theme = "Commun", Cost = { Feuille = 3 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 5 do
				local a = i / 6 * math.pi * 2
				add(model, Vector3.new(3, 0.2, 2), origin * CFrame.new(math.cos(a) * 1.6, 0.12 + i * 0.01, math.sin(a) * 1.6) * CFrame.Angles(0, a, 0), if i % 2 == 0 then LEAF else LEAF_DRY, Enum.Material.LeafyGrass)
			end
		end,
	},
	{
		Id = "Palissade", Name = "Palissade de brindilles", Theme = "Commun", Cost = { Brindille = 4 }, Solid = true,
		Build = function(model, origin)
			for i = -2, 2 do
				stick(model, origin, Vector3.new(i * 1.2, 0, 0), Vector3.new(i * 1.2, 4 + (i % 2) * 0.4, 0), 0.4, TWIG)
			end
			stick(model, origin, Vector3.new(-2.8, 1.2, 0.3), Vector3.new(2.8, 1.2, 0.3), 0.3, TWIG)
			stick(model, origin, Vector3.new(-2.8, 3, 0.3), Vector3.new(2.8, 3, 0.3), 0.3, TWIG)
		end,
	},
	{
		Id = "Muret", Name = "Muret de cailloux", Theme = "Commun", Cost = { Caillou = 3 }, Solid = true,
		Build = function(model, origin)
			for i = 0, 5 do
				local s = 1.2 + (i % 3) * 0.2
				add(model, Vector3.new(s, s * 0.75, s), origin * CFrame.new(-2.5 + i, s * 0.37, 0) * CFrame.Angles(0, i * 0.7, 0), STONE:Lerp(Color3.new(1, 1, 1), (i % 2) * 0.08), Enum.Material.Slate)
			end
			for i = 0, 3 do
				add(model, Vector3.new(1.1, 0.8, 1.1), origin * CFrame.new(-1.5 + i, 1.3, 0) * CFrame.Angles(0, i, 0), STONE, Enum.Material.Slate)
			end
		end,
	},
	{
		Id = "Butte", Name = "Butte de terre", Theme = "Commun", Cost = { Terre = 4 }, Solid = true,
		Build = function(model, origin)
			add(model, Vector3.new(5, 1.2, 5), origin * CFrame.new(0, 0.6, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(3.4, 1.2, 3.4), origin * CFrame.new(0, 1.6, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(1.8, 1, 1.8), origin * CFrame.new(0, 2.6, 0), EARTH, Enum.Material.Ground)
		end,
	},

	-- ================= Fourmilière / Terrier =================
	{
		Id = "DomeTerre", Name = "Dôme de terre", Theme = "Terre", Cost = { Terre = 8, Brindille = 2 }, Solid = true,
		Build = function(model, origin)
			ring(model, origin, 3.6, 0.8, 12, Vector3.new(2, 1.6, 1.4), EARTH, Enum.Material.Ground, 0.4)
			ring(model, origin, 2.6, 2.3, 9, Vector3.new(1.9, 1.5, 1.4), EARTH, Enum.Material.Ground)
			ring(model, origin, 1.4, 3.6, 6, Vector3.new(1.6, 1.3, 1.3), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(1.4, 1, 1.4), origin * CFrame.new(0, 4.6, 0), EARTH, Enum.Material.Ground)
		end,
	},
	{
		Id = "EntreeTunnel", Name = "Entrée de galerie", Theme = "Terre", Cost = { Terre = 4, Caillou = 1 }, Solid = true,
		Build = function(model, origin)
			add(model, Vector3.new(1, 2.6, 1.6), origin * CFrame.new(-1.6, 1.3, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(1, 2.6, 1.6), origin * CFrame.new(1.6, 1.3, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(4.2, 1, 1.8), origin * CFrame.new(0, 3, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(2.2, 0.2, 2), origin * CFrame.new(0, 0.05, 0), Color3.fromRGB(40, 30, 22), Enum.Material.Ground)
		end,
	},
	{
		Id = "Cheminee", Name = "Cheminée d'aération", Theme = "Terre", Cost = { Terre = 5 }, Solid = true,
		Build = function(model, origin)
			for i = 0, 4 do
				local w = 2.6 - i * 0.35
				add(model, Vector3.new(w, 1.3, w), origin * CFrame.new(0, 0.65 + i * 1.3, 0) * CFrame.Angles(0, i * 0.3, 0), EARTH:Lerp(Color3.new(0, 0, 0), i * 0.04), Enum.Material.Ground)
			end
		end,
	},
	{
		Id = "Chambre", Name = "Chambre à couvain", Theme = "Terre", Cost = { Terre = 5, Feuille = 2 }, Solid = true,
		Build = function(model, origin)
			ring(model, origin, 2.2, 0.7, 8, Vector3.new(1.6, 1.4, 1.1), EARTH, Enum.Material.Ground, 0.5)
			add(model, Vector3.new(3, 0.8, 3), origin * CFrame.new(0, 1.8, 0), EARTH, Enum.Material.Ground)
			add(model, Vector3.new(2.4, 0.2, 2.4), origin * CFrame.new(0, 0.1, 0), LEAF_DRY, Enum.Material.LeafyGrass)
		end,
	},

	-- ================= Ruche & papier =================
	{
		Id = "Rayon", Name = "Rayon d'alvéoles", Theme = "Ruche", Cost = { Cire = 6 }, Solid = true,
		Build = function(model, origin)
			for row = 0, 3 do
				for col = 0, 4 do
					local x = -2 + col + (row % 2) * 0.5
					add(model, Vector3.new(0.95, 0.85, 0.6), origin * CFrame.new(x, 0.5 + row * 0.85, 0), if (row + col) % 3 == 0 then WAX:Lerp(Color3.fromRGB(200, 120, 20), 0.4) else WAX, Enum.Material.SmoothPlastic)
				end
			end
		end,
	},
	{
		Id = "TourCire", Name = "Tour de cire", Theme = "Ruche", Cost = { Cire = 5 }, Solid = true,
		Build = function(model, origin)
			for i = 0, 5 do
				add(model, Vector3.new(1.8, 0.9, 1.8), origin * CFrame.new(0, 0.45 + i * 0.9, 0) * CFrame.Angles(0, i * math.pi / 6, 0), WAX, Enum.Material.SmoothPlastic)
			end
			add(model, Vector3.new(1.2, 0.6, 1.2), origin * CFrame.new(0, 5.7, 0), WAX:Lerp(Color3.new(1, 1, 1), 0.3), Enum.Material.SmoothPlastic)
		end,
	},
	{
		Id = "CoquePapier", Name = "Coque de papier", Theme = "Papier", Cost = { Papier = 6, Brindille = 1 }, Solid = true,
		Build = function(model, origin)
			ring(model, origin, 2.4, 1, 10, Vector3.new(1.6, 2, 0.4), PAPER, Enum.Material.Fabric, 0.35)
			ring(model, origin, 2, 2.8, 8, Vector3.new(1.6, 1.8, 0.4), PAPER:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Fabric)
			add(model, Vector3.new(2.6, 0.6, 2.6), origin * CFrame.new(0, 4, 0), PAPER, Enum.Material.Fabric)
		end,
	},

	-- ================= Soie =================
	{
		Id = "PanneauToile", Name = "Panneau de toile", Theme = "Soie", Cost = { Brindille = 2, Soie = 2 }, Solid = false,
		Build = function(model, origin)
			stick(model, origin, Vector3.new(-2.6, 0, 0), Vector3.new(-2.6, 5, 0), 0.35, TWIG)
			stick(model, origin, Vector3.new(2.6, 0, 0), Vector3.new(2.6, 5, 0), 0.35, TWIG)
			local center = Vector3.new(0, 2.6, 0)
			for i = 0, 7 do
				local a = i / 8 * math.pi * 2
				stick(model, origin, center, center + Vector3.new(math.cos(a) * 2.5, math.sin(a) * 2.3, 0), 0.06, SILK, Enum.Material.SmoothPlastic)
			end
			for r = 1, 3 do
				for i = 0, 7 do
					local a, b = i / 8 * math.pi * 2, (i + 1) / 8 * math.pi * 2
					local f = r * 0.7
					stick(model, origin, center + Vector3.new(math.cos(a) * f, math.sin(a) * f * 0.92, 0), center + Vector3.new(math.cos(b) * f, math.sin(b) * f * 0.92, 0), 0.05, SILK, Enum.Material.SmoothPlastic)
				end
			end
		end,
	},
	{
		Id = "TunnelSoie", Name = "Tunnel de soie", Theme = "Soie", Cost = { Soie = 3 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 4 do
				add(model, Vector3.new(2.4, 2.4, 0.9), origin * CFrame.new(0, 1.2, -2 + i), SILK, Enum.Material.Fabric, 0.35)
			end
		end,
	},
	{
		Id = "CoconSoie", Name = "Sac d'oeufs de soie", Theme = "Soie", Cost = { Soie = 2 }, Solid = false,
		Build = function(model, origin)
			stick(model, origin, Vector3.new(0, 0, 0), Vector3.new(0, 3.2, 0), 0.06, SILK, Enum.Material.SmoothPlastic)
			add(model, Vector3.new(1.4, 1.6, 1.4), origin * CFrame.new(0, 2.2, 0), SILK, Enum.Material.Fabric)
			add(model, Vector3.new(1, 2, 1), origin * CFrame.new(0, 2.2, 0), SILK, Enum.Material.Fabric)
		end,
	},
	{
		Id = "HamacSoie", Name = "Hamac de soie", Theme = "Soie", Cost = { Brindille = 2, Soie = 2 }, Solid = false,
		Build = function(model, origin)
			for _, x in ipairs({ -2.5, 2.5 }) do
				stick(model, origin, Vector3.new(x, 0, 0), Vector3.new(x, 2.2, 0), 0.3, TWIG)
			end
			add(model, Vector3.new(5, 0.1, 2.4), origin * CFrame.new(0, 1.8, 0), SILK, Enum.Material.Fabric, 0.3)
		end,
	},

	-- ================= Aquatique =================
	{
		Id = "CercleGravier", Name = "Cercle de gravier", Theme = "Aquatique", Cost = { Caillou = 3 }, Solid = false,
		Build = function(model, origin)
			ring(model, origin, 2.4, 0.25, 12, Vector3.new(0.8, 0.5, 0.8), SAND, Enum.Material.Sand)
			add(model, Vector3.new(3.4, 0.15, 3.4), origin * CFrame.new(0, 0.08, 0), SAND:Lerp(Color3.new(1, 1, 1), 0.2), Enum.Material.Sand)
		end,
	},
	{
		Id = "Roseaux", Name = "Bosquet de roseaux", Theme = "Aquatique", Cost = { Feuille = 2, Brindille = 1 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 6 do
				local a = i * 2.4
				local x, z = math.cos(a) * (0.4 + i * 0.15), math.sin(a) * (0.4 + i * 0.15)
				stick(model, origin, Vector3.new(x, 0, z), Vector3.new(x * 1.3, 5 + (i % 3), z * 1.3), 0.22, REED, Enum.Material.Grass)
			end
		end,
	},
	{
		Id = "Coquillage", Name = "Coquillage abri", Theme = "Aquatique", Cost = { Caillou = 4 }, Solid = true,
		Build = function(model, origin)
			ring(model, origin, 2, 0.6, 9, Vector3.new(1.4, 1.2, 0.5), Color3.fromRGB(230, 214, 196), Enum.Material.Marble, 0.6)
			add(model, Vector3.new(3.6, 0.5, 3.6), origin * CFrame.new(0, 1.4, 0) * CFrame.Angles(0.15, 0, 0), Color3.fromRGB(236, 200, 180), Enum.Material.Marble)
		end,
	},
	{
		Id = "BulleAir", Name = "Bulle d'air", Theme = "Aquatique", Cost = { Feuille = 2 }, Solid = false,
		Build = function(model, origin)
			add(model, Vector3.new(3, 2.6, 3), origin * CFrame.new(0, 2.4, 0), Color3.fromRGB(190, 225, 245), Enum.Material.Glass, 0.6)
			add(model, Vector3.new(2.2, 3.2, 2.2), origin * CFrame.new(0, 2.4, 0), Color3.fromRGB(190, 225, 245), Enum.Material.Glass, 0.6)
		end,
	},

	-- ================= Nid d'oiseau =================
	{
		Id = "CoupeBrindilles", Name = "Coupe de brindilles", Theme = "Oiseau", Cost = { Brindille = 6, Feuille = 2 }, Solid = true,
		Build = function(model, origin)
			for layer = 0, 2 do
				for i = 0, 9 do
					local a = i / 10 * math.pi * 2 + layer * 0.3
					local r = 2.6 + layer * 0.25
					local p = Vector3.new(math.cos(a) * r, 0.4 + layer * 0.55, math.sin(a) * r)
					local q = Vector3.new(math.cos(a + 0.8) * r, 0.6 + layer * 0.55, math.sin(a + 0.8) * r)
					stick(model, origin, p, q, 0.35, TWIG:Lerp(LEAF_DRY, (i % 3) * 0.15))
				end
			end
			add(model, Vector3.new(4, 0.3, 4), origin * CFrame.new(0, 0.3, 0), LEAF_DRY, Enum.Material.Fabric)
		end,
	},
	{
		Id = "Perchoir", Name = "Perchoir", Theme = "Oiseau", Cost = { Brindille = 3 }, Solid = false,
		Build = function(model, origin)
			stick(model, origin, Vector3.new(0, 0, 0), Vector3.new(0, 6, 0), 0.45, TWIG)
			stick(model, origin, Vector3.new(-2.2, 5.2, 0), Vector3.new(2.2, 5.4, 0), 0.35, TWIG)
		end,
	},
	{
		Id = "LitPlumes", Name = "Lit de duvet", Theme = "Oiseau", Cost = { Feuille = 3 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 6 do
				local a = i * 0.9
				add(model, Vector3.new(1.4, 0.3, 0.6), origin * CFrame.new(math.cos(a) * 0.9, 0.2, math.sin(a) * 0.9) * CFrame.Angles(0, a, 0.2), Color3.fromRGB(240, 236, 228), Enum.Material.Fabric)
			end
		end,
	},

	-- ================= Drey d'écureuil =================
	{
		Id = "BouleFeuilles", Name = "Boule de feuilles", Theme = "Ecureuil", Cost = { Feuille = 6, Brindille = 3 }, Solid = true,
		Build = function(model, origin)
			ring(model, origin, 2.8, 1.2, 10, Vector3.new(2, 2.2, 1), LEAF_DRY, Enum.Material.LeafyGrass, 0.35)
			ring(model, origin, 2.2, 3, 8, Vector3.new(2, 1.8, 1), LEAF_DRY:Lerp(LEAF, 0.3), Enum.Material.LeafyGrass)
			add(model, Vector3.new(3, 1, 3), origin * CFrame.new(0, 4.2, 0), LEAF_DRY, Enum.Material.LeafyGrass)
		end,
	},
	{
		Id = "ReserveGlands", Name = "Réserve de glands", Theme = "Ecureuil", Cost = { Caillou = 1, Feuille = 1 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 5 do
				local x, z = (i % 3 - 1) * 0.9, (i // 3 - 0.5) * 0.9
				add(model, Vector3.new(0.8, 0.9, 0.8), origin * CFrame.new(x, 0.45 + (i // 3) * 0.3, z), Color3.fromRGB(150, 100, 50), Enum.Material.Wood)
				add(model, Vector3.new(0.85, 0.3, 0.85), origin * CFrame.new(x, 0.95 + (i // 3) * 0.3, z), Color3.fromRGB(95, 65, 35), Enum.Material.Wood)
			end
		end,
	},
	{
		Id = "Branchage", Name = "Branchage", Theme = "Ecureuil", Cost = { Brindille = 4 }, Solid = true,
		Build = function(model, origin)
			stick(model, origin, Vector3.new(-3, 0, 0), Vector3.new(3, 1.5, 0), 0.6, TWIG)
			for i = -1, 1 do
				stick(model, origin, Vector3.new(i * 1.6, 0.4 + i * 0.4, 0), Vector3.new(i * 1.6 + 0.8, 2.6, -0.8), 0.3, TWIG)
			end
		end,
	},

	-- ================= Feuillage (autres insectes) =================
	{
		Id = "TenteFeuille", Name = "Tente de feuille", Theme = "Feuillage", Cost = { Feuille = 4, Brindille = 1 }, Solid = true,
		Build = function(model, origin)
			add(model, Vector3.new(0.2, 3.4, 5), origin * CFrame.new(-1.2, 1.5, 0) * CFrame.Angles(0, 0, -0.5), LEAF, Enum.Material.LeafyGrass)
			add(model, Vector3.new(0.2, 3.4, 5), origin * CFrame.new(1.2, 1.5, 0) * CFrame.Angles(0, 0, 0.5), LEAF, Enum.Material.LeafyGrass)
			stick(model, origin, Vector3.new(0, 2.9, -2.5), Vector3.new(0, 2.9, 2.5), 0.25, TWIG)
		end,
	},
	{
		Id = "RouleauFeuille", Name = "Feuille roulée", Theme = "Feuillage", Cost = { Feuille = 3 }, Solid = false,
		Build = function(model, origin)
			for i = 0, 5 do
				local a = i / 6 * math.pi * 2
				add(model, Vector3.new(0.2, 1, 4), origin * CFrame.new(math.cos(a) * 0.9, 1 + math.sin(a) * 0.9, 0) * CFrame.Angles(0, 0, a), LEAF:Lerp(LEAF_DRY, 0.3), Enum.Material.LeafyGrass)
			end
		end,
	},
	{
		Id = "Champignon", Name = "Champignon", Theme = "Feuillage", Cost = { Terre = 2 }, Solid = true,
		Build = function(model, origin)
			add(model, Vector3.new(0.9, 2.6, 0.9), origin * CFrame.new(0, 1.3, 0), Color3.fromRGB(235, 225, 205), Enum.Material.SmoothPlastic)
			add(model, Vector3.new(3.2, 0.9, 3.2), origin * CFrame.new(0, 2.9, 0), Color3.fromRGB(200, 60, 45), Enum.Material.SmoothPlastic)
			add(model, Vector3.new(2.2, 0.6, 2.2), origin * CFrame.new(0, 3.5, 0), Color3.fromRGB(200, 60, 45), Enum.Material.SmoothPlastic)
		end,
	},
}

local byId: { [string]: Piece } = {}
for _, piece in ipairs(PIECES) do
	byId[piece.Id] = piece
end

-- Thème de construction d'une espèce (insecte ou animal jouable).
local THEME_BY_SPECIES: { [string]: string } = {
	FourmiRousse = "Terre", TermiteSoldat = "Terre", ScorpionEmpereur = "Terre", Cigale = "Terre",
	ScarabeeHercule = "Terre", ScarabeeBombardier = "Terre", LucaneCerfVolant = "Terre",
	AbeilleMellifere = "Ruche", FrelonAsiatique = "Papier", GuepeEmeraude = "Papier",
	VeuveNoire = "Soie", AraigneeSauteuse = "Soie", Argyronete = "Soie",
	Oiseau = "Oiseau", Ecureuil = "Ecureuil",
	PoissonRouge = "Aquatique", Crabe = "Aquatique",
}

function NestPieces.ThemeFor(speciesId: string, category: string?): string
	local theme = THEME_BY_SPECIES[speciesId]
	if theme then
		return theme
	end
	if category == "Aquatique" then
		return "Aquatique"
	end
	return "Feuillage"
end

function NestPieces.Get(pieceId: string): Piece?
	return byId[pieceId]
end

-- Pièces disponibles pour un thème : les siennes puis les communes.
function NestPieces.ForTheme(theme: string): { Piece }
	local list: { Piece } = {}
	for _, piece in ipairs(PIECES) do
		if piece.Theme == theme then
			table.insert(list, piece)
		end
	end
	for _, piece in ipairs(PIECES) do
		if piece.Theme == "Commun" then
			table.insert(list, piece)
		end
	end
	return list
end

-- Construit une pièce (modèle de parts ancrées) posée sur `origin`.
function NestPieces.Build(piece: Piece, origin: CFrame): Model
	local model = Instance.new("Model")
	model.Name = piece.Id
	piece.Build(model, origin)
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			part.CanCollide = piece.Solid
			part.CanQuery = piece.Solid
		end
	end
	return model
end

return NestPieces
