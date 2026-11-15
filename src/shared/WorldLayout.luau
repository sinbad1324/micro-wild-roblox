--!strict
-- WorldLayout.luau
-- Source unique de vérité pour la géométrie de la Grande Map (GDD section 4) : données pures,
-- aucun service, aucun require. WorldGenerationService construit la carte à partir de ces
-- valeurs ; AnimalService, SeasonVisualService, ShowcaseService, DigService, GrowthAndNestService
-- et GameConstants les lisent au lieu de dupliquer des nombres.
--
-- Toutes les coordonnées liées au Terrain sont des multiples de 4 (taille d'un voxel) : les
-- berges, l'eau et les galeries tombent alors exactement sur la grille, sans demi-voxel.

export type Box = { MinX: number, MaxX: number, MinZ: number, MaxZ: number }

local GROUND_TOP_Y = 48 -- au-dessus de tout contenu Workspace préexistant (Baseplate inclus)
local GROUND_BOTTOM_Y = 8
local MAP_SIZE = 1500 -- 3x l'ancienne carte (500) par côté
local MAP_HALF = MAP_SIZE / 2

-- Un biome par quadrant, le Grand Chêne au centre.
local BIOME_OFFSET = 500

local TREE_POSITION = Vector3.new(0, GROUND_TOP_Y, 0)
local TRUNK_RADIUS = 14
local TRUNK_HEIGHT = 220

local POND_CENTER = Vector3.new(BIOME_OFFSET, GROUND_TOP_Y, -BIOME_OFFSET)
local POND_WATER_LEVEL = GROUND_TOP_Y - 8 -- en contrebas du sol : berges visibles tout autour
local POND_DEPTH = 16

local STUMP_CENTER = Vector3.new(-BIOME_OFFSET, GROUND_TOP_Y, -BIOME_OFFSET)

local WorldLayout = {
	GROUND_TOP_Y = GROUND_TOP_Y,
	GROUND_BOTTOM_Y = GROUND_BOTTOM_Y,
	MAP_SIZE = MAP_SIZE,
	MAP_HALF = MAP_HALF,

	-- "Le Grand Chêne"
	TREE_POSITION = TREE_POSITION,
	TRUNK_RADIUS = TRUNK_RADIUS,
	TRUNK_HEIGHT = TRUNK_HEIGHT,
	CANOPY_RADIUS = 100, -- emprise horizontale maximale des branches + feuillage
	OAK_CENTER = TREE_POSITION,
	OAK_RADIUS = 130, -- zone du biome (racines, fruits tombés, litière)
	-- Corniche "EmplacementRuche" sur le tronc (côté -X), réservée à une future ruche.
	HIVE_POSITION = TREE_POSITION + Vector3.new(-(TRUNK_RADIUS + 4), TRUNK_HEIGHT * 0.55 + 1, 0),

	-- "La Mare" : boîte d'eau alignée sur les axes, centrée sur POND_CENTER.
	POND_CENTER = POND_CENTER,
	POND_RADIUS = 130,
	POND_WATER_SIZE = Vector3.new(200, POND_DEPTH, 144), -- X, profondeur, Z
	POND_BANK_WIDTH = 8, -- berge de sable au niveau de l'eau, tout autour
	POND_WATER_LEVEL = POND_WATER_LEVEL, -- = attribut workspace "PondWaterLevel"
	POND_DEPTH = POND_DEPTH, -- fond à POND_WATER_LEVEL - POND_DEPTH

	-- "Le Ruisseau" : suite de boîtes d'eau (jamais tournées) qui serpente de la mare vers le
	-- Chêne. Même niveau d'eau que la mare ; chaque boîte devient une zone "PondZone".
	STREAM_CENTER = Vector3.new(168, GROUND_TOP_Y, -332),
	STREAM_RADIUS = 260,
	STREAM_DEPTH = 8,
	STREAM_BANK_WIDTH = 8,
	STREAM_SEGMENTS = {
		{ MinX = 240, MaxX = 404, MinZ = -508, MaxZ = -492 }, -- sort de la mare vers l'ouest
		{ MinX = 240, MaxX = 256, MinZ = -508, MaxZ = -324 }, -- remonte vers le nord
		{ MinX = 80, MaxX = 256, MinZ = -340, MaxZ = -324 }, -- ouest
		{ MinX = 80, MaxX = 96, MinZ = -340, MaxZ = -172 }, -- nord
		{ MinX = -80, MaxX = 96, MinZ = -188, MaxZ = -172 }, -- ouest, finit au sud du Chêne
	} :: { Box },

	-- "La Prairie Fleurie"
	PRAIRIE_CENTER = Vector3.new(-BIOME_OFFSET, GROUND_TOP_Y, BIOME_OFFSET),
	PRAIRIE_RADIUS = 200,

	-- "La Souche Pourrie & Les Galeries Souterraines"
	STUMP_CENTER = STUMP_CENTER,
	STUMP_RADIUS = 150,

	-- "Le Coin des Rochers Arides"
	ROCKS_CENTER = Vector3.new(BIOME_OFFSET, GROUND_TOP_Y, BIOME_OFFSET),
	ROCKS_RADIUS = 180,

	-- SpawnLocation "OeufSpawn" (centre de la dalle), près de l'entrée des galeries de la Souche.
	SPAWN_POSITION = STUMP_CENTER + Vector3.new(90, 0.5, 60),

	-- Galerie des modèles 3D (ShowcaseService) : juste au-delà du bord ouest, côté Souche.
	SHOWCASE_ORIGIN = Vector3.new(-MAP_HALF - 12, GROUND_TOP_Y, -640),
}

return WorldLayout
