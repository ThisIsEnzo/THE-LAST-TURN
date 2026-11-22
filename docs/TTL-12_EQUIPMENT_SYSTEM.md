# TTL-12 — Equipment System

**Status:** Approved design baseline; implementation pending  
**Scope:** Initial mission equipment, loadout selection, server-authoritative equipment effects, and the admission constraints required to use equipment safely.  
**Last updated:** 2026-11-22

> This document records the decisions already made for TTL-12. It is not a claim that the system has been implemented or tested. Source-dependent integration details marked **VERIFY DURING IMPLEMENTATION** must be checked against the current code before they are treated as implementation facts.

## 1. Goals

- Give every player useful investigative tools without mandatory classes or role restrictions.
- Make equipment understandable, complementary, and usable on PC, mobile, and gamepad.
- Keep gameplay effects server-authoritative.
- Keep equipment separate from the Evidence collection/confirmation pipeline.
- Keep the initial equipment set free and mission-local. No paid gameplay advantage, persistent inventory, trading, or progression is part of TTL-12.

## 2. Initial equipment

Five items are in the initial catalog:

| ID | Category | Action | Purpose |
|---|---|---|---|
| `EMF_READER` | Detection | `SCAN` | Detect electrical anomalies |
| `THERMOMETER` | Detection | `SCAN` | Detect cold spots and thermal anomalies |
| `FIELD_CAMERA` | Observation | `CAPTURE` | Detect directional physical disturbances |
| `SPIRIT_BOX` | Communication | `SCAN` | Listen for audio phenomena |
| `UTILITY_FLASHLIGHT` | Utility | `TOGGLE_LIGHT` | Server-controlled flashlight |

Protection remains a category vocabulary only. No Protection item is included in the initial catalog. In particular, do not add `WARD_CHARM` without a separately approved design and a real gameplay consumer.

### Loadout rules

- Three equipment slots per player.
- No duplicate item IDs in one loadout.
- No category restrictions; any valid combination of the five items is allowed.
- Default loadout: `UTILITY_FLASHLIGHT` + `EMF_READER`.
- All five items are available without payment.
- Loadout is mission-local; no persistent inventory, trading, unlock progression, or paid advantages.
- Do not introduce equipment-gated objectives.

## 3. Player eligibility and life state

- Physical equipment can be used only by an admitted, living participant.
- Dead and ghost players cannot use physical equipment.
- Death makes the inventory inert. Respawn must not reactivate equipment, restore an alive state, or turn the flashlight back on.
- Equipment availability must depend on both life state and mission admission. A transient `ALIVE` state during player registration/reconnect is not sufficient proof that the player may act.

### Admission boundary

Admission and life state are separate concepts. The design uses an independent participant admission state:

`CONNECTING → ADMITTING → ACTIVE`, with failure ending in `REJECTED`.

A participant may be alive while still connecting/admitting, but must not be allowed to perform gameplay mutations until admission is `ACTIVE`.

**VERIFY DURING IMPLEMENTATION:** inspect all actual mutation entry points and registration side effects. Do not assume that all interactions pass through one service until the full call chain is verified. Include objective, evidence, equipment, prompts, and mission actions.

Snapshot requests are not automatically safe merely because they are read-only:
- Before `ACTIVE`, expose only the minimum data required for admission/initialization.
- Full gameplay snapshots are available only after admission succeeds.
- Do not leak evidence, objective, or other mission state to an unadmitted player.

## 4. Equipment behavior and provisional tuning

The following values are initial tuning targets, not balance-validated constants:

| Item | Behavior | Initial tuning |
|---|---|---|
| EMF reader | Server-evaluated electrical scan | 6 s cooldown |
| Thermometer | Server-evaluated thermal scan | 6 s cooldown |
| Field camera | Directional physical-disturbance capture | 10 stud range; cone dot threshold 0.7; 3 charges; 8 s cooldown |
| Spirit Box | Listening-only audio scan | 10 s cooldown |
| Utility flashlight | Server-created/server-controlled light toggle | 0.5 s cooldown |

### Scanner output

- Scanner bands are owner-only and range from 1 to 5.
- Exact provisional thresholds:
  - distance ≤ 6: band 5
  - 6 < distance ≤ 10: band 4
  - 10 < distance ≤ 16: band 3
  - 16 < distance ≤ 24: band 2
  - distance > 24 or no target: band 1
- Do not expose `SourceId`, `EvidenceId`, source position, exact distance, direction, confirmation state, or evidence ledger data in equipment responses.
- Do not let scanner responses reveal more than the intended band/result.

### Field camera

- Returns only `PRESENT` or `ABSENT`.
- Consume a charge only on `PRESENT`.
- Apply cooldown on both `PRESENT` and `ABSENT`.
- Target selection must be deterministic and server-evaluated.

### Spirit Box

- Listening only. It does not confirm, collect, or consume evidence.

### Flashlight

- Created and controlled by the server.
- Must not reactivate after death, respawn, or an unadmitted reconnect.

## 5. Evidence separation

Equipment scans and Evidence collection are separate systems.

- Scanners must not observe, confirm, collect, consume, or modify Evidence.
- No `EvidenceService → EquipmentService` dependency.
- No capability framework is introduced for TTL-12.
- Do not modify EvidenceCore, EvidenceRuntime, EvidenceService, or EvidenceCatalog as part of the equipment implementation.
- Equipment may evaluate its own server-side scan targets, but must not return evidence identifiers or ledger details.

### Scanner channels

`ScannerChannel` is independent of Evidence category and Evidence ID:

| Evidence ID | Scanner channel | Matching tool |
|---|---|---|
| `COLD_SPOT` | `THERMAL` | `THERMOMETER` |
| `STATIC_INTERFERENCE` | `ELECTRICAL` | `EMF_READER` |
| `MOVED_OBJECT` | `PHYSICAL` | `FIELD_CAMERA` |
| `VOICE_ECHO` | `AUDIO` | `SPIRIT_BOX` |

Allowed channel values: `ELECTRICAL`, `THERMAL`, `AUDIO`, `PHYSICAL`.

### Asylum content requirement

The currently authored map content has two thermal evidence sources:
- `COLD_SPOT_QUARANTINE`
- `COLD_SPOT_TREATMENT`

The initial playable equipment experience must include valid authored sources for all four scanner channels. The additional electrical, physical, and audio source placement/content work belongs to TTL-12 delivery. Do not invent source IDs, coordinates, or counts; author and validate actual map content.

Names such as `CELLAR`, `ATTIC`, `RADIO_ROOM`, `BOILER`, `NURSERY`, `STAIRS`, `CORRIDOR`, and `CHAPEL` have appeared as test fixture names and must not be represented as authored map sources without checking the map.

## 6. Loadout validation and canonical representation

TeleportData is untrusted input. Validation must be server-side and must not treat a client-supplied loadout as authoritative merely because it arrived through teleport.

For cross-participant loadout consistency, use a canonical ordered representation:
- An ordered array of records shaped as `{ userId, items }`.
- Sort records by numeric `UserId`.
- Sort item IDs lexicographically.
- Serialize deterministically. If the platform JSON encoder does not guarantee the required object-field order, use an explicit deterministic writer.
- Validate dense arrays by inspecting keys: positive integer indices, contiguous `1..n`, bounded inspection work, and explicit handling of an empty array. Do not use `#array` as proof of density and do not perform an unbounded sort before validation.
- `MaxLoadoutBytes = 2048` is provisional and applies to the loadout field only.

Canonical comparison proves consistency between received representations; it does not prove authenticity.

## 7. Mission admission, late arrivals, and reconnect constraints

These rules capture the current product decisions and the architecture constraints that must be preserved during implementation.

### Arrival windows

- Initial arrival window: 45 seconds (provisional).
- If all expected participants arrive before timeout, start immediately.
- If timeout expires and at least one valid participant has arrived, start with the participants who arrived.
- Missing expected participants remain eligible for Late Join until the deadline.
- Late Join window: 120 seconds after mission start (provisional).
- After the deadline, admission closes permanently for that mission.
- A participant who misses the deadline is excluded from the current mission and may join a later session.
- The original mission context and expected member set remain immutable.
- Late Join is not revival.

### HUB routing versus Mission admission

These are separate responsibilities:

- HUB routing retains the information needed to direct an eligible late participant to the existing reserved server.
- Mission admission independently validates the authenticated Roblox `UserId`, immutable expected-member membership, mission context, deadline, and loadout consistency.
- A HUB in-memory registry is local to that HUB server. It does not automatically become visible to a different HUB server or to the Mission server.
- Do not claim cross-HUB-server late join unless a cross-server persistence/coordination mechanism is separately approved.
- The reserved server ID is server-only and must never be replicated to clients or placed in client-visible payloads.

The HUB teleport callback receives launch information before `TeleportAsync`; capturing routing data there is the intended low-change direction. Do not attempt to recover the reserved server ID from a completion summary after the launch record has been released.

### Reconnect and death

Maintain a mission-scoped participant record keyed by authenticated Roblox `UserId`:
- Record existence distinguishes a previously admitted participant from a first-time arrival.
- `hasDied` is monotonic and must never be cleared during the mission.
- A living reconnect resumes the same life and inventory state; do not refresh charges or cooldowns.
- A participant who has died must not receive a new life on reconnect. Restore the dead/ghost outcome through legal lifecycle transitions.
- An excluded participant remains excluded.
- Do not trust client-supplied life state.
- The admission gate must block gameplay while reconnect state is being restored. Check registration/event side effects so a temporary `ALIVE` registration cannot activate gameplay or equipment before admission completes.
- Mission-scoped in-memory records are sufficient for the current design; no DataStore or MemoryStore dependency is approved for TTL-12.

### Zero-arrival and disconnect cases

- If nobody ever reaches the Mission server, the Mission server cannot run a timeout that depends on a first arrival. HUB routing/admission-record expiry handles stale routing state. This is not a guarantee that Roblox immediately destroys the reserved server.
- If the first accepted participant disconnects before the initial arrival timeout, start only if at least one accepted participant is still connected at evaluation time.
- If some participants arrive, start with the accepted connected participants after the timeout and retain the immutable expected set for Late Join.

**VERIFY DURING IMPLEMENTATION:** confirm the actual accepted/connected-set semantics in the arrival store and its `leave` path, the timeout configuration, reconnect registration behavior, and all admission gate insertion points.

## 8. Hub integration

- Reuse the existing HUB EquipmentRoom and LoadoutTerminal.
- Do not create a duplicate room or terminal.
- The terminal is an existing world asset; its interaction/activation wiring is part of TTL-12 implementation.

## 9. Explicit non-goals

- No paid equipment or paid gameplay advantages.
- No persistent inventory, trading, unlock progression, or mandatory player classes.
- No Protection item in the initial catalog.
- No equipment-gated objectives.
- No evidence collection/confirmation integration from equipment.
- No broad capability framework.
- No changes to EvidenceCore/Runtime/Service/Catalog for equipment scanning.
- No MemoryStore/DataStore dependency in TTL-12.
- No claim of cross-HUB-server Late Join.

## 10. Implementation acceptance criteria

- All five items can be selected in the existing HUB terminal and are represented in a validated three-slot loadout.
- Server validates loadout shape, item IDs, duplicates, slot count, canonical representation, and size bounds.
- All equipment effects are server-authoritative and rate-limited.
- PC, mobile, and gamepad can invoke the intended actions.
- Scanners return only the permitted owner-specific result and never mutate or reveal Evidence state.
- Camera charge/cooldown behavior matches the rules above.
- Flashlight is server-controlled and remains inactive for dead, ghost, or unadmitted players.
- Admission blocks all gameplay mutations until `ACTIVE`; pre-admission snapshots reveal only minimum initialization data.
- Reconnect preserves the participant's life and inventory; a dead participant cannot regain a living state.
- Asylum has authored, validated sources for all four scanner channels.
- Automated tests cover validation, canonical serialization, scanner output privacy, cooldowns/charges, admission gating, and reconnect/death cases.
- Rojo builds, Lune tests, map validation, and Studio multiplayer/mobile checks are reported separately. CI success alone is not evidence of Studio validation.

## 11. Verification status

This file is the design baseline, not an implementation report.

The following values remain provisional pending playtesting: scanner band thresholds, camera range/cone/charges/cooldown, EMF and thermometer cooldowns, Spirit Box cooldown, flashlight cooldown, 45-second initial arrival window, 120-second Late Join window, and 2048-byte loadout limit.

Source-dependent details must be verified during implementation against the branch being changed. Do not mark them verified based only on this document or on earlier chat summaries.
