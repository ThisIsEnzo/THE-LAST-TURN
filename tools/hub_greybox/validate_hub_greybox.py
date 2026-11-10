#!/usr/bin/env python3
"""Offline sanity checks for the HUB greybox sources (TTL-HUB-01). Standard library only.

    python3 tools/hub_greybox/validate_hub_greybox.py [repo_root] [--render out.ppm-less-png]

This is NOT a substitute for opening the place in Roblox Studio. It checks:
  1. every file parses and only uses classes, properties and value shapes documented for Rojo 7 JSON models;
  2. names are unique among siblings and there are no scripts;
  3. collidable geometry does not overlap accidentally (known intentional overlaps are listed explicitly);
  4. a character-sized walker starting on the spawn can reach every accessible room, the spawn pad is free and
     the restricted area cannot be reached.
"""
import json
import os
import sys
from collections import deque

FY = 1.0
CHAR_RADIUS = 1.0  # half width used to inflate obstacles (a Roblox character is ~2 studs wide)
BODY_BOTTOM = FY + 0.8  # anything lower than this is a negligible step
BODY_TOP = FY + 5.5  # character height
CELL = 0.5

# Floor support: what counts as a surface a character can walk on. Floors are large, thick, collidable slabs whose top
# is at floor height. The exterior Ground slab (top below floor height, 400 studs wide) and the template Baseplate
# (top at y = 0, 512 studs wide) are explicitly NOT valid indoor surfaces; thin markings and furniture never support.
SUPPORT_MIN_TOP = FY - 0.1
SUPPORT_MAX_TOP = FY + 0.5
SUPPORT_MIN_THICKNESS = 0.5
SUPPORT_MIN_SPAN = 2.0
SUPPORT_MAX_SPAN = 200.0
SUPPORT_MARGIN = 0.5  # the walker's centre must have floor this far in every direction (partial edge support only)

ALLOWED_CLASSES = {"Model", "Folder", "Part", "SpawnLocation", "SurfaceGui", "TextLabel", "PointLight"}
ALLOWED_PROPS = {
    "Part": {"Size", "CFrame", "Anchored", "Material", "Color", "CanCollide", "Transparency", "CastShadow"},
    "SpawnLocation": {"Size", "CFrame", "Anchored", "Transparency", "Neutral", "AllowTeamChangeOnTouch", "Duration", "Enabled"},
    "SurfaceGui": {"Face", "SizingMode", "PixelsPerStud", "LightInfluence"},
    "TextLabel": {"Size", "BackgroundTransparency", "Text", "TextColor3", "TextScaled", "TextWrapped", "FontFace"},
    "PointLight": {"Brightness", "Range", "Color", "Shadows"},
    "Model": set(),
    "Folder": set(),
}
MATERIALS = {"Concrete", "Metal", "Glass", "Neon", "SmoothPlastic", "Fabric", "DiamondPlate", "Wood", "Slate", "CorrodedMetal"}
FACES = {"Front", "Back", "Left", "Right", "Top", "Bottom"}
IDENTITY = [1, 0, 0, 0, 1, 0, 0, 0, 1]

errors = []


def fail(message):
    errors.append(message)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check_props(path, node):
    cls = node.get("ClassName")
    if cls not in ALLOWED_CLASSES:
        fail(f"{path}: class {cls!r} is not allowed")
        return
    props = node.get("Properties", {})
    unknown = set(props) - ALLOWED_PROPS[cls]
    if unknown:
        fail(f"{path}: unexpected properties {sorted(unknown)}")
    for key, value in props.items():
        if key == "Size" and cls != "TextLabel":
            if not (isinstance(value, list) and len(value) == 3 and all(is_num(v) and v > 0 for v in value)):
                fail(f"{path}.Size invalid: {value}")
        elif key == "CFrame":
            if not (isinstance(value, list) and len(value) == 12 and all(is_num(v) for v in value)):
                fail(f"{path}.CFrame must be a flat list of 12 numbers")
            elif value[3:] != IDENTITY:
                fail(f"{path}.CFrame is rotated; the layout is axis aligned only")
        elif key in ("Color", "TextColor3"):
            if not (isinstance(value, list) and len(value) == 3 and all(is_num(v) and 0 <= v <= 1 for v in value)):
                fail(f"{path}.{key} invalid: {value}")
        elif key == "Material" and value not in MATERIALS:
            fail(f"{path}.Material {value!r} unknown")
        elif key == "Face" and value not in FACES:
            fail(f"{path}.Face {value!r} unknown")
    if cls == "TextLabel":
        size = props.get("Size")
        if not (isinstance(size, dict) and list(size) == ["UDim2"]):
            fail(f"{path}.Size must use the explicit UDim2 form")
    if cls in ("Part", "SpawnLocation") and props.get("Anchored") is not True:
        fail(f"{path}: part is not anchored")


def walk(node, path, parts, counts):
    name = node.get("Name", "")
    here = f"{path}/{name}" if name else path
    check_props(here, node)
    counts[node.get("ClassName")] = counts.get(node.get("ClassName"), 0) + 1
    children = node.get("Children", [])
    seen = set()
    for child in children:
        child_name = child.get("Name")
        if not child_name:
            fail(f"{here}: child without a Name")
            continue
        if child_name in seen:
            fail(f"{here}: duplicate sibling name {child_name!r}")
        seen.add(child_name)
    if node.get("ClassName") in ("Part", "SpawnLocation"):
        p = node["Properties"]
        sx, sy, sz = p["Size"]
        cx, cy, cz = p["CFrame"][:3]
        parts.append({
            "path": here,
            "name": name or os.path.basename(path),
            "box": (cx - sx / 2, cx + sx / 2, cy - sy / 2, cy + sy / 2, cz - sz / 2, cz + sz / 2),
            "collide": p.get("CanCollide", True),
            "cls": node["ClassName"],
        })
    for child in children:
        if child.get("Name"):
            walk(child, here, parts, counts)


def load(world):
    parts, counts = [], {}
    files = []
    for base, _, names in os.walk(world):
        for fname in sorted(names):
            if fname.endswith(".json"):
                files.append(os.path.join(base, fname))
    for path in sorted(files):
        rel = os.path.relpath(path, world)
        try:
            with open(path, encoding="utf-8") as handle:
                node = json.load(handle)
        except Exception as exc:  # noqa: BLE001
            fail(f"{rel}: cannot parse: {exc}")
            continue
        stem = os.path.basename(path)[: -len(".model.json")]
        node = dict(node)
        node.setdefault("Name", stem)
        walk(node, "", parts, counts)
    return parts, counts, files


def overlap(a, b, tol=0.02):
    return all(min(a[i + 1], b[i + 1]) - max(a[i], b[i]) > tol for i in (0, 2, 4))


def intentional(a, b):
    na, nb = a["name"], b["name"]
    pa, pb = a["path"], b["path"]

    def kind(p):
        for token in ("/Walls/", "/Floors/", "/Ceilings/", "/Exterior/"):
            if token in p:
                return token
        return None

    ka, kb = kind(pa), kind(pb)
    if ka == "/Walls/" and kb == "/Walls/":
        return True  # wall segments meet at corners and junctions, frames and trims clad walls
    if {ka, kb} <= {"/Floors/", "/Exterior/", None} and ("SpawnLocation" in (a["cls"], b["cls"])):
        return True  # the spawn pad is embedded flush in the floor
    if "/Floors/" in (ka, kb) and ("/Walls/" in (ka, kb)):
        return False
    if "Ground" in (na, nb):
        return True
    return False


def floor_support_parts(parts):
    """Parts that can support a walking character (large, thick, collidable, at floor height)."""
    result = []
    for p in parts:
        x0, x1, y0, y1, z0, z1 = p["box"]
        span_x, span_z = x1 - x0, z1 - z0
        if (
            p["cls"] == "Part"
            and p["collide"]
            and p["name"] not in ("Ground", "Baseplate")
            and SUPPORT_MIN_TOP <= y1 <= SUPPORT_MAX_TOP
            and (y1 - y0) >= SUPPORT_MIN_THICKNESS
            and min(span_x, span_z) >= SUPPORT_MIN_SPAN
            and max(span_x, span_z) <= SUPPORT_MAX_SPAN
        ):
            result.append(p)
    return result


def floor_support_rects(parts):
    """Horizontal rectangles (x0, x1, z0, z1) of the floor-support parts."""
    return [(p["box"][0], p["box"][1], p["box"][4], p["box"][5]) for p in floor_support_parts(parts)]


class Navigation:
    """Grid walkability: a cell is walkable only if it is free of (inflated) obstacles AND has floor support."""

    def __init__(self, parts, start, require_floor=True):
        footprint = [p for p in parts if p["name"] not in ("Ground", "Baseplate") and max(p["box"][1] - p["box"][0], p["box"][5] - p["box"][4]) <= SUPPORT_MAX_SPAN]
        xs = [p["box"][0] for p in footprint] + [p["box"][1] for p in footprint]
        zs = [p["box"][4] for p in footprint] + [p["box"][5] for p in footprint]
        self.gx0, self.gz0 = min(xs) - 4, min(zs) - 4
        self.nx = int((max(xs) + 4 - self.gx0) / CELL) + 1
        self.nz = int((max(zs) + 4 - self.gz0) / CELL) + 1
        self.rects = floor_support_rects(parts)
        self.require_floor = require_floor

        solids = [p for p in parts if p["collide"] and p["name"] not in ("Ground", "Baseplate")]
        self.blocked = [[False] * self.nz for _ in range(self.nx)]
        for p in solids:
            x0, x1, y0, y1, z0, z1 = p["box"]
            if p["cls"] == "SpawnLocation" or y1 <= BODY_BOTTOM or y0 >= BODY_TOP:
                continue
            ix0, ix1 = int((x0 - CHAR_RADIUS - self.gx0) / CELL), int((x1 + CHAR_RADIUS - self.gx0) / CELL) + 1
            iz0, iz1 = int((z0 - CHAR_RADIUS - self.gz0) / CELL), int((z1 + CHAR_RADIUS - self.gz0) / CELL) + 1
            for ix in range(max(ix0, 0), min(ix1, self.nx)):
                for iz in range(max(iz0, 0), min(iz1, self.nz)):
                    self.blocked[ix][iz] = True

        self.supported = [[False] * self.nz for _ in range(self.nx)]
        for ix in range(self.nx):
            for iz in range(self.nz):
                cx, cz = self.gx0 + (ix + 0.5) * CELL, self.gz0 + (iz + 0.5) * CELL
                self.supported[ix][iz] = all(
                    self._point_supported(cx + dx, cz + dz)
                    for dx, dz in ((0, 0), (SUPPORT_MARGIN, 0), (-SUPPORT_MARGIN, 0), (0, SUPPORT_MARGIN), (0, -SUPPORT_MARGIN))
                )

        self.start = self.cell(*start)
        self.reach = [[False] * self.nz for _ in range(self.nx)]
        if self.walkable_cell(*self.start):
            queue = deque([self.start])
            self.reach[self.start[0]][self.start[1]] = True
            while queue:
                x, z = queue.popleft()
                for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    a, b = x + dx, z + dz
                    if 0 <= a < self.nx and 0 <= b < self.nz and not self.reach[a][b] and self.walkable_cell(a, b):
                        self.reach[a][b] = True
                        queue.append((a, b))

    def _point_supported(self, x, z):
        return any(x0 <= x <= x1 and z0 <= z <= z1 for x0, x1, z0, z1 in self.rects)

    def cell(self, x, z):
        return int((x - self.gx0) / CELL), int((z - self.gz0) / CELL)

    def walkable_cell(self, ix, iz):
        if not (0 <= ix < self.nx and 0 <= iz < self.nz) or self.blocked[ix][iz]:
            return False
        return self.supported[ix][iz] or not self.require_floor

    def reachable(self, x, z):
        ix, iz = self.cell(x, z)
        return 0 <= ix < self.nx and 0 <= iz < self.nz and self.reach[ix][iz]

    def supported_at(self, x, z):
        ix, iz = self.cell(x, z)
        return 0 <= ix < self.nx and 0 <= iz < self.nz and self.supported[ix][iz]


# Probe points (x, z) in studs. Required points must be reachable from the spawn; forbidden ones must not be.
SPAWN = (0, 50)
REQUIRED = {
    "spawn pad corners": [(-6, 47), (6, 47), (-6, 53), (6, 53)],
    "reception": [(-12, 44), (12, 34), (0, 40)],
    "main lobby": [(0, 20), (-12, 6), (12, 6), (0, -4), (-26, 15), (26, 15), (0, 27)],
    "mission preparation": [(0, -20), (0, -34), (10, -14), (-10, -30)],
    "equipment room": [(-38, 15), (-50, 20), (-56, 10), (-45, 24)],
    "briefing room": [(34, 16), (36, 10), (36, 22)],
}
# Doorway thresholds on the wall centrelines: both rooms' floors must meet here, and a walker must be able to stand on
# the threshold itself (supported and reachable), not just on either side.
DOORWAYS = {
    "reception to lobby": [(0, 31), (0, 30), (0, 29)],
    "lobby to mission preparation": [(0, -7), (0, -8), (0, -9)],
    "lobby to equipment room": [(-29, 15), (-30, 15), (-31, 15)],
    "lobby to briefing room": [(29, 16), (30, 16), (31, 16)],
}
ROOM_FLOORS_EXPECTED = ("Reception", "MainLobby", "MissionPreparation", "EquipmentRoom", "BriefingRoom", "RestrictedArea")
FORBIDDEN = {"restricted area": [(25, -28), (35, -28), (45, -30), (45, -24)]}


def check_navigation(parts, require_floor=True):
    """Returns (list of problem strings, Navigation)."""
    problems = []
    nav = Navigation(parts, SPAWN, require_floor=require_floor)
    if nav.blocked[nav.start[0]][nav.start[1]]:
        problems.append("spawn centre is inside geometry")
    elif require_floor and not nav.supported_at(*SPAWN):
        problems.append("spawn centre has no floor support")
    for room, points in REQUIRED.items():
        for x, z in points:
            if not nav.reachable(x, z):
                problems.append(f"not reachable: {room} at ({x}, {z})")
    for door, points in DOORWAYS.items():
        for x, z in points:
            if require_floor and not nav.supported_at(x, z):
                problems.append(f"doorway has no floor support: {door} at ({x}, {z})")
            elif not nav.reachable(x, z):
                problems.append(f"doorway not passable: {door} at ({x}, {z})")
    for room, points in FORBIDDEN.items():
        for x, z in points:
            if nav.reachable(x, z):
                problems.append(f"{room} is reachable at ({x}, {z})")
    return problems, nav


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    render = None
    if "--render" in sys.argv:
        render = sys.argv[sys.argv.index("--render") + 1]
        args = [a for a in args if a != render]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    world = os.path.join(root, "src", "hub", "world")
    parts, counts, files = load(world)
    print(f"files: {len(files)}  parts: {len(parts)}  instances by class: {dict(sorted(counts.items()))}")

    # Geometry: accidental overlaps among collidable parts.
    solids = [p for p in parts if p["collide"] and "Ground" != p["name"]]
    flagged = 0
    for i in range(len(solids)):
        for j in range(i + 1, len(solids)):
            a, b = solids[i], solids[j]
            if overlap(a["box"], b["box"]) and not intentional(a, b):
                flagged += 1
                if flagged <= 25:
                    fail(f"overlap: {a['path']}  x  {b['path']}")
    if flagged > 25:
        fail(f"... and {flagged - 25} more overlaps")

    # Navigation: obstacles AND floor support.
    nav_problems, nav = check_navigation(parts)
    for message in nav_problems:
        fail(message)
    if len(nav.rects) != len(ROOM_FLOORS_EXPECTED):
        fail(f"expected {len(ROOM_FLOORS_EXPECTED)} floor slabs as walking surfaces, found {len(nav.rects)}")
    total_free = sum(1 for x in range(nav.nx) for z in range(nav.nz) if nav.reach[x][z])
    print(f"walkable cells (r={CHAR_RADIUS} inflated, floor-supported, {CELL} stud grid): {total_free}  (~{total_free * CELL * CELL:.0f} sq studs of centre positions); floor slabs: {len(nav.rects)}")

    # The spawn pad must sit flush with the floor.
    pads = [p for p in parts if p["cls"] == "SpawnLocation"]
    if len(pads) != 1:
        fail(f"expected exactly one SpawnLocation, found {len(pads)}")
    else:
        top = pads[0]["box"][3]
        if abs(top - (FY + 0.02)) > 0.011:
            fail(f"spawn pad top is {top}, expected {FY + 0.02}")

    if render:
        from PIL import Image, ImageDraw

        px = 6  # pixels per grid cell
        img = Image.new("RGB", (nav.nx * px + 1, nav.nz * px + 1), (20, 22, 26))
        draw = ImageDraw.Draw(img)
        for x in range(nav.nx):
            for z in range(nav.nz):
                if nav.reach[x][z]:
                    fill = (48, 74, 92)
                elif nav.supported[x][z] and not nav.blocked[x][z]:
                    fill = (74, 58, 40)  # floor-supported but not reachable (e.g. the sealed restricted area)
                elif nav.supported[x][z]:
                    fill = (34, 36, 42)
                else:
                    continue
                draw.rectangle([x * px, z * px, (x + 1) * px, (z + 1) * px], fill=fill)
        for p in parts:
            x0, x1, y0, y1, z0, z1 = p["box"]
            if not p["collide"] or p["name"] == "Ground" or y1 <= BODY_BOTTOM or y0 >= BODY_TOP or p["cls"] == "SpawnLocation":
                continue
            draw.rectangle([(x0 - nav.gx0) / CELL * px, (z0 - nav.gz0) / CELL * px, (x1 - nav.gx0) / CELL * px, (z1 - nav.gz0) / CELL * px], fill=(190, 190, 200))
        sx_, sz_ = nav.cell(*SPAWN)
        draw.ellipse([sx_ * px - 5, sz_ * px - 5, sx_ * px + 5, sz_ * px + 5], fill=(240, 200, 60))
        img.save(render)
        print(f"rendered {render}")

    if errors:
        print(f"\n{len(errors)} problem(s):")
        for message in errors:
            print("  -", message)
        sys.exit(1)
    print("OK: schema, naming, overlap and navigation checks passed")


if __name__ == "__main__":
    main()
