# TTL-10 — First Mission Map (THE ASYLUM)

Status: **IMPLEMENTED; PR #25 is open on `feat/map-ttl-10-first-mission-map` and pending review/merge. CI and Rojo builds passed on the PR head. Not validated in Roblox Studio.** Automated results are recorded in section 9; everything that needs Studio, a real device or real multiplayer remains pending (section 10).

Source of truth: `docs/TTL-09_OBJECTIVE_SYSTEM.md` (anchors, decision D5), `docs/TTL-09B_OBJECTIVE_SERVICE.md`, `docs/HUB_GREYBOX.md` (the authoring convention this task follows).

## 1. What changed

- The MISSION place now contains an authored, source-controlled ASYLUM greybox: static Rojo JSON models under `src/mission/world`, mapped into `Workspace` by `mission.project.json` (with `$ignoreUnknownInstances`, like the HUB). No script and no runtime builder creates the map.
- `ObjectiveService` no longer builds a runtime anchor row. It discovers the authored anchors server-side (parts tagged `ObjectivePoint` with a `PointId` attribute) and binds the existing objective slots to them. `ObjectiveFixture` was deleted; the fixture settings were removed from `ObjectiveConfig`. Objective state, interaction validation, the snapshot contract and the HUD are unchanged.
- The `EXTRACT` interaction is still the TTL-09 **dev placeholder** (section 7).

## 2. Layout

Compact, single level, about 120 x 104 studs, built on a 4-stud tile grid (walls 1 stud thick, 12 studs high, doorways 7 to 11 studs clear). North is -z; the spawn faces north. Coordinates below are world studs.

```
 north wing (quarantine, reached only through the gate hall)
 +-------------+----------+---------------+-----------+
 | StaffOffice | GateHall | QuarantineWard| LoadingDock| <- EXTRACT anchor (placeholder)
 +-------------+-----+----+---------------+-----------+
   CrossN (north cross corridor)  [WING_ACCESS_PANEL beside the gate]
 +--CorrW--+  +-- HallN --+  +----------CorrE--+
 |  Treatment |  (central) | Hydrotherapy       |  <- POWER_FUSE_C
 |  Room      |   hall     | Ward               |
 +--CorrW--+  +-----------+  +----------CorrE--+
   CrossS (south cross corridor)
 +---------+--------+---+------+---+--------+-----------+
 | Patient | Records| Admiss| HallS |Nurse| Utility    |  <- FUSE_B (ward), RECORDS (office), FUSE_A (utility)
 | Ward A  | Office | Office|   |   |Stn  | Room       |
 +---------+--------+   +---+  +---+-----+-+----------+
                      | Entrance Lobby (spawn) | Storage |
                      +------------------------+---------+
```

| Room | Interior (x, z) | Size |
|---|---|---|
| CrossS | x -48..48, z 4..16 | 96 x 12 |
| CrossN | x -48..48, z -32..-20 | 96 x 12 |
| CorrW | x -48..-36, z -20..4 | 12 x 24 |
| CorrE | x 36..48, z -20..4 | 12 x 24 |
| HallS | x -8..4, z 16..28 | 12 x 12 |
| HallN | x -8..4, z -20..4 | 12 x 24 |
| EntranceLobby | x -20..20, z 28..52 | 40 x 24 |
| AdmissionsOffice | x -20..-8, z 16..28 | 12 x 12 |
| NurseStation | x 4..20, z 16..28 | 16 x 12 |
| PatientWardA | x -60..-40, z 16..40 | 20 x 24 |
| RecordsOffice | x -40..-20, z 16..40 | 20 x 24 |
| UtilityRoom | x 20..48, z 16..40 | 28 x 24 |
| StorageRoom | x 20..48, z 40..52 | 28 x 12 |
| TreatmentRoom | x -36..-8, z -20..4 | 28 x 24 |
| HydrotherapyWard | x 4..36, z -20..4 | 32 x 24 |
| GateHall | x -12..12, z -52..-32 | 24 x 20 |
| StaffOffice | x -44..-12, z -52..-32 | 32 x 20 |
| QuarantineWard | x 12..36, z -52..-32 | 24 x 20 |
| LoadingDock | x 36..60, z -52..-32 | 24 x 20 |

Circulation is a ring (CrossN, CorrW, CrossS, CorrE) crossed by a central hall, plus a second loop through the lobby, the storage room, the utility room and the south cross corridor: five independent loops in total (measured by the validator). The north wing is a deliberate branch: the gate hall is its only entrance, a natural place for a future door.

## 3. Intended route and landmarks

1. Spawn in the Entrance Lobby (reception desk, benches), walk north through the central hall to the cross corridor.
2. Restore power: fuse boxes in three different areas of the map: the Utility Room (south-east, boilers), Patient Ward A (south-west, beds) and the Hydrotherapy Ward (centre-north, tubs). Any player, any order.
3. Open the wing: the access panel on the north wall of the north cross corridor, next to the open gate into the quarantine wing.
4. Optional: the records cabinet in the Records Office (south-west), available from the start.
5. Escape: through the gate hall and the quarantine ward to the Loading Dock in the north-east (dev placeholder).

Landmarks: the reception lobby with the desk, the long straight central hall, the twin boilers, the three bathtubs, the gate pillars, the cots of the quarantine ward and the dock crates. Colours and materials differ per area (see `STYLE` in `tools/asylum_greybox/asylum_layout.py`) so players can orient themselves.

## 4. Objective anchors

Every `pointId` in `ObjectiveContent.lua` has one authored anchor; the table is exact and enforced by the validator.

| PointId | Room | Position (x, y, z) |
|---|---|---|
| `POWER_FUSE_A` | UtilityRoom | (46.8, 4.5, 28) |
| `POWER_FUSE_B` | PatientWardA | (-58.8, 4.5, 28) |
| `POWER_FUSE_C` | HydrotherapyWard | (20, 4.5, -18.8) |
| `WING_ACCESS_PANEL` | CrossN | (8, 4.5, -30.8) |
| `EXTRACTION_POINT` | LoadingDock | (58.8, 4.5, -42) |
| `RECORDS_CABINET` | RecordsOffice | (-30, 4.5, 38.8) |

Each anchor is a small non-collidable amber Part flush against a wall of its room, at 4.5 studs height, so it reads as a panel or cabinet in the greybox. The anchors are spread across the whole map (they are not in a row and none is near the spawn); the three fuse boxes are at least 30 studs apart.

## 5. How anchors are discovered and validated

- **Authoring:** `src/mission/world/AsylumMap/ObjectiveAnchors.model.json` declares the parts with `"Properties": {"Tags": ["ObjectivePoint"]}` and `"Attributes": {"PointId": "<same as the part name>"}`.
- **Runtime (server only):** `ObjectiveService.start` collects `CollectionService:GetTagged("ObjectivePoint")`, keeps the `BasePart`s that are in the Workspace, reads `PointId`, and hands the list to the pure `ObjectiveAnchors.index` (`src/server_shared/Objective/ObjectiveAnchors.lua`): ids must look like content ids, an id claimed by two parts is ambiguous and resolves to nothing, invalid entries are counted. The result feeds `ObjectiveRuntime` as its `resolveAnchor`. Clients never supply anchors or positions.
- **Fail closed:** a missing or ambiguous REQUIRED anchor makes the runtime throw during start, so the lifecycle aborts the mission; a missing OPTIONAL anchor cancels that objective (existing 09B behavior). The service logs which ids are missing, ambiguous or invalid.
- **Cleanup:** the service only unregisters its own prompts and request handler; it never creates, moves or destroys the authored map.
- **Offline validation (`tools/asylum_greybox/validate_asylum_greybox.py`):** reads the generated JSON independently and checks, among others: tag and attribute on every anchor, part name equals PointId, PointIds exactly equal the pointIds parsed from `ObjectiveContent.lua` (no missing, no extra, no duplicates), each anchor inside its intended room, a walkable position within 75 percent of the configured prompt distance, spread over the map, not next to the spawn. Lune covers the pure side (`tests/server_shared/ObjectiveAnchors.spec.lua`).

## 6. Rojo representation

- `mission.project.json` maps `Workspace` to `src/mission/world` (`$ignoreUnknownInstances: true`, so the template baseplate is untouched) and sets a few `Lighting` properties (very dark ambient, night clock time, no post-processing, no fog). Pinned Rojo is 7.6.1.
- `src/mission/world/SpawnLocation.model.json`: the spawn pad (14 x 1 x 8, invisible, flush with the floor) named `SpawnLocation` at (0, 44) in the lobby, so it patches the template spawn instead of adding a second one.
- `src/mission/world/AsylumMap/`: `Architecture` (Floors, Walls, Ceilings), `Props`, `Lighting` (small neon lamps with low-brightness `PointLight`s) and `ObjectiveAnchors`. About 160 parts in total, wall runs merged.
- Formats follow the HUB convention: documented Rojo JSON forms only (`Vector3`/`Color3` arrays, enum names as strings, flat 12-number `CFrame`, identity orientation). The part `Tags` property and node-level `Attributes` map are also used for the objective anchors. **Rojo 7.6.1 accepted the complete MISSION project, including these tags and attributes, in the successful CI `build-places` job.** This confirms the place build; the resulting tag/attribute behavior in a live Studio session remains on the owner checklist.
- Regenerate with `python3 tools/asylum_greybox/generate_asylum_greybox.py` (layout data in `asylum_layout.py`); the JSON files are the source Rojo reads, and a test fails if they drift from the generator.

## 7. Extraction warning

`EXTRACT` remains the single-slot DEV PLACEHOLDER from TTL-09: one interaction by any living participant at the Loading Dock completes it and the mission then ends for everyone. This PR does **not** choose or build an extraction policy (`ANY_ELIGIBLE`, `ALL_LIVING`, quorum, timeout). The final rule needs product-owner approval before it is built (design 11.6, D2). The dock was placed as a sensible physical end point, nothing more.

## 8. Greybox limitations and deferred work

- Greybox only: no final art, no textures, no decals, no sound, no post-processing; a few diegetic props, no text signage.
- No door system: all openings are plain doorways (the gate hall, the quarantine wing and the lobby are natural future door sites). `OPEN_WING` gates progression, not the geometry yet.
- Single level: no basement or stairs (the validator's walker is 2D); deferred.
- The map is compact (the longest spawn-to-anchor walk is about 140 studs); mission length targets depend on later systems (evidence, entities, rituals), not on distance.
- Characters can see the whole building through open doorways; sightlines and lighting will be tuned in Studio. Line of sight for prompts is not validated (known TTL-08B limitation): keep anchors on wall faces inside their rooms.
- Two spawn-adjacent rooms (admissions office, nurse station) are small filler spaces without gameplay yet.
- Optional objective access: the records office is a dead-end room by design (optional content only).

## 9. Checks that were actually run

### CI results (PR #25 head `add8a6ab2e4df3a3dee836aed0226c30b0b1a8b4`)

Both GitHub Actions check runs completed successfully on the PR head:

- **`build-places` — SUCCESS** (`rojo-build.yml`): pinned Rojo 7.6.1 successfully built both `hub.project.json` and `mission.project.json`; the workflow then ran `lune run tests/run`. This also verifies that Rojo accepts the MISSION map JSON, including the `Tags` and `Attributes` used by the authored objective anchors.
- **`Validate THE ASYLUM greybox geometry and objective anchors` — SUCCESS** (`mission-greybox-validation.yml`): the map validator passed (19 rooms, 23 doorways, 5 independent loops, all six anchors resolved and reachable) and the Python regression suite passed (24 tests).

The successful CI checks supersede the earlier authoring-environment limitation: Lune, both Rojo place builds and the greybox validation workflow **did run in CI and passed**. The authoring environment itself did not run those tools locally. The earlier local checks also passed: the Python validator and 24 tests, plus 65 objective-related tests in a Lua 5.4 shim (not a substitute for Lune).

Not covered by CI and still pending: Luau strict-mode diagnostics beyond the configured workflow, and anything that requires opening/running the place in Roblox Studio. In particular, visually inspecting the map, confirming tags/attributes on selected instances in Studio, prompt placement/reach, mobile controls, multiplayer behavior, camera clipping and low-end device performance remain owner tasks.

## 10. Studio validation checklist (owner task, all pending)

1. Open the MISSION place built from `mission.project.json`: the map appears, there is exactly one spawn, the template baseplate is below the floor and harmless, and the lighting is dark but readable.
2. Spawn in the lobby, not inside geometry; walk to every room; confirm doorways are comfortable on PC and with a mobile thumbstick.
3. Select an anchor in Studio: confirm the `ObjectivePoint` tag and the `PointId` attribute were applied by Rojo (this verifies the unconfirmed Rojo syntax).
4. Run a mission: the objective HUD lists the four objectives; prompts appear at the six authored locations and not before their objectives unlock.
5. Fill the three fuses (any order, several players), open the wing at the panel, finish at the dock; the mission ends once and players return.
6. Delete one required anchor in Studio and start a mission: it must abort cleanly (and a missing `RECORDS_CABINET` must only cancel the optional objective).
7. Confirm the map is still in the Workspace after the mission ends or the service stops (it is never destroyed by the service).
8. Solo, 2, 4 players; later 8. Check sightlines, lighting, prompt reach (anchors on walls), camera clipping in corridors, and performance on a low-end phone.
9. Check the door gaps on mobile camera and that no prop traps a character.
