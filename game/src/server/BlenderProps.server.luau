-- BlenderProps (Script in ServerScriptService)
-- Swaps the basic-part placeholders for the props made in Blender.
--
-- How to use (once, in Roblox Studio):
--   1. File > Import 3D > choose AvatarthonProps.fbx
--   2. Leave the imported model "AvatarthonProps" in Workspace
--      (or drag it into ServerStorage so it is out of sight)
--   3. Press Play. This script copies each Blender prop onto every spot.
-- If the model is not there, the placeholders stay and the game still works.
--
-- Every spot in the course is a Model with:
--   PropAnchor  - invisible part: where the prop stands and which way it faces
--   Placeholder - the basic-part version (hidden once the Blender prop is in)
-- Collisions never come from the Blender meshes, so the course plays the same
-- with or without them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local course = workspace:WaitForChild("Course")

local function findImportedModel()
	for _, container in { workspace, ServerStorage, ReplicatedStorage } do
		local found = container:FindFirstChild(GameConfig.PROP_MODEL_NAME, true)
		if found then
			return found
		end
	end
	return nil
end

-- "JumpMushroom_Cap.001" -> kind "JumpMushroom", mesh name "JumpMushroom_Cap"
local function splitMeshName(name)
	local kind, part = string.match(name, "^(%w+)_(%w+)")
	if not kind then
		return nil, nil
	end
	return kind, kind .. "_" .. part
end

-- Group the imported meshes by prop and make one ready-to-copy model per prop
local function buildLibrary(imported, holder)
	local groups = {}
	for _, item in imported:GetDescendants() do
		if item:IsA("BasePart") then
			local kind, meshName = splitMeshName(item.Name)
			if kind and GameConfig.PROPS[kind] then
				groups[kind] = groups[kind] or {}
				table.insert(groups[kind], { part = item, meshName = meshName })
			end
		end
	end

	local library = {}
	for kind, entries in groups do
		local spec = GameConfig.PROPS[kind]
		local model = Instance.new("Model")
		model.Name = kind
		for _, entry in entries do
			local copy = entry.part:Clone()
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanTouch = false
			copy.CanQuery = false
			copy.Massless = true
			local color = GameConfig.MESH_COLORS[entry.meshName]
			if color then
				copy.Color = color
			end
			copy.Parent = model
		end
		model.Parent = holder

		-- Measure with a world-aligned box, scale to the target size,
		-- then move the pivot to the bottom (or top) center of the prop.
		model.WorldPivot = CFrame.new()
		local _, size = model:GetBoundingBox()
		local current = if spec.by == "width" then math.max(size.X, size.Z) else size.Y
		if current > 0 then
			model:ScaleTo(spec.size / current)
		end
		local boxCFrame, boxSize = model:GetBoundingBox()
		local yOffset = if spec.pivot == "top" then boxSize.Y / 2 else -boxSize.Y / 2
		model.WorldPivot = CFrame.new(boxCFrame.Position + Vector3.new(0, yOffset, 0))
		library[kind] = model
	end
	return library
end

local function placeProp(spot, template)
	local anchor = spot:FindFirstChild("PropAnchor")
	if not anchor then
		return
	end
	local copy = template:Clone()
	copy.Name = "BlenderMesh"
	copy:PivotTo(anchor.CFrame)
	copy.Parent = spot

	local placeholder = spot:FindFirstChild("Placeholder")
	if placeholder then
		for _, part in placeholder:GetDescendants() do
			if part:IsA("BasePart") then
				part.Transparency = 1 -- hidden, but still solid where it was solid
			end
		end
	end
end

local imported = findImportedModel()
if not imported then
	print("[BlenderProps] '" .. GameConfig.PROP_MODEL_NAME .. "' not found - using basic-part placeholders")
else
	imported.Parent = ServerStorage -- keep the original out of the course

	local holder = Instance.new("Folder")
	holder.Name = "PropLibrary"
	holder.Parent = ServerStorage

	local library = buildLibrary(imported, holder)
	local placed = 0
	for folderName, kind in GameConfig.PROP_FOLDERS do
		local folder = course:FindFirstChild(folderName)
		local template = library[kind]
		if folder and template then
			for _, spot in folder:GetChildren() do
				placeProp(spot, template)
				placed += 1
			end
		elseif not template then
			warn("[BlenderProps] no meshes named " .. kind .. "_* inside " .. GameConfig.PROP_MODEL_NAME)
		end
	end
	print(string.format("[BlenderProps] placed %d Blender props", placed))
end
