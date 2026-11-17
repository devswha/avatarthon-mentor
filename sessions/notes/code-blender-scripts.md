# Blender 모델링 스크립트 원문

소품 5종(별·버섯·깃발·트로피·구름)은 Blender 5.2.4를 화면 없이(`blender -b`) 파이썬 스크립트로 돌려 만들었다.
스크립트는 Claude Code가 작성했고, 렌더 결과를 보며 여러 번 고쳤다. `.py`는 제출함에 넣을 수 없어 원문을 여기에 옮긴다.

- `make_props.py`: 빈 장면에서 소품을 만들고 검사한 뒤 `AvatarthonProps.fbx`·`.glb`로 내보내고 미리보기를 렌더한다.
- `render_previews.py`: 미리보기 PNG 6장 렌더.
- `verify_exports.py`: 내보낸 FBX·GLB를 새 장면에 다시 불러와 이름·크기·방향·삼각형 수를 확인한다(결과 PASS).


## `blender/make_props.py`

~~~~python
"""
make_props.py -- builds the low-poly prop kit for the Avatarthon kids' obby /
star-collecting Roblox game entirely from code, exports it as FBX + GLB and
(optionally) renders preview PNGs.

Run headless (tested with Blender 5.2.4 LTS; needs at least the 4.1+ mesh
smoothing API):

    blender -b --factory-startup --python make_props.py
    blender -b --factory-startup --python make_props.py -- --skip-render
    blender -b --factory-startup --python verify_exports.py   # re-import check

Outputs go next to this file (blender/). No .blend file is written.

Naming contract with the game script (every object is a top-level mesh, the
game groups parts by the prefix before "_" and uses the group's bounding box):

    StarCoin_Body
    JumpMushroom_Cap, JumpMushroom_Dots, JumpMushroom_Stem
    CheckFlag_Pole, CheckFlag_Cloth, CheckFlag_Base
    GoalTrophy_Cup, GoalTrophy_Base
    CloudPad_Body

Conventions used below:
  * Blender is Z-up, meters. Every prop rests on z = 0 and is centered on
    y = 0; props are spaced along X (see SLOT_X).
  * All geometry is written straight into mesh data in world space, so every
    object keeps an identity transform ("transforms applied") and no
    modifiers are left on any object.
  * One Principled BSDF material per object, named after its color (M_Gold...).
"""

import math
import os
import shutil
import sys
import tempfile

import bmesh
import bpy
from mathutils import Matrix, Vector

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = SCRIPT_DIR  # outputs sit next to the scripts (copied to assets/blender/ in the submission)
EXPORT_BASENAME = "AvatarthonProps"

# X position of each prop (meters). Each prop's own vertical axis sits here.
SLOT_X = {
    "StarCoin": 0.0,
    "JumpMushroom": 4.0,
    "CheckFlag": 8.0,
    "GoalTrophy": 12.0,
    "CloudPad": 16.0,
}

# Material color name -> sRGB hex (the hex values are the art-direction spec).
COLORS = {
    "Gold": "#FFC83D",
    "Red": "#E8463C",
    "Ivory": "#FFF6E8",
    "Cream": "#F3DDB3",
    "LightGray": "#E6E6EA",
    "SkyBlue": "#3FA9F5",
    "DarkGray": "#4A4F5A",
    "Purple": "#5B3A8C",
    "White": "#FFFFFF",
}

# Soft budget per prop (sum over its parts).
MAX_TRIS_PER_PROP = 4000


# ---------------------------------------------------------------------------
# Scene / material helpers
# ---------------------------------------------------------------------------

def reset_scene():
    """Delete every object and every data-block a default scene may contain."""
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                 bpy.data.lights, bpy.data.metaballs, bpy.data.curves,
                 bpy.data.images):
        for block in list(coll):
            coll.remove(block)


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_to_linear_rgba(hex_code):
    h = hex_code.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(srgb_to_linear(c) for c in srgb) + (1.0,)


def get_material(color_name, roughness=0.5):
    """Return (creating on first use) the flat-color material M_<color_name>."""
    name = f"M_{color_name}"
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    if mat.node_tree is None:  # Blender < 5.0 does not create nodes by default
        mat.use_nodes = True
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    rgba = hex_to_linear_rgba(COLORS[color_name])
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = 0.0
    # Viewport / Workbench color, also used by some exporters as a fallback.
    mat.diffuse_color = rgba
    mat.roughness = roughness
    return mat


def make_object(name, bm, material, shading="angle", angle_deg=45.0):
    """Turn a bmesh into a top-level mesh object linked to the scene.

    shading: "smooth" = all faces smooth, "angle" = smooth with sharp edges
    above angle_deg, "keep" = keep the smooth/sharp flags set in the bmesh.
    """
    # Make every closed shell's normals point outward.
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    if shading == "smooth":
        me.shade_smooth()
    elif shading == "angle":
        me.shade_smooth()
        me.set_sharp_from_angle(angle=math.radians(angle_deg))
    me.materials.append(material)
    me.validate()
    me.update()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------------------
# 2D curve helpers (used for star outlines and lathe profiles)
# ---------------------------------------------------------------------------

def dedupe(points, eps=1e-6, closed=False):
    out = [points[0]]
    for p in points[1:]:
        if (p - out[-1]).length > eps:
            out.append(p)
    if closed and len(out) > 1 and (out[0] - out[-1]).length <= eps:
        out.pop()
    return out


def fillet_polyline(points, radii, segments=4, closed=False):
    """Round the corners of a 2D polyline with circular arcs.

    points   -- list of (x, y)
    radii    -- fillet radius per point (0 keeps the corner sharp); end points
                of an open polyline are always kept as-is
    segments -- arc subdivisions per corner (int or per-point list)
    """
    pts = [Vector(p) for p in points]
    n = len(pts)
    segs = list(segments) if isinstance(segments, (list, tuple)) else [segments] * n
    out = []
    for i, p in enumerate(pts):
        is_end = (not closed) and (i == 0 or i == n - 1)
        if is_end or radii[i] <= 0.0:
            out.append(p.copy())
            continue
        a, b = pts[i - 1], pts[(i + 1) % n]
        u, w = (a - p).normalized(), (b - p).normalized()
        ang = math.acos(max(-1.0, min(1.0, u.dot(w))))  # angle between edges
        if ang > math.pi - 1e-4:  # collinear, nothing to round
            out.append(p.copy())
            continue
        r = radii[i]
        d = r / math.tan(ang / 2.0)  # distance from corner to tangent points
        d_max = 0.49 * min((a - p).length, (b - p).length)
        if d > d_max:  # shrink the radius so neighbouring fillets never overlap
            d = d_max
            r = d * math.tan(ang / 2.0)
        t1, t2 = p + u * d, p + w * d
        c = p + (u + w).normalized() * (r / math.sin(ang / 2.0))
        a1 = math.atan2(t1.y - c.y, t1.x - c.x)
        a2 = math.atan2(t2.y - c.y, t2.x - c.x)
        sweep = (a2 - a1 + math.pi) % (2.0 * math.pi) - math.pi  # short way round
        for k in range(segs[i] + 1):
            t = a1 + sweep * k / segs[i]
            out.append(Vector((c.x + r * math.cos(t), c.y + r * math.sin(t))))
    return dedupe(out, closed=closed)


def densify(points, max_len, closed=False):
    """Insert points so no segment is longer than max_len."""
    out = []
    n = len(points)
    for i in range(n if closed else n - 1):
        a, b = points[i], points[(i + 1) % n]
        out.append(a)
        steps = max(1, int(math.ceil((b - a).length / max_len)))
        for k in range(1, steps):
            out.append(a.lerp(b, k / steps))
    if not closed:
        out.append(points[-1])
    return out


def polygon_area(points):
    s = 0.0
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        s += p.x * q.y - q.x * p.y
    return 0.5 * s


def profile(ctrl, segments=4):
    """ctrl = [(r, z, fillet_radius), ...] -> rounded (r, z) lathe profile."""
    pts = fillet_polyline([(c[0], c[1]) for c in ctrl], [c[2] for c in ctrl],
                          segments=segments, closed=False)
    # Snap tiny radii to the axis so they become clean poles.
    return [Vector((0.0 if p.x < 1e-4 else p.x, p.y)) for p in pts]


# ---------------------------------------------------------------------------
# 3D construction helpers (all write into a bmesh)
# ---------------------------------------------------------------------------

def connect_rings(bm, ra, rb):
    """Fill faces between two vertex rings (a ring of 1 vertex is a pole)."""
    if len(ra) == 1 and len(rb) == 1:
        return
    if len(ra) == 1:
        n = len(rb)
        for i in range(n):
            bm.faces.new((ra[0], rb[i], rb[(i + 1) % n]))
    elif len(rb) == 1:
        n = len(ra)
        for i in range(n):
            bm.faces.new((ra[i], ra[(i + 1) % n], rb[0]))
    else:
        n = len(ra)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((ra[i], ra[j], rb[j], rb[i]))


def add_lathe(bm, prof, segments, center_xy=(0.0, 0.0)):
    """Revolve a (r, z) profile around a vertical axis. r == 0 -> pole."""
    cx, cy = center_xy
    rings = []
    for p in prof:
        r, z = p[0], p[1]
        if r <= 0.0:
            rings.append([bm.verts.new((cx, cy, z))])
        else:
            rings.append([
                bm.verts.new((cx + r * math.cos(2 * math.pi * i / segments),
                              cy + r * math.sin(2 * math.pi * i / segments), z))
                for i in range(segments)])
    for ra, rb in zip(rings, rings[1:]):
        connect_rings(bm, ra, rb)


def add_tube_xz(bm, path, radius, segments=10):
    """Sweep a circle along a path lying in the XZ plane, capped at both ends."""
    path = [Vector(p) for p in path]
    side = Vector((0.0, 1.0, 0.0))  # the path is planar, so the Y axis is a stable binormal
    rings = []
    for i, p in enumerate(path):
        if i == 0:
            t = path[1] - path[0]
        elif i == len(path) - 1:
            t = path[-1] - path[-2]
        else:
            t = path[i + 1] - path[i - 1]
        t.normalize()
        nrm = side.cross(t).normalized()
        rings.append([
            bm.verts.new(p + radius * (math.cos(a) * nrm + math.sin(a) * side))
            for a in (2 * math.pi * k / segments for k in range(segments))])
    for ra, rb in zip(rings, rings[1:]):
        connect_rings(bm, ra, rb)
    connect_rings(bm, [bm.verts.new(path[0])], rings[0])
    connect_rings(bm, rings[-1], [bm.verts.new(path[-1])])


def add_rounded_box(bm, center, size, bevel, segments=3):
    """Box with rounded edges. Edges where the bevel meets a flat side are
    marked sharp so the big faces stay perfectly flat-shaded."""
    ret = bmesh.ops.create_cube(bm, size=1.0,
                                matrix=Matrix.LocRotScale(Vector(center), None, Vector(size)))
    verts = ret["verts"]
    edges = list({e for v in verts for e in v.link_edges})
    bev = bmesh.ops.bevel(bm, geom=verts + edges, offset=bevel, segments=segments,
                          profile=0.5, affect="EDGES", clamp_overlap=True)
    bevel_faces = set(bev["faces"])
    for f in bevel_faces:
        for e in f.edges:
            if any(lf not in bevel_faces for lf in e.link_faces):
                e.smooth = False
    for f in bm.faces:
        f.smooth = True


def mesh_tris(me):
    return sum(len(p.vertices) - 2 for p in me.polygons)


def signed_volume(me):
    me.calc_loop_triangles()
    vol = 0.0
    for tri in me.loop_triangles:
        a, b, c = (me.vertices[i].co for i in tri.vertices)
        vol += a.dot(b.cross(c)) / 6.0
    return vol


# ---------------------------------------------------------------------------
# Props (each builder works around x = y = 0 and returns its objects)
# ---------------------------------------------------------------------------

def build_star_coin():
    """Puffy five-pointed star, 1.0 m tall, faces pointing along +/-Y.

    The cross-section is a pillow: a half-round rim (radius RIM) all around
    the outline and a gentle dome on each face rising to the center.
    """
    height = 1.0
    half_center = 0.15   # half of the 0.3 m center thickness
    rim = 0.065          # rim roundness == half thickness at the outline

    # 1) Rounded 2D star outline (x across, y up), 10 alternating corners.
    corners, radii, segs = [], [], []
    for i in range(10):
        ang = math.pi / 2 + i * math.pi / 5
        tip = (i % 2 == 0)
        r = 1.0 if tip else 0.5  # fat inner radius = chunky, kid-friendly star
        corners.append((r * math.cos(ang), r * math.sin(ang)))
        radii.append(0.15 if tip else 0.09)
        segs.append(8 if tip else 3)
    outline = fillet_polyline(corners, radii, segs, closed=True)
    scale = height / (max(p.y for p in outline) - min(p.y for p in outline))
    outline = [p * scale for p in outline]
    # A regular star is ~5 % wider than tall. Narrow it slightly so its
    # tallest axis is Z (the game sizes the coin by height / "upright").
    width = max(p.x for p in outline) - min(p.x for p in outline)
    squeeze = 0.96 * height / width
    outline = densify([Vector((p.x * squeeze, p.y)) for p in outline], 0.09, closed=True)
    if polygon_area(outline) < 0:
        outline.reverse()
    n = len(outline)
    # Outward 2D normals of the (counter-clockwise) outline.
    normals = []
    for j in range(n):
        t = outline[(j + 1) % n] - outline[j - 1]
        normals.append(Vector((t.y, -t.x)).normalized())

    bm = bmesh.new()

    def ring(points2d, y):
        # 2D (x, up) -> 3D (x, y, z): the star stands in the XZ plane.
        return [bm.verts.new((p.x, y, p.y)) for p in points2d]

    equator = ring(outline, 0.0)
    inner = [o - nn * rim for o, nn in zip(outline, normals)]
    for sign in (1.0, -1.0):
        rings = [equator]
        # Quarter-round from the equator to the face.
        for deg in (30, 60, 90):
            th = math.radians(deg)
            inset = rim * (1.0 - math.cos(th))
            rings.append(ring([o - nn * inset for o, nn in zip(outline, normals)],
                              sign * rim * math.sin(th)))
        # Dome rings shrinking toward the center.
        for s in (0.33, 0.66):
            y = rim + (half_center - rim) * (1.0 - (1.0 - s) ** 2)
            rings.append(ring([q * (1.0 - s) for q in inner], sign * y))
        rings.append([bm.verts.new((0.0, sign * half_center, 0.0))])
        for ra, rb in zip(rings, rings[1:]):
            connect_rings(bm, ra, rb)

    return [make_object("StarCoin_Body", bm, get_material("Gold", 0.35), "smooth")]


def build_jump_mushroom():
    """Bouncy mushroom: chunky dome cap with white dots on a cream stem."""
    seg = 32
    a, b, z_rim = 0.90, 0.58, 0.72  # cap radius, dome height, rim height
    p_exp = 2.5                       # superellipse exponent (>2 = fuller dome)

    def dome_rz(theta):
        """Dome profile; theta = 0 at the rim, pi/2 at the top."""
        c, s = max(0.0, math.cos(theta)), max(0.0, math.sin(theta))
        return a * c ** (2.0 / p_exp), z_rim + b * s ** (2.0 / p_exp)

    # --- Cap: dome from the top down to the rim, then a rounded lip that
    # curls under and a slightly concave underside back to the axis.
    n_dome = 11
    cap_prof = [Vector(dome_rz(math.pi / 2 * (1 - i / n_dome))) for i in range(n_dome + 1)]
    cap_prof[0] = Vector((0.0, z_rim + b))
    lip = profile([
        (a, z_rim, 0.0),
        (a - 0.02, z_rim - 0.13, 0.08),
        (0.52, z_rim - 0.10, 0.12),
        (0.0, z_rim - 0.02, 0.0),
    ], segments=4)
    cap_prof += lip[1:]
    bm = bmesh.new()
    add_lathe(bm, cap_prof, seg)
    cap = make_object("JumpMushroom_Cap", bm, get_material("Red", 0.45), "angle", 60)

    # --- Dots: flattened spheres sitting on the dome, aligned to its normal.
    def dome_point(theta, phi):
        r, z = dome_rz(theta)
        return Vector((r * math.cos(phi), r * math.sin(phi), z))

    def dome_normal(theta, phi):
        if theta > math.pi / 2 - 1e-3:
            return Vector((0.0, 0.0, 1.0))
        e = 1e-4
        d_theta = dome_point(theta + e, phi) - dome_point(theta - e, phi)
        d_phi = dome_point(theta, phi + e) - dome_point(theta, phi - e)
        nrm = d_phi.cross(d_theta).normalized()
        if nrm.dot(dome_point(theta, phi) - Vector((0, 0, z_rim))) < 0:
            nrm.negate()
        return nrm

    # (theta, phi, dot radius). Front of the scene is -Y (phi = -90 deg).
    dots = [(math.pi / 2, 0.0, 0.22)]
    for k in range(5):
        dots.append((math.radians(32), math.radians(-54 + 72 * k), 0.17))
    bm = bmesh.new()
    for theta, phi, rd in dots:
        nrm = dome_normal(theta, phi)
        half_h = rd * 0.35          # flattened: 35 % as thick as wide
        poke = 0.035                # how far the dot rises above the cap
        center = dome_point(theta, phi) + nrm * (poke - half_h)
        rot = nrm.to_track_quat("Z", "Y").to_matrix().to_4x4()
        mtx = Matrix.Translation(center) @ rot @ Matrix.Diagonal((rd, rd, half_h, 1.0))
        bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=8, radius=1.0, matrix=mtx)
    dots_obj = make_object("JumpMushroom_Dots", bm, get_material("Ivory", 0.5), "smooth")

    # --- Stem: bulgy at the bottom, tucked up inside the cap.
    stem_prof = profile([
        (0.0, 0.0, 0.0),
        (0.34, 0.0, 0.08),
        (0.38, 0.18, 0.25),
        (0.30, 0.62, 0.20),
        (0.30, 0.80, 0.02),
        (0.0, 0.80, 0.0),
    ], segments=3)
    bm = bmesh.new()
    add_lathe(bm, stem_prof, seg)
    stem = make_object("JumpMushroom_Stem", bm, get_material("Cream", 0.6), "angle", 50)
    return [cap, dots_obj, stem]


def build_check_flag():
    """Checkpoint flag: round base, pole with a ball on top, wavy pennant."""
    # --- Base: rounded puck with a small collar that holds the pole.
    base_prof = profile([
        (0.0, 0.0, 0.0),
        (0.40, 0.0, 0.03),
        (0.40, 0.07, 0.05),
        (0.30, 0.15, 0.06),
        (0.13, 0.165, 0.03),
        (0.125, 0.26, 0.02),
        (0.0, 0.26, 0.0),
    ], segments=3)
    bm = bmesh.new()
    add_lathe(bm, base_prof, 24)
    base = make_object("CheckFlag_Base", bm, get_material("DarkGray", 0.6), "angle", 50)

    # --- Pole + ball finial (one object). Total height 2.6 m.
    bm = bmesh.new()
    add_lathe(bm, [Vector((0.0, 0.20)), Vector((0.055, 0.20)),
                   Vector((0.055, 2.47)), Vector((0.0, 2.47))], 16)
    bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=8, radius=0.11,
                              matrix=Matrix.Translation((0.0, 0.0, 2.49)))
    pole = make_object("CheckFlag_Pole", bm, get_material("LightGray", 0.4), "angle", 40)

    # --- Cloth: a wavy pennant pointing +X, solidified so it has thickness
    # (Roblox renders single-sided planes, so a flat sheet would vanish from
    # one side), plus a sleeve wrapped around the pole.
    z_top, height, length = 2.30, 0.78, 1.20
    nu, nv = 14, 5
    bm = bmesh.new()
    grid = []
    for i in range(nu + 1):
        u = i / nu
        half = 0.5 * height * (1.0 - u) + 0.035 * u        # tapers to a blunt tip
        zc = z_top - 0.5 * height - 0.06 * u * u           # slight droop
        y = 0.11 * math.sin(2.0 * math.pi * 1.1 * u) * u   # wave grows toward the tip
        grid.append([bm.verts.new((length * u, y, zc + half * (1.0 - 2.0 * j / nv)))
                     for j in range(nv + 1)])
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
    thickness = 0.035
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=thickness)
    # Re-center the solidified sheet on its original mid-surface.
    sheet_y = sum(v.co.y for v in bm.verts if v.co.x < 1e-4) / max(
        1, sum(1 for v in bm.verts if v.co.x < 1e-4))
    bmesh.ops.translate(bm, verts=bm.verts[:], vec=(0.0, -sheet_y, 0.0))
    sleeve = profile([
        (0.0, z_top - height - 0.02, 0.0),
        (0.085, z_top - height - 0.02, 0.02),
        (0.085, z_top + 0.02, 0.02),
        (0.0, z_top + 0.02, 0.0),
    ], segments=2)
    add_lathe(bm, sleeve, 16)
    cloth = make_object("CheckFlag_Cloth", bm, get_material("SkyBlue", 0.55), "angle", 50)
    return [pole, cloth, base]


def build_goal_trophy():
    """Goal trophy: gold cup with two loop handles on a stepped purple base."""
    # --- Stepped square base (two rounded tiers), top at z = 0.38.
    bm = bmesh.new()
    add_rounded_box(bm, (0.0, 0.0, 0.10), (1.0, 1.0, 0.20), bevel=0.045)
    add_rounded_box(bm, (0.0, 0.0, 0.29), (0.76, 0.76, 0.18), bevel=0.04)
    base = make_object("GoalTrophy_Base", bm, get_material("Purple", 0.55), "keep")

    # --- Cup body: lathe profile from the foot up the outside, over the
    # rounded rim and back down the inside of the bowl.
    ctrl = [
        (0.0, 0.38, 0.0),
        (0.25, 0.38, 0.02),    # foot disk
        (0.25, 0.44, 0.035),
        (0.11, 0.50, 0.04),    # foot flares into the neck
        (0.075, 0.60, 0.03),
        (0.12, 0.66, 0.035),   # decorative knob
        (0.12, 0.71, 0.035),
        (0.075, 0.77, 0.03),
        (0.16, 0.83, 0.05),    # bowl
        (0.38, 0.98, 0.18),
        (0.46, 1.30, 0.25),
        (0.48, 1.60, 0.022),   # rim, outer edge
        (0.425, 1.60, 0.02),   # rim, inner edge
        (0.405, 1.30, 0.20),   # inside wall
        (0.33, 1.06, 0.15),
        (0.15, 0.98, 0.08),
        (0.0, 0.96, 0.0),
    ]
    segs = [1, 2, 2, 2, 1, 2, 2, 1, 2, 3, 2, 2, 2, 2, 2, 2, 1]
    cup_prof = profile(ctrl, segments=segs)
    bm = bmesh.new()
    add_lathe(bm, cup_prof, 28)

    # Outer wall radius as a function of z (for attaching the handles).
    top_idx = max(range(len(cup_prof)), key=lambda i: (cup_prof[i].y, cup_prof[i].x))
    outer = [p for p in cup_prof[:top_idx + 1] if p.y >= 0.83]

    def outer_radius(z):
        for p, q in zip(outer, outer[1:]):
            if p.y <= z <= q.y:
                t = (z - p.y) / max(1e-9, q.y - p.y)
                return p.x + (q.x - p.x) * t
        raise ValueError(z)

    # --- Handles: elliptical loops in the XZ plane, both ends pushed a bit
    # into the cup wall so the joins are hidden inside the solid wall.
    cx, cz, rx, rz = 0.54, 1.24, 0.13, 0.165
    tube_r = 0.045
    for side in (1.0, -1.0):
        arc = []
        for k in range(13):
            th = math.radians(110 - 220 * k / 12)  # 110 deg -> -110 deg
            arc.append(Vector((cx + rx * math.cos(th), 0.0, cz + rz * math.sin(th))))
        z_hi, z_lo = arc[0].z, arc[-1].z
        path = ([Vector((outer_radius(z_hi) - 0.02, 0.0, z_hi))] + arc +
                [Vector((outer_radius(z_lo) - 0.02, 0.0, z_lo))])
        if side < 0:
            path = [Vector((-p.x, p.y, p.z)) for p in path]
        add_tube_xz(bm, path, tube_r, segments=8)
    cup = make_object("GoalTrophy_Cup", bm, get_material("Gold", 0.35), "angle", 50)
    return [cup, base]


def bake_modifiers(obj):
    """Apply the modifier stack by baking the evaluated mesh into obj.data."""
    deps = bpy.context.evaluated_depsgraph_get()
    new_me = bpy.data.meshes.new_from_object(obj.evaluated_get(deps))
    old = obj.data
    obj.modifiers.clear()
    obj.data = new_me
    bpy.data.meshes.remove(old)


def build_cloud_pad():
    """Cloud platform: metaball puffs -> mesh, top flattened so a character can
    stand on it, then decimated to stay low poly. ~3.2 x 2.2 x 0.9 m."""
    target = Vector((3.2, 2.2, 0.9))
    mb = bpy.data.metaballs.new("CloudPad_Meta")
    mb.resolution = 0.05
    mb.render_resolution = 0.05
    mb.threshold = 0.6
    meta = bpy.data.objects.new("CloudPad_Meta", mb)
    bpy.context.scene.collection.objects.link(meta)

    def puff(x, y, z, r):
        el = mb.elements.new(type="BALL")
        el.co = (x, y, z)
        el.radius = r
        el.stiffness = 2.0

    # Core slab
    el = mb.elements.new(type="ELLIPSOID")
    el.co = (0.0, 0.0, 0.45)
    el.radius = 1.0
    el.size_x, el.size_y, el.size_z = 1.32, 0.82, 0.40
    el.stiffness = 2.0
    # Ring of puffs around the edge (varied sizes so it looks hand-made)
    ring_r = [0.60, 0.53, 0.58, 0.52, 0.62, 0.55, 0.59, 0.52, 0.60, 0.54, 0.57]
    for k, r in enumerate(ring_r):
        ang = 2.0 * math.pi * k / len(ring_r) + 0.15
        puff(1.26 * math.cos(ang), 0.78 * math.sin(ang), 0.45, r + 0.03)
    # A few softer puffs underneath so the bottom is round, not flat
    for x, y, r in ((-0.55, 0.0, 0.55), (0.55, 0.05, 0.55), (0.0, -0.2, 0.5)):
        puff(x, y, 0.30, r)

    bpy.context.view_layer.update()
    deps = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(meta.evaluated_get(deps))
    bpy.data.objects.remove(meta, do_unlink=True)
    bpy.data.metaballs.remove(mb)

    # Soft-flatten the top: above z0 heights are squashed with tanh, which
    # leaves a nearly flat walkable top that still rolls into the puffy sides.
    bm = bmesh.new()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
    zs = [v.co.z for v in bm.verts]
    zmin, zmax = min(zs), max(zs)
    z0 = zmin + 0.62 * (zmax - zmin)
    soft = 0.16 * (zmax - zmin)
    for v in bm.verts:
        if v.co.z > z0:
            v.co.z = z0 + soft * math.tanh((v.co.z - z0) / soft)
    obj = make_object("CloudPad_Body", bm, get_material("White", 0.7), "smooth")

    # Decimate to a low-poly budget, then bake the modifier away.
    dec = obj.modifiers.new("Decimate", "DECIMATE")
    dec.ratio = min(1.0, 2400.0 / max(1, mesh_tris(obj.data)))
    dec.use_collapse_triangulate = True
    bake_modifiers(obj)

    # Exact target size.
    me = obj.data
    lo = Vector([min(v.co[i] for v in me.vertices) for i in range(3)])
    hi = Vector([max(v.co[i] for v in me.vertices) for i in range(3)])
    dims = hi - lo
    center = (lo + hi) / 2.0
    me.transform(Matrix.Translation(-center))
    me.transform(Matrix.Diagonal((target.x / dims.x, target.y / dims.y, target.z / dims.z, 1.0)))
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(me)
    bm.free()
    me.shade_smooth()
    if not me.materials:
        me.materials.append(get_material("White", 0.7))
    return [obj]


# ---------------------------------------------------------------------------
# Layout, checks, export
# ---------------------------------------------------------------------------

def group_bounds(objs):
    pts = [o.matrix_world @ v.co for o in objs for v in o.data.vertices]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


def place_group(objs, slot_x):
    """Move a prop so its axis is at x = slot_x, it is centered on y = 0 and
    its lowest point touches z = 0 (moves mesh data, transforms stay identity)."""
    lo, hi = group_bounds(objs)
    offset = Vector((slot_x, -(lo.y + hi.y) / 2.0, -lo.z))
    for o in objs:
        o.data.transform(Matrix.Translation(offset))
        o.data.update()


def build_all():
    reset_scene()
    builders = {
        "StarCoin": build_star_coin,
        "JumpMushroom": build_jump_mushroom,
        "CheckFlag": build_check_flag,
        "GoalTrophy": build_goal_trophy,
        "CloudPad": build_cloud_pad,
    }
    groups = {}
    for prefix, fn in builders.items():
        objs = fn()
        place_group(objs, SLOT_X[prefix])
        for o in objs:
            o.data.name = o.name  # keep mesh data names == object names
        groups[prefix] = objs
    return groups


def check_scene(groups):
    """Sanity checks: contract names, identity transforms, no modifiers,
    outward normals, triangle budget. Prints a summary table."""
    ok = True
    print("\n%-20s %6s %8s  %-24s %s" % ("object", "tris", "volume", "dimensions (m)", "material"))
    for prefix, objs in groups.items():
        total = 0
        for o in objs:
            me = o.data
            tris = mesh_tris(me)
            total += tris
            vol = signed_volume(me)
            lo, hi = group_bounds([o])
            d = hi - lo
            mats = [m.name for m in me.materials]
            print("%-20s %6d %8.4f  %5.2f x %5.2f x %5.2f   %s" % (o.name, tris, vol, d.x, d.y, d.z, mats))
            if not o.name.startswith(prefix + "_") or o.parent or o.modifiers:
                ok = False
                print("  !! naming / parenting / modifier problem")
            if o.matrix_world != Matrix.Identity(4):
                ok = False
                print("  !! transform not applied")
            if vol <= 0:
                ok = False
                print("  !! negative volume -> normals point inward")
            if len(me.materials) != 1:
                ok = False
                print("  !! expected exactly one material")
        lo, hi = group_bounds(objs)
        d = hi - lo
        print("  -> %-14s total tris %5d | size %.2f x %.2f x %.2f | min z %.4f | center y %.4f"
              % (prefix, total, d.x, d.y, d.z, lo.z, (lo.y + hi.y) / 2))
        if total > MAX_TRIS_PER_PROP:
            ok = False
            print("  !! over triangle budget")
    if not ok:
        raise RuntimeError("Prop sanity checks failed (see log above)")
    print("All prop checks passed.\n")


def _forbidden_strings():
    """Byte strings that must never end up in a shipped binary."""
    out = {os.path.expanduser("~").encode()}
    try:
        import getpass
        out.add(getpass.getuser().encode())
    except Exception:
        pass
    return [s for s in out if s and s != b"/"]


def export_all(asset_dir):
    """Export every mesh to FBX + GLB.

    Files are first written into a neutral temp folder and then moved, and
    both binaries are scanned for the home path / user name before they are
    accepted. (Blender 5.2's FBX writer only stores a "/foobar.fbx"
    placeholder as DocumentUrl, but older/newer IO versions may differ, and
    the submission must never ship a /home/[사용자]/... path.)
    """
    os.makedirs(asset_dir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="props_export_")
    fbx_tmp = os.path.join(tmp, EXPORT_BASENAME + ".fbx")
    glb_tmp = os.path.join(tmp, EXPORT_BASENAME + ".glb")

    bpy.ops.export_scene.fbx(
        filepath=fbx_tmp,
        use_selection=False,
        object_types={"MESH"},
        axis_forward="-Z",
        axis_up="Y",
        apply_scale_options="FBX_SCALE_ALL",
        use_mesh_modifiers=True,
        add_leaf_bones=False,
        path_mode="STRIP",
        embed_textures=False,
    )
    bpy.ops.export_scene.gltf(
        filepath=glb_tmp,
        export_format="GLB",
        use_selection=False,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_extras=False,
    )

    outputs = []
    for src in (fbx_tmp, glb_tmp):
        with open(src, "rb") as fh:
            data = fh.read()
        leaks = [s for s in _forbidden_strings() if s in data]
        if leaks:
            raise RuntimeError(f"{src} contains forbidden strings: {leaks}")
        dst = os.path.join(asset_dir, os.path.basename(src))
        shutil.move(src, dst)
        outputs.append(dst)
        print(f"Exported {dst} ({os.path.getsize(dst)} bytes)")
    shutil.rmtree(tmp, ignore_errors=True)
    return outputs


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    groups = build_all()
    check_scene(groups)
    export_all(ASSET_DIR)
    if "--skip-render" not in argv:
        sys.dont_write_bytecode = True  # keep the blender/ folder free of __pycache__
        sys.path.insert(0, SCRIPT_DIR)
        import render_previews
        render_previews.render_all(groups, ASSET_DIR)


if __name__ == "__main__":
    main()
~~~~


## `blender/render_previews.py`

~~~~python
"""
render_previews.py -- soft "toy studio" preview renders of the prop kit.

Called by make_props.py after export, or standalone (rebuilds the props in
memory with make_props.build_all(), does NOT export anything):

    blender -b --factory-startup --python render_previews.py

Rendering: Cycles (GPU via OptiX/CUDA/HIP when available, CPU otherwise) with
transparent film and an invisible shadow-catcher floor. Each frame is then
composited over a pastel vertical gradient with numpy, so the PNGs get a clean
background plus a soft contact shadow.
"""

import math
import os
import shutil
import sys
import tempfile

import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# One entry per PNG. prefix None = every prop (the lineup shot).
# bg = (top, bottom) pastel gradient, cam = (azimuth, elevation) in degrees,
# exposure in stops (the all-white cloud needs a little less light to show
# its shading).
SHOTS = [
    dict(prefix="StarCoin", file="preview_star_coin.png", bg=("#EEE9FF", "#D3C9FB"),
         res=(1024, 1024), cam=(28, 16), exposure=0.0),
    dict(prefix="JumpMushroom", file="preview_jump_mushroom.png", bg=("#E9F9F1", "#C6ECDA"),
         res=(1024, 1024), cam=(32, 24), exposure=0.0),
    dict(prefix="CheckFlag", file="preview_check_flag.png", bg=("#FFF4E6", "#FFDCC0"),
         res=(1024, 1024), cam=(30, 14), exposure=0.0),
    dict(prefix="GoalTrophy", file="preview_goal_trophy.png", bg=("#E6F4FF", "#C3E1FB"),
         res=(1024, 1024), cam=(32, 18), exposure=0.0),
    dict(prefix="CloudPad", file="preview_cloud_pad.png", bg=("#D3EBFF", "#9ECCF6"),
         res=(1024, 1024), cam=(32, 30), exposure=-0.3),
    dict(prefix=None, file="preview_all_props.png", bg=("#EAF6FF", "#C2E1FA"),
         res=(2048, 1024), cam=(16, 16), exposure=-0.15),
]

# Gap between props in the lineup shot. The real scene spaces props 4 m apart
# along X; for the group photo they are temporarily packed closer (object
# location only, restored afterwards) so they don't end up tiny.
LINEUP_GAP = 0.55
LINEUP_ORDER = ["StarCoin", "JumpMushroom", "CheckFlag", "GoalTrophy", "CloudPad"]

SAMPLES = 128
CAMERA_LENS_MM = 60.0


def hex_to_srgb(hex_code):
    h = hex_code.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def direction(az_deg, el_deg):
    """Unit vector pointing from the subject toward the viewer/light.
    az = 0 is the front of the scene (-Y), positive az swings toward +X."""
    az, el = math.radians(az_deg), math.radians(el_deg)
    return Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))


def look_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


# ---------------------------------------------------------------------------
# Studio setup
# ---------------------------------------------------------------------------

def setup_engine(scene):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    scene.cycles.device = "CPU"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for dev_type in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL"):
            try:
                prefs.compute_device_type = dev_type
            except TypeError:
                continue
            prefs.get_devices()
            gpus = [d for d in prefs.devices if d.type == dev_type]
            if gpus:
                for d in prefs.devices:
                    d.use = d.type == dev_type
                scene.cycles.device = "GPU"
                print(f"Cycles device: {dev_type} {[d.name for d in gpus]}")
                break
    except Exception as exc:  # no GPU support -> stay on CPU
        print("GPU setup failed, using CPU:", exc)
    if scene.cycles.device == "CPU":
        scene.cycles.samples = min(SAMPLES, 64)
        print("Cycles device: CPU")

    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.resolution_percentage = 100
    # "Standard" keeps the art-direction hex colors close to what you see in
    # the PNG (AgX would wash out the saturated toy colors).
    for vt in ("Standard", "AgX"):
        try:
            scene.view_settings.view_transform = vt
            break
        except TypeError:
            pass
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0


def setup_world(scene):
    world = bpy.data.worlds.new("PreviewWorld")
    scene.world = world
    if world.node_tree is None:
        world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (0.85, 0.90, 1.0, 1.0)  # cool sky fill
    bg.inputs["Strength"].default_value = 0.45


def make_area_light(name, color):
    data = bpy.data.lights.new(name, "AREA")
    data.shape = "DISK"
    data.color = color
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def make_shadow_catcher():
    me = bpy.data.meshes.new("ShadowCatcher")
    s = 200.0
    z = -0.002  # a hair below z = 0 so flat prop bottoms don't z-fight
    me.from_pydata([(-s, -s, z), (s, -s, z), (s, s, z), (-s, s, z)], [], [(0, 1, 2, 3)])
    obj = bpy.data.objects.new("ShadowCatcher", me)
    bpy.context.scene.collection.objects.link(obj)
    obj.is_shadow_catcher = True
    return obj


class Studio:
    def __init__(self, scene):
        self.scene = scene
        setup_engine(scene)
        setup_world(scene)
        cam_data = bpy.data.cameras.new("PreviewCam")
        cam_data.lens = CAMERA_LENS_MM
        cam_data.sensor_fit = "AUTO"
        self.cam = bpy.data.objects.new("PreviewCam", cam_data)
        scene.collection.objects.link(self.cam)
        scene.camera = self.cam
        self.key = make_area_light("Key", (1.0, 0.97, 0.92))
        self.fill = make_area_light("Fill", (0.85, 0.92, 1.0))
        self.rim = make_area_light("Rim", (1.0, 1.0, 1.0))
        self.catcher = make_shadow_catcher()

    def frame(self, objs, az, el, res, fill=0.80):
        """Aim the camera at the objects and fit their bounding box into the
        frame (fill = fraction of the frame the bbox spans along its larger
        projected side). Lens shift centers the projected bbox."""
        scene = self.scene
        scene.render.resolution_x, scene.render.resolution_y = res
        pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
        lo = Vector([min(p[i] for p in pts) for i in range(3)])
        hi = Vector([max(p[i] for p in pts) for i in range(3)])
        center = (lo + hi) / 2.0
        size = (hi - lo).length
        d = direction(az, el)
        cam = self.cam
        cam.data.shift_x = cam.data.shift_y = 0.0
        dist = size * 2.0
        for _ in range(6):
            cam.location = center + d * dist
            look_at(cam, center)
            bpy.context.view_layer.update()
            ndc = [world_to_camera_view(scene, cam, p) for p in pts]
            us = [p.x for p in ndc]
            vs = [p.y for p in ndc]
            span = max(max(us) - min(us), max(vs) - min(vs))
            dist *= span / fill
            # Lens shift is measured in units of the larger image side.
            aspect = res[0] / res[1]
            sx = ((max(us) + min(us)) / 2.0 - 0.5) * (1.0 if aspect >= 1 else aspect)
            sy = ((max(vs) + min(vs)) / 2.0 - 0.5) * (1.0 / aspect if aspect >= 1 else 1.0)
            cam.data.shift_x += sx
            cam.data.shift_y += sy
        cam.data.clip_end = dist * 10 + 100

        # Light rig relative to the camera azimuth, scaled to the subject.
        # A disk light of P watts at distance D lights a facing white diffuse
        # surface to a pixel value of about P / (pi^2 D^2) (measured), so
        # "level" below is the target pixel contribution of each light.
        rig = [
            # light,     azimuth, elev, dist, size, level, casts shadow
            (self.key, az - 55, 50, 3.0, 1.4, 0.55, True),    # warm key, front-left, high
            (self.fill, az + 70, 15, 3.0, 1.6, 0.18, False),  # cool fill, right, low
            (self.rim, az + 170, 40, 3.0, 1.0, 0.35, False),  # rim from behind
        ]
        for light, laz, lel, dmul, smul, level, shadow in rig:
            ld = size * dmul
            light.location = center + direction(laz, lel) * ld
            look_at(light, center)
            light.data.size = size * smul
            light.data.energy = level * math.pi ** 2 * ld * ld
            light.data.use_shadow = shadow

    def render(self, objs, path):
        visible = set(objs)
        for o in self.scene.objects:
            if o.type == "MESH" and o is not self.catcher:
                o.hide_render = o not in visible
        self.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)


def composite_over_gradient(src_path, dst_path, top_hex, bottom_hex):
    """Alpha-over the transparent render onto a vertical pastel gradient."""
    img = bpy.data.images.load(src_path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    px = px.reshape(h, w, 4)  # row 0 is the bottom of the image
    rgb, alpha = px[..., :3], px[..., 3:4]
    t = np.linspace(0.0, 1.0, h, dtype=np.float32).reshape(h, 1, 1) ** 0.8
    bg = hex_to_srgb(bottom_hex) * (1.0 - t) + hex_to_srgb(top_hex) * t
    out = np.concatenate([rgb * alpha + bg * (1.0 - alpha), np.ones_like(alpha)], axis=2)
    out_img = bpy.data.images.new("composite", w, h, alpha=False)
    out_img.pixels.foreach_set(out.astype(np.float32).ravel())
    out_img.filepath_raw = dst_path
    out_img.file_format = "PNG"
    out_img.save()
    bpy.data.images.remove(out_img)


def world_bounds(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


def pack_for_lineup(groups):
    """Temporarily slide each prop group along X so they stand side by side
    with LINEUP_GAP between them. Returns a function that undoes it."""
    saved = {o: o.location.copy() for objs in groups.values() for o in objs}
    cursor = 0.0
    for prefix in LINEUP_ORDER + [p for p in groups if p not in LINEUP_ORDER]:
        objs = groups.get(prefix)
        if not objs:
            continue
        lo, hi = world_bounds(objs)
        for o in objs:
            o.location.x += cursor - lo.x
        cursor += (hi.x - lo.x) + LINEUP_GAP
    bpy.context.view_layer.update()

    def restore():
        for o, loc in saved.items():
            o.location = loc
        bpy.context.view_layer.update()
    return restore


def render_all(groups, out_dir, only=None):
    """groups: {prefix: [mesh objects]} as returned by make_props.build_all().
    Must run after export: it adds a camera, lights and a catcher plane."""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    studio = Studio(scene)
    raw_dir = tempfile.mkdtemp(prefix="props_raw_")
    for shot in SHOTS:
        if only and shot["file"] not in only:
            continue
        restore = None
        if shot["prefix"] is None:
            restore = pack_for_lineup(groups)
            objs = [o for objs in groups.values() for o in objs]
        else:
            objs = groups[shot["prefix"]]
        scene.view_settings.exposure = shot["exposure"]
        studio.frame(objs, *shot["cam"], shot["res"],
                     fill=0.90 if shot["prefix"] is None else 0.80)
        raw = os.path.join(raw_dir, shot["file"])
        studio.render(objs, raw)
        if restore:
            restore()
        dst = os.path.join(out_dir, shot["file"])
        composite_over_gradient(raw, dst, *shot["bg"])
        print(f"Preview written: {dst}")
    shutil.rmtree(raw_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.dont_write_bytecode = True  # keep the blender/ folder free of __pycache__
    sys.path.insert(0, SCRIPT_DIR)
    import make_props

    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = make_props.ASSET_DIR
    only = None
    for a in argv:
        if a.startswith("--out="):
            out = a.split("=", 1)[1]
        elif a.startswith("--only="):
            only = a.split("=", 1)[1].split(",")
    render_all(make_props.build_all(), out, only)
~~~~


## `blender/verify_exports.py`

~~~~python
"""
verify_exports.py -- re-import the exported FBX and GLB into a fresh, empty
Blender session and print what a downstream tool would actually see.

    blender -b --factory-startup --python verify_exports.py

For each file it prints object names, triangle counts and world-space
bounding-box dimensions, checks the names against the game-script contract,
checks that everything is a top-level mesh, that each prop group rests on the
ground and that the star / flag / trophy are tallest along Z (upright), and
that no user-specific absolute path is embedded in the binary.
Exits with a non-zero status if any check fails.
"""

import os
import sys

import bpy
from mathutils import Vector

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = SCRIPT_DIR  # outputs sit next to the scripts (copied to assets/blender/ in the submission)

EXPECTED = {
    "StarCoin_Body",
    "JumpMushroom_Cap", "JumpMushroom_Dots", "JumpMushroom_Stem",
    "CheckFlag_Pole", "CheckFlag_Cloth", "CheckFlag_Base",
    "GoalTrophy_Cup", "GoalTrophy_Base",
    "CloudPad_Body",
}
UPRIGHT = {"StarCoin", "CheckFlag", "GoalTrophy"}  # tallest axis must be Z
TRI_BUDGET = 4000


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def world_bounds(objs):
    pts = [o.matrix_world @ v.co for o in objs for v in o.data.vertices]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


def tris(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def check_file(path, importer):
    print("\n" + "=" * 78)
    print(f"{os.path.basename(path)}  ({os.path.getsize(path)} bytes)")
    print("=" * 78)
    errors = []

    with open(path, "rb") as fh:
        data = fh.read()
    home = os.path.expanduser("~").encode()
    user = os.path.basename(os.path.expanduser("~")).encode()
    for needle in (home, user):
        if needle and data.count(needle):
            errors.append(f"binary contains {needle!r} {data.count(needle)} time(s)")

    clear_scene()
    importer(path)
    objs = list(bpy.context.scene.objects)
    meshes = [o for o in objs if o.type == "MESH"]
    others = [o for o in objs if o.type != "MESH"]
    if others:
        errors.append(f"non-mesh objects imported: {[(o.name, o.type) for o in others]}")
    names = {o.name for o in meshes}
    if names != EXPECTED:
        errors.append(f"name mismatch: missing={sorted(EXPECTED - names)} extra={sorted(names - EXPECTED)}")
    for o in meshes:
        if o.parent is not None:
            errors.append(f"{o.name} has parent {o.parent.name}")

    print("%-20s %6s  %-22s %s" % ("object", "tris", "dims X x Y x Z (m)", "material"))
    for o in sorted(meshes, key=lambda o: o.name):
        lo, hi = world_bounds([o])
        d = hi - lo
        mats = [m.name for m in o.data.materials if m]
        print("%-20s %6d  %5.2f x %5.2f x %5.2f   %s" % (o.name, tris(o), d.x, d.y, d.z, mats))

    print("\n%-14s %6s  %-22s %-8s %-8s %s" % ("prop", "tris", "dims X x Y x Z (m)",
                                               "min z", "ctr y", "tallest"))
    groups = {}
    for o in meshes:
        groups.setdefault(o.name.split("_")[0], []).append(o)
    for prefix in sorted(groups):
        g = groups[prefix]
        lo, hi = world_bounds(g)
        d = hi - lo
        total = sum(tris(o) for o in g)
        tallest = "XYZ"[max(range(3), key=lambda i: d[i])]
        print("%-14s %6d  %5.2f x %5.2f x %5.2f   %7.3f  %7.3f  %s"
              % (prefix, total, d.x, d.y, d.z, lo.z, (lo.y + hi.y) / 2, tallest))
        if prefix in UPRIGHT and tallest != "Z":
            errors.append(f"{prefix} is not upright (tallest axis {tallest})")
        if abs(lo.z) > 1e-3:
            errors.append(f"{prefix} lowest point is z={lo.z:.4f}, expected 0")
        if total > TRI_BUDGET:
            errors.append(f"{prefix} has {total} tris (> {TRI_BUDGET})")

    if errors:
        print("\nFAILED:")
        for e in errors:
            print("  -", e)
    else:
        print("\nOK: names match the contract, all top-level meshes, upright, grounded, "
              "no user path in binary.")
    return not errors


def main():
    ok = True
    ok &= check_file(os.path.join(ASSET_DIR, "AvatarthonProps.fbx"),
                     lambda p: bpy.ops.import_scene.fbx(filepath=p))
    ok &= check_file(os.path.join(ASSET_DIR, "AvatarthonProps.glb"),
                     lambda p: bpy.ops.import_scene.gltf(filepath=p))
    print("\nVERIFY RESULT:", "PASS" if ok else "FAIL")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
~~~~
