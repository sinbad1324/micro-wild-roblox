--!strict
-- CharacterState.luau
-- État local du personnage de l'insecte (StarterCharacterScripts.characterState)
-- + entrées communes aux contrôleurs de déplacement (escalade, vol, nage) : vecteur de
-- déplacement brut, saut maintenu, bouton "Descendre" (clavier / manette / tactile).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local DESCEND_ACTION = "MW_Descend"

local CharacterState = {
	IsClimbingWall = false,
	IsFlying = false,
	IsSwimming = false,
	IsGrabbingPrey = false,
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

-- Saut maintenu, toutes plateformes : le ControlModule recopie le bouton saut (tactile compris)
-- dans Humanoid.Jump à chaque frame.
function CharacterState.IsJumpHeld(humanoid: Humanoid): boolean
	if humanoid.Jump then
		return true
	end
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
end

-- Bouton "Descendre" (vol / nage) : lié seulement tant qu'un contrôleur en a besoin, pour ne pas
-- encombrer l'écran tactile au sol. Monter = bouton de saut habituel.
local descendHeld = false
local descendOwners: { [string]: boolean } = {}
local descendBound = false

local function onDescend(_actionName: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	descendHeld = inputState == Enum.UserInputState.Begin
	return Enum.ContextActionResult.Pass
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
	elseif not needed and descendBound then
		descendBound = false
		descendHeld = false
		ContextActionService:UnbindAction(DESCEND_ACTION)
	end
end

function CharacterState.IsDescendHeld(): boolean
	return descendHeld
end

-- Mort / réapparition : le module disparaît avec le personnage, le bouton tactile aussi.
script.Destroying:Connect(function()
	table.clear(descendOwners)
	if descendBound then
		descendBound = false
		descendHeld = false
		ContextActionService:UnbindAction(DESCEND_ACTION)
	end
end)

return CharacterState
