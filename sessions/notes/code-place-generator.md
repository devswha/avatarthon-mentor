# 게임 파일 생성기 원문

`game/place/AvatarthonStarObby.rbxlx`는 이 스크립트가 만든다(파이썬 표준 라이브러리만 사용).
작업한 PC가 리눅스라 Roblox Studio를 쓸 수 없었고, 내려받은 Rojo 실행도 막혀서 로블록스 XML을 직접 쓰는 방법을 택했다.

- `build_place.py`: 코스 배치(발판·별·버섯·체크포인트·용암·유리 발판·회전 막대·구름·골인)와 `src/`의 Luau 스크립트를 합쳐 `.rbxlx`를 쓴다.
- `render_course.py`: 같은 배치를 Blender로 그려 코스 미리보기(`layout-course_*.png`)를 만든다. 게임의 BlenderProps 스크립트와 같은 규칙으로 소품을 얹어, 배치와 크기 계산이 맞는지 확인하는 데 썼다.


## `tools/build_place.py`

~~~~python
#!/usr/bin/env python3
"""Build the Roblox place file (place/AvatarthonStarObby.rbxlx) from the Luau sources and the course layout below.

Standard library only. Writes Roblox XML (rbxlx, version 4) directly, so no Rojo or Studio is needed to build.
Script naming follows the Rojo convention:
  src/server/*.server.luau  -> Script in ServerScriptService
  src/client/*.client.luau  -> LocalScript in StarterPlayer.StarterPlayerScripts
  src/shared/*.luau         -> ModuleScript in ReplicatedStorage

Course layout: the course runs from the start island toward -Z. Heights are given as the TOP surface of each
platform (y_top), which is easier to reason about for jump distances than part centers.
Default character: walk speed 16, jump height about 7 studs, so gaps stay at 2-6 studs and steps up at most 2.
"""
import math
import uuid
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "place" / "AvatarthonStarObby.rbxlx"

MATERIAL = {"Plastic": 256, "SmoothPlastic": 272, "Neon": 288, "Wood": 512, "WoodPlanks": 528, "Slate": 800,
            "Concrete": 816, "Grass": 1280, "Sand": 1296, "Ice": 1536, "Glass": 1568}
SHAPE = {"Ball": 0, "Block": 1, "Cylinder": 2}
TECHNOLOGY_SHADOWMAP = 3

IDENTITY = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


# ── rotation helpers (row-major 3x3, same layout as Roblox R00..R22) ──────────────
def rot_y(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((c, 0, s), (0, 1, 0), (-s, 0, c))


def rot_z(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((c, -s, 0), (s, c, 0), (0, 0, 1))


def matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


UPRIGHT = rot_z(90)   # a Roblox cylinder's axis is X; this stands it up along Y


# ── instance tree ──────────────────────────────────────────────────────────
class Inst:
    def __init__(self, cls, name, props=None, children=None):
        self.cls, self.name = cls, name
        self.props = props or {}
        self.children = list(children or [])

    def add(self, *kids):
        self.children.extend(kids)
        return self


def num(v):
    v = round(float(v), 4)
    if v == 0:
        v = 0.0   # no "-0"
    return f"{v:.4f}".rstrip("0").rstrip(".")


def color_u8(rgb):
    r, g, b = rgb
    return str(0xFF000000 | (r << 16) | (g << 8) | b)


def prop_xml(name, value):
    kind, v = value
    if kind == "string":
        return f'<string name="{name}">{escape(v)}</string>'
    if kind == "bool":
        return f'<bool name="{name}">{"true" if v else "false"}</bool>'
    if kind in ("float", "int"):
        return f'<{kind} name="{name}">{num(v) if kind == "float" else int(v)}</{kind}>'
    if kind == "token":
        return f'<token name="{name}">{int(v)}</token>'
    if kind == "Vector3":
        return f'<Vector3 name="{name}"><X>{num(v[0])}</X><Y>{num(v[1])}</Y><Z>{num(v[2])}</Z></Vector3>'
    if kind == "Color3":
        return f'<Color3 name="{name}"><R>{num(v[0] / 255)}</R><G>{num(v[1] / 255)}</G><B>{num(v[2] / 255)}</B></Color3>'
    if kind == "Color3uint8":
        return f'<Color3uint8 name="{name}">{color_u8(v)}</Color3uint8>'
    if kind == "CFrame":
        pos, r = v
        cells = "".join(f"<R{i}{j}>{num(r[i][j])}</R{i}{j}>" for i in range(3) for j in range(3))
        return (f'<CoordinateFrame name="{name}"><X>{num(pos[0])}</X><Y>{num(pos[1])}</Y><Z>{num(pos[2])}</Z>'
                f"{cells}</CoordinateFrame>")
    if kind == "source":
        assert "]]>" not in v, "script source must not contain ]]>"
        return f'<ProtectedString name="{name}"><![CDATA[{v}]]></ProtectedString>'
    raise ValueError(kind)


def item_xml(inst, out, depth):
    pad = "\t" * depth
    out.append(f'{pad}<Item class="{inst.cls}" referent="RBX{uuid.uuid4().hex.upper()}">')
    out.append(f"{pad}\t<Properties>")
    out.append(f"{pad}\t\t{prop_xml('Name', ('string', inst.name))}")
    for key in sorted(inst.props):
        out.append(f"{pad}\t\t{prop_xml(key, inst.props[key])}")
    out.append(f"{pad}\t</Properties>")
    for child in inst.children:
        item_xml(child, out, depth + 1)
    out.append(f"{pad}</Item>")


# ── part helpers ───────────────────────────────────────────────────────────
def part(name, size, pos, rgb, material="SmoothPlastic", rot=IDENTITY, shape="Block", collide=True,
         transparency=0.0, touch=True, query=True, shadow=True, reflectance=0.0, cls="Part", extra=None):
    props = {
        "Anchored": ("bool", True),
        "CFrame": ("CFrame", (pos, rot)),
        "size": ("Vector3", size),
        "Color3uint8": ("Color3uint8", rgb),
        "Material": ("token", MATERIAL[material]),
        "shape": ("token", SHAPE[shape]),
        "CanCollide": ("bool", collide),
        "CanTouch": ("bool", touch),
        "CanQuery": ("bool", query),
        "CastShadow": ("bool", shadow),
        "Transparency": ("float", transparency),
        "Reflectance": ("float", reflectance),
        "TopSurface": ("token", 0),
        "BottomSurface": ("token", 0),
    }
    props.update(extra or {})
    return Inst(cls, name, props)


def block(name, size, x, y_top, z, rgb, **kw):
    """Block whose TOP surface is at y_top."""
    return part(name, size, (x, y_top - size[1] / 2, z), rgb, **kw)


def cylinder(name, height, diameter, x, y_bottom, z, rgb, **kw):
    """Upright cylinder standing on y_bottom."""
    return part(name, (height, diameter, diameter), (x, y_bottom + height / 2, z), rgb, shape="Cylinder",
                rot=UPRIGHT, **kw)


def ball(name, diameter, x, y, z, rgb, **kw):
    return part(name, (diameter, diameter, diameter), (x, y, z), rgb, shape="Ball", **kw)


def anchor(x, y, z, yaw=0):
    """Invisible marker: where a Blender prop's pivot goes."""
    return part("PropAnchor", (1, 1, 1), (x, y, z), (255, 255, 255), rot=rot_y(yaw), collide=False,
                transparency=1, touch=False, query=False, shadow=False)


def model(name, *children):
    return Inst("Model", name, children=children)


def folder(name, *children):
    return Inst("Folder", name, children=children)


# ── palette ────────────────────────────────────────────────────────────────
GRASS = (106, 190, 48)
DIRT = (125, 84, 54)
SAND = (240, 214, 150)
ZONE1 = (255, 214, 92)       # sunny yellow hops
ZONE1B = (255, 168, 76)
ZONE2 = (245, 140, 190)      # mushroom forest pink
ZONE2B = (190, 130, 230)
STONE = (88, 84, 98)         # lava zone
CP = (240, 240, 245)
SKY = (140, 200, 255)
GOLD = (255, 200, 61)
LAVA = (255, 98, 0)
WATER = (52, 152, 219)
GLASS = (150, 220, 255)
WHITE = (255, 255, 255)
RED = (232, 70, 60)
CREAM = (243, 221, 179)
FLAG = (63, 169, 245)
POLE = (230, 230, 234)
DARK = (74, 79, 90)
PURPLE = (91, 58, 140)
SIGN = (52, 44, 92)
WOOD = (150, 103, 64)
LEAF = (60, 170, 70)


# ── course pieces ──────────────────────────────────────────────────────────
STAR_HEIGHT = 3.2


def star(index, x, y_center, z):
    """Collectible star. Placeholder: a gold coin. The Blender star replaces it."""
    return model(
        f"Star{index:02d}",
        part("Hitbox", (3.4, 3.4, 3.4), (x, y_center, z), GOLD, collide=False, transparency=1, shadow=False),
        anchor(x, y_center - STAR_HEIGHT / 2, z),
        model("Placeholder",
              part("Coin", (0.6, 2.8, 2.8), (x, y_center, z), GOLD, shape="Cylinder", collide=False,
                   touch=False, query=False, rot=rot_y(90))),
    )


def mushroom(index, x, ground, z):
    """Bounce pad. The invisible Pad on top does the bouncing (see GameClient)."""
    dots = [ball(f"Dot{i}", 1.1, x + dx, ground + 4.55, z + dz, WHITE, collide=False, touch=False, query=False)
            for i, (dx, dz) in enumerate([(1.6, 0.6), (-1.4, 1.2), (0.2, -1.8), (-1.2, -1.0), (1.0, 1.9)])]
    return model(
        f"Mushroom{index}",
        block("Pad", (6, 1, 6), x, ground + 4.5, z, RED, transparency=1, shadow=False),
        anchor(x, ground, z),
        model("Placeholder",
              cylinder("Stem", 3.2, 2.4, x, ground, z, CREAM),
              cylinder("Cap", 1.4, 6.5, x, ground + 3.1, z, RED, collide=False),
              *dots),
    )


def checkpoint(index, x, top, z):
    """Checkpoint pad with a flag beside it."""
    fx = x + 5
    return model(
        f"Checkpoint{index}",
        block("Pad", (6, 0.6, 6), x, top + 0.6, z, CP, material="SmoothPlastic"),
        anchor(fx, top, z, yaw=180),
        model("Placeholder",
              cylinder("Base", 0.6, 2.2, fx, top, z, DARK, collide=False),
              cylinder("Pole", 7.6, 0.5, fx, top + 0.4, z, POLE),
              part("Cloth", (0.2, 2.2, 3.2), (fx, top + 6.6, z - 1.6), FLAG, collide=False, touch=False)),
    )


def cloud(index, x, top, z):
    """Cloud platform. Floor is the solid part; puffs are decoration."""
    puffs = [ball(f"Puff{i}", d, x + dx, top - 0.8, z + dz, WHITE, collide=False, touch=False, query=False)
             for i, (dx, dz, d) in enumerate([(-3.4, 0, 3.4), (3.4, 0, 3.4), (0, 2.2, 3.0), (0, -2.2, 3.0)])]
    return model(
        f"Cloud{index}",
        anchor(x, top + 0.3, z),
        model("Placeholder", block("Floor", (8, 1.2, 6), x, top, z, WHITE), *puffs),
    )


def sign(name, text, size, pos, yaw=0):
    return part(name, size, pos, SIGN, rot=rot_y(yaw), extra={}).add(Inst("StringValue", "Text", {"Value": ("string", text)}))


def tree(name, x, ground, z, height=6):
    return model(name,
                 cylinder("Trunk", height, 1.4, x, ground, z, WOOD, material="Wood"),
                 ball("Leaves", 6.5, x, ground + height + 1.5, z, LEAF, material="Grass", collide=False))


def build_course():
    ground = folder("Ground")
    decor = folder("Decor")
    stars = folder("Stars")
    pads = folder("JumpPads")
    clouds = folder("Clouds")
    checkpoints = folder("Checkpoints")
    hazards = folder("Hazards")
    tiles = folder("FadingTiles")
    spinners = folder("Spinners")
    signs = folder("Signs")
    goal = folder("Goal")

    star_spots = []

    # Start island (top y = 1)
    ground.add(block("StartIsland", (26, 4, 26), 0, 1, 0, GRASS, material="Grass"),
               block("StartIslandDirt", (22, 6, 22), 0, -3, 0, DIRT))
    decor.add(tree("Tree1", -9, 1, 8), tree("Tree2", 9, 1, 8, height=7), tree("Tree3", -10, 1, -7, height=5))
    signs.add(sign("WelcomeSign", "⭐ 별을 모으며 🏆 트로피까지! ⭐", (16, 3.6, 0.6), (0, 9.5, -11)))
    star_spots += [(-5, 2.8, -4), (5, 2.8, -4)]

    # Zone 1: sunny hops (gaps 2-4 studs, steps up 1.5)
    ground.add(block("Hop1", (8, 2, 8), 0, 1, -20, ZONE1),
               block("Hop2", (6, 2, 6), 4, 2.5, -30, ZONE1B),
               block("Hop3", (6, 2, 6), -2, 4, -40, ZONE1),
               block("Hop4", (6, 2, 6), 4, 5.5, -50, ZONE1B),
               block("BonusHop", (4, 2, 4), -8, 4, -50, ZONE1B),
               block("Beam1", (3, 2, 12), 4, 5.5, -61, ZONE1),
               block("Checkpoint1Island", (16, 2, 14), 0, 5.5, -76, CP))
    star_spots += [(4, 5.3, -30), (1, 9.5, -45), (-8, 6.8, -50), (4, 8.3, -61)]
    checkpoints.add(checkpoint(1, 0, 5.5, -77))

    # Zone 2: mushroom forest (bounce up to high islands)
    signs.add(sign("Zone2Sign", "2구역 · 🍄 버섯 트램펄린", (10, 3, 0.6), (-9, 10.5, -82)))
    ground.add(block("MushroomIsland1", (12, 2, 12), 0, 5.5, -93, ZONE2),
               block("HighIsland1", (12, 2, 12), 0, 22, -108, ZONE2B),
               block("MushroomIsland2", (10, 2, 10), 0, 14, -126, ZONE2),
               block("Checkpoint2Island", (16, 2, 14), 0, 30, -144, CP))
    pads.add(mushroom(1, 0, 5.5, -93), mushroom(2, 0, 14, -126))
    star_spots += [(0, 18, -97), (0, 27, -101), (4, 24.8, -110), (0, 26, -130), (0, 36, -134), (-5, 32.8, -141)]
    checkpoints.add(checkpoint(2, 0, 30, -145))

    # Zone 3: lava bridge and glass tiles that vanish
    signs.add(sign("Zone3Sign", "3구역 · 🔥 용암 다리 (유리 발판은 사라져요!)", (14, 3, 0.6), (-10, 34.5, -150)))
    hazards.add(block("LavaPool", (34, 1, 70), 0, 18, -190, LAVA, material="Neon"),
                block("LavaBump", (3, 1.4, 1), 0, 31.4, -158, LAVA, material="Neon"))
    ground.add(block("LavaBeam", (3, 2, 16), 0, 30, -159, STONE, material="Slate"))
    for i, (x, z) in enumerate([(-3, -171), (2, -178), (-2, -185), (3, -192), (-1, -199), (2, -206)], start=1):
        tiles.add(block(f"Glass{i}", (5, 1, 5), x, 30, z, GLASS, material="Glass", transparency=0.25))
    star_spots += [(0, 32.8, -164), (2, 32.8, -178), (-1, 32.8, -199)]
    ground.add(block("Checkpoint3Island", (16, 2, 14), 0, 30, -217, CP))
    checkpoints.add(checkpoint(3, 0, 30, -218))

    # Zone 4: spinning bar, then clouds up to the goal
    signs.add(sign("Zone4Sign", "4구역 · 🌀 회전 막대 → ☁️ 구름길", (12, 3, 0.6), (-10, 34.5, -223)))
    ground.add(block("SpinnerArena", (24, 2, 24), 0, 30, -238, SKY, material="Slate"))
    spinners.add(model("Spinner1",
                       cylinder("Hub", 4, 2.5, 0, 30, -238, DARK),
                       part("Bar", (22, 1.2, 1.2), (0, 31.4, -238), RED, material="Neon", collide=False,
                            touch=False, query=False)))
    clouds.add(cloud(1, 0, 31, -258), cloud(2, -5, 33, -269), cloud(3, 0, 35, -280), cloud(4, 5, 37, -291))
    star_spots += [(-8, 32.8, -244), (-2.5, 36.5, -264), (-2.5, 38.5, -275), (2.5, 40.5, -286), (5, 39.8, -291)]

    # Goal island with an arch
    ground.add(block("GoalIsland", (20, 2, 20), 0, 37, -306, SKY))
    decor.add(block("ArchLeft", (2, 11, 2), -8, 48, -298, PURPLE),
              block("ArchRight", (2, 11, 2), 8, 48, -298, PURPLE))
    signs.add(sign("GoalSign", "🏆 골인! 🏆", (18, 3, 2), (0, 49.5, -298)))
    goal.add(model("Goal",
                   block("Pad", (12, 0.6, 12), 0, 37.6, -306, GOLD),
                   anchor(0, 37.6, -310),
                   model("Placeholder",
                         block("Base", (3, 1.2, 3), 0, 38.8, -310, PURPLE, collide=False),
                         cylinder("Cup", 3.2, 2.6, 0, 38.8, -310, GOLD, collide=False),
                         block("HandleLeft", (0.6, 1.6, 0.6), -1.7, 41.4, -310, GOLD, collide=False),
                         block("HandleRight", (0.6, 1.6, 0.6), 1.7, 41.4, -310, GOLD, collide=False))))

    # Sea under everything: falling in sends you back to your checkpoint
    hazards.add(block("Sea", (700, 2, 800), 0, -19, -150, WATER, transparency=0.15, reflectance=0.1,
                      shadow=False))

    for i, (x, y, z) in enumerate(star_spots, start=1):
        stars.add(star(i, x, y, z))

    spawn = block("StartSpawn", (6, 1, 6), 0, 2, 6, (255, 255, 255), cls="SpawnLocation",
                  extra={"Neutral": ("bool", True), "Duration": ("int", 0),
                         "AllowTeamChangeOnTouch": ("bool", False), "Enabled": ("bool", True)})
    course = folder("Course", spawn, ground, decor, signs, stars, pads, clouds, checkpoints, hazards, tiles,
                    spinners, goal)
    return course, len(star_spots)


# ── scripts ────────────────────────────────────────────────────────────────
def script_items(folder_path, suffix, cls):
    items = []
    for f in sorted(folder_path.glob(f"*{suffix}")):
        name = f.name[: -len(suffix)]
        items.append(Inst(cls, name, {"Source": ("source", f.read_text(encoding="utf-8"))}))
    return items


def build_place():
    src = ROOT / "src"
    course, star_count = build_course()

    workspace = Inst("Workspace", "Workspace", {"StreamingEnabled": ("bool", False)}, [course])
    lighting = Inst("Lighting", "Lighting", {
        "TimeOfDay": ("string", "14:30:00"),
        "Brightness": ("float", 2.4),
        "Ambient": ("Color3", (110, 110, 130)),
        "OutdoorAmbient": ("Color3", (150, 150, 170)),
        "GlobalShadows": ("bool", True),
        "Technology": ("token", TECHNOLOGY_SHADOWMAP),
    }, [Inst("Sky", "Sky"),
        Inst("Atmosphere", "Atmosphere", {"Density": ("float", 0.25), "Haze": ("float", 0.6),
                                          "Color": ("Color3", (200, 220, 255))})])
    replicated = Inst("ReplicatedStorage", "ReplicatedStorage",
                      children=script_items(src / "shared", ".luau", "ModuleScript"))
    server = Inst("ServerScriptService", "ServerScriptService",
                  children=script_items(src / "server", ".server.luau", "Script"))
    starter_player = Inst("StarterPlayer", "StarterPlayer", children=[
        Inst("StarterPlayerScripts", "StarterPlayerScripts",
             children=script_items(src / "client", ".client.luau", "LocalScript")),
        Inst("StarterCharacterScripts", "StarterCharacterScripts"),
    ])
    services = [workspace, lighting, replicated, server, Inst("ServerStorage", "ServerStorage"),
                starter_player, Inst("StarterGui", "StarterGui")]

    out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
           'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
           "\t<External>null</External>", "\t<External>nil</External>"]
    for s in services:
        item_xml(s, out, 1)
    out.append("</roblox>")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    return star_count


def dump_parts(path):
    """Write every course part as JSON (for the Blender layout preview in tools/render_course.py)."""
    import json
    course, _ = build_course()
    parts = []

    def walk(inst, trail):
        if inst.cls in ("Part", "SpawnLocation"):
            pos, rot = inst.props["CFrame"][1]
            parts.append({"path": "/".join(trail + [inst.name]), "size": inst.props["size"][1], "pos": pos,
                          "rot": rot, "color": inst.props["Color3uint8"][1],
                          "shape": {v: k for k, v in SHAPE.items()}[inst.props["shape"][1]],
                          "transparency": inst.props["Transparency"][1]})
        for child in inst.children:
            walk(child, trail + [inst.name])

    walk(course, [])
    Path(path).write_text(json.dumps(parts, indent=1), encoding="utf-8")
    return len(parts)


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "--dump-json":
        print(f"dumped {dump_parts(sys.argv[2])} parts to {sys.argv[2]}")
    else:
        n = build_place()
        print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB, {n} stars)")
~~~~


## `tools/render_course.py`

~~~~python
"""Blender layout preview of the Roblox course (not a Studio screenshot).

Rebuilds every course part from the JSON written by `build_place.py --dump-json`, then places the Blender props
from AvatarthonProps.glb on each PropAnchor with the same rules as src/server/BlenderProps.server.luau
(group meshes by name prefix, scale to the target size, pivot at bottom/top center). Placeholder and invisible
parts are hidden, so the image shows what the game looks like after the Blender props are imported.

Run:
  blender -b --factory-startup --python tools/render_course.py -- <parts.json> <props.glb> <out_dir> [engine]
Coordinates: Roblox (x, y, z) with Y up  ->  Blender (x, -z, y) with Z up.
"""
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
PARTS_JSON, PROPS_GLB, OUT_DIR = Path(argv[0]), Path(argv[1]), Path(argv[2])
ENGINE = argv[3] if len(argv) > 3 else "EEVEE"

# Same table as GameConfig.PROPS / PROP_FOLDERS
PROPS = {"StarCoin": (3.2, "height", "bottom"), "JumpMushroom": (6.5, "width", "bottom"),
         "CheckFlag": (8, "height", "bottom"), "GoalTrophy": (8, "height", "bottom"), "CloudPad": (10, "width", "top")}
FOLDERS = {"Stars": "StarCoin", "JumpPads": "JumpMushroom", "Checkpoints": "CheckFlag", "Goal": "GoalTrophy",
           "Clouds": "CloudPad"}

P = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))   # Roblox axes -> Blender axes


def rbx_pos(p):
    return Vector((p[0], -p[2], p[1]))


def rbx_rot(r):
    return P @ Matrix(r) @ P.transposed()


def material(rgb, alpha):
    key = f"C_{rgb}_{alpha:.2f}"
    mat = bpy.data.materials.get(key)
    if mat:
        return mat
    mat = bpy.data.materials.new(key)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
    bsdf.inputs["Roughness"].default_value = 0.6
    if alpha < 1:
        bsdf.inputs["Alpha"].default_value = alpha
        if hasattr(mat, "blend_method"):
            mat.blend_method = "BLEND"
    mat.diffuse_color = (*[(c / 255) ** 2.2 for c in rgb], alpha)   # workbench viewport color
    return mat


def add_part(part):
    sx, sy, sz = part["size"]
    shape = part["shape"]
    if shape == "Ball":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=sx / 2)
        local = Matrix.Identity(4)
    elif shape == "Cylinder":
        # Roblox cylinder axis = local X (length sx, diameter sy); Blender cylinder axis = local Z
        bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=sy / 2, depth=sx)
        local = Matrix.Rotation(math.radians(90), 4, "Y")
    else:
        bpy.ops.mesh.primitive_cube_add(size=1)
        local = Matrix.Diagonal((sx, sz, sy, 1))   # Roblox size (x, y, z) -> Blender (x, z-depth, y-height)
    obj = bpy.context.active_object
    obj.name = part["path"].split("/")[-1]
    world = Matrix.Translation(rbx_pos(part["pos"])) @ rbx_rot(part["rot"]).to_4x4()
    obj.matrix_world = world @ local
    obj.data.materials.append(material(tuple(part["color"]), 1 - part["transparency"]))
    if shape != "Block":
        bpy.ops.object.shade_smooth()
    return obj


def load_props():
    """Import the GLB once and return {kind: [mesh objects]} (kept hidden as templates)."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(PROPS_GLB))
    groups = {}
    for obj in set(bpy.data.objects) - before:
        if obj.type != "MESH":
            continue
        kind = obj.name.split("_")[0]
        if kind in PROPS:
            groups.setdefault(kind, []).append(obj)
    return groups


def world_bbox(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def place_prop(templates, kind, anchor):
    size, by, pivot = PROPS[kind]
    lo, hi = world_bbox(templates)
    dims = hi - lo
    current = max(dims.x, dims.y) if by == "width" else dims.z
    scale = size / current
    pivot_pt = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z if pivot == "top" else lo.z))
    target = Matrix.Translation(rbx_pos(anchor["pos"])) @ rbx_rot(anchor["rot"]).to_4x4()
    xform = target @ Matrix.Scale(scale, 4) @ Matrix.Translation(-pivot_pt)
    for t in templates:
        copy = t.copy()
        copy.data = t.data   # linked duplicate is enough for a render
        bpy.context.scene.collection.objects.link(copy)
        copy.matrix_world = xform @ t.matrix_world
        copy.hide_render = False
        copy.hide_viewport = False


def setup_world():
    scene = bpy.context.scene
    names = {"EEVEE": ["BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"], "CYCLES": ["CYCLES"]}.get(ENGINE, [ENGINE])
    for engine in names + ["BLENDER_WORKBENCH"]:
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if scene.render.engine == "CYCLES":
        scene.cycles.samples = 48
    scene.render.resolution_x, scene.render.resolution_y = 1600, 1000
    world = bpy.data.worlds.new("Sky")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.75, 1.0, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    bpy.ops.object.light_add(type="SUN", rotation=(math.radians(40), math.radians(10), math.radians(-35)))
    bpy.context.active_object.data.energy = 3.5
    if scene.render.engine == "BLENDER_WORKBENCH":
        shading = scene.display.shading
        shading.light, shading.color_type = "STUDIO", "MATERIAL"
        shading.show_shadows = True
    world.color = (0.55, 0.75, 1.0)


def shoot(name, location, look_at, lens=28):
    cam_data = bpy.data.cameras.new(name)
    cam_data.lens = lens
    cam_data.clip_end = 2000
    cam = bpy.data.objects.new(name, cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = location
    cam.rotation_euler = (Vector(look_at) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam
    bpy.context.scene.render.filepath = str(OUT_DIR / f"{name}.png")
    bpy.ops.render.render(write_still=True)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    parts = json.loads(PARTS_JSON.read_text(encoding="utf-8"))
    groups = load_props() if PROPS_GLB.exists() else {}
    for objs in groups.values():
        for o in objs:
            o.hide_render = True
            o.hide_viewport = True
    for part in parts:
        segs = part["path"].split("/")
        if "Placeholder" in segs and groups:
            continue                 # replaced by the Blender prop
        if segs[-1] == "PropAnchor":
            kind = FOLDERS.get(segs[1])
            if kind in groups:
                place_prop(groups[kind], kind, part)
            continue
        if part["transparency"] >= 1:
            continue                 # invisible colliders / hitboxes
        if segs[-1] == "Sea":
            continue                 # huge plane; the sky background reads as sea from above
        add_part(part)
    setup_world()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Roblox z runs from +13 (start) to -316 (goal) -> Blender y from -13 to +316
    shoot("course_overview", (70, -60, 120), (0, 150, 15), lens=24)
    shoot("course_start", (14, -30, 18), (0, 10, 4), lens=30)
    shoot("course_mushrooms", (30, 75, 40), (0, 115, 18), lens=30)
    shoot("course_goal", (22, 255, 50), (0, 300, 38), lens=30)


main()
~~~~
