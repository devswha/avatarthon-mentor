-- GameConfig (ModuleScript in ReplicatedStorage)
-- Numbers and colors shared by the server and the client.
-- Tune the game here without touching the main scripts.

local GameConfig = {}

-- Gameplay feel
GameConfig.BOUNCE_SPEED = 95 -- upward speed a mushroom gives you (about 23 studs high)
GameConfig.FADE_WARNING = 0.35 -- seconds a glass tile blinks before it starts to vanish
GameConfig.FADE_TIME = 0.6 -- seconds a glass tile takes to disappear
GameConfig.FADE_RESPAWN = 2.5 -- seconds before a vanished tile comes back
GameConfig.SPINNER_SPEED = 1.4 -- spinning bar speed (radians per second)
GameConfig.STAR_SPIN_SPEED = 2.2 -- how fast stars turn
GameConfig.RESPAWN_TIME = 1 -- seconds before you come back after falling
GameConfig.TOTAL_ZONES = 4 -- start area + 3 checkpoints

-- Blender props
-- In Roblox Studio use File > Import 3D and pick AvatarthonProps.fbx.
-- The imported model keeps this name. The BlenderProps script finds it and
-- puts a copy of each prop on every matching spot in the course.
GameConfig.PROP_MODEL_NAME = "AvatarthonProps"

-- size: target size in studs, by: which side to measure,
-- pivot: which point of the prop sits on the spot's PropAnchor part
GameConfig.PROPS = {
	StarCoin = { size = 3.2, by = "height", pivot = "bottom" },
	JumpMushroom = { size = 6.5, by = "width", pivot = "bottom" },
	CheckFlag = { size = 8, by = "height", pivot = "bottom" },
	GoalTrophy = { size = 8, by = "height", pivot = "bottom" },
	CloudPad = { size = 10, by = "width", pivot = "top" },
}

-- Which course folder uses which prop
GameConfig.PROP_FOLDERS = {
	Stars = "StarCoin",
	JumpPads = "JumpMushroom",
	Checkpoints = "CheckFlag",
	Goal = "GoalTrophy",
	Clouds = "CloudPad",
}

-- Mesh colors (same as the Blender materials), so the props look right
-- even if the importer drops the material colors.
GameConfig.MESH_COLORS = {
	StarCoin_Body = Color3.fromRGB(255, 200, 61),
	JumpMushroom_Cap = Color3.fromRGB(232, 70, 60),
	JumpMushroom_Dots = Color3.fromRGB(255, 246, 232),
	JumpMushroom_Stem = Color3.fromRGB(243, 221, 179),
	CheckFlag_Pole = Color3.fromRGB(230, 230, 234),
	CheckFlag_Cloth = Color3.fromRGB(63, 169, 245),
	CheckFlag_Base = Color3.fromRGB(74, 79, 90),
	GoalTrophy_Cup = Color3.fromRGB(255, 200, 61),
	GoalTrophy_Base = Color3.fromRGB(91, 58, 140),
	CloudPad_Body = Color3.fromRGB(255, 255, 255),
}

-- A reached checkpoint turns this color on your screen
GameConfig.REACHED_COLOR = Color3.fromRGB(80, 220, 120)

-- Spinning bar angle from the shared server clock, so every screen agrees.
-- The clock is a huge number (seconds since 1970), so wrap it to one turn
-- BEFORE it goes into CFrame.Angles, which works in lower precision.
function GameConfig.spinnerAngle(serverTime)
	return (serverTime * GameConfig.SPINNER_SPEED) % (2 * math.pi)
end

return GameConfig
