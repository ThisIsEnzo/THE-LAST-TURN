#!/usr/bin/env python3
"""Regression tests for the HUB greybox validator (standard library only).

    python3 -m unittest discover -s tools/hub_greybox

The key regression: a route through UNSUPPORTED space (no floor) must not count as walkable. Before the fix the flood fill
only rejected cells occupied by obstacles, so a walled but floorless corridor, or empty space outside the building,
connected rooms that no character could actually cross.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_hub_greybox as v  # noqa: E402

FY = v.FY
WORLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "src", "hub", "world")


def box(name, x0, x1, y0, y1, z0, z1, collide=True, cls="Part"):
    return {"path": "/" + name, "name": name, "box": (x0, x1, y0, y1, z0, z1), "collide": collide, "cls": cls}


def floor(name, x0, x1, z0=0, z1=10):
    return box(name, x0, x1, FY - 1, FY, z0, z1)


def corridor_fixture(floor_a=True, floor_c=True, floor_b=True, extra=()):
    """Three walled zones in a row: A (x 0..10), corridor C (x 10..20), B (x 20..30), joined by 6-stud doorways.
    The corridor is walled and obstacle free, so whether B is reachable depends only on floor support."""
    parts = []
    height = FY + 10
    for name, x in (("WallW", 0), ("WallP1", 10), ("WallP2", 20), ("WallE", 30)):
        if name in ("WallW", "WallE"):
            parts.append(box(name, x - 0.5, x + 0.5, FY, height, -0.5, 10.5))
        else:  # partitions with a doorway at z 2..8
            parts.append(box(name + "_S", x - 0.5, x + 0.5, FY, height, -0.5, 2))
            parts.append(box(name + "_N", x - 0.5, x + 0.5, FY, height, 8, 10.5))
    parts.append(box("WallSouth", -0.5, 30.5, FY, height, -0.5, 0.5))
    parts.append(box("WallNorth", -0.5, 30.5, FY, height, 9.5, 10.5))
    if floor_a:
        parts.append(floor("Floor_A", 0, 10))
    if floor_c:
        parts.append(floor("Floor_C", 10, 20))
    if floor_b:
        parts.append(floor("Floor_B", 20, 30))
    parts.extend(extra)
    return parts


def reaches_b(parts, require_floor=True):
    nav = v.Navigation(parts, (5, 5), require_floor=require_floor)
    return nav.reachable(25, 5)


class FloorSupportRegression(unittest.TestCase):
    def test_baseline_with_floors_everywhere_is_connected(self):
        self.assertTrue(reaches_b(corridor_fixture()))

    def test_route_through_unsupported_space_is_rejected(self):
        parts = corridor_fixture(floor_c=False)
        self.assertFalse(reaches_b(parts), "a floorless corridor must not connect the rooms")

    def test_the_old_behaviour_would_have_accepted_it(self):
        # Proves the regression is meaningful: without the floor requirement the same geometry looks connected.
        parts = corridor_fixture(floor_c=False)
        self.assertTrue(reaches_b(parts, require_floor=False))

    def test_exterior_ground_slab_is_not_a_walking_surface(self):
        ground = box("Ground", -200, 200, -2.05, -0.05, -200, 200)
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[ground])))

    def test_template_baseplate_is_not_a_walking_surface(self):
        baseplate = box("Baseplate", -256, 256, -20, 0, -256, 256)
        lookalike = box("SomeBigSlab", -256, 256, -20, 0, -256, 256)  # excluded by height and size even if renamed
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[baseplate])))
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[lookalike])))

    def test_each_ground_exclusion_rule_works_on_its_own(self):
        # By name: a small slab at floor height that is called Ground.
        by_name = box("Ground", 10, 20, FY - 1, FY, 0, 10)
        # By height: a thick, 150-stud slab whose top is below floor height (the real Ground sits at y = -0.05).
        by_height = box("LowSlab", -70, 80, -3, -0.05, -70, 80)
        # By size: a floor-height slab wider than any room (the template Baseplate is 512 wide).
        by_size = box("HugeSlab", -300, 300, FY - 1, FY, -300, 300)
        for extra in (by_name, by_height, by_size):
            self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[extra])), extra["name"])

    def test_a_non_collidable_slab_is_not_a_walking_surface(self):
        ghost_floor = box("GhostFloor", 10, 20, FY - 1, FY, 0, 10, collide=False)  # thick, floor height, but no collision
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[ghost_floor])))

    def test_walker_needs_support_around_it_not_just_under_its_centre(self):
        # A 1-stud channel between two obstacle blocks, floored by a 2-stud strip whose edge lies under the channel.
        def field(strip_z0):
            return [
                floor("Floor_A", 0, 10, 0, 20),
                floor("Floor_B", 20, 30, 0, 20),
                floor("Floor_Strip", 10, 20, strip_z0, strip_z0 + 2),
                box("Block1", 10, 20, FY, FY + 10, -5, 6.0),
                box("Block2", 10, 20, FY, FY + 10, 9.0, 25),
            ]

        well_supported = v.Navigation(field(7.0), (5, 7.75))
        self.assertTrue(well_supported.reachable(25, 7.75), "a strip centred on the channel carries the walker")
        edge_only = v.Navigation(field(7.5), (5, 7.75))
        self.assertFalse(edge_only.reachable(25, 7.75), "a walker whose centre is within half a stud of the strip edge is not supported")

    def test_thin_markings_are_not_floor_support(self):
        non_collidable_strip = box("Strip", 10, 20, FY, FY + 0.06, 0, 10, collide=False)
        thin_collidable_plate = box("Plate", 10, 20, FY - 0.06, FY, 0, 10)
        slab_too_thin = box("ThinSlab", 10, 20, FY - 0.2, FY, 0, 10)
        for extra in (non_collidable_strip, thin_collidable_plate, slab_too_thin):
            self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[extra])), extra["name"])

    def test_a_walking_surface_must_be_wide_enough(self):
        narrow = floor("Floor_Narrow", 10, 20, 4.25, 5.75)  # 1.5 studs wide
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[narrow])))

    def test_furniture_tops_are_not_floor_support(self):
        tabletop = box("TableTop", 10, 20, FY + 3.2, FY + 3.6, 0, 10)
        self.assertFalse(reaches_b(corridor_fixture(floor_c=False, extra=[tabletop])))

    def test_floors_must_meet_at_the_doorway(self):
        gap = corridor_fixture(floor_c=False, extra=[floor("Floor_C_Short", 10, 18)])  # 2 studs short of B's floor
        self.assertFalse(reaches_b(gap), "a gap at the threshold must block the route")
        contiguous = corridor_fixture(floor_c=False, extra=[floor("Floor_C_Full", 10, 20)])
        self.assertTrue(reaches_b(contiguous))

    def test_a_missing_start_floor_is_reported(self):
        nav = v.Navigation(corridor_fixture(floor_a=False), (5, 5))
        self.assertFalse(nav.supported_at(5, 5))
        self.assertFalse(nav.reachable(5, 5))


class RealGeometry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        v.errors.clear()
        cls.parts, _, _ = v.load(WORLD)

    def test_real_hub_passes_navigation_with_floor_support(self):
        problems, _ = v.check_navigation(self.parts)
        self.assertEqual(problems, [])

    def test_only_the_six_room_floors_support_walking(self):
        names = sorted(p["name"] for p in v.floor_support_parts(self.parts))
        self.assertEqual(names, sorted("Floor_" + n for n in v.ROOM_FLOORS_EXPECTED))
        self.assertIn("Ground", [p["name"] for p in self.parts], "the exterior slab exists but is never a surface")

    def test_doorway_thresholds_are_supported_and_passable(self):
        _, nav = v.check_navigation(self.parts)
        for door, points in v.DOORWAYS.items():
            for x, z in points:
                self.assertTrue(nav.supported_at(x, z), f"{door} {x},{z} unsupported")
                self.assertTrue(nav.reachable(x, z), f"{door} {x},{z} not passable")

    def test_the_restricted_area_has_floor_but_stays_unreachable(self):
        _, nav = v.check_navigation(self.parts)
        for x, z in v.FORBIDDEN["restricted area"]:
            self.assertTrue(nav.supported_at(x, z))
            self.assertFalse(nav.reachable(x, z))

    def test_removing_a_room_floor_is_detected(self):
        without_lobby_floor = [p for p in self.parts if p["name"] != "Floor_MainLobby"]
        problems, _ = v.check_navigation(without_lobby_floor)
        self.assertTrue(any("main lobby" in m for m in problems), problems)
        self.assertTrue(any("mission preparation" in m for m in problems), problems)

    def test_removing_all_floors_is_detected_even_though_ground_remains(self):
        without_floors = [p for p in self.parts if not p["name"].startswith("Floor_")]
        problems, _ = v.check_navigation(without_floors)
        self.assertIn("spawn centre has no floor support", problems)
        # The pre-fix behaviour (no support requirement) saw nothing wrong with the same geometry:
        old_problems, _ = v.check_navigation(without_floors, require_floor=False)
        self.assertFalse(any(m.startswith("not reachable") for m in old_problems), old_problems)


if __name__ == "__main__":
    unittest.main()
