"""Single source of truth for the THE ASYLUM greybox layout (TTL-10). Standard library only.

Everything is axis aligned and expressed on a 4-stud tile grid; world coordinates are derived (x east, z south, so
north is -z and the SpawnLocation faces -z by default). Both the generator and the validator import this module, but the
validator checks the GENERATED JSON geometry independently (parsed from src/mission/world), so a divergence between
this data and the files on disk is detected.
"""

TILE = 4.0
OX = -60.0  # world x of tile column 0
OZ = -52.0  # world z of tile row 0
FY = 1.0  # floor top
WALL_T = 1.0
WALL_H = 12.0
SLAB_T = 1.0

# name -> (tx0, tz0, tx1, tz1), half open tile rectangles, pairwise disjoint.
REGIONS = {
    # circulation: a ring (CrossN, CorrW, CrossS, CorrE) crossed by a central hall
    "CrossS": (3, 14, 27, 17),
    "CrossN": (3, 5, 27, 8),
    "CorrW": (3, 8, 6, 14),
    "CorrE": (24, 8, 27, 14),
    "HallS": (13, 17, 16, 20),
    "HallN": (13, 8, 16, 14),
    # arrival and south wing
    "EntranceLobby": (10, 20, 20, 26),
    "AdmissionsOffice": (10, 17, 13, 20),
    "NurseStation": (16, 17, 20, 20),
    "PatientWardA": (0, 17, 5, 23),
    "RecordsOffice": (5, 17, 10, 23),
    "UtilityRoom": (20, 17, 27, 23),
    "StorageRoom": (20, 23, 27, 26),
    # inner ring
    "TreatmentRoom": (6, 8, 13, 14),
    "HydrotherapyWard": (16, 8, 24, 14),
    # north (quarantine) wing, reached only through the gate hall
    "GateHall": (12, 0, 18, 5),
    "StaffOffice": (4, 0, 12, 5),
    "QuarantineWard": (18, 0, 24, 5),
    "LoadingDock": (24, 0, 30, 5),
}

CIRCULATION = {"CrossS", "CrossN", "CorrW", "CorrE", "HallS", "HallN"}

# (region a, region b, first tile along the shared boundary, number of tiles). Doorway clear width is n * 4 - 1 studs.
DOORS = [
    ("EntranceLobby", "HallS", 13, 3),
    ("HallS", "CrossS", 13, 3),
    ("CrossS", "HallN", 13, 3),
    ("HallN", "CrossN", 13, 3),
    ("CrossS", "CorrW", 3, 3),
    ("CrossS", "CorrE", 24, 3),
    ("CrossN", "CorrW", 3, 3),
    ("CrossN", "CorrE", 24, 3),
    ("CrossS", "AdmissionsOffice", 10, 2),
    ("CrossS", "NurseStation", 17, 2),
    ("CrossS", "PatientWardA", 3, 2),
    ("CrossS", "RecordsOffice", 6, 2),
    ("CrossS", "UtilityRoom", 22, 3),
    ("UtilityRoom", "StorageRoom", 23, 2),
    ("EntranceLobby", "StorageRoom", 24, 2),
    ("TreatmentRoom", "CorrW", 10, 2),
    ("TreatmentRoom", "HallN", 10, 3),
    ("HydrotherapyWard", "HallN", 10, 3),
    ("HydrotherapyWard", "CorrE", 10, 2),
    ("CrossN", "GateHall", 13, 3),
    ("GateHall", "StaffOffice", 1, 3),
    ("GateHall", "QuarantineWard", 1, 3),
    ("QuarantineWard", "LoadingDock", 1, 3),
]

# Wall / floor style per region: (wall colour, floor material, floor colour)
STYLE = {
    "CrossS": ((0.55, 0.56, 0.55), "Concrete", (0.34, 0.35, 0.34)),
    "CrossN": ((0.55, 0.56, 0.55), "Concrete", (0.34, 0.35, 0.34)),
    "CorrW": ((0.55, 0.56, 0.55), "Concrete", (0.34, 0.35, 0.34)),
    "CorrE": ((0.55, 0.56, 0.55), "Concrete", (0.34, 0.35, 0.34)),
    "HallS": ((0.6, 0.6, 0.58), "Concrete", (0.38, 0.38, 0.36)),
    "HallN": ((0.6, 0.6, 0.58), "Concrete", (0.38, 0.38, 0.36)),
    "EntranceLobby": ((0.62, 0.58, 0.5), "Slate", (0.3, 0.29, 0.27)),
    "AdmissionsOffice": ((0.5, 0.46, 0.4), "Wood", (0.26, 0.21, 0.16)),
    "NurseStation": ((0.6, 0.64, 0.62), "SmoothPlastic", (0.36, 0.4, 0.38)),
    "PatientWardA": ((0.5, 0.58, 0.54), "Concrete", (0.3, 0.34, 0.32)),
    "RecordsOffice": ((0.52, 0.46, 0.36), "Wood", (0.28, 0.22, 0.16)),
    "UtilityRoom": ((0.3, 0.32, 0.36), "Metal", (0.2, 0.21, 0.24)),
    "StorageRoom": ((0.4, 0.38, 0.34), "Concrete", (0.26, 0.25, 0.23)),
    "TreatmentRoom": ((0.7, 0.76, 0.78), "SmoothPlastic", (0.5, 0.56, 0.58)),
    "HydrotherapyWard": ((0.42, 0.56, 0.58), "Slate", (0.26, 0.34, 0.36)),
    "GateHall": ((0.46, 0.32, 0.3), "Concrete", (0.26, 0.2, 0.2)),
    "StaffOffice": ((0.44, 0.34, 0.3), "Wood", (0.24, 0.18, 0.14)),
    "QuarantineWard": ((0.4, 0.26, 0.26), "Concrete", (0.22, 0.17, 0.17)),
    "LoadingDock": ((0.32, 0.33, 0.36), "DiamondPlate", (0.22, 0.23, 0.26)),
}

# Lamps: region -> list of (world x, world z) fixed below.  Computed from the region centre unless listed.
LAMP_SPACING = 24.0

SPAWN = {"x": 0.0, "z": 44.0, "size": (14.0, 1.0, 8.0), "region": "EntranceLobby"}

# Objective anchors: PointId -> (expected region, world x, world y, world z, size). They sit against a wall of their room.
# The PointIds must equal the pointIds in src/mission/server/Objective/ObjectiveContent.lua exactly.
ANCHORS = {
    "POWER_FUSE_A": ("UtilityRoom", 46.8, 4.5, 28.0, (1.2, 3.0, 3.0)),
    "POWER_FUSE_B": ("PatientWardA", -58.8, 4.5, 28.0, (1.2, 3.0, 3.0)),
    "POWER_FUSE_C": ("HydrotherapyWard", 20.0, 4.5, -18.8, (3.0, 3.0, 1.2)),
    "WING_ACCESS_PANEL": ("CrossN", 8.0, 4.5, -30.8, (3.0, 3.5, 1.2)),
    "EXTRACTION_POINT": ("LoadingDock", 58.8, 4.5, -42.0, (1.2, 4.0, 5.0)),
    "RECORDS_CABINET": ("RecordsOffice", -30.0, 4.5, 38.8, (4.0, 5.0, 1.2)),
}

# Evidence sources: SourceId -> (evidenceId, expected region, world x, world y, world z, size).
# Wall-mounted non-collidable parts discovered through EvidenceSource + EvidenceId/SourceId.
EVIDENCE_SOURCES = {
    "COLD_SPOT_TREATMENT": ("COLD_SPOT", "TreatmentRoom", -34.8, 4.5, -6.0, (1.2, 3.0, 3.0)),
    "COLD_SPOT_QUARANTINE": ("COLD_SPOT", "QuarantineWard", 34.8, 4.5, -42.0, (1.2, 3.0, 3.0)),
}
EVIDENCE_TAG = "EvidenceSource"
MIN_SOURCE_SEPARATION = 40.0

# Props: (region, name, x0, z0, x1, z1, height, material, colour) in WORLD studs. Anchored, collidable.
PROPS = [
    ("EntranceLobby", "ReceptionDesk", -18.0, 34.0, -10.0, 38.0, 3.5, "Wood", (0.3, 0.22, 0.15)),
    ("EntranceLobby", "WaitingBenchA", 12.0, 34.0, 15.0, 40.0, 2.0, "Fabric", (0.22, 0.26, 0.3)),
    ("EntranceLobby", "WaitingBenchB", 12.0, 44.0, 15.0, 50.0, 2.0, "Fabric", (0.22, 0.26, 0.3)),
    ("AdmissionsOffice", "AdmissionsDesk", -19.0, 22.5, -13.0, 25.0, 3.2, "Wood", (0.3, 0.22, 0.15)),
    ("NurseStation", "NurseCounter", 6.0, 24.5, 14.0, 26.5, 3.5, "SmoothPlastic", (0.7, 0.74, 0.72)),
    ("PatientWardA", "BedA", -57.0, 18.0, -54.0, 25.0, 1.8, "Metal", (0.5, 0.52, 0.5)),
    ("PatientWardA", "BedB", -57.0, 31.0, -54.0, 38.0, 1.8, "Metal", (0.5, 0.52, 0.5)),
    ("PatientWardA", "BedC", -48.0, 34.0, -45.0, 38.5, 1.8, "Metal", (0.5, 0.52, 0.5)),
    ("RecordsOffice", "Shelves", -22.5, 20.0, -20.8, 36.0, 7.0, "Wood", (0.34, 0.26, 0.18)),
    ("RecordsOffice", "ArchiveDesk", -38.0, 30.0, -33.0, 33.0, 3.2, "Wood", (0.3, 0.22, 0.15)),
    ("RecordsOffice", "FileCabinets", -33.0, 36.4, -27.0, 37.9, 5.0, "Metal", (0.4, 0.42, 0.42)),
    ("UtilityRoom", "BoilerA", 24.0, 20.0, 30.0, 28.0, 8.0, "CorrodedMetal", (0.32, 0.26, 0.22)),
    ("UtilityRoom", "BoilerB", 24.0, 31.0, 30.0, 38.0, 8.0, "CorrodedMetal", (0.32, 0.26, 0.22)),
    ("StorageRoom", "ShelfRowA", 24.0, 49.0, 44.0, 51.0, 8.0, "Metal", (0.38, 0.4, 0.42)),
    ("StorageRoom", "CratesA", 40.0, 41.5, 44.0, 45.0, 3.0, "Wood", (0.36, 0.28, 0.2)),
    ("TreatmentRoom", "ExamTableA", -28.0, -14.0, -22.0, -10.0, 2.8, "SmoothPlastic", (0.8, 0.82, 0.84)),
    ("TreatmentRoom", "ExamTableB", -28.0, -2.0, -22.0, 2.0, 2.8, "SmoothPlastic", (0.8, 0.82, 0.84)),
    ("TreatmentRoom", "InstrumentCabinet", -34.5, -19.0, -33.0, -13.0, 6.0, "Metal", (0.74, 0.76, 0.78)),
    ("HydrotherapyWard", "TubA", 10.0, -4.0, 14.0, 3.0, 2.2, "Metal", (0.62, 0.66, 0.68)),
    ("HydrotherapyWard", "TubB", 17.0, -4.0, 21.0, 3.0, 2.2, "Metal", (0.62, 0.66, 0.68)),
    ("HydrotherapyWard", "TubC", 25.0, -4.0, 29.0, 3.0, 2.2, "Metal", (0.62, 0.66, 0.68)),
    ("StaffOffice", "StaffDesk", -40.0, -46.0, -33.0, -42.0, 3.2, "Wood", (0.3, 0.22, 0.15)),
    ("StaffOffice", "LockerBank", -43.0, -38.0, -41.5, -33.0, 7.0, "Metal", (0.34, 0.36, 0.38)),
    ("GateHall", "GatePillarW", -10.0, -42.0, -7.5, -39.5, 12.0, "Concrete", (0.4, 0.34, 0.32)),
    ("GateHall", "GatePillarE", 7.5, -42.0, 10.0, -39.5, 12.0, "Concrete", (0.4, 0.34, 0.32)),
    ("QuarantineWard", "CotA", 22.0, -50.0, 25.0, -44.0, 1.8, "Metal", (0.45, 0.4, 0.4)),
    ("QuarantineWard", "CotB", 22.0, -40.0, 25.0, -34.0, 1.8, "Metal", (0.45, 0.4, 0.4)),
    ("QuarantineWard", "CotC", 29.0, -50.0, 32.0, -44.0, 1.8, "Metal", (0.45, 0.4, 0.4)),
    ("LoadingDock", "CrateStackA", 40.0, -50.0, 46.0, -45.0, 4.0, "Wood", (0.36, 0.28, 0.2)),
    ("LoadingDock", "CrateStackB", 40.0, -37.0, 45.0, -33.5, 3.0, "Wood", (0.36, 0.28, 0.2)),
]


def region_box(name):
    tx0, tz0, tx1, tz1 = REGIONS[name]
    return (tx0 * TILE + OX, tx1 * TILE + OX, tz0 * TILE + OZ, tz1 * TILE + OZ)  # x0, x1, z0, z1


def door_threshold(door):
    """World (x, z) of the doorway's centre on the shared boundary, plus its orientation ('H' or 'V')."""
    a, b, start, count = door
    ax0, ax1, az0, az1 = region_box(a)
    bx0, bx1, bz0, bz1 = region_box(b)
    if abs(ax1 - bx0) < 1e-6 or abs(bx1 - ax0) < 1e-6:  # side by side: vertical boundary
        x = ax1 if abs(ax1 - bx0) < 1e-6 else ax0
        z = (start + count / 2.0) * TILE + OZ
        return x, z, "V"
    z = az1 if abs(az1 - bz0) < 1e-6 else az0
    x = (start + count / 2.0) * TILE + OX
    return x, z, "H"
