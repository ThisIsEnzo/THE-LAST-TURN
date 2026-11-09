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


def build_grid(parts):
    # The exterior ground slab is huge; the walkable grid only needs the facility footprint.
    footprint = [p for p in parts if p["name"] != "Ground"]
    xs = [p["box"][0] for p in footprint] + [p["box"][1] for p in footprint]
    zs = [p["box"][4] for p in footprint] + [p["box"][5] for p in footprint]
    x0, x1, z0, z1 = min(xs) - 4, max(xs) + 4, min(zs) - 4, max(zs) + 4
    # Ground is a huge slab: use the facility footprint only.
    nx, nz = int((x1 - x0) / CELL) + 1, int((z1 - z0) / CELL) + 1
    return x0, z0, nx, nz


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

    # Navigation.
    gx0, gz0, nx, nz = build_grid(parts)
    blocked = [[False] * nz for _ in range(nx)]
    margin = CHAR_RADIUS
    for p in solids:
        x0, x1, y0, y1, z0, z1 = p["box"]
        if p["cls"] == "SpawnLocation" or y1 <= BODY_BOTTOM or y0 >= BODY_TOP:
            continue
        ix0, ix1 = int((x0 - margin - gx0) / CELL), int((x1 + margin - gx0) / CELL) + 1
        iz0, iz1 = int((z0 - margin - gz0) / CELL), int((z1 + margin - gz0) / CELL) + 1
        for ix in range(max(ix0, 0), min(ix1, nx)):
            for iz in range(max(iz0, 0), min(iz1, nz)):
                blocked[ix][iz] = True

    def cell(x, z):
        return int((x - gx0) / CELL), int((z - gz0) / CELL)

    start = cell(0, 50)
    reach = [[False] * nz for _ in range(nx)]
    if blocked[start[0]][start[1]]:
        fail("spawn centre is inside geometry")
    queue = deque([start])
    reach[start[0]][start[1]] = True
    while queue:
        x, z = queue.popleft()
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            a, b = x + dx, z + dz
            if 0 <= a < nx and 0 <= b < nz and not blocked[a][b] and not reach[a][b]:
                reach[a][b] = True
                queue.append((a, b))

    def reachable(x, z):
        cx, cz = cell(x, z)
        return reach[cx][cz]

    required = {
        "spawn pad corners": [(-6, 47), (6, 47), (-6, 53), (6, 53)],
        "reception": [(-12, 44), (12, 34), (0, 40)],
        "main lobby": [(0, 20), (-12, 6), (12, 6), (0, -4), (-26, 15), (26, 15), (0, 27)],
        "mission preparation": [(0, -20), (0, -34), (10, -14), (-10, -30)],
        "equipment room": [(-38, 15), (-50, 20), (-56, 10), (-45, 24)],
        "briefing room": [(34, 16), (36, 10), (36, 22)],
    }
    for room, points in required.items():
        for x, z in points:
            if not reachable(x, z):
                fail(f"not reachable: {room} at ({x}, {z})")
    forbidden = {"restricted area": [(25, -28), (35, -28), (45, -30), (45, -24)]}
    for room, points in forbidden.items():
        for x, z in points:
            if reachable(x, z):
                fail(f"restricted area is reachable at ({x}, {z})")

    total_free = sum(1 for x in range(nx) for z in range(nz) if reach[x][z])
    print(f"walkable cells (r={CHAR_RADIUS} inflated, {CELL} stud grid): {total_free}  (~{total_free * CELL * CELL:.0f} sq studs of centre positions)")

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

        s = 6  # pixels per grid cell
        img = Image.new("RGB", (nx * s + 1, nz * s + 1), (20, 22, 26))
        draw = ImageDraw.Draw(img)
        for x in range(nx):
            for z in range(nz):
                if reach[x][z]:
                    draw.rectangle([x * s, z * s, (x + 1) * s, (z + 1) * s], fill=(48, 74, 92))
        for p in solids:
            x0, x1, y0, y1, z0, z1 = p["box"]
            if y1 <= BODY_BOTTOM or y0 >= BODY_TOP or p["cls"] == "SpawnLocation":
                continue
            draw.rectangle([(x0 - gx0) / CELL * s, (z0 - gz0) / CELL * s, (x1 - gx0) / CELL * s, (z1 - gz0) / CELL * s], fill=(190, 190, 200))
        sx_, sz_ = cell(0, 50)
        draw.ellipse([sx_ * s - 5, sz_ * s - 5, sx_ * s + 5, sz_ * s + 5], fill=(240, 200, 60))
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
