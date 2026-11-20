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
local MAP_SIZE = 4000 -- immense carte 4000x4000 polyvalente
local MAP_HALF = MAP_SIZE / 2

-- Un biome par quadrant, le Grand Chêne au centre.
local BIOME_OFFSET = 1200

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
	OAK_RADIUS = 180, -- zone du biome (racines, fruits tombés, litière)
	-- Corniche "EmplacementRuche" sur le tronc (côté -X), réservée à une future ruche.
	HIVE_POSITION = TREE_POSITION + Vector3.new(-(TRUNK_RADIUS + 4), TRUNK_HEIGHT * 0.55 + 1, 0),

	-- "La Mare" : boîte d'eau alignée sur les axes, centrée sur POND_CENTER.
	POND_CENTER = POND_CENTER,
	POND_RADIUS = 200,
	POND_WATER_SIZE = Vector3.new(280, POND_DEPTH, 208), -- X, profondeur, Z
	POND_BANK_WIDTH = 8, -- berge de sable au niveau de l'eau, tout autour
	POND_WATER_LEVEL = POND_WATER_LEVEL, -- = attribut workspace "PondWaterLevel"
	POND_DEPTH = POND_DEPTH, -- fond à POND_WATER_LEVEL - POND_DEPTH

	-- "Le Ruisseau" : suite de boîtes d'eau (jamais tournées) qui serpente de la mare vers le
	-- Chêne. Même niveau d'eau que la mare ; chaque boîte devient une zone "PondZone".
	STREAM_CENTER = Vector3.new(440, GROUND_TOP_Y, -720),
	STREAM_RADIUS = 560,
	STREAM_DEPTH = 8,
	STREAM_BANK_WIDTH = 8,
	STREAM_SEGMENTS = {
		{ MinX = 620, MaxX = 1064, MinZ = -1212, MaxZ = -1188 }, -- sort de la mare vers l'ouest
		{ MinX = 620, MaxX = 644, MinZ = -1212, MaxZ = -680 }, -- descend vers le sud
		{ MinX = 200, MaxX = 644, MinZ = -704, MaxZ = -680 }, -- ouest
		{ MinX = 200, MaxX = 224, MinZ = -704, MaxZ = -220 }, -- sud
		{ MinX = -120, MaxX = 224, MinZ = -244, MaxZ = -220 }, -- ouest, finit au sud du Chêne
	} :: { Box },

	-- "L'Étang de la Prairie" & son ruisseau : point d'eau en lisière est de la Prairie Fleurie.
	PRAIRIE_POND_CENTER = Vector3.new(-720, GROUND_TOP_Y, 760),
	PRAIRIE_POND_SIZE = Vector3.new(160, 12, 120),
	PRAIRIE_POND_DEPTH = 12,
	PRAIRIE_STREAM_SEGMENTS = {
		{ MinX = -644, MaxX = -380, MinZ = 748, MaxZ = 772 },
		{ MinX = -404, MaxX = -380, MinZ = 340, MaxZ = 772 },
		{ MinX = -404, MaxX = -180, MinZ = 340, MaxZ = 364 },
	} :: { Box },

	-- "Bassin de la Cascade" & "Rivière de l'Est" : au pied du massif montagneux Est, rejoint la Mare.
	WATERFALL_POOL_CENTER = Vector3.new(1320, GROUND_TOP_Y, -260),
	WATERFALL_POOL_SIZE = Vector3.new(144, 12, 128),
	WATERFALL_POOL_DEPTH = 12,
	WATERFALL_ORIGIN = Vector3.new(1460, GROUND_TOP_Y + 96, -260),
	EAST_RIVER_SEGMENTS = {
		{ MinX = 1308, MaxX = 1332, MinZ = -640, MaxZ = -320 },
		{ MinX = 1188, MaxX = 1332, MinZ = -640, MaxZ = -616 },
		{ MinX = 1188, MaxX = 1212, MinZ = -1100, MaxZ = -616 },
	} :: { Box },

	-- "Oasis du Sud" : point d'eau stratégique entre la Prairie et les Rochers Arides.
	SOUTH_OASIS_CENTER = Vector3.new(240, GROUND_TOP_Y, 1240),
	SOUTH_OASIS_SIZE = Vector3.new(168, 12, 128),
	SOUTH_OASIS_DEPTH = 12,

	-- "Bassin de l'Ouest" : point d'eau calme côté Souche / Bois mort.
	WEST_POND_CENTER = Vector3.new(-1240, GROUND_TOP_Y, -180),
	WEST_POND_SIZE = Vector3.new(144, 12, 112),
	WEST_POND_DEPTH = 12,

	-- "La Prairie Fleurie"
	PRAIRIE_CENTER = Vector3.new(-BIOME_OFFSET, GROUND_TOP_Y, BIOME_OFFSET),
	PRAIRIE_RADIUS = 420,

	-- "La Souche Pourrie & Les Galeries Souterraines"
	STUMP_CENTER = STUMP_CENTER,
	STUMP_RADIUS = 240,

	-- "Le Coin des Rochers Arides"
	ROCKS_CENTER = Vector3.new(BIOME_OFFSET, GROUND_TOP_Y, BIOME_OFFSET),
	ROCKS_RADIUS = 360,

	-- SpawnLocation "OeufSpawn" (centre de la dalle), près de l'entrée des galeries de la Souche.
	SPAWN_POSITION = STUMP_CENTER + Vector3.new(90, 0.5, 60),

	-- Galerie des modèles 3D (ShowcaseService) : juste au-delà du bord ouest, côté Souche.
	SHOWCASE_ORIGIN = Vector3.new(-MAP_HALF - 12, GROUND_TOP_Y, -640),
}

return WorldLayout
