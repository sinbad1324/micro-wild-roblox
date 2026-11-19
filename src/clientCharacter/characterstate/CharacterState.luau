--!strict
-- CharacterState.luau
-- État local du personnage de l'insecte (StarterCharacterScripts.characterState)
-- + entrées communes aux contrôleurs de déplacement (escalade, vol, nage) : vecteur de
-- déplacement brut, saut maintenu, bouton "Descendre" (clavier / manette / tactile).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local DESCEND_ACTION = "MW_Descend"
local ASCEND_ACTION = "MW_Ascend"

-- Bouton "Haut" (vol / nage), lu par IsJumpHeld ; lié/délié avec "Bas" par SetVerticalControls.
local ascendHeld = false

local CharacterState = {
	IsClimbingWall = false,
	IsFlying = false,
	IsSwimming = false,
	IsGrabbingPrey = false,
	-- Fin de la fenêtre d'un saut mural (os.clock) : l'appui qui détache du mur ne fait pas décoller.
	WallJumpUntil = 0,
}

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model

-- ControlModule de Roblox : seule source fiable du stick tactile / manette, lu sans allocation.
local controls: any = nil
task.spawn(function()
	local playerScripts = player:WaitForChild("PlayerScripts", 10)
	local playerModule = if playerScripts then playerScripts:WaitForChild("PlayerModule", 10) else nil
	if playerModule then
		local ok, module = pcall(require, playerModule)
		if ok and module then
			local okControls, result = pcall(function()
				return (module :: any):GetControls()
			end)
			if okControls then
				controls = result
			end
		end
	end
end)

-- Entrée brute, dans le repère de la caméra : X = droite, Z = arrière (donc avancer = -Z).
-- Repli sur Humanoid.MoveDirection si le ControlModule est indisponible.
function CharacterState.GetMoveVector(humanoid: Humanoid): Vector3
	local move = Vector3.zero
	if controls then
		move = controls:GetMoveVector()
		-- Même inversion que StatusEffectController (qui ne corrige que Humanoid:Move).
		if character:GetAttribute("Status_InvertControls") == true or character:GetAttribute("Status_MindControl") == true then
			move = -move
		end
	else
		local camera = workspace.CurrentCamera
		local direction = humanoid.MoveDirection
		if camera and direction.Magnitude > 0.01 then
			local relative = camera.CFrame:VectorToObjectSpace(direction)
			local flat = Vector3.new(relative.X, 0, relative.Z)
			if flat.Magnitude > 0.01 then
				move = flat.Unit * math.min(1, direction.Magnitude)
			end
		end
	end
	return move
end

-- Au-delà de cette inclinaison de caméra (sinus), avancer fait aussi monter/plonger (vol, nage).
local CAMERA_PITCH_DEADZONE = 0.5

-- Déplacement en espace monde : direction horizontale (longueur 0..1) + composante verticale
-- (-1..1) tirée de l'inclinaison de la caméra, nulle dans la zone morte (caméra de suivi normale).
function CharacterState.GetWorldMove(humanoid: Humanoid): (Vector3, number)
	local move = CharacterState.GetMoveVector(humanoid)
	local magnitude = math.min(1, move.Magnitude)
	local camera = workspace.CurrentCamera
	if magnitude < 0.01 or not camera then
		return Vector3.zero, 0
	end
	local world = camera.CFrame:VectorToWorldSpace(move)
	local vertical = world.Y
	if math.abs(vertical) < CAMERA_PITCH_DEADZONE then
		vertical = 0
	else
		vertical = math.sign(vertical) * (math.abs(vertical) - CAMERA_PITCH_DEADZONE) / (1 - CAMERA_PITCH_DEADZONE)
	end
	local flat = Vector3.new(world.X, 0, world.Z)
	if flat.Magnitude < 0.01 then
		return Vector3.zero, vertical
	end
	return flat.Unit * magnitude, vertical
end

-- Saut maintenu, toutes plateformes : le ControlModule recopie le bouton saut (tactile compris)
-- dans Humanoid.Jump à chaque frame.
function CharacterState.IsJumpHeld(humanoid: Humanoid): boolean
	if humanoid.Jump or ascendHeld then
		return true
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
end

-- Boutons "Haut" / "Bas" (vol / nage) : liés seulement tant qu'un contrôleur en a besoin, pour ne
-- pas encombrer l'écran tactile au sol. Le bouton de saut habituel monte aussi.
local descendHeld = false
local descendOwners: { [string]: boolean } = {}
local descendBound = false

local function onDescend(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	descendHeld = inputState == Enum.UserInputState.Begin
	return Enum.ContextActionResult.Pass
end

local function onAscend(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	ascendHeld = inputState == Enum.UserInputState.Begin
	return Enum.ContextActionResult.Pass
end

local function unbindVerticalControls()
	descendBound = false
	descendHeld = false
	ascendHeld = false
	ContextActionService:UnbindAction(DESCEND_ACTION)
	ContextActionService:UnbindAction(ASCEND_ACTION)
end

function CharacterState.SetVerticalControls(owner: string, enabled: boolean)
	descendOwners[owner] = if enabled then true else nil
	local needed = next(descendOwners) ~= nil
	if needed and not descendBound then
		descendBound = true
		ContextActionService:BindAction(
			DESCEND_ACTION,
			onDescend,
			true,
			Enum.KeyCode.LeftControl,
			Enum.KeyCode.Q,
			Enum.KeyCode.ButtonL3,
			Enum.KeyCode.DPadDown
		)
		ContextActionService:SetTitle(DESCEND_ACTION, "Bas")
		ContextActionService:SetPosition(DESCEND_ACTION, UDim2.new(1, -350, 1, -110))
		ContextActionService:BindAction(ASCEND_ACTION, onAscend, true, Enum.KeyCode.ButtonR3, Enum.KeyCode.DPadUp)
		ContextActionService:SetTitle(ASCEND_ACTION, "Haut")
		ContextActionService:SetPosition(ASCEND_ACTION, UDim2.new(1, -350, 1, -170))
	elseif not needed and descendBound then
		unbindVerticalControls()
	end
end

function CharacterState.IsDescendHeld(): boolean
	return descendHeld
end

-- Mort / réapparition : le module disparaît avec le personnage, le bouton tactile aussi.
script.Destroying:Connect(function()
	table.clear(descendOwners)
	if descendBound then
		unbindVerticalControls()
	end
end)

return CharacterState
