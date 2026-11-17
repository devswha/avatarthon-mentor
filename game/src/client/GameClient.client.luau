-- GameClient (LocalScript in StarterPlayerScripts)
-- What each player sees and feels: the score bar, spinning stars,
-- mushroom bounces, spinning bars and the goal screen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local course = workspace:WaitForChild("Course")
local starsFolder = course:WaitForChild("Stars")

local FONT = Enum.Font.FredokaOne
local WHITE = Color3.new(1, 1, 1)

---------------------------------------------------------------------------
-- Screen: score bar, short messages and the goal panel
---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "GameHud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function makeLabel(parent, text, textSize)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.Text = text
	label.TextSize = textSize
	label.TextColor3 = WHITE
	label.Parent = parent
	return label
end

local scoreBar = Instance.new("Frame")
scoreBar.AnchorPoint = Vector2.new(0.5, 0)
scoreBar.Position = UDim2.new(0.5, 0, 0, 10)
scoreBar.Size = UDim2.fromOffset(500, 50)
scoreBar.BackgroundColor3 = Color3.fromRGB(34, 30, 58)
scoreBar.BackgroundTransparency = 0.15
scoreBar.Parent = gui
addCorner(scoreBar, UDim.new(0.5, 0))

local scoreLabel = makeLabel(scoreBar, "", 26)
scoreLabel.AnchorPoint = Vector2.new(0.5, 0.5)
scoreLabel.Position = UDim2.fromScale(0.5, 0.5)
scoreLabel.Size = UDim2.new(1, -28, 1, -10)
scoreLabel.TextScaled = true
local scoreTextLimit = Instance.new("UITextSizeConstraint")
scoreTextLimit.MaxTextSize = 26
scoreTextLimit.Parent = scoreLabel

local toast = makeLabel(gui, "", 30)
toast.AnchorPoint = Vector2.new(0.5, 0)
toast.Position = UDim2.new(0.5, 0, 0, 70)
toast.Size = UDim2.fromOffset(520, 44)
toast.TextStrokeTransparency = 0.2
toast.Visible = false

local toastId = 0
local function showToast(text, color)
	toastId += 1
	local myId = toastId
	toast.Text = text
	toast.TextColor3 = color or WHITE
	toast.Visible = true
	task.delay(1.8, function()
		if toastId == myId then
			toast.Visible = false
		end
	end)
end

-- Goal panel
local goalPanel = Instance.new("Frame")
goalPanel.AnchorPoint = Vector2.new(0.5, 0.5)
goalPanel.Position = UDim2.fromScale(0.5, 0.5)
goalPanel.Size = UDim2.fromOffset(420, 300)
goalPanel.BackgroundColor3 = Color3.fromRGB(34, 30, 58)
goalPanel.BackgroundTransparency = 0.05
goalPanel.Visible = false
goalPanel.Parent = gui
addCorner(goalPanel, UDim.new(0, 24))

local goalTitle = makeLabel(goalPanel, "🏆 골인!", 54)
goalTitle.Position = UDim2.fromOffset(0, 24)
goalTitle.Size = UDim2.new(1, 0, 0, 64)
goalTitle.TextColor3 = Color3.fromRGB(255, 210, 70)

local goalBody = makeLabel(goalPanel, "", 30)
goalBody.Position = UDim2.fromOffset(0, 100)
goalBody.Size = UDim2.new(1, 0, 0, 90)

local againButton = Instance.new("TextButton")
againButton.AnchorPoint = Vector2.new(0.5, 1)
againButton.Position = UDim2.new(0.5, 0, 1, -24)
againButton.Size = UDim2.fromOffset(260, 56)
againButton.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
againButton.Font = FONT
againButton.Text = "처음부터 다시 하기"
againButton.TextSize = 28
againButton.TextColor3 = WHITE
againButton.Parent = goalPanel
addCorner(againButton, UDim.new(0, 16))

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function getStatValue(statName)
	local leaderstats = player:FindFirstChild("leaderstats")
	local stat = leaderstats and leaderstats:FindFirstChild(statName)
	return stat and stat.Value or 0
end

local function updateScore()
	local startTime = player:GetAttribute("StartTime")
	local endTime = player:GetAttribute("FinishTime") or workspace:GetServerTimeNow()
	local elapsed = if startTime then endTime - startTime else 0
	scoreLabel.Text = string.format(
		"⭐ %d / %d     🚩 %d / %d 구역     ⏱ %s",
		getStatValue("별"),
		player:GetAttribute("TotalStars") or 0,
		math.max(1, getStatValue("구역")),
		GameConfig.TOTAL_ZONES,
		formatTime(elapsed)
	)
end

---------------------------------------------------------------------------
-- Little effects
---------------------------------------------------------------------------
local function burst(position, colors, count)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.Position = position
	holder.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = colors
	emitter.LightEmission = 0.6
	emitter.Lifetime = NumberRange.new(0.5, 1)
	emitter.Speed = NumberRange.new(12, 22)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Enabled = false
	emitter.Parent = holder
	emitter:Emit(count)
	Debris:AddItem(holder, 1.5)
end

local GOLD = ColorSequence.new(Color3.fromRGB(255, 220, 80), Color3.fromRGB(255, 160, 40))
local PARTY = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 80)),
	ColorSequenceKeypoint.new(0.66, Color3.fromRGB(90, 200, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 110, 255)),
})

---------------------------------------------------------------------------
-- Stars: spin and bob on screen, vanish when collected
---------------------------------------------------------------------------
local spinning = {} -- [starModel] = { center = CFrame, parts = { { part, offset } } }
local hiddenStars = {} -- stars this player already collected
local originalCFrames = {} -- first CFrame we saw for each star part
local pendingRefresh = {}

local function refreshStar(star)
	pendingRefresh[star] = nil
	local hitbox = star:FindFirstChild("Hitbox")
	if not hitbox or hiddenStars[star] then
		return
	end
	local center = hitbox.CFrame
	local parts = {}
	for _, item in star:GetDescendants() do
		if item:IsA("BasePart") and item ~= hitbox and item.Name ~= "PropAnchor" then
			originalCFrames[item] = originalCFrames[item] or item.CFrame
			table.insert(parts, { part = item, offset = center:ToObjectSpace(originalCFrames[item]) })
		end
	end
	spinning[star] = { center = center, parts = parts }
end

for _, star in starsFolder:GetChildren() do
	refreshStar(star)
	-- the Blender mesh can arrive a moment later: rebuild once it does
	star.DescendantAdded:Connect(function(item)
		if item:IsA("BasePart") and not pendingRefresh[star] then
			pendingRefresh[star] = true
			task.defer(refreshStar, star)
		end
	end)
end

remotes:WaitForChild("StarCollected").OnClientEvent:Connect(function(star)
	if hiddenStars[star] then
		return
	end
	local hitbox = star:FindFirstChild("Hitbox")
	if hitbox then
		burst(hitbox.Position, GOLD, 24)
	end
	hiddenStars[star] = true
	spinning[star] = nil
	star.Parent = nil -- only on this player's screen
	showToast(string.format("⭐ 별 %d / %d", getStatValue("별"), player:GetAttribute("TotalStars") or 0))
end)

---------------------------------------------------------------------------
-- Checkpoints: flag turns green on your screen
---------------------------------------------------------------------------
local checkpointsFolder = course:WaitForChild("Checkpoints")
local flagColors = {}

local function paintCheckpoint(checkpoint, color)
	for _, item in checkpoint:GetDescendants() do
		if item:IsA("BasePart") and (item.Name == "Pad" or string.find(item.Name, "Cloth")) then
			flagColors[item] = flagColors[item] or item.Color
			item.Color = color or flagColors[item]
		end
	end
end

remotes:WaitForChild("CheckpointReached").OnClientEvent:Connect(function(number)
	local checkpoint = checkpointsFolder:FindFirstChild("Checkpoint" .. number)
	if checkpoint then
		paintCheckpoint(checkpoint, GameConfig.REACHED_COLOR)
		local pad = checkpoint:FindFirstChild("Pad")
		if pad then
			burst(pad.Position + Vector3.new(0, 2, 0), PARTY, 30)
		end
	end
	showToast(string.format("🚩 체크포인트! 이제 %d구역", number + 1), GameConfig.REACHED_COLOR)
end)

---------------------------------------------------------------------------
-- Mushrooms: bounce your character up
---------------------------------------------------------------------------
local lastBounce = 0
for _, mushroom in course:WaitForChild("JumpPads"):GetChildren() do
	local pad = mushroom:WaitForChild("Pad")
	pad.Touched:Connect(function(hit)
		local character = player.Character
		if not character or not hit:IsDescendantOf(character) then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			return
		end
		if os.clock() - lastBounce < 0.4 then
			return
		end
		lastBounce = os.clock()
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, GameConfig.BOUNCE_SPEED, velocity.Z)
		burst(pad.Position + Vector3.new(0, 1, 0), ColorSequence.new(Color3.fromRGB(255, 120, 110)), 14)
	end)
end

---------------------------------------------------------------------------
-- Spinning bars: every screen spins the bar with the shared server clock,
-- and checks only its own character, so what you see is what hits you.
---------------------------------------------------------------------------
local spinnerHit = remotes:WaitForChild("SpinnerHit")
local spinnerParams = OverlapParams.new()
spinnerParams.FilterType = Enum.RaycastFilterType.Include
local lastSpinnerHit = 0
local spinners = {}
for _, spinner in course:WaitForChild("Spinners"):GetChildren() do
	local hub = spinner:WaitForChild("Hub")
	local bar = spinner:WaitForChild("Bar")
	table.insert(spinners, {
		hub = hub,
		bar = bar,
		offset = CFrame.new(hub.Position):ToObjectSpace(bar.CFrame),
	})
end

local function checkSpinnerHit(barCFrame, barSize)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or os.clock() - lastSpinnerHit < 1 then
		return
	end
	spinnerParams.FilterDescendantsInstances = { character }
	for _, part in workspace:GetPartBoundsInBox(barCFrame, barSize, spinnerParams) do
		-- hats and hair have big boxes: only the body counts
		if not part:FindFirstAncestorOfClass("Accessory") then
			lastSpinnerHit = os.clock()
			spinnerHit:FireServer()
			return
		end
	end
end

---------------------------------------------------------------------------
-- Goal and restart
---------------------------------------------------------------------------
remotes:WaitForChild("GoalReached").OnClientEvent:Connect(function(result)
	goalBody.Text = string.format("모은 별  %d / %d\n기록  %s", result.stars, result.total, formatTime(result.seconds))
	goalPanel.Visible = true
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		for i = 0, 2 do
			task.delay(i * 0.35, burst, root.Position + Vector3.new(0, 3, 0), PARTY, 40)
		end
	end
end)

againButton.Activated:Connect(function()
	goalPanel.Visible = false
	remotes.RestartRequest:FireServer()
end)

remotes:WaitForChild("RestartRequest").OnClientEvent:Connect(function()
	goalPanel.Visible = false
	for star in hiddenStars do
		star.Parent = starsFolder
	end
	table.clear(hiddenStars)
	for _, star in starsFolder:GetChildren() do
		refreshStar(star)
	end
	for _, checkpoint in checkpointsFolder:GetChildren() do
		paintCheckpoint(checkpoint, nil)
	end
	showToast("다시 출발! ⭐ 별을 모아 보세요")
end)

---------------------------------------------------------------------------
-- Every frame
---------------------------------------------------------------------------
local clockStart = os.clock()
RunService.RenderStepped:Connect(function()
	local now = os.clock() - clockStart -- small numbers keep the spin smooth
	for _, info in spinning do
		local turn = info.center * CFrame.new(0, math.sin(now * 2) * 0.3, 0) * CFrame.Angles(0, (now * GameConfig.STAR_SPIN_SPEED) % (2 * math.pi), 0)
		for _, item in info.parts do
			item.part.CFrame = turn * item.offset
		end
	end

	local angle = GameConfig.spinnerAngle(workspace:GetServerTimeNow())
	for _, spinner in spinners do
		local barCFrame = CFrame.new(spinner.hub.Position) * CFrame.Angles(0, angle, 0) * spinner.offset
		spinner.bar.CFrame = barCFrame
		checkSpinnerHit(barCFrame, spinner.bar.Size)
	end

	updateScore()
end)

showToast("⭐ 별을 모으며 🏆 트로피까지 가 보세요!")
