--!strict
-- CharacterState.luau
-- État local du personnage de l'insecte (StarterCharacterScripts.characterState)
-- + entrées communes aux contrôleurs de déplacement (escalade, vol, nage) : vecteur de
-- déplacement brut, saut maintenu, bouton "Descendre" (clavier / manette / tactile).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local InsectData = require(ReplicatedStorage.shared.InsectData)

local DESCEND_ACTION = "MW_Descend"
local ASCEND_ACTION = "MW_Ascend"

-- Bouton "Haut" (vol / nage), lu par IsJumpHeld ; lié/délié avec "Bas" par SetVerticalControls.
local ascendHeld = false

local CharacterState = {
	IsClimbingWall = false,
	IsFlying = false,
	IsSwimming = false,
	IsGrabbingPrey = false,
	IsSwinging = false, -- araignée suspendue à son fil (WebSwingController)
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

-- Marche franchissable : jusqu'à STEP_FACTOR fois la hauteur du corps (pattes + root), au moins MIN_STEP.
-- Le relief rocheux (facettes du Terrain, voxels de 4 studs) fait des marches énormes pour un insecte.
local STEP_FACTOR = 1.6
local MIN_STEP = 1.2
local MAX_STEP = 4

-- Autre insecte / animal : jamais une marche (sinon on bondit sur son dos au lieu de le mordre).
local function isCharacterPart(instance: Instance): boolean
	local model = instance:FindFirstAncestorWhichIsA("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- Hauteur (au-dessus des pieds) de la marche juste devant, si elle est franchissable d'un petit bond ;
-- nil s'il n'y a rien devant, une pente douce (le Humanoid la gère) ou un vrai mur (trop haut).
function CharacterState.StepHeight(rootPart: BasePart, humanoid: Humanoid, direction: Vector3, params: RaycastParams): number?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return nil
	end
	flat = flat.Unit
	local size = rootPart.Size
	local bodyHeight = humanoid.HipHeight + size.Y
	local feet = rootPart.Position - Vector3.yAxis * (humanoid.HipHeight + size.Y * 0.5)
	local maxStep = math.clamp(bodyHeight * STEP_FACTOR, MIN_STEP, MAX_STEP)
	-- Demi-longueur de la boîte du root dans la direction de marche (corps allongé).
	local l = rootPart.CFrame:VectorToObjectSpace(flat)
	local extent = math.abs(l.X) * size.X * 0.5 + math.abs(l.Y) * size.Y * 0.5 + math.abs(l.Z) * size.Z * 0.5
	local low = workspace:Raycast(feet + Vector3.yAxis * math.min(0.15, bodyHeight * 0.2), flat * (extent + 0.5), params)
	-- Seule une contremarche quasi verticale compte : une pente (même raide) reste au Humanoid / à l'escalade.
	if not low or low.Distance < 0.01 or low.Normal.Y > 0.35 or isCharacterPart(low.Instance) then
		return nil
	end
	-- Dessus de l'obstacle : rayon vers le bas depuis la hauteur max de marche, juste après le contact.
	local over = low.Position + flat * 0.3
	local origin = Vector3.new(over.X, feet.Y + maxStep + 0.1, over.Z)
	local top = workspace:Raycast(origin, Vector3.yAxis * -(maxStep + 0.1), params)
	-- Rien / départ dans la matière (mur plus haut que la marche) / dessus trop raide : pas une marche.
	if not top or top.Distance < 0.01 or top.Normal.Y < 0.6 or isCharacterPart(top.Instance) then
		return nil
	end
	local rise = top.Position.Y - feet.Y
	if rise <= 0.05 then
		return nil
	end
	-- Place au-dessus de la marche (tunnel, surplomb) : sinon on bondirait dans le plafond en boucle.
	if workspace:Raycast(top.Position + Vector3.yAxis * 0.05, Vector3.yAxis * (bodyHeight + 0.2), params) then
		return nil
	end
	return rise
end

-- ============================================================
-- Vent ressenti par l'insecte (exposition, abri, poids de l'espèce, turbulences)
-- ============================================================

local windExposure = 1
local nextWindCheckAt = 0
local windSeed = (player.UserId % 991) + 0.37

-- Renvoie le vecteur de vent réellement ressenti par le personnage (nul sous terre, dans un abri,
-- sous l'eau ou en Œuf/Cocon ; atténué derrière un tronc/rocher ; amplifié pour les espèces légères).
function CharacterState.GetEffectiveWind(rootPart: BasePart, params: RaycastParams): Vector3
	local stage = player:GetAttribute("Stage")
	if
		stage == "Oeuf"
		or stage == "Cocon"
		or player:GetAttribute("InShelterOrColony") == true
		or CharacterState.IsSwimming
	then
		return Vector3.zero
	end

	local rawWind = workspace:GetAttribute("WindVector")
	if typeof(rawWind) ~= "Vector3" or rawWind.Magnitude < 0.4 then
		return Vector3.zero
	end

	local now = os.clock()
	if now >= nextWindCheckAt then
		nextWindCheckAt = now + 0.25
		local pos = rootPart.Position
		-- 1) Plafond solide (galerie souterraine, dessous de rocher) : coupe le vent.
		local roofHit = workspace:Raycast(pos, Vector3.new(0, 26, 0), params)
		if roofHit and roofHit.Instance == workspace.Terrain then
			windExposure = 0
		else
			-- 2) Obstacle face au vent (tronc du Grand Chêne, pierre, feuille) : abri aérodynamique.
			local windDir = rawWind.Unit
			local upwindHit = workspace:Raycast(pos, -windDir * 14, params)
			windExposure = if upwindHit then 0.2 else 1
		end
	end
	if windExposure <= 0.01 then
		return Vector3.zero
	end

	-- Sensibilité selon la masse / robustesse de l'espèce (un moustique ou papillon dérive plus qu'un scarabée Hercule).
	local speciesId = (player:GetAttribute("Species") :: string?) or "FourmiRousse"
	local species = InsectData[speciesId]
	local susceptibility = 1
	if species then
		-- 45 PV (Moustique) -> ~1.35 ; 120 PV -> ~1.0 ; 280 PV (Hercule) -> ~0.55
		susceptibility = math.clamp(1.42 - (species.MaxHealth / 320), 0.52, 1.38)
		if
			table.find(species.Abilities, "CarapaceBlindee")
			or table.find(species.Abilities, "BouclierChitine")
			or table.find(species.Abilities, "FourreauArmureCailloux")
			or table.find(species.Abilities, "ForceHerculeenne")
		then
			susceptibility *= 0.75
		end
	end
	if stage == "Larve" or stage == "Mue" then
		susceptibility *= 1.1
	end

	-- Micro-turbulences organiques (bruit de Perlin) : le vent vit et fluctue légèrement.
	local gustWave = 1 + math.noise(now * 1.15, windSeed) * 0.24
	local crossSwirl = math.noise(windSeed, now * 1.4) * 0.18
	local perp = Vector3.new(-rawWind.Z, 0, rawWind.X)
	return (rawWind * gustWave + perp * crossSwirl) * (windExposure * susceptibility)
end

return CharacterState
