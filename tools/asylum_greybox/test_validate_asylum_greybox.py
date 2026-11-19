"""Regression tests for the THE ASYLUM greybox validator and generator (TTL-10). Standard library only.

    python3 -m unittest discover -s tools/asylum_greybox -p "test_*.py" -v

Each test copies the few files the validator reads into a temporary tree, breaks one thing, and expects the validator to
notice. The pristine repository must pass.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import asylum_layout as L  # noqa: E402
import generate_asylum_greybox as G  # noqa: E402
import validate_asylum_greybox as V  # noqa: E402

COPIED = [
    "mission.project.json",
    os.path.join("src", "mission", "server", "Objective", "ObjectiveContent.lua"),
    os.path.join("src", "mission", "server", "Objective", "ObjectiveConfig.lua"),
    os.path.join("src", "mission", "server", "Evidence", "EvidenceContent.lua"),
    os.path.join("src", "mission", "server", "Evidence", "EvidenceObjectiveContent.lua"),
]


def make_tree():
    tmp = tempfile.mkdtemp(prefix="asylum_")
    for rel in COPIED:
        dest = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), dest)
    shutil.copytree(os.path.join(ROOT, "src", "mission", "world"), os.path.join(tmp, "src", "mission", "world"))
    return tmp


def world_path(tmp, *parts):
    return os.path.join(tmp, "src", "mission", "world", *parts)


def edit_json(path, mutate):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    mutate(data)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)


def find_child(node, name):
    for child in node.get("Children", []):
        if child.get("Name") == name:
            return child
    raise KeyError(name)


def problems(tmp):
    return V.validate(tmp).errors


class AsylumGreyboxTests(unittest.TestCase):
    def setUp(self):
        self.tmp = make_tree()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def assertProblem(self, fragment):
        errors = problems(self.tmp)
        self.assertTrue(any(fragment in e for e in errors), f"expected a problem containing {fragment!r}, got {errors}")

    # baseline ------------------------------------------------------------------------------------------------------

    def test_repository_passes(self):
        report = V.validate(ROOT)
        self.assertEqual(report.errors, [])
        self.assertEqual(report.info["rooms"], len(L.REGIONS))
        self.assertGreaterEqual(report.info["independent loops"], 2)

    def test_generated_files_are_up_to_date(self):
        expected = {
            os.path.join("SpawnLocation.model.json"): G.build_spawn(),
            os.path.join("AsylumMap", "Architecture.model.json"): G.build_architecture(),
            os.path.join("AsylumMap", "Lighting.model.json"): G.build_lamps(),
            os.path.join("AsylumMap", "Props.model.json"): G.build_props(),
            os.path.join("AsylumMap", "ObjectiveAnchors.model.json"): G.build_anchors(),
            os.path.join("AsylumMap", "EvidenceSources.model.json"): G.build_evidence_sources(),
        }
        for rel, node in expected.items():
            with open(os.path.join(ROOT, "src", "mission", "world", rel), encoding="utf-8") as handle:
                self.assertEqual(json.load(handle), node, f"{rel} is stale: run generate_asylum_greybox.py")

    def test_layout_regions_are_disjoint(self):
        names = list(L.REGIONS)
        for i, a in enumerate(names):
            for b in names[i + 1 :]:
                ra, rb = L.REGIONS[a], L.REGIONS[b]
                separated = ra[2] <= rb[0] or rb[2] <= ra[0] or ra[3] <= rb[1] or rb[3] <= ra[1]
                self.assertTrue(separated, f"{a} overlaps {b}")

    def test_no_runtime_fixture_remains_in_server_sources(self):
        for base, _, names in os.walk(os.path.join(ROOT, "src")):
            for name in names:
                if name.endswith(".lua"):
                    with open(os.path.join(base, name), encoding="utf-8") as handle:
                        text = handle.read()
                    self.assertNotIn("ObjectiveFixture", text, f"{name} still references the runtime objective fixture")

    # geometry ------------------------------------------------------------------------------------------------------

    def test_blocked_doorway_is_detected(self):
        def mutate(data):
            walls = find_child(data, "Walls")
            x, z, orientation = L.door_threshold(L.DOORS[0])
            walls["Children"].append(
                {
                    "Name": "Plug",
                    "ClassName": "Part",
                    "Properties": {"Size": [14, 12, 2], "CFrame": [x, 7, z] + [1, 0, 0, 0, 1, 0, 0, 0, 1], "Anchored": True, "Material": "Concrete", "Color": [0.5, 0.5, 0.5]},
                }
            )

        edit_json(world_path(self.tmp, "AsylumMap", "Architecture.model.json"), mutate)
        self.assertProblem("not passable")

    def test_sealed_room_is_detected(self):
        def mutate(data):
            walls = find_child(data, "Walls")
            x0, x1, z0, z1 = L.region_box("StorageRoom")
            walls["Children"].append(
                {
                    "Name": "Seal",
                    "ClassName": "Part",
                    "Properties": {"Size": [60, 12, 1], "CFrame": [(x0 + x1) / 2, 7, z0 + 0.5] + [1, 0, 0, 0, 1, 0, 0, 0, 1], "Anchored": True, "Material": "Concrete", "Color": [0.5, 0.5, 0.5]},
                }
            )

        edit_json(world_path(self.tmp, "AsylumMap", "Architecture.model.json"), mutate)
        errors = problems(self.tmp)
        self.assertTrue(any("not passable" in e or "not reachable" in e or "mostly blocked" in e for e in errors), errors)

    def test_overlapping_prop_is_detected(self):
        def mutate(data):
            props = find_child(data, "Props")
            first = props["Children"][0]
            clone = json.loads(json.dumps(first))
            clone["Name"] = "Clone"
            props["Children"].append(clone)

        edit_json(world_path(self.tmp, "AsylumMap", "Props.model.json"), mutate)
        self.assertProblem("overlap")

    def test_unanchored_part_and_scripts_are_rejected(self):
        def mutate(data):
            props = find_child(data, "Props")
            props["Children"][0]["Properties"]["Anchored"] = False
            props["Children"].append({"Name": "Evil", "ClassName": "Script"})

        edit_json(world_path(self.tmp, "AsylumMap", "Props.model.json"), mutate)
        errors = problems(self.tmp)
        self.assertTrue(any("not anchored" in e for e in errors))
        self.assertTrue(any("not allowed" in e for e in errors))

    def test_duplicate_sibling_names_are_rejected(self):
        def mutate(data):
            props = find_child(data, "Props")
            props["Children"][1]["Name"] = props["Children"][0]["Name"]

        edit_json(world_path(self.tmp, "AsylumMap", "Props.model.json"), mutate)
        self.assertProblem("duplicate sibling name")

    def test_spawn_outside_the_lobby_is_detected(self):
        def mutate(data):
            data["Properties"]["CFrame"][0] = 40.0

        edit_json(world_path(self.tmp, "SpawnLocation.model.json"), mutate)
        self.assertProblem("spawn")

    def test_second_spawn_is_detected(self):
        shutil.copy(world_path(self.tmp, "SpawnLocation.model.json"), world_path(self.tmp, "SecondSpawn.model.json"))
        self.assertProblem("exactly one SpawnLocation")

    # anchors -------------------------------------------------------------------------------------------------------

    def anchors_path(self):
        return world_path(self.tmp, "AsylumMap", "ObjectiveAnchors.model.json")

    def test_missing_anchor_is_detected(self):
        edit_json(self.anchors_path(), lambda d: d["Children"].pop(0))
        self.assertProblem("has no authored anchor")

    def test_unknown_anchor_is_detected(self):
        def mutate(data):
            extra = json.loads(json.dumps(data["Children"][0]))
            extra["Name"] = "SURPRISE_POINT"
            extra["Attributes"]["PointId"] = "SURPRISE_POINT"
            extra["Properties"]["CFrame"][0] += 3
            data["Children"].append(extra)

        edit_json(self.anchors_path(), mutate)
        self.assertProblem("matches no objective pointId")

    def test_wrong_point_id_attribute_is_detected(self):
        edit_json(self.anchors_path(), lambda d: d["Children"][0]["Attributes"].update({"PointId": "WRONG_ID"}))
        errors = problems(self.tmp)
        self.assertTrue(any("must equal its PointId" in e for e in errors))
        self.assertTrue(any("has no authored anchor" in e for e in errors))

    def test_missing_tag_and_attribute_are_detected(self):
        def mutate(data):
            del data["Children"][0]["Properties"]["Tags"]
            del data["Children"][1]["Attributes"]

        edit_json(self.anchors_path(), mutate)
        errors = problems(self.tmp)
        self.assertTrue(any("missing tag" in e for e in errors) or any("has no authored anchor" in e for e in errors), errors)

    def test_wrong_tag_is_detected(self):
        edit_json(self.anchors_path(), lambda d: d["Children"][0]["Properties"].update({"Tags": ["Other"]}))
        self.assertProblem("Tags must be exactly")

    def test_duplicate_point_id_is_detected(self):
        def mutate(data):
            clone = json.loads(json.dumps(data["Children"][0]))
            clone["Name"] = "DUPLICATE"
            clone["Properties"]["CFrame"][2] += 4
            data["Children"].append(clone)

        edit_json(self.anchors_path(), mutate)
        self.assertProblem("duplicate PointId")

    def test_anchor_in_the_wrong_room_is_detected(self):
        def mutate(data):
            node = next(c for c in data["Children"] if c["Name"] == "POWER_FUSE_A")
            node["Properties"]["CFrame"][0] = -58.8
            node["Properties"]["CFrame"][2] = 28.0

        edit_json(self.anchors_path(), mutate)
        self.assertProblem("expected UtilityRoom")

    def test_anchor_next_to_the_spawn_is_detected(self):
        def mutate(data):
            node = next(c for c in data["Children"] if c["Name"] == "POWER_FUSE_A")
            node["Properties"]["CFrame"][0] = 3.0
            node["Properties"]["CFrame"][2] = 40.0

        edit_json(self.anchors_path(), mutate)
        errors = problems(self.tmp)
        self.assertTrue(any("from the spawn" in e for e in errors), errors)

    def test_anchor_out_of_reach_is_detected(self):
        def mutate(data):
            node = next(c for c in data["Children"] if c["Name"] == "EXTRACTION_POINT")
            node["Properties"]["CFrame"][1] = 4.5
            node["Properties"]["CFrame"][0] = 70.0  # outside the building, beyond the wall

        edit_json(self.anchors_path(), mutate)
        errors = problems(self.tmp)
        self.assertTrue(any("no walkable position" in e or "expected LoadingDock" in e for e in errors), errors)

    def test_collidable_anchor_is_rejected(self):
        edit_json(self.anchors_path(), lambda d: d["Children"][0]["Properties"].pop("CanCollide"))
        self.assertProblem("must be non-collidable")

    def test_content_and_layout_disagreement_is_detected(self):
        path = os.path.join(self.tmp, "src", "mission", "server", "Objective", "ObjectiveContent.lua")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace('"RECORDS_CABINET", "Records cabinet"', '"RECORDS_CABINET_2", "Records cabinet"'))
        errors = problems(self.tmp)
        self.assertTrue(any("RECORDS_CABINET_2" in e and "no authored anchor" in e for e in errors), errors)
        self.assertTrue(any("matches no objective pointId" in e for e in errors), errors)

    # evidence sources ----------------------------------------------------------------------------------------------

    def evidence_sources_path(self):
        return world_path(self.tmp, "AsylumMap", "EvidenceSources.model.json")

    def test_missing_evidence_source_is_detected(self):
        edit_json(self.evidence_sources_path(), lambda data: data["Children"].pop(0))
        self.assertProblem("cannot be CONFIRMED")

    def test_missing_evidence_tag_is_detected(self):
        edit_json(self.evidence_sources_path(), lambda data: data["Children"][0]["Properties"].pop("Tags"))
        self.assertProblem("missing tag EvidenceSource")

    def test_unknown_evidence_id_is_detected(self):
        edit_json(self.evidence_sources_path(), lambda data: data["Children"][0]["Attributes"].update({"EvidenceId": "NOT_REAL"}))
        self.assertProblem("is not in EvidenceContent.lua")

    def test_duplicate_source_id_is_detected(self):
        def mutate(data):
            clone = json.loads(json.dumps(data["Children"][0]))
            clone["Properties"]["CFrame"][0] -= 4
            data["Children"].append(clone)
        edit_json(self.evidence_sources_path(), mutate)
        self.assertProblem("duplicate SourceId")

    def test_collidable_evidence_source_is_rejected(self):
        edit_json(self.evidence_sources_path(), lambda data: data["Children"][0]["Properties"].pop("CanCollide"))
        self.assertProblem("must be non-collidable")

    # structure -----------------------------------------------------------------------------------------------------

    def test_a_tree_shaped_room_graph_is_rejected(self):
        original = list(L.DOORS)
        parent = {name: name for name in L.REGIONS}

        def find(n):
            while parent[n] != n:
                n = parent[n]
            return n

        tree = []
        for door in original:  # keep only a spanning tree of the doorways: no loops left
            ra, rb = find(door[0]), find(door[1])
            if ra != rb:
                parent[ra] = rb
                tree.append(door)
        try:
            L.DOORS[:] = tree
            report = V.validate(ROOT)
        finally:
            L.DOORS[:] = original
        self.assertTrue(any("independent loops" in e for e in report.errors), report.errors)

    def test_workspace_mapping_is_required(self):
        path = os.path.join(self.tmp, "mission.project.json")
        edit_json(path, lambda d: d["tree"].pop("Workspace"))
        self.assertProblem("Workspace")


if __name__ == "__main__":
    unittest.main()
