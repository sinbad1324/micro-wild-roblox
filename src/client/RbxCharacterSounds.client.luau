--!strict
-- RbxCharacterSounds.client.luau
-- Remplace le script Roblox par défaut du même nom (un LocalScript "RbxCharacterSounds" placé dans
-- StarterPlayerScripts empêche Roblox d'insérer le sien) : plus de bruits de pas humains, mais
-- des sons d'insecte pour TOUS les personnages visibles (sons 3D posés sur leur HumanoidRootPart).
--   au sol / en escalade : cliquetis rapide de petites pattes
--   en vol (adultes volants) : bourdonnement d'ailes
--   sous l'eau             : brassage
--   saut / atterrissage    : petit "tic"
-- Oeuf et cocon : silencieux.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InsectData = require(ReplicatedStorage.shared.InsectData)

-- Sons intégrés à Roblox (toujours disponibles), accélérés pour sonner "petit insecte".
-- shortcut: pas de vrais sons d'insecte intégrés à Roblox ; remplacer ces SoundId par des sons de
-- la Creator Store (ex. "rbxassetid://<id>" d'un bourdonnement) pour un rendu plus réaliste.
local SOUNDS = {
	Skitter = { Id = "rbxasset://sounds/action_footsteps_plastic.mp3", Volume = 0.35, Speed = 2.6 },
	Buzz = { Id = "rbxasset://sounds/action_footsteps_plastic.mp3", Volume = 0.25, Speed = 7 },
	Swim = { Id = "rbxasset://sounds/action_swim.mp3", Volume = 0.3, Speed = 1.8 },
	Jump = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.15, Speed = 2.2 },
	Land = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.2, Speed = 2.4 },
}
local UPDATE_INTERVAL = 0.1
local MOVE_THRESHOLD = 0.8 -- studs/s en dessous duquel l'insecte est considéré immobile

type Entry = {
	Player: Player,
	Humanoid: Humanoid,
	Root: BasePart,
	Skitter: Sound,
	Buzz: Sound,
	Swim: Sound,
	Jump: Sound,
	Land: Sound,
	Connections: { RBXScriptConnection },
}

local entries: { [Model]: Entry } = {}

local function makeSound(parent: BasePart, name: string, config: { Id: string, Volume: number, Speed: number }, looped: boolean): Sound
	local sound = Instance.new("Sound")
	sound.Name = "Insecte_" .. name
	sound.SoundId = config.Id
	sound.Volume = config.Volume
	sound.PlaybackSpeed = config.Speed
	sound.Looped = looped
	sound.RollOffMaxDistance = 60
	sound.RollOffMinDistance = 4
	sound.Parent = parent
	return sound
end

local function isInPond(position: Vector3): boolean
	local waterLevel = workspace:GetAttribute("PondWaterLevel") :: number?
	if not waterLevel or position.Y >= waterLevel then
		return false
	end
	for _, zone in ipairs(CollectionService:GetTagged("PondZone")) do
		if zone:IsA("BasePart") then
			local relative = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size * 0.5
			if math.abs(relative.X) <= half.X and math.abs(relative.Z) <= half.Z then
				return true
			end
		end
	end
	return false
end

local function setPlaying(sound: Sound, playing: boolean)
	if playing and not sound.IsPlaying then
		sound:Play()
	elseif not playing and sound.IsPlaying then
		sound:Stop()
	end
end

local function untrack(character: Model)
	local entry = entries[character]
	if not entry then
		return
	end
	entries[character] = nil
	for _, connection in ipairs(entry.Connections) do
		connection:Disconnect()
	end
	for _, sound in ipairs({ entry.Skitter, entry.Buzz, entry.Swim, entry.Jump, entry.Land }) do
		sound:Destroy()
	end
end

local function track(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root or character.Parent == nil or entries[character] then
		return
	end
	local entry: Entry = {
		Player = player,
		Humanoid = humanoid,
		Root = root,
		Skitter = makeSound(root, "Pattes", SOUNDS.Skitter, true),
		Buzz = makeSound(root, "Ailes", SOUNDS.Buzz, true),
		Swim = makeSound(root, "Nage", SOUNDS.Swim, true),
		Jump = makeSound(root, "Saut", SOUNDS.Jump, false),
		Land = makeSound(root, "Atterrissage", SOUNDS.Land, false),
		Connections = {},
	}
	entries[character] = entry

	table.insert(entry.Connections, humanoid.StateChanged:Connect(function(_old, new)
		local stage = player:GetAttribute("Stage")
		if stage == "Oeuf" or stage == "Cocon" then
			return
		end
		if new == Enum.HumanoidStateType.Jumping then
			entry.Jump:Play()
		elseif new == Enum.HumanoidStateType.Landed then
			entry.Land:Play()
		end
	end))
	table.insert(entry.Connections, humanoid.Died:Connect(function()
		setPlaying(entry.Skitter, false)
		setPlaying(entry.Buzz, false)
		setPlaying(entry.Swim, false)
	end))
	table.insert(entry.Connections, character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			untrack(character)
		end
	end))
end

local function update()
	for _, entry in pairs(entries) do
		local humanoid = entry.Humanoid
		local stage = entry.Player:GetAttribute("Stage")
		local alive = humanoid.Health > 0 and stage ~= "Oeuf" and stage ~= "Cocon"
		local velocity = entry.Root.AssemblyLinearVelocity
		local speed = velocity.Magnitude
		local moving = alive and speed > MOVE_THRESHOLD

		local species = InsectData[(entry.Player:GetAttribute("Species") :: string?) or ""]
		local canFly = species ~= nil and species.CanFly and stage == "Adulte"
		local state = humanoid:GetState()
		local climbing = state == Enum.HumanoidStateType.PlatformStanding -- WallClimbController
		local airborne = humanoid.FloorMaterial == Enum.Material.Air and not climbing
		local swimming = alive and isInPond(entry.Root.Position)
		local flying = alive and canFly and airborne and not swimming and speed > 2

		-- Pattes : rythme proportionnel à la vitesse, plus grave et doux pour une larve.
		local walking = moving and not airborne and not swimming
		setPlaying(entry.Skitter, walking)
		if walking then
			local larvaFactor = if stage == "Adulte" then 1 else 0.6
			entry.Skitter.PlaybackSpeed = SOUNDS.Skitter.Speed * larvaFactor * math.clamp(speed / 16, 0.6, 1.6)
			entry.Skitter.Volume = SOUNDS.Skitter.Volume * larvaFactor
		end
		setPlaying(entry.Buzz, flying)
		setPlaying(entry.Swim, swimming and moving)
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		track(player, character)
	end)
	player.CharacterRemoving:Connect(untrack)
	if player.Character then
		task.spawn(track, player, player.Character)
	end
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
end

local elapsed = 0
RunService.Heartbeat:Connect(function(deltaTime)
	elapsed += deltaTime
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0
	update()
end)
