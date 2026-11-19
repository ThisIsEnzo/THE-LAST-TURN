#!/usr/bin/env python3
"""Offline sanity checks for the THE ASYLUM greybox sources (TTL-10). Standard library only.

    python3 tools/asylum_greybox/validate_asylum_greybox.py [repo_root] [--render out.png]

This is NOT a substitute for opening the place in Roblox Studio. It checks:
  1. every model file parses and only uses classes, properties and value shapes documented for Rojo 7 JSON models;
     names are unique among siblings; there are no scripts;
  2. collidable geometry does not overlap accidentally;
  3. a character-sized walker starting on the spawn reaches every room, every doorway threshold and an interaction
     position at every objective anchor, with floor support under every step;
  4. the objective anchors: tag `ObjectivePoint`, attribute `PointId` equal to the part name, PointIds EXACTLY equal to the
     pointIds of src/mission/server/Objective/ObjectiveContent.lua, each inside its intended room, within interaction
     reach of a walkable position, spread over the map and not next to the spawn;
  5. the circulation has real loops, and mission.project.json maps the world into Workspace.
"""
import json
import os
import re
import sys
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asylum_layout as L  # noqa: E402

FY = L.FY
CHAR_RADIUS = 1.0
BODY_BOTTOM = FY + 0.8
BODY_TOP = FY + 5.5
CELL = 0.5
SUPPORT_MIN_TOP = FY - 0.1
SUPPORT_MAX_TOP = FY + 0.5
SUPPORT_MIN_THICKNESS = 0.5
SUPPORT_MARGIN = 0.5
MIN_DOOR_CLEAR = 7.0  # studs; a Roblox character is about 2 studs wide
MIN_SPAWN_DISTANCE = 24.0
MIN_FUSE_SEPARATION = 30.0
MIN_ANCHOR_SPREAD = 40.0  # bounding box of all anchors must exceed this in x AND z (not a line)
REACH_FACTOR = 0.75  # an interaction position must be within this fraction of the configured prompt distance

TAG = "ObjectivePoint"
ATTRIBUTE = "PointId"
EVIDENCE_TAG = "EvidenceSource"
EVIDENCE_ATTRIBUTES = {"EvidenceId", "SourceId"}
EVIDENCE_TAG = "EvidenceSource"
EVIDENCE_ATTRIBUTES = {"EvidenceId", "SourceId"}
SOURCE_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,31}$")

ALLOWED_CLASSES = {"Model", "Folder", "Part", "SpawnLocation", "PointLight"}
ALLOWED_PROPS = {
    "Part": {"Size", "CFrame", "Anchored", "Material", "Color", "CanCollide", "Transparency", "CastShadow", "Tags"},
    "SpawnLocation": {"Size", "CFrame", "Anchored", "Transparency", "Neutral", "AllowTeamChangeOnTouch", "Duration", "Enabled"},
    "PointLight": {"Brightness", "Range", "Color", "Shadows"},
    "Model": set(),
    "Folder": set(),
}
MATERIALS = {"Concrete", "Metal", "Neon", "SmoothPlastic", "Fabric", "DiamondPlate", "Wood", "Slate", "CorrodedMetal"}
IDENTITY = [1, 0, 0, 0, 1, 0, 0, 0, 1]


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


class Report:
    def __init__(self):
        self.errors = []
        self.info = {}

    def fail(self, message):
        self.errors.append(message)


# ---------------------------------------------------------------------------------------------------------------------
# schema and loading
# ---------------------------------------------------------------------------------------------------------------------


def check_node(report, path, node):
    cls = node.get("ClassName")
    if cls not in ALLOWED_CLASSES:
        report.fail(f"{path}: class {cls!r} is not allowed (no scripts or unreviewed classes)")
        return
    props = node.get("Properties", {})
    unknown = set(props) - ALLOWED_PROPS[cls]
    if unknown:
        report.fail(f"{path}: unexpected properties {sorted(unknown)}")
    extra_keys = set(node) - {"Name", "ClassName", "Properties", "Children", "Attributes"}
    if extra_keys:
        report.fail(f"{path}: unexpected keys {sorted(extra_keys)}")
    for key, value in props.items():
        if key == "Size":
            if not (isinstance(value, list) and len(value) == 3 and all(is_num(v) and v > 0 for v in value)):
                report.fail(f"{path}.Size invalid: {value}")
        elif key == "CFrame":
            if not (isinstance(value, list) and len(value) == 12 and all(is_num(v) for v in value)):
                report.fail(f"{path}.CFrame must be a flat list of 12 numbers")
            elif value[3:] != IDENTITY:
                report.fail(f"{path}.CFrame is rotated; the layout is axis aligned only")
        elif key == "Color":
            if not (isinstance(value, list) and len(value) == 3 and all(is_num(v) and 0 <= v <= 1 for v in value)):
                report.fail(f"{path}.Color invalid: {value}")
        elif key == "Material" and value not in MATERIALS:
            report.fail(f"{path}.Material {value!r} unknown")
        elif key == "Tags":
            if value not in ([TAG], [EVIDENCE_TAG]):
                report.fail(f"{path}.Tags must be exactly [{TAG!r}] or [{EVIDENCE_TAG!r}]")
    attributes = node.get("Attributes")
    if attributes is not None:
        if not (isinstance(attributes, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in attributes.items())):
            report.fail(f"{path}.Attributes must be a string-to-string map")
        else:
            keys = set(attributes)
            if keys - ({ATTRIBUTE} | EVIDENCE_ATTRIBUTES):
                report.fail(f"{path}.Attributes: only {ATTRIBUTE}, EvidenceId and SourceId are allowed")
            elif EVIDENCE_ATTRIBUTES & keys and keys != EVIDENCE_ATTRIBUTES:
                report.fail(f"{path}.Attributes: an evidence source needs both EvidenceId and SourceId")
            elif ATTRIBUTE in keys and keys != {ATTRIBUTE}:
                report.fail(f"{path}.Attributes: an objective anchor may only carry {ATTRIBUTE}")
    if cls in ("Part", "SpawnLocation") and props.get("Anchored") is not True:
        report.fail(f"{path}: part is not anchored")


def walk(report, node, path, parts, anchors, sources):
    name = node.get("Name", "")
    here = f"{path}/{name}" if name else path
    check_node(report, here, node)
    children = node.get("Children", [])
    seen = set()
    for child in children:
        child_name = child.get("Name")
        if not child_name:
            report.fail(f"{here}: child without a Name")
            continue
        if child_name in seen:
            report.fail(f"{here}: duplicate sibling name {child_name!r}")
        seen.add(child_name)
    if node.get("ClassName") in ("Part", "SpawnLocation"):
        p = node.get("Properties", {})
        if isinstance(p.get("Size"), list) and isinstance(p.get("CFrame"), list) and len(p["Size"]) == 3 and len(p["CFrame"]) >= 3:
            sx, sy, sz = p["Size"]
            cx, cy, cz = p["CFrame"][:3]
            entry = {
                "path": here,
                "name": name,
                "box": (cx - sx / 2, cx + sx / 2, cy - sy / 2, cy + sy / 2, cz - sz / 2, cz + sz / 2),
                "collide": p.get("CanCollide", True),
                "cls": node["ClassName"],
                "tags": p.get("Tags", []),
                "attributes": node.get("Attributes", {}),
            }
            parts.append(entry)
            if EVIDENCE_TAG in entry["tags"] or EVIDENCE_ATTRIBUTES & set(entry["attributes"]):
                sources.append(entry)
            elif TAG in entry["tags"] or ATTRIBUTE in entry["attributes"]:
                anchors.append(entry)
    for child in children:
        if child.get("Name"):
            walk(report, child, here, parts, anchors, sources)


def load(report, world):
    parts, anchors, sources, files = [], [], [], []
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
            report.fail(f"{rel}: cannot parse: {exc}")
            continue
        stem = os.path.basename(path)[: -len(".model.json")] if path.endswith(".model.json") else os.path.basename(path)
        node = dict(node)
        node.setdefault("Name", stem)
        walk(report, node, "", parts, anchors, sources)
    return parts, anchors, sources, files


# ---------------------------------------------------------------------------------------------------------------------
# overlaps
# ---------------------------------------------------------------------------------------------------------------------


def overlap(a, b, tol=0.02):
    return all(min(a[i + 1], b[i + 1]) - max(a[i], b[i]) > tol for i in (0, 2, 4))


def kind_of(path):
    for token in ("/Walls/", "/Floors/", "/Ceilings/", "/Props/"):
        if token in path:
            return token
    return None


def intentional(a, b):
    ka, kb = kind_of(a["path"]), kind_of(b["path"])
    if ka == "/Walls/" and kb == "/Walls/":
        return True  # wall runs meet at corners and junctions
    if "SpawnLocation" in (a["cls"], b["cls"]) and "/Floors/" in (ka, kb):
        return True  # the spawn pad is embedded flush in the floor
    return False


# ---------------------------------------------------------------------------------------------------------------------
# navigation
# ---------------------------------------------------------------------------------------------------------------------


class Navigation:
    def __init__(self, parts, start):
        floors = [p for p in parts if "/Floors/" in p["path"] and p["collide"]]
        self.rects = []
        for p in floors:
            x0, x1, y0, y1, z0, z1 = p["box"]
            if SUPPORT_MIN_TOP <= y1 <= SUPPORT_MAX_TOP and (y1 - y0) >= SUPPORT_MIN_THICKNESS:
                self.rects.append((x0, x1, z0, z1))
        solids = [p for p in parts if p["collide"] and "/Floors/" not in p["path"] and p["cls"] != "SpawnLocation" and "/Ceilings/" not in p["path"]]
        footprint = [p for p in parts if "/Floors/" in p["path"] or "/Walls/" in p["path"]]
        xs = [p["box"][0] for p in footprint] + [p["box"][1] for p in footprint]
        zs = [p["box"][4] for p in footprint] + [p["box"][5] for p in footprint]
        self.gx0, self.gz0 = min(xs) - 4, min(zs) - 4
        self.nx = int((max(xs) + 4 - self.gx0) / CELL) + 1
        self.nz = int((max(zs) + 4 - self.gz0) / CELL) + 1

        self.blocked = [[False] * self.nz for _ in range(self.nx)]
        for p in solids:
            x0, x1, y0, y1, z0, z1 = p["box"]
            if y1 <= BODY_BOTTOM or y0 >= BODY_TOP:
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
        self.dist = [[-1] * self.nz for _ in range(self.nx)]
        if self.walkable_cell(*self.start):
            queue = deque([self.start])
            self.dist[self.start[0]][self.start[1]] = 0
            while queue:
                x, z = queue.popleft()
                for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    a, b = x + dx, z + dz
                    if 0 <= a < self.nx and 0 <= b < self.nz and self.dist[a][b] < 0 and self.walkable_cell(a, b):
                        self.dist[a][b] = self.dist[x][z] + 1
                        queue.append((a, b))

    def _point_supported(self, x, z):
        return any(x0 <= x <= x1 and z0 <= z <= z1 for x0, x1, z0, z1 in self.rects)

    def cell(self, x, z):
        return int((x - self.gx0) / CELL), int((z - self.gz0) / CELL)

    def centre(self, ix, iz):
        return self.gx0 + (ix + 0.5) * CELL, self.gz0 + (iz + 0.5) * CELL

    def walkable_cell(self, ix, iz):
        return 0 <= ix < self.nx and 0 <= iz < self.nz and not self.blocked[ix][iz] and self.supported[ix][iz]

    def reachable(self, x, z):
        ix, iz = self.cell(x, z)
        return 0 <= ix < self.nx and 0 <= iz < self.nz and self.dist[ix][iz] >= 0

    def supported_at(self, x, z):
        ix, iz = self.cell(x, z)
        return 0 <= ix < self.nx and 0 <= iz < self.nz and self.supported[ix][iz]

    def nearest_reachable_distance(self, x, z, limit):
        """Smallest 2D distance from (x, z) to any reachable cell centre, or None beyond `limit`."""
        best = None
        r = int(limit / CELL) + 1
        cx, cz = self.cell(x, z)
        for ix in range(max(cx - r, 0), min(cx + r + 1, self.nx)):
            for iz in range(max(cz - r, 0), min(cz + r + 1, self.nz)):
                if self.dist[ix][iz] >= 0:
                    px, pz = self.centre(ix, iz)
                    d = ((px - x) ** 2 + (pz - z) ** 2) ** 0.5
                    if d <= limit and (best is None or d < best):
                        best = d
        return best


# ---------------------------------------------------------------------------------------------------------------------
# content / config / project readers
# ---------------------------------------------------------------------------------------------------------------------


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def content_point_ids(root):
    text = read_text(os.path.join(root, "src", "mission", "server", "Objective", "ObjectiveContent.lua"))
    return re.findall(r'slot\(\s*"[A-Z0-9_]+"\s*,\s*"([A-Z0-9_]+)"', text)


def content_evidence_requirements(root):
    text = read_text(os.path.join(root, "src", "mission", "server", "Evidence", "EvidenceContent.lua"))
    pattern = r'evidence\(\s*"([A-Z0-9_]+)"\s*,\s*"[A-Z0-9_]+"\,\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*(\d+)\s*\)'
    return {match[0]: int(match[1]) for match in re.findall(pattern, text)}


def content_signal_objectives(root):
    text = read_text(os.path.join(root, "src", "mission", "server", "Objective", "ObjectiveContent.lua"))
    result = {}
    for objective_id in re.findall(r'id\s*=\s*"([A-Z0-9_]+)"', text):
        match = re.search(r'id\s*=\s*"' + re.escape(objective_id) + r'"[\s\S]{0,1200}?kind\s*=\s*"SIGNAL"[\s\S]{0,400}?sourceToken\s*=\s*"([A-Za-z0-9_-]+)"', text)
        if match:
            result[objective_id] = match.group(1)
    return result


def content_mappings(root):
    text = read_text(os.path.join(root, "src", "mission", "server", "Evidence", "EvidenceObjectiveContent.lua"))
    return re.findall(r'evidenceId\s*=\s*"([A-Z0-9_]+)"\s*,\s*objectiveId\s*=\s*"([A-Z0-9_]+)"\s*,\s*sourceToken\s*=\s*"([A-Za-z0-9_-]+)"', text)


def configured_prompt_distance(root):
    text = read_text(os.path.join(root, "src", "mission", "server", "Objective", "ObjectiveConfig.lua"))
    match = re.search(r"maxDistance\s*=\s*([0-9.]+)", text)
    return float(match.group(1)) if match else None


# ---------------------------------------------------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------------------------------------------------


def region_of(x, z):
    for name in L.REGIONS:
        x0, x1, z0, z1 = L.region_box(name)
        if x0 <= x <= x1 and z0 <= z <= z1:
            return name
    return None


def validate(root, report=None):
    report = report or Report()
    world = os.path.join(root, "src", "mission", "world")
    parts, anchors, sources, files = load(report, world)
    report.info["files"] = len(files)
    report.info["parts"] = len(parts)
    if not parts:
        report.fail("no geometry found under src/mission/world")
        return report

    # 1. overlaps
    solids = [p for p in parts if p["collide"]]
    flagged = 0
    for i in range(len(solids)):
        for j in range(i + 1, len(solids)):
            a, b = solids[i], solids[j]
            if overlap(a["box"], b["box"]) and not intentional(a, b):
                flagged += 1
                if flagged <= 25:
                    report.fail(f"overlap: {a['path']}  x  {b['path']}")
    if flagged > 25:
        report.fail(f"... and {flagged - 25} more overlaps")

    # 2. spawn
    pads = [p for p in parts if p["cls"] == "SpawnLocation"]
    if len(pads) != 1:
        report.fail(f"expected exactly one SpawnLocation, found {len(pads)}")
        spawn_xz = (L.SPAWN["x"], L.SPAWN["z"])
    else:
        pad = pads[0]
        x0, x1, y0, y1, z0, z1 = pad["box"]
        spawn_xz = ((x0 + x1) / 2, (z0 + z1) / 2)
        if abs(y1 - (FY + 0.02)) > 0.011:
            report.fail(f"spawn pad top is {y1}, expected {FY + 0.02} (flush with the floor)")
        if region_of(*spawn_xz) != L.SPAWN["region"]:
            report.fail(f"spawn is not inside {L.SPAWN['region']}")
        rx0, rx1, rz0, rz1 = L.region_box(L.SPAWN["region"])
        if not (rx0 + 2 <= x0 and x1 <= rx1 - 2 and rz0 + 2 <= z0 and z1 <= rz1 - 2):
            report.fail("spawn pad is too close to the lobby walls (needs 2 studs of clearance)")

    nav = Navigation(parts, spawn_xz)
    if nav.blocked[nav.start[0]][nav.start[1]]:
        report.fail("spawn centre is inside geometry")
    elif not nav.supported_at(*spawn_xz):
        report.fail("spawn centre has no floor support")
    if pads:
        x0, x1, _, _, z0, z1 = pads[0]["box"]
        for fx in (0.15, 0.5, 0.85):
            for fz in (0.15, 0.5, 0.85):
                if not nav.reachable(x0 + (x1 - x0) * fx, z0 + (z1 - z0) * fz):
                    report.fail("the spawn pad is not free of obstacles / not connected to the map")
                    break

    # 3. rooms and doorways
    for name in L.REGIONS:
        x0, x1, z0, z1 = L.region_box(name)
        total = reach = 0
        for ix in range(nav.nx):
            for iz in range(nav.nz):
                px, pz = nav.centre(ix, iz)
                if x0 + 1.5 <= px <= x1 - 1.5 and z0 + 1.5 <= pz <= z1 - 1.5:
                    if nav.walkable_cell(ix, iz):
                        total += 1
                    if nav.dist[ix][iz] >= 0:
                        reach += 1
        if reach == 0:
            report.fail(f"room not reachable from the spawn: {name}")
        elif total and reach < 0.3 * (x1 - x0 - 3) * (z1 - z0 - 3) / (CELL * CELL):
            report.fail(f"room mostly blocked: {name} ({reach} reachable cells)")
    for door in L.DOORS:
        x, z, orientation = L.door_threshold(door)
        _, _, start, count = door
        clear = count * L.TILE - L.WALL_T
        if clear < MIN_DOOR_CLEAR:
            report.fail(f"doorway too narrow: {door[0]} <-> {door[1]} ({clear} studs)")
        half = (count * L.TILE) / 2 - 2.0
        for offset in (-half, 0.0, half):
            px, pz = (x, z + offset) if orientation == "V" else (x + offset, z)
            if not nav.supported_at(px, pz):
                report.fail(f"doorway has no floor support: {door[0]} <-> {door[1]} at ({px}, {pz})")
            elif not nav.reachable(px, pz):
                report.fail(f"doorway not passable: {door[0]} <-> {door[1]} at ({px}, {pz})")

    # 4. loops in the circulation (the map is not a tree)
    names = list(L.REGIONS)
    edges = {frozenset((a, b)) for a, b, _, _ in L.DOORS}
    parent = {n: n for n in names}

    def find(n):
        while parent[n] != n:
            parent[n] = parent[parent[n]]
            n = parent[n]
        return n

    for edge in edges:
        a, b = tuple(edge)
        parent[find(a)] = find(b)
    components = len({find(n) for n in names})
    cycles = len(edges) - len(names) + components
    report.info["rooms"] = len(names)
    report.info["doorways"] = len(L.DOORS)
    report.info["independent loops"] = cycles
    if components != 1:
        report.fail(f"the room graph has {components} disconnected parts")
    if cycles < 2:
        report.fail(f"expected at least 2 independent loops in the room graph, found {cycles}")

    # 5. objective anchors
    by_id = {}
    for entry in anchors:
        by_id.setdefault(entry["attributes"].get(ATTRIBUTE), []).append(entry)
    content_ids = content_point_ids(root)
    if len(content_ids) != len(set(content_ids)):
        report.fail("ObjectiveContent has duplicate pointIds")
    if not content_ids:
        report.fail("could not read any pointId from ObjectiveContent.lua")
    for entry in anchors:
        pid = entry["attributes"].get(ATTRIBUTE)
        if TAG not in entry["tags"]:
            report.fail(f"anchor {entry['path']}: missing tag {TAG}")
        if pid is None:
            report.fail(f"anchor {entry['path']}: missing attribute {ATTRIBUTE}")
        elif entry["name"] != pid:
            report.fail(f"anchor {entry['path']}: part name must equal its {ATTRIBUTE} ({pid})")
        if entry["collide"] is not False:
            report.fail(f"anchor {entry['path']}: must be non-collidable")
    for pid, entries in by_id.items():
        if pid is not None and len(entries) > 1:
            report.fail(f"duplicate PointId {pid}: {len(entries)} anchors")
    found = {pid for pid in by_id if pid is not None}
    for pid in content_ids:
        if pid not in found:
            report.fail(f"objective pointId {pid} has no authored anchor")
    for pid in sorted(found - set(content_ids)):
        report.fail(f"anchor {pid} matches no objective pointId in ObjectiveContent.lua")
    if set(L.ANCHORS) != set(content_ids):
        report.fail("asylum_layout.ANCHORS does not match the objective content pointIds")

    prompt = configured_prompt_distance(root)
    if prompt is None:
        report.fail("could not read interaction.maxDistance from ObjectiveConfig.lua")
        prompt = 8.0
    reach_limit = prompt * REACH_FACTOR
    centres = {}
    for pid, entries in by_id.items():
        if pid is None or len(entries) != 1:
            continue
        x0, x1, y0, y1, z0, z1 = entries[0]["box"]
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        centres[pid] = (cx, cz)
        expected = L.ANCHORS.get(pid)
        if expected is not None:
            room = region_of(cx, cz)
            if room != expected[0]:
                report.fail(f"anchor {pid} is in {room}, expected {expected[0]}")
        if y1 - y0 < 2 or y0 < FY or y1 > FY + 9:
            report.fail(f"anchor {pid} is not at a usable height")
        gap = nav.nearest_reachable_distance(cx, cz, reach_limit)
        if gap is None:
            report.fail(f"anchor {pid}: no walkable position within {reach_limit} studs (prompt distance {prompt})")
        distance_to_spawn = ((cx - spawn_xz[0]) ** 2 + (cz - spawn_xz[1]) ** 2) ** 0.5
        if distance_to_spawn < MIN_SPAWN_DISTANCE:
            report.fail(f"anchor {pid} is only {distance_to_spawn:.0f} studs from the spawn (minimum {MIN_SPAWN_DISTANCE})")
    fuses = [pid for pid in centres if pid.startswith("POWER_FUSE_")]
    for i in range(len(fuses)):
        for j in range(i + 1, len(fuses)):
            a, b = centres[fuses[i]], centres[fuses[j]]
            if ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5 < MIN_FUSE_SEPARATION:
                report.fail(f"{fuses[i]} and {fuses[j]} are too close together")
    if len(centres) >= 3:
        xs = [c[0] for c in centres.values()]
        zs = [c[1] for c in centres.values()]
        if max(xs) - min(xs) < MIN_ANCHOR_SPREAD or max(zs) - min(zs) < MIN_ANCHOR_SPREAD:
            report.fail("objective anchors are not spread over the map (they form a line or a cluster)")
    # Route lengths (information only): walking distance from the spawn to each anchor, in studs.
    lengths = {}
    for pid, (cx, cz) in centres.items():
        best = None
        for ix in range(nav.nx):
            for iz in range(nav.nz):
                if nav.dist[ix][iz] >= 0:
                    px, pz = nav.centre(ix, iz)
                    if ((px - cx) ** 2 + (pz - cz) ** 2) ** 0.5 <= reach_limit and (best is None or nav.dist[ix][iz] < best):
                        best = nav.dist[ix][iz]
        if best is not None:
            lengths[pid] = round(best * CELL)
    report.info["walk distance spawn -> anchor (studs, grid path)"] = dict(sorted(lengths.items()))


    # 5b. authored evidence sources (TTL-11D)
    requirements = content_evidence_requirements(root)
    if not requirements:
        report.fail("could not read any evidence definition from EvidenceContent.lua")
    seen_sources = {}
    per_evidence = {}
    for entry in sources:
        attrs = entry["attributes"]
        evidence_id, source_id = attrs.get("EvidenceId"), attrs.get("SourceId")
        if EVIDENCE_TAG not in entry["tags"]:
            report.fail(f"evidence source {entry['path']}: missing tag {EVIDENCE_TAG}")
        if not evidence_id or not SOURCE_ID_PATTERN.fullmatch(evidence_id):
            report.fail(f"evidence source {entry['path']}: missing or invalid EvidenceId")
        if not source_id or not SOURCE_ID_PATTERN.fullmatch(source_id):
            report.fail(f"evidence source {entry['path']}: missing or invalid SourceId")
        if source_id and entry["name"] != source_id:
            report.fail(f"evidence source {entry['path']}: part name must equal its SourceId ({source_id})")
        if entry["collide"] is not False:
            report.fail(f"evidence source {entry['path']}: must be non-collidable")
        if evidence_id and evidence_id not in requirements:
            report.fail(f"evidence source {entry['path']}: EvidenceId {evidence_id} is not in EvidenceContent.lua")
        if source_id:
            if source_id in seen_sources:
                report.fail(f"duplicate SourceId {source_id}")
            seen_sources[source_id] = entry
        if evidence_id and source_id and evidence_id in requirements:
            per_evidence.setdefault(evidence_id, []).append(entry)
    for evidence_id, entries in sorted(per_evidence.items()):
        for entry in entries:
            x0, x1, _, _, z0, z1 = entry["box"]
            cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
            source_id = entry["attributes"].get("SourceId")
            expected = L.EVIDENCE_SOURCES.get(source_id)
            if expected and region_of(cx, cz) != expected[1]:
                report.fail(f"evidence source {source_id} is in {region_of(cx, cz)}, expected {expected[1]}")
            if nav.nearest_reachable_distance(cx, cz, reach_limit) is None:
                report.fail(f"evidence source {source_id}: no walkable interaction position within {reach_limit} studs")
        for i in range(len(entries)):
            for j in range(i + 1, len(entries)):
                a, b = entries[i]["box"], entries[j]["box"]
                ax, az = (a[0] + a[1]) / 2, (a[4] + a[5]) / 2
                bx, bz = (b[0] + b[1]) / 2, (b[4] + b[5]) / 2
                distance = ((ax - bx) ** 2 + (az - bz) ** 2) ** 0.5
                if distance < L.MIN_SOURCE_SEPARATION:
                    report.fail(f"evidence {evidence_id}: sources are closer than {L.MIN_SOURCE_SEPARATION} studs")
    if set(L.EVIDENCE_SOURCES) != set(seen_sources):
        report.fail("asylum_layout.EVIDENCE_SOURCES does not match the authored evidence sources")
    report.info["evidence sources"] = len(sources)

    # 5c. evidence -> SIGNAL objective mapping consistency
    signal_objectives = content_signal_objectives(root)
    for evidence_id, objective_id, token in content_mappings(root):
        if evidence_id not in requirements:
            report.fail(f"mapping {evidence_id} -> {objective_id}: evidence id is not in EvidenceContent.lua")
        if objective_id not in signal_objectives:
            report.fail(f"mapping {evidence_id} -> {objective_id}: objective is not a SIGNAL objective in ObjectiveContent.lua")
        elif signal_objectives[objective_id] != token:
            report.fail(f"mapping {evidence_id} -> {objective_id}: sourceToken does not match the objective's configured token")
        if len(per_evidence.get(evidence_id, [])) < requirements.get(evidence_id, 1):
            report.fail(f"mapping {evidence_id} -> {objective_id}: evidence cannot be CONFIRMED with the authored sources")

    # 5b. authored evidence source validation (TTL-11D)
    evidence_text = read_text(os.path.join(root, "src", "mission", "server", "Evidence", "EvidenceContent.lua"))
    required_counts = {m[0]: int(m[1]) for m in re.findall(r'evidence\(\s*"([A-Z0-9_]+)"\s*,\s*"[A-Z0-9_]+"\s*,\s*"[^"]*"\s*,\s*"[^"]*"\s*,\s*(\d+)\s*\)', evidence_text)}
    seen_source_ids = set()
    counts_by_evidence = {}
    for source in sources:
        attrs = source["attributes"]
        evidence_id, source_id = attrs.get("EvidenceId"), attrs.get("SourceId")
        if EVIDENCE_TAG not in source["tags"]: report.fail(f"evidence source {source['path']}: missing tag {EVIDENCE_TAG}")
        if not evidence_id or evidence_id not in required_counts: report.fail(f"evidence source {source['path']}: unknown or missing EvidenceId {evidence_id}")
        if not source_id or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,31}", source_id): report.fail(f"evidence source {source['path']}: invalid or missing SourceId")
        if source_id and source["name"] != source_id: report.fail(f"evidence source {source['path']}: part name must equal SourceId")
        if source_id in seen_source_ids: report.fail(f"duplicate SourceId {source_id}")
        if source_id: seen_source_ids.add(source_id)
        if source["collide"] is not False: report.fail(f"evidence source {source['path']}: must be non-collidable")
        if evidence_id in required_counts: counts_by_evidence[evidence_id] = counts_by_evidence.get(evidence_id, 0) + 1
        if evidence_id and source_id:
            expected = L.EVIDENCE_SOURCES.get(source_id)
            x0, x1, _, _, z0, z1 = source["box"]
            cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
            if expected and region_of(cx, cz) != expected[1]: report.fail(f"evidence source {source_id}: expected room {expected[1]}")
            if nav.nearest_reachable_distance(cx, cz, reach_limit) is None: report.fail(f"evidence source {source_id}: no reachable interaction position")
    mapping_text = read_text(os.path.join(root, "src", "mission", "server", "Evidence", "EvidenceObjectiveContent.lua"))
    mapped_evidence_ids = set(re.findall(r'evidenceId\s*=\s*"([A-Z0-9_]+)"', mapping_text))
    for evidence_id in sorted(mapped_evidence_ids):
        required = required_counts.get(evidence_id)
        if required is None:
            report.fail(f"evidence mapping references unknown catalog id {evidence_id}")
        elif counts_by_evidence.get(evidence_id, 0) < required:
            report.fail(f"evidence {evidence_id} needs {required} distinct authored sources but only {counts_by_evidence.get(evidence_id, 0)} exist")
    if set(L.EVIDENCE_SOURCES) != seen_source_ids: report.fail("asylum_layout.EVIDENCE_SOURCES does not match authored evidence SourceIds")
    report.info["evidence sources"] = len(sources)

    # 6. Rojo mapping
    try:
        project = json.loads(read_text(os.path.join(root, "mission.project.json")))
        workspace = project["tree"]["Workspace"]
        if workspace.get("$path") != "src/mission/world":
            report.fail("mission.project.json: Workspace must map to src/mission/world")
        if workspace.get("$ignoreUnknownInstances") is not True:
            report.fail("mission.project.json: Workspace must set $ignoreUnknownInstances")
    except Exception as exc:  # noqa: BLE001
        report.fail(f"mission.project.json: cannot verify the Workspace mapping: {exc}")

    report.info["walkable cells"] = sum(1 for x in range(nav.nx) for z in range(nav.nz) if nav.dist[x][z] >= 0)
    report.nav = nav
    report.parts = parts
    return report


def render(report, path, spawn=(L.SPAWN["x"], L.SPAWN["z"])):
    from PIL import Image, ImageDraw

    nav = report.nav
    px = 6
    img = Image.new("RGB", (nav.nx * px + 1, nav.nz * px + 1), (20, 22, 26))
    draw = ImageDraw.Draw(img)
    for x in range(nav.nx):
        for z in range(nav.nz):
            if nav.dist[x][z] >= 0:
                draw.rectangle([x * px, z * px, (x + 1) * px, (z + 1) * px], fill=(48, 74, 92))
    for p in report.parts:
        x0, x1, y0, y1, z0, z1 = p["box"]
        if "/Walls/" in p["path"] or "/Props/" in p["path"]:
            draw.rectangle([(x0 - nav.gx0) / CELL * px, (z0 - nav.gz0) / CELL * px, (x1 - nav.gx0) / CELL * px, (z1 - nav.gz0) / CELL * px], fill=(190, 190, 200))
        if TAG in p["tags"]:
            cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
            sx, sz = (cx - nav.gx0) / CELL * px, (cz - nav.gz0) / CELL * px
            draw.ellipse([sx - 5, sz - 5, sx + 5, sz + 5], fill=(230, 160, 50))
    sx, sz = nav.cell(*spawn)
    draw.ellipse([sx * px - 5, sz * px - 5, sx * px + 5, sz * px + 5], fill=(240, 240, 90))
    img.save(path)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = None
    if "--render" in sys.argv:
        out = sys.argv[sys.argv.index("--render") + 1]
        args = [a for a in args if a != out]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    report = validate(root)
    for key, value in report.info.items():
        print(f"{key}: {value}")
    if out and hasattr(report, "nav"):
        render(report, out)
        print(f"rendered {out}")
    if report.errors:
        print(f"\n{len(report.errors)} problem(s):")
        for message in report.errors:
            print("  -", message)
        sys.exit(1)
    print("OK: schema, naming, overlap, navigation, doorway, loop and objective anchor checks passed")


if __name__ == "__main__":
    main()
