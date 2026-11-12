--!strict
-- MathUtils.luau
-- Fonctions utilitaires côté serveur

local MathUtils = {}

function MathUtils.RoundToDecimal(value: number, decimals: number): number
	local mult = 10 ^ decimals
	return math.round(value * mult) / mult
end

function MathUtils.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

return MathUtils
