--!strict
-- SfxController.luau
-- Tous les effets sonores du jeu (combat, progression, interface) + l'ambiance (vent, pluie).
--
-- Sources : uniquement les sons INTÉGRÉS à Roblox (content/sounds, toujours disponibles, aucun
-- asset à charger) : on en tire une palette en jouant sur la hauteur (PlaybackSpeed), en coupant
-- un court extrait (Start / Length) et en superposant plusieurs couches.
-- shortcut: palette limitée aux 11 sons intégrés ; pour un rendu "pro", remplacer un Id du
-- tableau SOUNDS par "rbxassetid://<id>" d'un son de la Creator Store (le nom d'effet ne change pas).
--
-- API : SfxController.Play(name, at?) — `at` = position (son 3D) ou nil (son 2D d'interface).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local SfxController = {}

local S = "rbxasset://sounds/"
type Layer = { Id: string, Volume: number, Speed: number, Start: number?, Length: number?, Delay: number? }

-- Chaque effet = 1 à 4 couches ; ±8 % de hauteur aléatoire à chaque lecture (pas de répétition sèche).
local SOUNDS: { [string]: { Layer } } = {
	-- Combat
	Bite = { -- morsure qui porte : craquement sec + choc mat
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.35, Speed = 3.2, Length = 0.25 },
		{ Id = S .. "action_jump_land.mp3", Volume = 0.5, Speed = 1.9 },
	},
	BiteHeavy = { -- notre coup : plus grave et plus fort
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.55, Speed = 2.4, Length = 0.35 },
		{ Id = S .. "action_jump_land.mp3", Volume = 0.7, Speed = 1.5 },
	},
	Hurt = { -- on est touché : couinement d'insecte
		{ Id = S .. "ouch.ogg", Volume = 0.35, Speed = 2.1 },
		{ Id = S .. "action_jump_land.mp3", Volume = 0.5, Speed = 1.3 },
	},
	Snap = { -- claquement de mandibules (dès l'appui)
		{ Id = S .. "action_footsteps_plastic.mp3", Volume = 0.6, Speed = 2.8, Start = 0, Length = 0.06 },
	},
	Spit = { -- départ de projectile (venin, acide, soie)
		{ Id = S .. "action_swim.mp3", Volume = 0.4, Speed = 2.6, Length = 0.25 },
	},
	Splash = { -- impact liquide
		{ Id = S .. "impact_water.mp3", Volume = 0.45, Speed = 1.9, Length = 0.4 },
	},
	Whoosh = { -- départ de bond / charge
		{ Id = S .. "action_falling.ogg", Volume = 0.35, Speed = 1.8, Length = 0.35 },
	},
	Slam = { -- atterrissage d'un bond d'attaque
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.45, Speed = 1.6, Length = 0.5 },
		{ Id = S .. "action_jump_land.mp3", Volume = 0.7, Speed = 0.9 },
	},
	Power = { -- éclat générique d'un pouvoir
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.3, Speed = 2.6, Length = 0.3 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.25, Speed = 0.7 },
	},
	Death = {
		{ Id = S .. "oof.ogg", Volume = 0.4, Speed = 1.7 },
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.25, Speed = 0.8, Length = 0.6 },
	},
	-- Progression / interface : arpèges sur un "tic" pitché (accord majeur 1, 1.26, 1.5, 2).
	XpTick = { { Id = S .. "volume_slider.ogg", Volume = 0.12, Speed = 1.5 } },
	LevelUp = {
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1.26, Delay = 0.08 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1.5, Delay = 0.16 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.6, Speed = 2, Delay = 0.26 },
	},
	Quest = {
		{ Id = S .. "volume_slider.ogg", Volume = 0.45, Speed = 1.5 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.45, Speed = 2, Delay = 0.1 },
	},
	Chest = {
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1.26, Delay = 0.07 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.5, Speed = 1.5, Delay = 0.14 },
		{ Id = S .. "impact_explosion_03.mp3", Volume = 0.3, Speed = 2.2, Length = 0.4, Delay = 0.2 },
	},
	Evolve = {
		{ Id = S .. "volume_slider.ogg", Volume = 0.45, Speed = 0.75 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.45, Speed = 1, Delay = 0.12 },
		{ Id = S .. "volume_slider.ogg", Volume = 0.45, Speed = 1.5, Delay = 0.24 },
	},
	Click = { { Id = S .. "volume_slider.ogg", Volume = 0.3, Speed = 1.2 } },
	Build = { -- pose d'un bloc / d'une pièce
		{ Id = S .. "action_jump_land.mp3", Volume = 0.6, Speed = 1.1 },
		{ Id = S .. "action_footsteps_plastic.mp3", Volume = 0.4, Speed = 1.6, Start = 0, Length = 0.08 },
	},
}

local folder: Folder? = nil
local MAX_DISTANCE = 120

local function playLayer(layer: Layer, at: Vector3?)
	local sound = Instance.new("Sound")
	sound.SoundId = layer.Id
	sound.Volume = layer.Volume
	sound.PlaybackSpeed = layer.Speed * (1 + (math.random() - 0.5) * 0.16)
	sound.TimePosition = layer.Start or 0
	local holder: Instance
	if at then
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = at
		attachment.Parent = workspace.Terrain
		sound.RollOffMinDistance = 6
		sound.RollOffMaxDistance = MAX_DISTANCE
		holder = attachment
	else
		holder = sound
	end
	sound.Parent = if at then holder else (folder or SoundService)
	sound:Play()
	-- Durée réelle = longueur jouée / vitesse ; marge pour le chargement du son.
	local length = layer.Length
	if length then
		task.delay(length / sound.PlaybackSpeed, function()
			sound:Stop()
			holder:Destroy()
		end)
	else
		sound.Ended:Once(function()
			holder:Destroy()
		end)
		task.delay(6, function() -- filet de sécurité si Ended ne vient jamais
			if holder.Parent then
				holder:Destroy()
			end
		end)
	end
end

function SfxController.Play(name: string, at: Vector3?)
	local layers = SOUNDS[name]
	if not layers then
		return
	end
	if at then
		local camera = workspace.CurrentCamera
		if not camera or (camera.CFrame.Position - at).Magnitude > MAX_DISTANCE then
			return
		end
	end
	for _, layer in ipairs(layers) do
		if layer.Delay and layer.Delay > 0 then
			task.delay(layer.Delay, playLayer, layer, at)
		else
			playLayer(layer, at)
		end
	end
end

-- ---------- Ambiance : vent (suit la force du vent) et pluie ----------
local function startAmbience()
	local wind = Instance.new("Sound")
	wind.Name = "AmbienceWind"
	wind.SoundId = S .. "action_falling.ogg"
	wind.Looped = true
	wind.Volume = 0
	wind.Parent = folder
	wind:Play()

	local rain = Instance.new("Sound")
	rain.Name = "AmbienceRain"
	rain.SoundId = S .. "action_swim.mp3" -- brassage d'eau accéléré = crépitement de pluie
	rain.Looped = true
	rain.PlaybackSpeed = 2.4
	rain.Volume = 0
	rain.Parent = folder
	rain:Play()

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.25 then
			return
		end
		local step = elapsed
		elapsed = 0
		local windVector = workspace:GetAttribute("WindVector")
		local strength = if typeof(windVector) == "Vector3" then (windVector :: Vector3).Magnitude else 0
		local targetWind = math.clamp(strength / 30, 0, 1) * 0.12
		wind.Volume += (targetWind - wind.Volume) * math.min(1, step * 2)
		wind.PlaybackSpeed = 0.55 + math.clamp(strength / 30, 0, 1) * 0.35
		local raining = workspace:GetAttribute("Precipitation") == "Rain"
		rain.Volume += ((if raining then 0.1 else 0) - rain.Volume) * math.min(1, step * 1.5)
	end)
end

function SfxController.Start()
	local created = Instance.new("Folder")
	created.Name = "Sfx"
	created.Parent = SoundService
	folder = created
	startAmbience()
	-- Mort du joueur local : son de fin de cycle.
	local function watch(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Once(function()
				SfxController.Play("Death")
			end)
		end
	end
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watch)
	if player.Character then
		task.spawn(watch, player.Character)
	end
end

return SfxController
