#!/usr/bin/env python3
"""Regenerates the HUB greybox Rojo sources under src/hub/world (TTL-HUB-01).

Optional authoring aid, standard library only. The generated *.model.json files are the source of truth that Rojo
reads; this script exists so the layout can be tuned from a few constants instead of editing ~300 parts by hand.
Running it overwrites src/hub/world/HubEnvironment/*.model.json and src/hub/world/SpawnLocation.model.json.

    python3 tools/hub_greybox/generate_hub_greybox.py [repo_root]

Conventions: x east, z south (north is -z), y up; studs. The facility floor top is FY (1.0) so it never shares a
plane with the template Baseplate (top at 0). Every part is axis aligned and anchored; there are no scripts.
"""
import json
import os
import re
import sys

FY = 1.0  # floor top height
H = 14.0  # room height (floor top to ceiling underside)
T = 1.0  # wall thickness
DH = 10.0  # doorway height

# Palette: cold, desaturated, industrial.
C_WALL = (0.50, 0.52, 0.55)
C_TRIM = (0.17, 0.18, 0.20)
C_CEIL = (0.22, 0.24, 0.26)
C_STEEL = (0.36, 0.40, 0.45)
C_DARK = (0.08, 0.09, 0.10)
C_TEXT = (0.84, 0.88, 0.90)
C_RED = (0.62, 0.16, 0.14)
C_GLASS = (0.62, 0.74, 0.80)
C_WOOD = (0.34, 0.30, 0.26)
C_FABRIC = (0.20, 0.25, 0.30)
C_PAPER = (0.78, 0.76, 0.70)


def num(value):
    value = round(float(value), 3)
    return int(value) if value == int(value) else value


def color(rgb):
    return [num(c) for c in rgb]


def part(name, cx, cy, cz, sx, sy, sz, material="Concrete", rgb=C_WALL, collide=True, transparency=None, shadow=True, children=None, cls="Part", **props):
    properties = {
        "Size": [num(sx), num(sy), num(sz)],
        "CFrame": [num(cx), num(cy), num(cz), 1, 0, 0, 0, 1, 0, 0, 0, 1],
        "Anchored": True,
        "Material": material,
        "Color": color(rgb),
    }
    if not collide:
        properties["CanCollide"] = False
    if transparency is not None:
        properties["Transparency"] = num(transparency)
    if not shadow:
        properties["CastShadow"] = False
    properties.update(props)
    node = {"Name": name, "ClassName": cls, "Properties": properties}
    if children:
        node["Children"] = children
    return node


def box_min_max(name, x0, x1, y0, y1, z0, z1, **kwargs):
    return part(name, (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, x1 - x0, y1 - y0, z1 - z0, **kwargs)


def folder(name, children):
    return {"Name": name, "ClassName": "Folder", "Children": children}


def model(children):
    return {"ClassName": "Model", "Children": children}


def sign(name, cx, cy, cz, sx, sy, sz, face, text, text_rgb=C_TEXT, bg=C_DARK, material="SmoothPlastic"):
    """A thin panel with a SurfaceGui text label. `face` is the part face the viewer sees (Front=-Z, Back=+Z,
    Left=-X, Right=+X)."""
    gui = {
        "Name": "Display",
        "ClassName": "SurfaceGui",
        "Properties": {"Face": face, "SizingMode": "PixelsPerStud", "PixelsPerStud": 50, "LightInfluence": 0},
        "Children": [
            {
                "Name": "Text",
                "ClassName": "TextLabel",
                "Properties": {
                    "Size": {"UDim2": [[1, 0], [1, 0]]},
                    "BackgroundTransparency": 1,
                    "Text": text,
                    "TextColor3": color(text_rgb),
                    "TextScaled": True,
                    "TextWrapped": True,
                    "FontFace": {"family": "rbxasset://fonts/families/GothamSSm.json", "weight": "Bold", "style": "Normal"},
                },
            }
        ],
    }
    return part(name, cx, cy, cz, sx, sy, sz, material=material, rgb=bg, shadow=False, children=[gui])


def fixture(name, cx, cz, rgb=(0.80, 0.90, 1.0), light_rgb=(0.85, 0.93, 1.0), brightness=0.8, rng=26):
    """A ceiling-mounted fluorescent panel carrying one PointLight."""
    light = {
        "Name": "Light",
        "ClassName": "PointLight",
        "Properties": {"Brightness": brightness, "Range": rng, "Color": color(light_rgb), "Shadows": False},
    }
    return part(name, cx, FY + H - 0.2, cz, 6, 0.4, 1.6, material="Neon", rgb=rgb, shadow=False, collide=False, children=[light])


# Walls ---------------------------------------------------------------------------------------------------------------

def wall(prefix, axis, fixed, lo, hi, openings=()):
    """Straight wall between lo and hi along `axis` ('x' = runs along x at z=fixed, 'z' = runs along z at x=fixed).
    Ends are extended by T/2 so corners close. Openings: dicts with a, b and kind open | window | glass_door."""
    parts = []

    def seg(name, a, b, y0, y1, **kw):
        if b - a < 0.01:
            return
        if axis == "x":
            parts.append(box_min_max(name, a, b, y0, y1, fixed - T / 2, fixed + T / 2, **kw))
        else:
            parts.append(box_min_max(name, fixed - T / 2, fixed + T / 2, y0, y1, a, b, **kw))

    def thin(name, a, b, y0, y1, depth, **kw):
        if axis == "x":
            parts.append(box_min_max(name, a, b, y0, y1, fixed - depth / 2, fixed + depth / 2, **kw))
        else:
            parts.append(box_min_max(name, fixed - depth / 2, fixed + depth / 2, y0, y1, a, b, **kw))

    ops = sorted(openings, key=lambda o: o["a"])
    cursor = lo - T / 2
    for index, op in enumerate(ops, start=1):
        seg(f"{prefix}_Segment{index}", cursor, op["a"], FY, FY + H)
        cursor = op["b"]
    seg(f"{prefix}_Segment{len(ops) + 1}", cursor, hi + T / 2, FY, FY + H)

    for index, op in enumerate(ops, start=1):
        a, b, kind = op["a"], op["b"], op["kind"]
        if kind == "window":
            sill, top = op.get("sill", 3), op.get("top", 10)
            seg(f"{prefix}_Sill{index}", a, b, FY, FY + sill)
            seg(f"{prefix}_Header{index}", a, b, FY + top, FY + H)
            thin(f"{prefix}_Glass{index}", a, b, FY + sill, FY + top, 0.3, material="Glass", rgb=C_GLASS, transparency=0.55, shadow=False)
            thin(f"{prefix}_WindowFrameTop{index}", a, b, FY + top - 0.3, FY + top, T + 0.3, material="Metal", rgb=C_TRIM)
            thin(f"{prefix}_WindowFrameBottom{index}", a, b, FY + sill, FY + sill + 0.3, T + 0.3, material="Metal", rgb=C_TRIM)
            continue
        seg(f"{prefix}_Lintel{index}", a, b, FY + DH, FY + H)
        thin(f"{prefix}_FrameLeft{index}", a - 0.5, a, FY, FY + DH, T + 0.3, material="Metal", rgb=C_TRIM)
        thin(f"{prefix}_FrameRight{index}", b, b + 0.5, FY, FY + DH, T + 0.3, material="Metal", rgb=C_TRIM)
        thin(f"{prefix}_FrameTop{index}", a, b, FY + DH - 0.4, FY + DH, T + 0.3, material="Metal", rgb=C_TRIM)
        if kind == "glass_door":
            mid = (a + b) / 2
            thin(f"{prefix}_Mullion{index}", mid - 0.4, mid + 0.4, FY, FY + DH, 0.5, material="Metal", rgb=C_TRIM)
            thin(f"{prefix}_PaneLeft{index}", a, mid - 0.4, FY, FY + DH - 0.4, 0.3, material="Glass", rgb=C_GLASS, transparency=0.55, shadow=False)
            thin(f"{prefix}_PaneRight{index}", mid + 0.4, b, FY, FY + DH - 0.4, 0.3, material="Glass", rgb=C_GLASS, transparency=0.55, shadow=False)
    return parts


OPEN = "open"


def op(a, b, kind=OPEN, **kw):
    data = {"a": a, "b": b, "kind": kind}
    data.update(kw)
    return data


# Room rectangles by wall centrelines: name -> (x0, x1, z0, z1)
ROOMS = {
    "Reception": (-20, 20, 30, 56),
    "MainLobby": (-30, 30, -8, 30),
    "MissionPreparation": (-20, 20, -40, -8),
    "EquipmentRoom": (-62, -30, 2, 28),
    "BriefingRoom": (30, 52, 6, 26),
    "RestrictedArea": (20, 50, -34, -22),
}
FLOOR = {
    "Reception": ("Slate", (0.30, 0.32, 0.34)),
    "MainLobby": ("Concrete", (0.36, 0.38, 0.40)),
    "MissionPreparation": ("Concrete", (0.30, 0.32, 0.35)),
    "EquipmentRoom": ("DiamondPlate", (0.30, 0.32, 0.35)),
    "BriefingRoom": ("Fabric", (0.18, 0.22, 0.27)),
    "RestrictedArea": ("CorrodedMetal", (0.28, 0.27, 0.26)),
}


def architecture():
    floors, ceilings, walls = [], [], []
    for name, (x0, x1, z0, z1) in ROOMS.items():
        material, rgb = FLOOR[name]
        floors.append(box_min_max(f"Floor_{name}", x0, x1, FY - 1, FY, z0, z1, material=material, rgb=rgb))
        ceilings.append(box_min_max(f"Ceiling_{name}", x0, x1, FY + H, FY + H + 1, z0, z1, rgb=C_CEIL))

    walls += wall("Reception_South", "x", 56, -20, 20, [op(-6, 6, "glass_door")])
    walls += wall("Reception_West", "z", -20, 30, 56)
    walls += wall("Reception_East", "z", 20, 30, 56)
    walls += wall("Lobby_South", "x", 30, -30, 30, [op(-10, 10)])
    walls += wall("Lobby_West", "z", -30, -8, 30, [op(9, 21)])
    walls += wall("Lobby_East", "z", 30, -8, 30, [op(10, 22)])
    walls += wall("Lobby_North", "x", -8, -30, 30, [op(-12, 12)])
    walls += wall("Mission_West", "z", -20, -40, -8)
    walls += wall("Mission_East", "z", 20, -40, -8, [op(-33.5, -28.5, "window", sill=3, top=10)])
    walls += wall("Mission_North", "x", -40, -20, 20)
    walls += wall("Equipment_West", "z", -62, 2, 28)
    walls += wall("Equipment_North", "x", 2, -62, -30)
    walls += wall("Equipment_South", "x", 28, -62, -30)
    walls += wall("Briefing_East", "z", 52, 6, 26)
    walls += wall("Briefing_North", "x", 6, 30, 52)
    walls += wall("Briefing_South", "x", 26, 30, 52)
    walls += wall("Restricted_North", "x", -34, 20, 50)
    walls += wall("Restricted_South", "x", -22, 20, 50)
    walls += wall("Restricted_East", "z", 50, -34, -22)

    ground = [part("Ground", 0, -1.05, 0, 400, 2, 400, material="Slate", rgb=(0.10, 0.11, 0.12))]
    return model([folder("Floors", floors), folder("Walls", walls), folder("Ceilings", ceilings), folder("Exterior", ground)])


def strip(name, x0, x1, z0, z1, rgb):
    return box_min_max(name, x0, x1, FY, FY + 0.06, z0, z1, material="SmoothPlastic", rgb=rgb, collide=False, shadow=False)


def reception():
    furniture, markings, signage = [], [], []
    # Reception desk (west side), outside the central lane.
    furniture.append(box_min_max("Desk_Body", -18, -10, FY, FY + 3.5, 36.5, 39.5, material="Metal", rgb=C_STEEL))
    furniture.append(box_min_max("Desk_Top", -18.3, -9.7, FY + 3.5, FY + 3.8, 36.2, 39.8, material="SmoothPlastic", rgb=C_DARK))
    # Waiting bench along the east wall.
    furniture.append(box_min_max("Bench_Seat", 16.8, 19, FY, FY + 1.2, 35, 43, material="Fabric", rgb=C_FABRIC))
    furniture.append(box_min_max("Bench_Back", 19, 19.4, FY + 1.2, FY + 3.4, 35, 43, material="Fabric", rgb=C_FABRIC))
    # Notice board on the west wall, with a few papers.
    furniture.append(box_min_max("NoticeBoard", -19.5, -19.3, FY + 3, FY + 8, 45, 52, material="Wood", rgb=C_WOOD))
    for index, (z, y, w, h) in enumerate([(46, 7, 1.4, 1.8), (48, 6, 1.6, 1.4), (50.5, 7, 1.4, 1.8), (47.5, 4.2, 1.8, 1.2), (50, 4.6, 1.4, 1.6)], start=1):
        furniture.append(box_min_max(f"NoticePaper{index}", -19.3, -19.25, FY + y - h / 2, FY + y + h / 2, z - w / 2, z + w / 2, material="SmoothPlastic", rgb=C_PAPER, collide=False, shadow=False))
    # Navigation cue: guide line from the spawn toward the lobby.
    markings.append(strip("GuideLine_ToLobby", -0.25, 0.25, 31, 45.6, (0.75, 0.70, 0.35)))
    markings.append(strip("ArrivalPadEdge_North", -7.2, 7.2, 45.8, 46.0, (0.55, 0.58, 0.62)))
    markings.append(strip("ArrivalPadEdge_South", -7.2, 7.2, 54.0, 54.2, (0.55, 0.58, 0.62)))
    # Signage.
    signage.append(sign("Sign_Reception", -19.35, FY + 7, 38, 0.2, 2, 8, "Right", "RECEPTION"))
    signage.append(sign("Sign_ToLobby", 0, FY + 12, 30.6, 10, 2, 0.2, "Back", "MAIN LOBBY"))
    signage.append(sign("Sign_Entrance", 0, FY + 12, 55.4, 12, 2, 0.2, "Front", "ENTRANCE SEALED", text_rgb=(0.80, 0.55, 0.50)))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def main_lobby():
    furniture, markings, signage = [], [], []
    for index, (x, z) in enumerate([(-18, 3), (18, 3), (-18, 25), (18, 25)], start=1):
        furniture.append(box_min_max(f"Pillar{index}", x - 1.2, x + 1.2, FY, FY + H, z - 1.2, z + 1.2, rgb=(0.44, 0.46, 0.49)))
    # South benches against the wall, clear of the doorway.
    for index, x in enumerate([-24, 24], start=1):
        furniture.append(box_min_max(f"SouthBench{index}_Seat", x - 4, x + 4, FY, FY + 1.2, 26.3, 28.5, material="Fabric", rgb=C_FABRIC))
        furniture.append(box_min_max(f"SouthBench{index}_Back", x - 4, x + 4, FY + 1.2, FY + 2.8, 28.5, 28.9, material="Fabric", rgb=C_FABRIC))
    # Waiting clusters in the north-west and north-east corners.
    for side, x in (("West", -24), ("East", 24)):
        furniture.append(box_min_max(f"Waiting{side}_BenchA", x - 4, x + 4, FY, FY + 1.2, -5, -3, material="Fabric", rgb=C_FABRIC))
        furniture.append(box_min_max(f"Waiting{side}_BenchB", x - 4, x + 4, FY, FY + 1.2, 1, 3, material="Fabric", rgb=C_FABRIC))
        furniture.append(box_min_max(f"Waiting{side}_Table", x - 1.5, x + 1.5, FY, FY + 1.1, -2.5, 0.5, material="Metal", rgb=C_STEEL))
    # Navigation cues: guide lines to each destination.
    markings.append(strip("GuideLine_Spine", -0.25, 0.25, 15, 31, (0.75, 0.70, 0.35)))
    markings.append(strip("GuideLine_Mission", -0.25, 0.25, -6, 15, (0.78, 0.60, 0.28)))
    markings.append(strip("GuideLine_Equipment", -28, 0, 14.75, 15.25, (0.35, 0.52, 0.68)))
    markings.append(strip("GuideLine_Briefing", 0, 28, 14.75, 15.25, (0.40, 0.62, 0.50)))
    # Signage: doorway signs (lobby side), directory and a placeholder for future party information.
    signage.append(sign("Sign_Arrival", 0, FY + 12, 29.4, 10, 2, 0.2, "Front", "ARRIVAL"))
    signage.append(sign("Sign_MissionPreparation", 0, FY + 12, -7.4, 18, 2, 0.2, "Back", "MISSION PREPARATION"))
    signage.append(sign("Sign_Equipment", -29.4, FY + 12, 15, 0.2, 2, 10, "Right", "EQUIPMENT"))
    signage.append(sign("Sign_Briefing", 29.4, FY + 12, 16, 0.2, 2, 10, "Left", "BRIEFING"))
    signage.append(sign("Directory", 22, FY + 6.5, 29.4, 10, 5, 0.2, "Front", "FACILITY DIRECTORY\nEQUIPMENT <   ^ MISSION   > BRIEFING"))
    signage.append(sign("PartyInfoPanel", 29.4, FY + 6.5, 0, 0.2, 5, 12, "Left", "PERSONNEL ROSTER\nNO ACTIVE TEAM"))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def mission_preparation():
    furniture, markings, signage = [], [], []
    # Large board wall for the future mission selection UI (north wall).
    furniture.append(box_min_max("BoardFrame", -13, 13, FY + 2, FY + 13, -39.5, -38.9, material="Metal", rgb=C_TRIM))
    furniture.append(sign("BoardScreen", 0, FY + 7.5, -38.8, 24, 9, 0.2, "Back", "MISSION BOARD\nNO ACTIVE ASSIGNMENTS"))
    furniture.append(box_min_max("BoardLedge", -13, 13, FY, FY + 2, -39.5, -38.0, material="Metal", rgb=C_TRIM))
    # Planning table and benches, off the central walking line.
    furniture.append(box_min_max("PlanningTable_Top", -17.5, -11.5, FY + 2.8, FY + 3.2, -18, -14, material="Metal", rgb=C_STEEL))
    for index, (x, z) in enumerate([(-17.2, -17.7), (-11.8, -17.7), (-17.2, -14.3), (-11.8, -14.3)], start=1):
        furniture.append(box_min_max(f"PlanningTable_Leg{index}", x - 0.2, x + 0.2, FY, FY + 2.8, z - 0.2, z + 0.2, material="Metal", rgb=C_TRIM))
    for index, z in enumerate([-30, -22], start=1):
        furniture.append(box_min_max(f"WallBench{index}_Seat", -19.5, -17.5, FY, FY + 1.2, z - 4, z + 4, material="Fabric", rgb=C_FABRIC))
    # Gathering zone in front of the board.
    for name, x0, x1, z0, z1 in [("North", -14, 14, -36.2, -35.8), ("South", -14, 14, -25.2, -24.8), ("West", -14.2, -13.8, -36, -25), ("East", 13.8, 14.2, -36, -25)]:
        markings.append(strip(f"GatherZone_{name}", x0, x1, z0, z1, (0.78, 0.60, 0.28)))
    markings.append(strip("GuideLine_FromLobby", -0.25, 0.25, -24.8, -8.5, (0.78, 0.60, 0.28)))
    signage.append(sign("Sign_ToLobby", 0, FY + 12, -8.6, 12, 2, 0.2, "Front", "MAIN LOBBY"))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def equipment_room():
    furniture, signage, markings = [], [], []
    for index in range(7):
        z = 5.5 + 3.2 * index
        furniture.append(box_min_max(f"Locker{index + 1}_Body", -61.5, -59.5, FY, FY + 7, z - 1.4, z + 1.4, material="Metal", rgb=C_STEEL))
        furniture.append(box_min_max(f"Locker{index + 1}_Door", -59.5, -59.35, FY + 0.5, FY + 6.5, z - 1.1, z + 1.1, material="Metal", rgb=(0.28, 0.32, 0.37), shadow=False))
    for index, x in enumerate([-54, -47, -40], start=1):
        furniture.append(box_min_max(f"Shelf{index}_PostA", x - 3, x - 2.7, FY, FY + 7, 2.5, 3.7, material="Metal", rgb=C_TRIM))
        furniture.append(box_min_max(f"Shelf{index}_PostB", x + 2.7, x + 3, FY, FY + 7, 2.5, 3.7, material="Metal", rgb=C_TRIM))
        for level, height in enumerate([0.5, 2.6, 4.7, 6.8], start=1):
            furniture.append(box_min_max(f"Shelf{index}_Board{level}", x - 2.7, x + 2.7, FY + height, FY + height + 0.3, 2.5, 3.7, material="Metal", rgb=C_STEEL))
        for level, height in enumerate([0.8, 2.9, 5.0], start=1):
            furniture.append(box_min_max(f"Shelf{index}_Crate{level}", x - 1.5 + level * 0.4, x - 0.3 + level * 0.4, FY + height, FY + height + 1.2, 2.8, 3.6, material="CorrodedMetal", rgb=(0.36, 0.33, 0.30)))
    furniture.append(box_min_max("Workbench_Top", -54, -46, FY + 3.2, FY + 3.6, 13.25, 16.75, material="Metal", rgb=C_STEEL))
    for index, (x, z) in enumerate([(-53.6, 13.6), (-46.4, 13.6), (-53.6, 16.4), (-46.4, 16.4)], start=1):
        furniture.append(box_min_max(f"Workbench_Leg{index}", x - 0.2, x + 0.2, FY, FY + 3.2, z - 0.2, z + 0.2, material="Metal", rgb=C_TRIM))
    furniture.append(box_min_max("LoadoutTerminal_Housing", -51, -40, FY, FY + 8, 26.9, 27.5, material="Metal", rgb=C_TRIM))
    furniture.append(sign("LoadoutTerminal_Screen", -45.5, FY + 5, 26.8, 10, 4.5, 0.2, "Front", "LOADOUT\nTERMINAL OFFLINE"))
    signage.append(sign("Sign_ToLobby", -30.6, FY + 12, 15, 0.2, 2, 10, "Left", "MAIN LOBBY"))
    markings.append(strip("GuideLine_FromLobby", -44, -30.5, 14.75, 15.25, (0.35, 0.52, 0.68)))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def briefing_room():
    furniture, signage, markings = [], [], []
    furniture.append(box_min_max("Table_Top", 40, 50, FY + 2.9, FY + 3.3, 14, 18, material="Wood", rgb=C_WOOD))
    for index, (x, z) in enumerate([(40.4, 14.4), (49.6, 14.4), (40.4, 17.6), (49.6, 17.6)], start=1):
        furniture.append(box_min_max(f"Table_Leg{index}", x - 0.2, x + 0.2, FY, FY + 2.9, z - 0.2, z + 0.2, material="Metal", rgb=C_TRIM))
    for side, zc, back_z0, back_z1 in (("North", 12.4, 11.3, 11.7), ("South", 19.6, 20.3, 20.7)):
        for index, x in enumerate([41.5, 44, 46.5, 49], start=1):
            furniture.append(box_min_max(f"Chair{side}{index}_Seat", x - 0.8, x + 0.8, FY + 1.5, FY + 1.8, zc - 0.8, zc + 0.8, material="Fabric", rgb=C_FABRIC))
            furniture.append(box_min_max(f"Chair{side}{index}_Leg", x - 0.2, x + 0.2, FY, FY + 1.5, zc - 0.2, zc + 0.2, material="Metal", rgb=C_TRIM))
            furniture.append(box_min_max(f"Chair{side}{index}_Back", x - 0.8, x + 0.8, FY + 1.8, FY + 3.6, back_z0, back_z1, material="Fabric", rgb=C_FABRIC))
    furniture.append(sign("BriefingDisplay", 51.3, FY + 6.5, 16, 0.2, 6, 12, "Left", "BRIEFING\nNO ACTIVE BRIEFING"))
    signage.append(sign("Sign_ToLobby", 30.6, FY + 12, 16, 0.2, 2, 10, "Right", "MAIN LOBBY"))
    markings.append(strip("GuideLine_FromLobby", 30.5, 38, 15.75, 16.25, (0.40, 0.62, 0.50)))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def restricted_area():
    furniture, signage, markings = [], [], []
    # Door slab and warning sign on the mission room side of the wall (decorative and solid: no access).
    furniture.append(box_min_max("SealedDoor", 19.2, 19.5, FY, FY + 9, -26.5, -22.5, material="Metal", rgb=(0.20, 0.21, 0.23)))
    furniture.append(box_min_max("SealedDoor_Lock", 19.0, 19.2, FY + 4, FY + 5, -25.5, -24.5, material="Metal", rgb=C_RED))
    signage.append(sign("Sign_Restricted", 19.3, FY + 11.2, -24.5, 0.2, 1.6, 6, "Left", "RESTRICTED ACCESS", text_rgb=(0.88, 0.45, 0.40)))
    # Sealed corridor behind the wall (visible through the window, not accessible).
    for index in range(12):
        shade = (0.78, 0.66, 0.16) if index % 2 == 0 else (0.10, 0.10, 0.10)
        markings.append(strip(f"HazardStripe{index + 1}", 23 + index * 2, 25 + index * 2, -29.5, -26.5, shade))
    furniture.append(box_min_max("Crate1", 42.5, 45.5, FY, FY + 3, -33, -30, material="CorrodedMetal", rgb=(0.34, 0.31, 0.28)))
    furniture.append(box_min_max("Crate2", 44, 47, FY, FY + 3, -26.5, -23.5, material="CorrodedMetal", rgb=(0.32, 0.30, 0.27)))
    furniture.append(box_min_max("Crate3", 42.8, 45.2, FY + 3, FY + 5.4, -32.6, -30.4, material="CorrodedMetal", rgb=(0.30, 0.28, 0.26)))
    furniture.append(box_min_max("Barricade", 31.5, 32.1, FY, FY + 4, -33.5, -22.5, material="Metal", rgb=C_TRIM))
    furniture.append(box_min_max("CautionTape_High", 28.9, 29, FY + 4.4, FY + 4.9, -33.5, -22.5, material="SmoothPlastic", rgb=(0.78, 0.66, 0.16), collide=False, shadow=False))
    furniture.append(box_min_max("CautionTape_Low", 28.9, 29, FY + 2.6, FY + 3.1, -33.5, -22.5, material="SmoothPlastic", rgb=(0.78, 0.66, 0.16), collide=False, shadow=False))
    furniture.append(box_min_max("ToppledChair_Seat", 36, 37.6, FY + 0.4, FY + 0.7, -31, -29.4, material="Fabric", rgb=C_FABRIC))
    signage.append(sign("Sign_Sealed", 49.3, FY + 6, -28, 0.2, 3, 8, "Left", "SECTOR 4\nSEALED", text_rgb=(0.88, 0.45, 0.40)))
    return model([folder("Furniture", furniture), folder("Markings", markings), folder("Signage", signage)])


def lighting_fixtures():
    spec = {
        "Reception": [(-10, 36), (10, 36), (-10, 48), (10, 48)],
        "MainLobby": [(-20, 0), (0, 0), (20, 0), (-20, 12), (0, 12), (20, 12), (-20, 24), (0, 24), (20, 24)],
        "MissionPreparation": [(-10, -34), (10, -34), (-10, -22), (10, -22), (0, -14)],
        "EquipmentRoom": [(-54, 8), (-38, 8), (-54, 22), (-38, 22)],
        "BriefingRoom": [(36, 12), (46, 12), (36, 20), (46, 20)],
    }
    groups = []
    for room, points in spec.items():
        groups.append(folder(room, [fixture(f"Fixture{index}", x, z) for index, (x, z) in enumerate(points, start=1)]))
    red = [fixture(f"Fixture{index}", x, z, rgb=(0.80, 0.30, 0.25), light_rgb=(1.0, 0.35, 0.30), brightness=0.6, rng=20) for index, (x, z) in enumerate([(28, -28), (42, -28)], start=1)]
    groups.append(folder("RestrictedArea", red))
    return model(groups)


def spawn_location():
    return {
        "ClassName": "SpawnLocation",
        "Properties": {
            "Size": [14, 1, 8],
            "CFrame": [0, num(FY - 0.48), 50, 1, 0, 0, 0, 1, 0, 0, 0, 1],
            "Anchored": True,
            "Transparency": 1,
            "Neutral": True,
            "AllowTeamChangeOnTouch": False,
            "Duration": 0,
            "Enabled": True,
        },
    }


def dump(path, node):
    text = json.dumps(node, indent=2, ensure_ascii=False)
    # Collapse arrays of plain numbers onto one line to keep the files reviewable.
    text = re.sub(r"\[\s*((?:-?\d+(?:\.\d+)?)(?:\s*,\s*-?\d+(?:\.\d+)?)*)\s*\]", lambda m: "[" + re.sub(r"\s+", " ", m.group(1)) + "]", text)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text + "\n")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    world = os.path.join(os.path.abspath(root), "src", "hub", "world")
    areas = {
        "Architecture": architecture(),
        "Reception": reception(),
        "MainLobby": main_lobby(),
        "MissionPreparation": mission_preparation(),
        "EquipmentRoom": equipment_room(),
        "BriefingRoom": briefing_room(),
        "RestrictedArea": restricted_area(),
        "Lighting": lighting_fixtures(),
    }
    for name, node in areas.items():
        dump(os.path.join(world, "HubEnvironment", f"{name}.model.json"), node)
    dump(os.path.join(world, "SpawnLocation.model.json"), spawn_location())
    print(f"Wrote {len(areas) + 1} files under {world}")


if __name__ == "__main__":
    main()
