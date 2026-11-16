#!/usr/bin/env python3
"""Regenerates the THE ASYLUM greybox Rojo sources under src/mission/world (TTL-10). Standard library only.

    python3 tools/asylum_greybox/generate_asylum_greybox.py

The *.model.json files are the source of truth Rojo reads; this script is an authoring aid that rebuilds them from
asylum_layout.py (it overwrites the generated files). Nothing here runs in the game: the map is static, source-controlled
geometry, never built by a runtime Lua builder.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asylum_layout as L  # noqa: E402

IDENTITY = [1, 0, 0, 0, 1, 0, 0, 0, 1]
TAG = "ObjectivePoint"
ATTRIBUTE = "PointId"


def cframe(x, y, z):
    return [round(x, 4), round(y, 4), round(z, 4)] + IDENTITY


def part(name, x0, x1, y0, y1, z0, z1, material, color, collide=True, extra=None, cls="Part"):
    props = {
        "Size": [round(x1 - x0, 4), round(y1 - y0, 4), round(z1 - z0, 4)],
        "CFrame": cframe((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
        "Anchored": True,
        "Material": material,
        "Color": [round(c, 3) for c in color],
    }
    if not collide:
        props["CanCollide"] = False
    if extra:
        props.update(extra)
    return {"Name": name, "ClassName": cls, "Properties": props}


def build_owner():
    owner = {}
    for name, (tx0, tz0, tx1, tz1) in L.REGIONS.items():
        for tx in range(tx0, tx1):
            for tz in range(tz0, tz1):
                if (tx, tz) in owner:
                    raise SystemExit(f"tile ({tx}, {tz}) belongs to both {owner[(tx, tz)]} and {name}")
                owner[(tx, tz)] = name
    return owner


def all_edges(owner):
    """Every tile boundary between two different owners (or an owner and the outside): (kind, line, along, a, b)."""
    xs = [t[0] for t in owner]
    zs = [t[1] for t in owner]
    edges = []
    for xline in range(min(xs), max(xs) + 2):
        for tz in range(min(zs), max(zs) + 1):
            a, b = owner.get((xline - 1, tz)), owner.get((xline, tz))
            if a != b:
                edges.append(("V", xline, tz, a, b))
    for zline in range(min(zs), max(zs) + 2):
        for tx in range(min(xs), max(xs) + 1):
            a, b = owner.get((tx, zline - 1)), owner.get((tx, zline))
            if a != b:
                edges.append(("H", zline, tx, a, b))
    return edges


def open_edges(edges):
    opened = set()
    for a, b, start, count in L.DOORS:
        found = [e for e in edges if {e[3], e[4]} == {a, b} and start <= e[2] < start + count]
        if len(found) != count:
            raise SystemExit(f"door {a} <-> {b} at {start}+{count}: found {len(found)} boundary tiles, expected {count}")
        kinds = {e[0] for e in found}
        lines = {e[1] for e in found}
        if len(kinds) != 1 or len(lines) != 1:
            raise SystemExit(f"door {a} <-> {b}: boundary tiles are not on one straight line")
        for e in found:
            opened.add((e[0], e[1], e[2]))
    return opened


def wall_color(a, b):
    candidates = [r for r in (a, b) if r is not None]
    rooms = [r for r in candidates if r not in L.CIRCULATION]
    chosen = sorted(rooms)[0] if rooms else sorted(candidates)[0]
    return L.STYLE[chosen][0]


def build_architecture():
    owner = build_owner()
    edges = all_edges(owner)
    opened = open_edges(edges)

    groups = {}
    for kind, line, along, a, b in edges:
        if (kind, line, along) in opened:
            continue
        groups.setdefault((kind, line, wall_color(a, b)), []).append(along)

    y0, y1 = L.FY, L.FY + L.WALL_H
    half = L.WALL_T / 2
    walls = []
    for (kind, line, color), alongs in sorted(groups.items()):
        alongs.sort()
        runs, start, prev = [], alongs[0], alongs[0]
        for value in alongs[1:]:
            if value == prev + 1:
                prev = value
                continue
            runs.append((start, prev))
            start = prev = value
        runs.append((start, prev))
        for first, last in runs:
            lo = first * L.TILE - half + (L.OX if kind == "H" else L.OZ)
            hi = (last + 1) * L.TILE + half + (L.OX if kind == "H" else L.OZ)
            centre = line * L.TILE + (L.OZ if kind == "H" else L.OX)
            if kind == "H":
                node = part(f"Wall_H_{line}_{first}_{last}", lo, hi, y0, y1, centre - half, centre + half, "Concrete", color)
            else:
                node = part(f"Wall_V_{line}_{first}_{last}", centre - half, centre + half, y0, y1, lo, hi, "Concrete", color)
            walls.append(node)

    floors, ceilings = [], []
    for name in sorted(L.REGIONS):
        x0, x1, z0, z1 = L.region_box(name)
        _, material, color = L.STYLE[name]
        floors.append(part(f"Floor_{name}", x0, x1, L.FY - L.SLAB_T, L.FY, z0, z1, material, color))
        ceilings.append(part(f"Ceiling_{name}", x0, x1, L.FY + L.WALL_H, L.FY + L.WALL_H + L.SLAB_T, z0, z1, "Concrete", (0.17, 0.17, 0.18)))

    return {
        "ClassName": "Model",
        "Children": [
            {"Name": "Floors", "ClassName": "Folder", "Children": floors},
            {"Name": "Walls", "ClassName": "Folder", "Children": walls},
            {"Name": "Ceilings", "ClassName": "Folder", "Children": ceilings},
        ],
    }


def build_lamps():
    lamps = []
    y = L.FY + L.WALL_H - 0.4
    for name in sorted(L.REGIONS):
        x0, x1, z0, z1 = L.region_box(name)
        spans_x, spans_z = x1 - x0, z1 - z0
        if spans_x >= spans_z:
            count = max(1, int(spans_x // L.LAMP_SPACING))
            points = [(x0 + (i + 0.5) * spans_x / count, (z0 + z1) / 2) for i in range(count)]
        else:
            count = max(1, int(spans_z // L.LAMP_SPACING))
            points = [((x0 + x1) / 2, z0 + (i + 0.5) * spans_z / count) for i in range(count)]
        cold = name in L.CIRCULATION or name in ("TreatmentRoom", "HydrotherapyWard")
        light_color = [0.78, 0.88, 1.0] if cold else [1.0, 0.82, 0.62]
        for index, (x, z) in enumerate(points):
            node = part(f"Lamp_{name}_{index + 1}", x - 1, x + 1, y - 0.2, y + 0.2, z - 1, z + 1, "Neon", (0.9, 0.9, 0.85), collide=False, extra={"CastShadow": False})
            node["Children"] = [{"Name": "Light", "ClassName": "PointLight", "Properties": {"Brightness": 0.9, "Range": 26, "Color": light_color, "Shadows": False}}]
            lamps.append(node)
    return {"ClassName": "Model", "Children": [{"Name": "Lamps", "ClassName": "Folder", "Children": lamps}]}


def build_props():
    children = []
    for region, name, x0, z0, x1, z1, height, material, color in L.PROPS:
        children.append(part(f"{region}_{name}", x0, x1, L.FY, L.FY + height, z0, z1, material, color))
    return {"ClassName": "Model", "Children": [{"Name": "Props", "ClassName": "Folder", "Children": children}]}


def build_anchors():
    children = []
    for point_id, (region, x, y, z, size) in sorted(L.ANCHORS.items()):
        node = part(point_id, x - size[0] / 2, x + size[0] / 2, y - size[1] / 2, y + size[1] / 2, z - size[2] / 2, z + size[2] / 2, "SmoothPlastic", (0.78, 0.6, 0.28), collide=False, extra={"Tags": [TAG]})
        node["Attributes"] = {ATTRIBUTE: point_id}
        children.append(node)
    return {"ClassName": "Model", "Children": children}


def build_spawn():
    sx, sy, sz = L.SPAWN["size"]
    return {
        "ClassName": "SpawnLocation",
        "Properties": {
            "Size": [sx, sy, sz],
            "CFrame": cframe(L.SPAWN["x"], L.FY - 0.48, L.SPAWN["z"]),
            "Anchored": True,
            "Transparency": 1,
            "Neutral": True,
            "AllowTeamChangeOnTouch": False,
            "Duration": 0,
            "Enabled": True,
        },
    }


def write(path, node):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(node, handle, indent=2)
        handle.write("\n")


def main():
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    world = os.path.join(root, "src", "mission", "world")
    write(os.path.join(world, "SpawnLocation.model.json"), build_spawn())
    env = os.path.join(world, "AsylumMap")
    write(os.path.join(env, "Architecture.model.json"), build_architecture())
    write(os.path.join(env, "Lighting.model.json"), build_lamps())
    write(os.path.join(env, "Props.model.json"), build_props())
    write(os.path.join(env, "ObjectiveAnchors.model.json"), build_anchors())
    print("generated", world)


if __name__ == "__main__":
    main()
