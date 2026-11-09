# HUB greybox environment (TTL-HUB-01)

Status: **IMPLEMENTED, IN REVIEW. Not validated in Roblox Studio.** The environment is a static, source-controlled Rojo
tree (no scripts, no runtime generation). Checks that were actually run are listed in section 6; everything that needs
Studio is pending (section 7).

## 1. What exists

A compact, connected facility (about 115 x 97 studs) for up to 8 players, built only from native Parts, Materials and
`PointLight`s, in a cold, desaturated concrete/metal/glass palette with fluorescent lighting. Room height 14 studs,
wall thickness 1, doorways 12 to 24 studs wide, floor top at y = 1.

```
                  N (-z)
                +--------------------+
                |  MISSION           |  sealed        (window + locked door;
                |  PREPARATION       |  RESTRICTED -> corridor behind the wall,
                |  (board wall)      |  no access)
   +------------+----+----------+----+----------+
   | EQUIPMENT       |   MAIN LOBBY   |  BRIEFING |
   | (lockers,       |   (seating,    |  (table,  |
   |  workbench)  <--+   directory)   +-->  chairs,|
   +-----------------+----+-----+-----+  display) |
                          | RECEPTION |  (spawn)
                          +-----------+
                  S (+z)  (sealed glass entrance)
```

| Area | Role | Interior (x, z) |
|---|---|---|
| Reception | Arrival: spawn pad, desk, notice board, sealed glass entrance | x -20..20, z 30..56 |
| Main Lobby | Hub: benches, directory, roster placeholder panel, guide lines | x -30..30, z -8..30 |
| Mission Preparation | Gathering zone and a 24 x 9 stud blank board wall for a future mission UI | x -20..20, z -40..-8 |
| Equipment Room | Lockers, shelves, workbench, "loadout terminal" placeholder | x -62..-30, z 2..28 |
| Briefing Room | Table, 8 chairs, display placeholder | x 30..52, z 6..26 |
| Restricted Area | Sealed hazard corridor, visible through a window, no opening | x 20..50, z -34..-22 |

Openings are plain doorways (no door parts, no interaction): reception to lobby 20 wide, lobby to mission room 24 wide,
lobby to equipment 12 wide, lobby to briefing 12 wide. Floor guide lines and doorway signs give orientation; all
text is diegetic placeholder text. Nothing implements mission selection, loadout, briefing, teleporting or interaction.

## 2. Rojo structure (the contract)

- `hub.project.json` now maps `Workspace` to `src/hub/world` with `"$ignoreUnknownInstances": true`, and sets a few
  `Lighting` properties (ambient colours, brightness, clock time; no post-processing, no fog).
- `src/hub/world/SpawnLocation.model.json`: a `SpawnLocation` named **`SpawnLocation`** directly under Workspace, 14 x 1 x 8
  studs, invisible, flush with the floor, at z = 50 inside Reception. The default orientation faces -z, i.e. toward the lobby.
  It deliberately keeps the template's name so Rojo patches the template's spawn instead of leaving two.
- `src/hub/world/HubEnvironment/*.model.json`: one Model per area (`Architecture`, `Reception`, `MainLobby`,
  `MissionPreparation`, `EquipmentRoom`, `BriefingRoom`, `RestrictedArea`, `Lighting`), each split into folders
  (`Floors`/`Walls`/`Ceilings`/`Exterior`, or `Furniture`/`Markings`/`Signage`). `Lighting` holds the fluorescent fixtures.
- The template Baseplate and Terrain are not touched (`$ignoreUnknownInstances`). The facility floor top is at y = 1, so
  it never shares a plane with the Baseplate top (y = 0); an exterior ground slab sits just below it. Delete the
  Baseplate in the place file if it is not wanted.
- MISSION is unchanged (`mission.project.json` and everything under `src/mission`).

## 3. Properties and formats used

JSON models use only documented Rojo 7 forms: `Vector3`/`Color3` arrays, enum names as strings, `CFrame` as a flat list of 12
numbers (all identity orientation: the layout is axis aligned), explicit `UDim2` for the sign labels, `FontFace` as an object.

## 4. Navigation notes

All geometry is anchored; thin floor markings are `CanCollide = false`. Furniture stays out of the doorway lanes; the
spawn pad (14 x 8; the glass entrance wall is about 1.5 studs beyond its south edge, the side walls about 12 studs away) has room for 8 characters.

## 5. Regenerating (optional authoring aid)

The `*.model.json` files are the source of truth Rojo reads. To change the layout from a few constants instead of editing
about 250 parts by hand, `tools/hub_greybox/generate_hub_greybox.py` regenerates them (it overwrites the generated files;
standard library only):

```
python3 tools/hub_greybox/generate_hub_greybox.py
python3 tools/hub_greybox/validate_hub_greybox.py [--render plan.png]
```

The validator checks that every file only uses the documented classes, properties and value shapes, that sibling names are
unique, that collidable geometry does not overlap accidentally, and that a character-sized walker (radius 1 stud) starting
on the spawn reaches every accessible room while the restricted corridor stays unreachable. It is an offline sanity check,
not a physics or visual test.

## 6. Checks run

| Check | Status |
|---|---|
| `tools/hub_greybox/validate_hub_greybox.py` (schema, naming, overlap, reachability) | passed |
| `hub.project.json` / `mission.project.json` parse as JSON | passed |
| `rojo build hub.project.json`, `rojo build mission.project.json` | **not run** (Rojo unavailable in the authoring environment); CI runs them |
| `lune run tests/run` | **not run** (Lune unavailable); no Lua source or test changed |
| Roblox Studio | **not performed** |

A successful Rojo build would not prove that the environment looks right or can be walked.

## 7. Manual Studio checklist (all pending)

1. `rojo serve hub.project.json`, connect, and confirm `Workspace` contains `HubEnvironment` and `SpawnLocation` in addition to the template Baseplate/Terrain, with no Rojo errors or warnings in the output.
2. Play: you spawn inside Reception on the pad, facing the lobby (if you face the wrong way, rotate the `SpawnLocation` CFrame), not inside geometry, and the template spawn is not used.
3. Walk (no jumping) Reception to Lobby to every room and back; also try 8 players (Local Server, 8 clients) and check the doorways are not congested.
4. Mission Preparation: the north board wall is a clear, empty-looking surface suitable for future UI.
5. The Restricted Area cannot be entered; the window shows the corridor; the locked door does nothing.
6. Lighting is readable on a phone/emulator (no area too dark, signs legible, no flickering z-fighting on walls or floors, no light leaking through walls).
7. Sign text faces the right way and is readable from the intended side; check the `SurfaceGui` text on mobile.
8. Performance: about 255 parts and 28 `PointLight`s; check frame rate on a low-end device.
9. Confirm the template Baseplate does not z-fight with the floor and that nothing else was removed from the place unexpectedly.

## 8. Known limitations

- Greybox only: no final art, no sound, no animation, no collision tuning beyond axis-aligned blocks.
- Whether Rojo live-sync treats the existing template `SpawnLocation` as the same instance is expected from the documented name matching but unverified.
- Sign and text readability, lighting levels and the feel of the scale are unverified until Studio.
- Mission selection, loadout, briefing, teleporting, party UI and interactions are out of scope.
