--!strict
-- WebSwingController.client.luau
-- Fil de soie des araignées, façon Spider-Man (StarterCharacterScripts.characterControllers).
-- Maintenir F : le fil part vers le point visé (souris / centre de l'écran), file jusqu'à la paroi en
-- ~0.1 s puis s'accroche ; on se balance au bout. Espace maintenu = remonter le fil, ZQSD = pomper
-- l'élan. Relâcher F = lâcher en gardant toute la vitesse (enchaîner les fils).
--
-- Pendule CINÉMATIQUE (comme WallClimbController) plutôt qu'une RopeConstraint : à chaque frame on
-- intègre gravité + élan, on contraint la position sur la sphère du fil (la vitesse radiale sortante
-- est retirée, la vitesse tangentielle conservée), et on pose la vitesse du root. Le Humanoid est en
-- PlatformStand (il ne lutte plus contre le fil), une VectorForce annule la gravité du moteur
-- (c'est nous qui l'appliquons) et les collisions restent gérées par la physique.
-- Le corps s'oriente le long de la trajectoire, le dos vers le point d'accroche.
-- Le serveur (CombatService.onWebLine) valide l'ancre et affiche le fil aux autres joueurs.
-- Lié à F seulement pour les espèces qui ont "FilDeRappel" (adulte) : sinon F reste "agripper".

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local character = script.Parent.Parent :: Model
local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
local humanoid = character:WaitForChild("Humanoid") :: Humanoid

local AbilityCatalog = require(ReplicatedStorage.shared.AbilityCatalog)
local AimUtil = require(ReplicatedStorage.shared.AimUtil)
local InsectData = require(ReplicatedStorage.shared.InsectData)
local Remotes = require(ReplicatedStorage.shared.Remotes)
local CharacterState = require(character:WaitForChild("characterState"):WaitForChild("CharacterState"))

local ACTION = "MW_WebSwing"
local ABILITY_ID = "FilDeRappel"
local SHOT_SPEED = 260 -- studs/s : le fil "file" jusqu'à la paroi avant de s'accrocher
local SHOT_MAX_TIME = 0.18
local REEL_SPEED = 30 -- studs/s : Espace raccourcit le fil
local MIN_LENGTH = 1.5
local PUMP_ACCEL = 32 -- studs/s² d'élan avec les touches (dans le plan perpendiculaire au fil)
local AIR_DRAG = 0.12 -- 1/s : le balancement s'amortit très peu
local SNAP_RATE = 0.5 -- part de l'écart au fil corrigée par frame (tension douce, pas de secousse)
local MAX_SPEED = 120
local RELEASE_LIFT = 5 -- petit coup vers le haut au lâcher (enchaîner les fils)
local ORIENT_SHARPNESS = 12
local GROUND_RELEASE_TIME = 0.25 -- posé au sol avec le fil mou : on lâche tout seul
local RECAST_DELAY = 0.15

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local rootAttachment = Instance.new("Attachment")
rootAttachment.Name = "WebSwingAttachment"
rootAttachment.Parent = rootPart

local antiGravity = Instance.new("VectorForce")
antiGravity.Name = "WebSwingAntiGravity"
antiGravity.Attachment0 = rootAttachment
antiGravity.RelativeTo = Enum.ActuatorRelativeTo.World
antiGravity.ApplyAtCenterOfMass = true
antiGravity.Enabled = false
antiGravity.Parent = rootPart

-- Fil local (Beam) : le lanceur le voit tout de suite, sans attendre le serveur.
local anchorPart = Instance.new("Part")
anchorPart.Name = "WebSwingAnchor"
anchorPart.Size = Vector3.one * 0.2
anchorPart.Transparency = 1
anchorPart.Anchored = true
anchorPart.CanCollide = false
anchorPart.CanQuery = false
anchorPart.CanTouch = false
local anchorAttachment = Instance.new("Attachment")
anchorAttachment.Parent = anchorPart
local strand = Instance.new("Beam")
strand.Attachment0 = rootAttachment
strand.Attachment1 = anchorAttachment
strand.Color = ColorSequence.new(Color3.fromRGB(245, 245, 250))
strand.Transparency = NumberSequence.new(0.05)
strand.LightEmission = 0.3
strand.FaceCamera = true
strand.Segments = 1
strand.Parent = anchorPart

type Phase = "Idle" | "Shooting" | "Attached"
local phase: Phase = "Idle"
local anchor = Vector3.zero
local shotT = 0
local shotTime = 0
local length = 0
local groundTime = 0
local nextCastAt = 0
local bound = false

-- Conditions portées par des attributs (signaux) : décident si F est lié au fil.
local function canBind(): boolean
	if humanoid.Health <= 0 or player:GetAttribute("Stage") ~= "Adulte" or player:GetAttribute("IsGrabbed") == true then
		return false
	end
	if character:GetAttribute("Status_Stun") == true then
		return false
	end
	local species = InsectData[(player:GetAttribute("Species") :: string?) or ""]
	return species ~= nil and table.find(species.Abilities, ABILITY_ID) ~= nil
end

-- + états locaux sans signal (vol, nage) : vérifiés au lancer et chaque frame.
local function allowed(): boolean
	return canBind() and not CharacterState.IsFlying and not CharacterState.IsSwimming
end

local function release(keepMomentum: boolean)
	local was = phase
	phase = "Idle"
	anchorPart.Parent = nil
	if was == "Idle" then
		return
	end
	Remotes.Get("RequestWebLine"):FireServer(nil)
	if was ~= "Attached" then
		return
	end
	CharacterState.IsSwinging = false
	antiGravity.Enabled = false
	humanoid.PlatformStand = false
	rootPart.AssemblyAngularVelocity = Vector3.zero
	if humanoid.Health <= 0 then
		return
	end
	-- Redressé (cap = direction de vol) : le Humanoid reprend la main sans trébucher.
	local velocity = rootPart.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	if flat.Magnitude < 0.5 then
		flat = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	end
	if flat.Magnitude > 0.05 then
		local position = rootPart.Position
		rootPart.CFrame = CFrame.lookAt(position, position + flat)
	end
	if keepMomentum then
		rootPart.AssemblyLinearVelocity = velocity + Vector3.new(0, RELEASE_LIFT, 0)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
end

local function cast()
	if phase ~= "Idle" or os.clock() < nextCastAt or not allowed() then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	nextCastAt = os.clock() + RECAST_DELAY
	local definition = AbilityCatalog[ABILITY_ID]
	local range = (if definition then definition.Range else 45) * math.max(character:GetScale(), 0.6)
	local ignore: { Instance } = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	rayParams.FilterDescendantsInstances = ignore
	-- On vise le décor ; le fil part de l'insecte et doit l'atteindre sans traverser de mur.
	local aimPoint, aimHit = AimUtil.Point(camera, rootPart.Position, range * 2, rayParams)
	if not aimHit then
		return -- rien à quoi s'accrocher (ciel)
	end
	local offset = aimPoint - rootPart.Position
	if offset.Magnitude > range then
		return
	end
	local check = workspace:Raycast(rootPart.Position, offset, rayParams)
	anchor = if check then check.Position else aimPoint

	-- Le fil file vers la paroi : l'accroche arrive à la fin du trajet (pas de téléportation du fil).
	phase = "Shooting"
	shotT = 0
	shotTime = math.min(SHOT_MAX_TIME, (anchor - rootPart.Position).Magnitude / SHOT_SPEED)
	strand.Width0 = 0.07 * math.max(character:GetScale(), 0.6)
	strand.Width1 = strand.Width0 * 0.7
	anchorPart.CFrame = CFrame.new(rootPart.Position)
	anchorPart.Parent = workspace
	Remotes.Get("RequestWebLine"):FireServer(anchor)
end

local function attach()
	phase = "Attached"
	anchorPart.CFrame = CFrame.new(anchor)
	-- Longueur = distance actuelle : le balancement commence tout de suite (pas de chute avant tension).
	length = math.max(MIN_LENGTH, (anchor - rootPart.Position).Magnitude)
	groundTime = 0
	CharacterState.IsSwinging = true
	humanoid.PlatformStand = true
	antiGravity.Enabled = true
end

local function onAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		cast()
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		release(true)
	end
	return Enum.ContextActionResult.Sink
end

-- F n'est pris que par les araignées adultes ; les autres gardent "agripper" (AbilityController).
local function refreshBinding()
	local want = canBind()
	if want and not bound then
		bound = true
		ContextActionService:BindActionAtPriority(ACTION, onAction, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.F, Enum.KeyCode.ButtonB)
		ContextActionService:SetTitle(ACTION, "Fil")
		-- Décalé du bouton F "agripper" (même place sinon, et le mauvais pourrait être au-dessus).
		ContextActionService:SetPosition(ACTION, UDim2.new(1, -110, 1, -290))
	elseif not want and bound then
		bound = false
		ContextActionService:UnbindAction(ACTION)
		release(false)
	end
end

-- Le Beam serveur de son propre fil est masqué : on voit déjà le fil local (pas de double fil).
local function hideOwnBeam(instance: Instance)
	if instance:IsA("Beam") and instance:GetAttribute("OwnerUserId") == player.UserId then
		instance.Enabled = false
	end
end
CollectionService:GetInstanceAddedSignal("WebLine"):Connect(hideOwnBeam)

local function swing(dt: number)
	-- WallClimbController (qui lâche le mur en voyant IsSwinging) remet PlatformStand à false.
	if not humanoid.PlatformStand then
		humanoid.PlatformStand = true
	end
	local position = rootPart.Position
	local velocity = rootPart.AssemblyLinearVelocity -- vraie vitesse : les chocs du décor sont pris en compte
	velocity += Vector3.new(0, -workspace.Gravity * dt, 0)

	local toAnchor = anchor - position
	local distance = toAnchor.Magnitude
	local inward = if distance > 1e-3 then toAnchor / distance else Vector3.yAxis

	-- Espace : on remonte le fil.
	if CharacterState.IsJumpHeld(humanoid) then
		length = math.max(MIN_LENGTH, length - REEL_SPEED * dt)
	end
	-- Pompe : l'input pousse dans le plan perpendiculaire au fil (on élargit l'arc, on ne tire pas dessus).
	local move = CharacterState.GetWorldMove(humanoid)
	if move.Magnitude > 0.05 then
		local push = move - inward * move:Dot(inward)
		velocity += push * (PUMP_ACCEL * dt)
	end
	velocity *= 1 - math.min(1, AIR_DRAG * dt)

	-- Contrainte du fil : au-delà de la longueur, la vitesse sortante est retirée (le reste devient
	-- rotation autour de l'ancre) et l'écart est rattrapé en douceur.
	local predicted = position + velocity * dt - anchor
	local reach = predicted.Magnitude
	if reach > length and reach > 1e-3 then
		local outward = predicted / reach
		local radial = velocity:Dot(outward)
		if radial > 0 then
			velocity -= outward * radial
		end
		velocity -= outward * ((reach - length) * SNAP_RATE / dt)
	end
	if velocity.Magnitude > MAX_SPEED then
		velocity = velocity.Unit * MAX_SPEED
	end

	-- Orientation : dos vers le fil, tête dans le sens du mouvement.
	local look = velocity - inward * velocity:Dot(inward)
	if look.Magnitude < 0.5 then
		look = rootPart.CFrame.LookVector - inward * rootPart.CFrame.LookVector:Dot(inward)
	end
	if look.Magnitude > 1e-3 then
		local target = CFrame.lookAt(position, position + look.Unit, inward)
		local alpha = 1 - math.exp(-ORIENT_SHARPNESS * dt)
		rootPart.CFrame = rootPart.CFrame:Lerp(target, alpha)
	end
	rootPart.AssemblyLinearVelocity = velocity
	rootPart.AssemblyAngularVelocity = Vector3.zero
	antiGravity.Force = Vector3.new(0, workspace.Gravity * rootPart.AssemblyMass, 0)

	-- Posé au sol avec le fil mou : on lâche (sinon on resterait couché en PlatformStand).
	local feet = humanoid.HipHeight + rootPart.Size.Y * 0.5 + 0.3
	rayParams.FilterDescendantsInstances = { character }
	local ground = workspace:Raycast(position, Vector3.new(0, -feet, 0), rayParams)
	if ground and distance < length - 0.2 and velocity.Y <= 0.5 then
		groundTime += dt
		if groundTime >= GROUND_RELEASE_TIME then
			release(false)
		end
	else
		groundTime = 0
	end
end

local stepConnection = RunService.RenderStepped:Connect(function(deltaTime: number)
	if phase == "Idle" then
		return
	end
	if not allowed() then
		release(false)
		return
	end
	local dt = math.clamp(deltaTime, 1 / 240, 1 / 20)
	if phase == "Shooting" then
		shotT += dt
		local t = if shotTime > 0 then math.min(1, shotT / shotTime) else 1
		anchorPart.CFrame = CFrame.new(rootPart.Position:Lerp(anchor, t))
		if t >= 1 then
			attach()
		end
		return
	end
	swing(dt)
end)

refreshBinding()
for _, attribute in ipairs({ "Species", "Stage", "IsGrabbed" }) do
	player:GetAttributeChangedSignal(attribute):Connect(refreshBinding)
end
character:GetAttributeChangedSignal("Status_Stun"):Connect(refreshBinding)

local function cleanup()
	release(false)
	stepConnection:Disconnect()
	anchorPart:Destroy()
	if bound then
		bound = false
		ContextActionService:UnbindAction(ACTION)
	end
end
humanoid.Died:Connect(cleanup)
script.Destroying:Connect(cleanup)
