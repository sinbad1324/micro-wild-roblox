--!strict
-- AimUtil.luau (client)
-- Visée commune (creuser, tirs de toile, fil de balancier) : rayon partant de la souris, ou du
-- centre de l'écran en manette / tactile / souris verrouillée. Le rayon démarre à hauteur de
-- l'insecte : caméra reculée dans un tunnel, on ne vise pas la paroi DERRIÈRE lui.

local UserInputService = game:GetService("UserInputService")

local AimUtil = {}

function AimUtil.Ray(camera: Camera, from: Vector3): (Vector3, Vector3)
	local viewport = camera.ViewportSize
	local lastInput = UserInputService:GetLastInputType()
	local usesMouse = UserInputService.MouseEnabled
		and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		and (lastInput == Enum.UserInputType.Keyboard or string.find(lastInput.Name, "Mouse") ~= nil)
	local aim = if usesMouse then UserInputService:GetMouseLocation() else viewport * 0.5
	local unitRay = camera:ViewportPointToRay(aim.X, aim.Y)
	local start = unitRay.Origin + unitRay.Direction * math.max(0, (from - unitRay.Origin):Dot(unitRay.Direction))
	return start, unitRay.Direction
end

-- Point visé dans le décor (personnages ignorés), ou loin devant si le rayon ne touche rien.
function AimUtil.Point(camera: Camera, from: Vector3, maxDistance: number, params: RaycastParams): (Vector3, RaycastResult?)
	local start, direction = AimUtil.Ray(camera, from)
	local hit = workspace:Raycast(start, direction * maxDistance, params)
	return (if hit then hit.Position else start + direction * maxDistance), hit
end

return AimUtil
