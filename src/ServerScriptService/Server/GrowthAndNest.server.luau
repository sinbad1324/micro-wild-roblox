--!strict
-- GrowthAndNest.server.luau
-- Gère le spawn en tant qu'Œuf dans le nid d'une Maman/Colonie, l'éclosion en Larve, la Métamorphose/Mue et l'état Adulte

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InsectData = require(Shared:WaitForChild("InsectData"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))

export type NestData = {
	OwnerUserId: number,
	SpeciesId: string,
	Position: Vector3,
	StoredFood: number,
	Children: { Player },
}

local ActiveNests: { [number]: NestData } = {}

-- Fonction pour appliquer la taille et la vitesse selon le stade d'évolution
local function updateCharacterStageVisuals(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
	local species = InsectData[speciesId] or InsectData.FourmiRousse
	local stage = (player:GetAttribute("Stage") :: string) or "Oeuf"

	if stage == "Oeuf" then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		character:ScaleTo(0.25)
	elseif stage == "Larve" then
		-- La larve ne peut se déplacer que lentement dans le nid et ne peut pas voler
		humanoid.WalkSpeed = math.max(6, species.WalkSpeed * 0.4)
		humanoid.JumpPower = 15
		character:ScaleTo(0.45)
	elseif stage == "Cocon" then
		-- Immobile pendant la métamorphose (chrysalide / nymphe)
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		character:ScaleTo(0.6)
	elseif stage == "Adulte" then
		humanoid.WalkSpeed = species.WalkSpeed
		humanoid.JumpPower = 50
		character:ScaleTo(1.0)
		humanoid.MaxHealth = species.MaxHealth
		humanoid.Health = species.MaxHealth
	end
end

-- Création d'un nid par une Maman / Reine (Adulte à 100% de croissance)
local function createNest(motherPlayer: Player)
	if motherPlayer:GetAttribute("Stage") ~= "Adulte" then
		return
	end
	local character = motherPlayer.Character
	if not character or not character.PrimaryPart then
		return
	end

	local speciesId = (motherPlayer:GetAttribute("Species") :: string) or "FourmiRousse"
	ActiveNests[motherPlayer.UserId] = {
		OwnerUserId = motherPlayer.UserId,
		SpeciesId = speciesId,
		Position = character.PrimaryPart.Position,
		StoredFood = 100,
		Children = {},
	}
	motherPlayer:SetAttribute("IsMother", true)
end

-- Boucle de croissance des insectes (Œuf -> Larve -> Cocon/Mue -> Adulte)
task.spawn(function()
	while true do
		task.wait(3)

		local currentSeasonName = workspace:GetAttribute("CurrentSeason") or "Printemps"
		local seasonInfo = SeasonConfig.Seasons[currentSeasonName] or SeasonConfig.Seasons.Printemps

		for _, player in ipairs(Players:GetPlayers()) do
			local hunger = (player:GetAttribute("Hunger") :: number) or 0
			local thirst = (player:GetAttribute("Thirst") :: number) or 0
			if hunger < 20 or thirst < 20 then
				-- Il faut être bien nourri (par sa Maman ou soi-même) pour grandir
				continue
			end

			local growth = (player:GetAttribute("Growth") :: number) or 0
			if growth >= 100 then
				continue
			end

			local speciesId = (player:GetAttribute("Species") :: string) or "FourmiRousse"
			local species = InsectData[speciesId] or InsectData.FourmiRousse
			local previousStage = (player:GetAttribute("Stage") :: string) or "Oeuf"

			growth = math.clamp(growth + (1.5 * seasonInfo.GrowthSpeedMultiplier), 0, 100)
			player:SetAttribute("Growth", math.round(growth * 10) / 10)

			local newStage = previousStage
			if growth < 15 then
				newStage = "Oeuf"
			elseif growth < 60 then
				newStage = "Larve"
			elseif growth < 75 then
				if species.GrowthType == "Metamorphose" then
					newStage = "Cocon"
				else
					newStage = "Larve" -- Mue progressive
				end
			else
				newStage = "Adulte"
				player:SetAttribute("CanLeaveNest", true)
			end

			if newStage ~= previousStage then
				player:SetAttribute("Stage", newStage)
				updateCharacterStageVisuals(player)
			end
		end
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.2)
		updateCharacterStageVisuals(player)
	end)
end)

return {
	CreateNest = createNest,
	ActiveNests = ActiveNests,
}
