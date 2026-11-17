-- GameServer (Script in ServerScriptService)
-- The rules of the game: stars, checkpoints, hazards, glass tiles,
-- the spinning bar and the goal. The client script draws things and
-- handles your own character (mushroom bounce, spinning-bar hits).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))

local course = workspace:WaitForChild("Course")
local starsFolder = course:WaitForChild("Stars")
local checkpointsFolder = course:WaitForChild("Checkpoints")
local hazardsFolder = course:WaitForChild("Hazards")
local tilesFolder = course:WaitForChild("FadingTiles")
local signsFolder = course:WaitForChild("Signs")
local goalModel = course:WaitForChild("Goal"):WaitForChild("Goal")

Players.RespawnTime = GameConfig.RESPAWN_TIME

-- Remote events: the server tells each player's screen what happened
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"

local function makeRemote(name)
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	return remote
end

local starCollected = makeRemote("StarCollected")
local checkpointReached = makeRemote("CheckpointReached")
local goalReached = makeRemote("GoalReached")
local restartRequest = makeRemote("RestartRequest")
local spinnerHit = makeRemote("SpinnerHit")
remotes.Parent = ReplicatedStorage

local TOTAL_STARS = #starsFolder:GetChildren()

-- progress[player] = { collected = { [starModel] = true }, zone = 1, finished = false }
local progress = {}

-- Which living player (if any) does this touching part belong to?
local function getPlayerFromPart(part)
	local character = part:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return nil
	end
	return player, humanoid
end

local function getStat(player, statName)
	local leaderstats = player:FindFirstChild("leaderstats")
	return leaderstats and leaderstats:FindFirstChild(statName)
end

local function resetProgress(player)
	progress[player] = { collected = {}, zone = 1, finished = false }
	local stars = getStat(player, "별")
	if stars then
		stars.Value = 0
	end
	local zone = getStat(player, "구역")
	if zone then
		zone.Value = 1
	end
	player:SetAttribute("TotalStars", TOTAL_STARS)
	player:SetAttribute("StartTime", workspace:GetServerTimeNow())
	player:SetAttribute("FinishTime", nil)
end

-- Put the character back on its last checkpoint
local function moveToCheckpoint(player, character)
	local data = progress[player]
	if not data or data.zone <= 1 then
		return -- zone 1 uses the normal start spawn
	end
	local checkpoint = checkpointsFolder:FindFirstChild("Checkpoint" .. (data.zone - 1))
	local pad = checkpoint and checkpoint:FindFirstChild("Pad")
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not pad or not root then
		return
	end
	if not character.Parent then
		character.AncestryChanged:Wait() -- wait until the character is in the world
	end
	task.wait() -- let the default spawn finish first
	character:PivotTo(CFrame.new(pad.Position + Vector3.new(0, 4, 0)))
end

local function setupPlayer(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local stars = Instance.new("IntValue")
	stars.Name = "별"
	stars.Parent = leaderstats

	local zone = Instance.new("IntValue")
	zone.Name = "구역"
	zone.Value = 1
	zone.Parent = leaderstats

	leaderstats.Parent = player
	resetProgress(player)

	player.CharacterAdded:Connect(function(character)
		moveToCheckpoint(player, character)
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in Players:GetPlayers() do
	setupPlayer(player)
end

Players.PlayerRemoving:Connect(function(player)
	progress[player] = nil
end)

-- Stars: each player collects their own stars
for _, star in starsFolder:GetChildren() do
	local hitbox = star:WaitForChild("Hitbox")
	hitbox.Touched:Connect(function(hit)
		local player = getPlayerFromPart(hit)
		local data = player and progress[player]
		if not data or data.collected[star] then
			return
		end
		data.collected[star] = true
		local stars = getStat(player, "별")
		if stars then
			stars.Value += 1
		end
		starCollected:FireClient(player, star)
	end)
end

-- Checkpoints: CheckpointN moves you into zone N + 1
for _, checkpoint in checkpointsFolder:GetChildren() do
	local number = tonumber(string.match(checkpoint.Name, "%d+"))
	local pad = checkpoint:WaitForChild("Pad")
	if number then
		pad.Touched:Connect(function(hit)
			local player = getPlayerFromPart(hit)
			local data = player and progress[player]
			if not data or number + 1 <= data.zone then
				return
			end
			data.zone = number + 1
			local zone = getStat(player, "구역")
			if zone then
				zone.Value = data.zone
			end
			checkpointReached:FireClient(player, number)
		end)
	end
end

-- Hazards (lava, water): touching one sends you back to your checkpoint
for _, hazard in hazardsFolder:GetChildren() do
	if hazard:IsA("BasePart") then
		hazard.Touched:Connect(function(hit)
			local _, humanoid = getPlayerFromPart(hit)
			if humanoid then
				humanoid.Health = 0
			end
		end)
	end
end

-- Glass tiles: blink, fade away, then come back
for _, tile in tilesFolder:GetChildren() do
	if tile:IsA("BasePart") then
		local busy = false
		local startColor = tile.Color
		local startTransparency = tile.Transparency
		tile.Touched:Connect(function(hit)
			if busy or not getPlayerFromPart(hit) then
				return
			end
			busy = true
			tile.Color = Color3.fromRGB(255, 170, 60)
			task.wait(GameConfig.FADE_WARNING)
			local fade = TweenService:Create(tile, TweenInfo.new(GameConfig.FADE_TIME), { Transparency = 1 })
			fade:Play()
			fade.Completed:Wait()
			tile.CanCollide = false
			task.wait(GameConfig.FADE_RESPAWN)
			tile.Color = startColor
			tile.Transparency = startTransparency
			tile.CanCollide = true
			busy = false
		end)
	end
end

-- Spinning bars: each player's screen spins the bar and checks its own
-- character against it (what you see is what hits you, even with lag).
-- The screen then asks the server to send that player back.
spinnerHit.OnServerEvent:Connect(function(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
end)

-- Goal
local goalPad = goalModel:WaitForChild("Pad")
goalPad.Touched:Connect(function(hit)
	local player = getPlayerFromPart(hit)
	local data = player and progress[player]
	-- you must have passed the last checkpoint (also ignores the old character
	-- still standing on the pad right after "play again")
	if not data or data.finished or data.zone < GameConfig.TOTAL_ZONES then
		return
	end
	data.finished = true
	local now = workspace:GetServerTimeNow()
	player:SetAttribute("FinishTime", now)
	local stars = getStat(player, "별")
	goalReached:FireClient(player, {
		stars = stars and stars.Value or 0,
		total = TOTAL_STARS,
		seconds = now - (player:GetAttribute("StartTime") or now),
	})
end)

-- "Play again" button on the goal screen
restartRequest.OnServerEvent:Connect(function(player)
	local data = progress[player]
	if not data or not data.finished then
		return
	end
	resetProgress(player)
	restartRequest:FireClient(player)
	player:LoadCharacter()
end)

-- Signs: each sign part has a StringValue "Text"
for _, sign in signsFolder:GetChildren() do
	local textValue = sign:FindFirstChild("Text")
	if sign:IsA("BasePart") and textValue then
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Back -- the side that faces players coming down the course
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.Text = textValue.Value
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Parent = gui

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0.04, 0)
		padding.PaddingRight = UDim.new(0.04, 0)
		padding.PaddingTop = UDim.new(0.08, 0)
		padding.PaddingBottom = UDim.new(0.08, 0)
		padding.Parent = label

		gui.Parent = sign
	end
end

print(string.format("[GameServer] ready: %d stars, %d checkpoints", TOTAL_STARS, #checkpointsFolder:GetChildren()))
