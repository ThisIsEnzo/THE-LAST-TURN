# THE LAST TURN — Testing Strategy

## 1. Testing principle

A successful Luau test or Rojo build is not proof that a Roblox multiplayer experience works. Report each validation layer separately and never claim a test that was not run.

## 2. Test layers

| Layer | What it validates | Evidence |
|---|---|---|
| Pure Luau tests | State machines, rules, config validation, calculations | Test output |
| Service tests | Server modules with controlled dependencies/mocks | Test output and setup |
| Static checks | Formatting, lint, type diagnostics where configured | Tool output |
| Rojo build | Files map into expected DataModel | Build command/output |
| Studio single-client | Real Roblox Instances, prompts, UI, lifecycle | Manual checklist |
| Studio multi-client | Replication, party flow, races, multiplayer objectives | Player count + checklist |
| Device tests | Mobile controls, performance, UI readability | Device and observations |
| Playtests | Comprehension, fairness, tension, replay intent | Tester notes and observed issues |

## 3. Required lifecycle scenarios

As systems are implemented, test applicable cases:
- Normal start, completion and failure.
- Solo and 2–4 player runs; later verify 5–8.
- Player disconnect during each major phase.
- Player death, Ghost transition and spectator behavior.
- Party leader disconnect before launch.
- Teleport failure and retry.
- Reset/cleanup with delayed tasks pending.
- Required resource carrier dies or disconnects.
- Duplicate interaction and duplicate reward request.
- Invalid, stale and rate-limited remote requests.

## 4. PR validation report

Every implementation PR must state:
- Automated tests run and exact result.
- Static checks run and exact result.
- Rojo build/sync result where relevant.
- Studio tests run, including client count.
- Tests not run and why.
- Known risks and manual follow-up.

## 5. MVP release test gate

Before public release:
- Complete multiple consecutive missions without softlocks.
- Validate all supported party sizes or document tested range and remaining risk.
- Test on representative mobile and PC devices.
- Verify server authority for objectives, evidence, death, rewards and purchases.
- Verify persistence failure/retry and duplicate reward handling if progression is enabled.
- Resolve all critical and high-severity blockers affecting mission completion, security or data integrity.

## 6. Networking tests (TTL-02)

Pure Luau tests live in `tests/server_shared/` and run with Lune (`lune run tests/run`, pinned in `rokit.toml`, executed in the Rojo build workflow). A small in-repo harness (`tests/Harness.lua`) is used instead of a framework.

| Spec | Covers |
|---|---|
| `Validator.spec.lua` | Valid payloads, missing required fields, unexpected fields (including client-supplied identity), wrong types, nil/malformed arguments, extra arguments, numeric boundaries, NaN/infinity/fractions, string length boundaries, invalid UTF-8, enums, nested objects, schema construction errors |
| `RateLimiter.spec.lua` | Accept/reject at capacity, refill and capacity cap, independent players, independent actions, unknown actions, cleanup on player removal, no accumulation across join/leave, clock regression, invalid configuration |

Not covered by automated tests (require Roblox runtime/Studio): `NetworkService` remote creation, idempotent init, `OnServerEvent` wiring, `PlayerRemoving` cleanup and the end-to-end handshake. These need Studio single-client and multi-client validation.

## 7. Player state tests (TTL-03)

`tests/server_shared/PlayerStateCore.spec.lua` covers the pure module: every allowed and forbidden transition (full 5x5 matrix), no return to ALIVE, RETURNING terminal, same-state idempotency, invalid state values, unknown player, registration/unregistration, independent players, clear/reinitialization, immutability of returned results, and consistency between the shared vocabulary and the core.

Requires Roblox Studio (not covered by Lune; not yet run):
- Players already present at `init()`, players joining and leaving, `PlayerRemoving` cleanup of connections.
- `CharacterAdded`/`CharacterRemoving`, respawn not resetting state, spawn with a delayed or missing Humanoid.
- `Humanoid.Died` -> DEAD, duplicate death events, stale callbacks after character replacement, disconnect during character loading.
- `LifecycleState` attribute visible to the owning client after join and respawn; client-side attribute edits not affecting server state.
- HUB and MISSION server bootstraps initializing in the required order.

## 8. Party tests (TTL-04)

`tests/server_shared/PartyCore.spec.lua` (Lune) covers the pure party rules: config validation, solo party creation, unique/never-reused ids, lookup and join order, snapshot immutability, capacity of 8 at invite and acceptance time, leader-only invites, accept/decline, expiry (lazy and timer-style), duplicate and capped invitations, refusal to move multi-member party members, superseded invitations, leave (member, leader with deterministic transfer, solo, last member), kick (authorized and every unauthorized variant), disconnect cleanup of membership and invitations, idempotent repeats, independent parties, and a deterministic 3000-step randomized sequence that asserts `validateInvariants` (no orphaned parties, memberships or invites; every registered player in exactly one party) after every operation.

Requires Roblox Studio (not covered by Lune; not yet run):
- `PartyService` init in the HUB bootstrap after `NetworkService` and `PlayerStateService`; players already connected at init; join/leave.
- Remote handlers with real clients: invite, accept/decline, leave, kick, snapshot pull; forged or malformed payloads, other players' UserIds, disconnected targets, rate limiting.
- Delivery of `PartySnapshot`, `PartyInviteReceived` and `PartyInviteEnded` only to the intended players; invitation timer expiry in real time.
- Simultaneous leave/kick/invite/disconnect with multiple clients; `shutdown()` followed by `init()`.

## 9. Mission Teleport tests (TTL-05)

Lune specs in `tests/server_shared/`: `TeleportPayload.spec.lua` (schema, bounds, duplicates, unexpected fields), `ArrivalCore.spec.lua` (environment checks, arrival coordination, mismatches, duplicates, timeout, leave/rejoin), `LaunchCoordinator.spec.lua` (validation, party changes during preparation, duplicate and concurrent launches, unique ids, invalid PlaceId, synchronous and asynchronous failures, same-destination retry, retry limit, disconnects, timeouts, no stale locks) using injected fake adapters; no Roblox teleport is simulated.

Cannot be automated and is NOT yet validated: real `TeleportAsync`, `TeleportInitFailed`, `GetJoinData`, reserved-server environment, remotes and timers. Requires a published Experience; see the checklist in `docs/TTL-05_MISSION_TELEPORT.md`.

## 10. Mission Lifecycle tests (TTL-06)

`tests/server_shared/MissionLifecycleCore.spec.lua` (Lune) covers the pure core: initial state, the full 8x8 transition matrix against an independent restatement, invalid/skipped transitions, idempotent repeats, READY-only startup, member and arrival validation (including holes, duplicates, over 8 members), duplicate initialization, COMPLETED/FAILED/ABORTED termination, abort while waiting and initializing, preserved original result across later states, terminal CLOSED, snapshot copies, invariants, shutdown semantics and config validation.

Requires Roblox Studio / a published Experience (not covered, not yet run): `MissionLifecycleService` event wiring, timers and stale-callback guards, `PlayerStateService` integration, return teleports (`TeleportAsync`, `TeleportInitFailed`), `BindToClose`. Checklist: `docs/TTL-06_MISSION_LIFECYCLE.md`.

## 11. Mission Configuration tests (TTL-07)

`tests/server_shared/SeededRandom.spec.lua` (Lune) covers the pure random streams: FNV-1a and finalizer known-answer vectors, golden xorshift32 outputs for several seeds and labels (computed with an independent reference implementation), a forced zero initial state, golden `nextInteger` results including the rejection-sampling path and the largest supported range (2^32 - 1 values; 2^32 is rejected), bounds, argument validation, stream isolation, independence from the global RNG and a deterministic distribution sanity check.

`tests/server_shared/MissionConfigCore.spec.lua` (Lune) covers content validation (every rejection code, boundaries), input validation, golden location selections for 3 and 4 locations, order independence over all permutations, the pinned selection algorithm, reachability/spread, no mutation or aliasing of inputs (plain and frozen), frozen result, the injected random-source contract and the shipped `MissionContent` (valid, deeply frozen, THE ASYLUM present). If a golden vector fails the deterministic algorithm changed: review the change, do not just update the numbers.

Requires Roblox Studio / a published Experience (not covered, not yet run): `MissionConfigService` registration order against `MissionLifecycleService.init()`, creation during INITIALIZING, abort on failure, `getConfig()` before start / after stop, behavior on shutdown. Checklist: `docs/TTL-07_MISSION_CONFIGURATION.md`.

## 12. Interaction core tests (TTL-08B-A)

`tests/server_shared/InteractionCore.spec.lua` (Lune) covers the pure interaction core: registration validation and limits, atomic failed registrations, target uniqueness by identity, frozen identity-validated handles (forged, copied, foreign and stale handles), strictly increasing serials, the fixed eligibility precedence, distance boundary and invalid-distance handling, the activation pipeline order (evaluate, token, evaluate, reserve, handler, complete), token rejections that never leave a registration busy, handler success/false/throw, reentrancy (unregister, disable, clear and re-registration while a handler runs), cleanup, and clock behaviour (boundary, backward, invalid values). Roblox runtime behaviour (prompts, `Triggered`, `PlayerRemoving`, timers) belongs to TTL-08B-B and is not covered or validated here. See `docs/TTL-08B-A_INTERACTION_CORE.md`.


## 13. Interaction service tests (TTL-08B-B)

`tests/server_shared/InteractionConfig.spec.lua` (Lune) covers the pure parts of the interaction adapter: validation of the server-only configuration, the distance-tolerance helpers checked against the real `InteractionCore` (prompt radius equals server-accepted radius; invalid raw distances are never made valid), and the rate-limit policy exercised through the real `RateLimiter` (burst, refill, one shared bucket across interactions, independent players, immediate plus deferred cleanup, `Interact` kept out of `NetworkConfig.RateLimits`). The `InteractionCore` specs are unchanged.

Requires Roblox Studio / a published Experience (not covered, not yet run): `InteractionService` prompt creation and cleanup, `Triggered` handling, character and target facts, `PlayerRemoving` timing, mission-lifecycle ordering and shutdown, touch behaviour. The 20-item checklist is in `docs/TTL-08B-B_INTERACTION_SERVICE.md`; every item is pending.


## 14. Door interaction tests (TTL-08C)

`tests/server_shared/DoorCore.spec.lua` (Lune) covers the pure door state machine: Closed to Open and Open to Closed, invalid transitions and states, rejection while transitioning (state and deadline unchanged), the exact deadline boundary, a backward clock, invalid clock values failing closed, a door that cannot stay stuck, and configuration validation. `tests/server_shared/DoorConfig.spec.lua` checks that the shipped door configuration is valid and cross-checks it against `DoorCore.validateConfig`, `InteractionCore.validateSpec` and the prompt-text validation (including cooldown at least the transition time), plus malformed and out-of-range settings. `tests/server_shared/InteractionConfig.spec.lua` gained cases for `validatePromptOptions`.

Requires Roblox Studio / a published Experience (not covered, not yet run): the runtime fixture, prompt behaviour, tween and final pose, lifecycle registration order, cleanup on shutdown, multi-player and mobile behaviour. The 13-item manual checklist is in `docs/TTL-08C_DOOR_INTERACTION.md`; every item is pending.


## 15. Party UI and mission preparation tests (TTL-HUB-02)

Pure Lune specs:
- `tests/shared/PartyView.spec.lua`: party snapshot validation, solo/multi-member rendering, leader changes, invite lifecycle/countdown, duplicate-action prevention, kick/leave affordances, and recovery of optimistic invite/responding state after server rejection.
- `tests/shared/LaunchView.spec.lua`: leader-only payload-less launch state, actual launch statuses, duplicate prevention, party-change reset and bounded recovery.
- `tests/shared/Messages.spec.lua`: safe text for launch and party-action rejection reasons, invite outcomes, and compact/regular layout metrics.

The server acknowledgement path in `PartyService` and the client controller wiring are Roblox-integrated code; pure specs do not execute RemoteEvents or prove delivery ordering. CI must run `lune run tests/run` and both HUB/MISSION Rojo builds. Do not describe these as passed until the workflow reports success.

Requires Roblox Studio / a published Experience (not covered by Lune): invite success and rejection (including unknown/disconnected target and invite quota), accept success and rejection when the target already belongs to a multi-member party, delayed/missing acknowledgement recovery, duplicate requests, leader changes, party UI updates on multiple clients, terminal prompt/input, leader-only launch, whole-party reserved-server teleport, failure/retry, and mobile portrait/landscape layout. The 16-item checklist is in `docs/TTL-HUB-02_PARTY_UI_MISSION_PREPARATION.md`; every item remains pending until performed and recorded.



## 16. Objective core tests (TTL-09A)

Pure Lune specs (no Roblox APIs; `docs/TTL-09_OBJECTIVE_SYSTEM.md` is the source of truth), registered in `tests/run.lua`:
- `tests/server_shared/ObjectiveGraph.spec.lua`: content validation (structure, limits, text rules, identity, references, cycles), the fixed validation order and deterministic first-offender reporting, the reserved `ALTERNATIVE` importance and `SIGNAL` completion being rejected with their own codes, input ownership (`validate` neither mutates nor freezes the caller's table; `compile` returns a frozen copy), runtime tri-state dependency evaluation (`allOf` / `anyOf`, unchanged semantics), and the mandatory progression rule: all nine examples of design section 6.4 as explicit tests, transitive invalidity, and a permutation test proving the verdict and the guaranteed set do not depend on definition order.
- `tests/server_shared/ObjectiveCore.spec.lua`: initialization and root availability, multi-slot contribution lifecycle, dependency cascades (including `anyOf` alternatives and dependents listed before their dependencies), parallel and optional objectives, duplicate and racing contributions, invalid contexts / contributors / objective and slot ids and the fixed rejection precedence, locked and terminal objectives, `fail` / `cancel` (REQUIRED objectives cannot be cancelled; idempotence; invalid transitions), atomicity (rejections and a hostile context change nothing), one revision per applied command, sticky exactly-once resolution (including the defense-in-depth `objective_unreachable` path on a hand-built plan), snapshot shape, privacy and copy semantics, hidden objectives, team-owned progress after a contributor becomes ineligible, determinism, and an invariant checker verified against deliberately corrupted state.
- `tests/server_shared/ObjectiveContent.spec.lua`: the shipped first-slice content passes `ObjectiveGraph`, is deeply frozen, has the documented objectives (`RESTORE_POWER` with three slots, `OPEN_WING`, the `EXTRACT` dev placeholder, optional `FIND_RECORDS`), satisfies the progression rule, uses no reserved feature, and is solo-completable through `ObjectiveCore`.

Run with `lune run tests/run`. CI must run it and both HUB/MISSION Rojo builds; do not describe TTL-09A as passed until the workflow reports success.

Not covered, not run, and out of scope for TTL-09A: `ObjectiveService`, interaction prompts, network contract and replication, client UI, mission lifecycle wiring, team-wipe handling, extraction policy, and every Roblox Studio / multiplayer / mobile check (the Studio checklist in the design document section 13 is unchanged and pending).

## 17. Objective service tests (TTL-09B)

Pure Lune specs, registered in `tests/run.lua`. `ObjectiveService` itself is Roblox glue and cannot be required under Lune; all orchestration lives in the pure `ObjectiveRuntime`, which the specs drive with in-memory fakes for the interaction layer, anchors, lifecycle, players, network, scheduler and clock (the real `ObjectiveGraph`, `ObjectiveCore`, shipped `ObjectiveContent` and `ObjectiveConfig` are used).
- `tests/server_shared/ObjectiveRuntime.spec.lua`: initialization with valid content, loud failure for invalid content / roster / bindings with full rollback; progression rejected before ACTIVE, after the lifecycle left ACTIVE and after stop (stale handlers stay dead, even after a restart); valid, invalid, unauthorized and duplicate interactions; prerequisite unlock and prompt reconciliation (including healing after a failed prompt update); one snapshot per applied command with consecutive revisions and none for rejections; initial snapshot and pull semantics (roster only, requester only); duplicate and stale revisions against a consumer-side revision rule; identical state and independent copies for several players; isolated delivery failures; resolution reported once, deferred, only through `isActive` / `endMission` and never over a lifecycle that already left ACTIVE.
- `tests/server_shared/ObjectiveConfig.spec.lua`: shipped configuration validity, derived interaction specs and prompt options against `InteractionCore.validateSpec` / `InteractionConfig.validatePromptOptions`, and the network contract additions (request, notification, rate limit, no objective command remote).

Run with `lune run tests/run`; CI must also run both Rojo builds. Not covered and not run: `ObjectiveService` wiring, `ObjectiveFixture` placement, real prompts, remotes and replication, mission teardown order and every Roblox Studio / multiplayer / mobile check. The Studio checklist is in `docs/TTL-09B_OBJECTIVE_SERVICE.md` and is pending.

## 18. Objective client tests (TTL-09C)

Pure Lune specs, registered in `tests/run.lua`. The HUD itself builds Roblox GUI instances and `ObjectiveNetwork` touches RemoteEvents, so neither can be required under Lune; all client state, revision and synchronization logic lives in the pure `ObjectiveView` and `ObjectiveController`, the latter driven by fakes for the listener, pull request, timers, clock and log.
- `tests/shared/ObjectiveView.spec.lua`: initial snapshot accepted as a baseline, newer revision replaces, stale and duplicate revisions change nothing, out-of-order convergence, malformed payloads rejected as a whole (every field of the snapshot and of each entry, inconsistent progress, duplicate ids, limits), empty and missing collections, only server-sent entries exposed (extra server fields never leak, hidden objectives appear only when the server includes them), required versus optional representation and flags, server order preserved, tracker selection, transition events, copy semantics.
- `tests/shared/ObjectiveController.spec.lua`: listener connected before the pull and the pull only after the ready signal, initialization race (lost push, push before ready, duplicate pull answer), idempotent start, newer / stale / duplicate revisions with no redundant notification, malformed payloads with bounded and throttled refreshes, bounded retry while unsynced, failing pull and listener tolerated, empty collections, copy semantics, listener isolation, destroy (disconnect, timers cancelled, listeners cleared, late deliveries ignored), restart with dead stale subscriptions.
- `tests/shared/Messages.spec.lua`: the new objective HUD strings.

Run with `lune run tests/run`; CI must also run both Rojo builds. Not covered and not run: `ObjectiveHud` rendering (layout, colours, touch targets, safe areas, toasts), `ObjectiveNetwork` against real remotes, the Bootstrap wiring, mission teardown behavior and every Roblox Studio / mobile / multiplayer check. The Studio checklist is in `docs/TTL-09C_OBJECTIVE_HUD.md` and is pending.

## 19. Mission map and objective anchor tests (TTL-10)

- `tests/server_shared/ObjectiveAnchors.spec.lua` (Lune, pure): `ObjectiveAnchors.index` / `missing` (valid ids, ambiguous ids resolve to nothing, invalid entries counted, order independence, garbage input), every shipped `pointId` is a valid anchor id, and the integration with `ObjectiveRuntime`: a complete map starts, a missing or ambiguous REQUIRED anchor fails the start closed, a missing OPTIONAL anchor only cancels its objective. `ObjectiveConfig.spec.lua` was adjusted for the removed fixture settings.
- `tools/asylum_greybox/validate_asylum_greybox.py` and `tools/asylum_greybox/test_validate_asylum_greybox.py` (Python, standard library only, run by `.github/workflows/mission-greybox-validation.yml`): schema and naming of the map sources, overlaps, a character-sized walker from the spawn through every room, doorway and anchor, loops in the room graph, the exact match between the authored `PointId`s and `ObjectiveContent.lua`, the Rojo `Workspace` mapping, freshness of the generated files and absence of the removed fixture.

Run `python3 tools/asylum_greybox/validate_asylum_greybox.py` and `python3 -m unittest discover -s tools/asylum_greybox -p "test_*.py"`, plus `lune run tests/run` and both Rojo builds. Not covered and not run: how the map looks and plays in Roblox Studio, Rojo's handling of the `Tags` and `Attributes` JSON forms, prompts at the authored positions, mobile and multiplayer behavior. See the checklist in `docs/TTL-10_FIRST_MISSION_MAP.md`.

## 20. Evidence core tests (TTL-11A)

Pure Lune specs, registered in `tests/run.lua` (no Roblox APIs):
- `tests/server_shared/EvidenceCatalog.spec.lua`: definition validation (structure, limits, tokens, text including control characters, the confirmation requirement, duplicate ids), fixed error ordering, determinism, input ownership (`validate` neither mutates nor freezes the caller's table), and `compile` as a frozen copy.
- `tests/server_shared/EvidenceCore.spec.lua`: initial state, the explicit state machine (valid and invalid transitions, terminal CONFIRMED, a seeded pseudo-random command stream checked against the transition table), duplicate observations and confirmations, shared and capped progress, source limit, invalid contexts / contributors / evidence / source ids, rejection precedence, atomicity, revision, copy semantics, determinism, mission-agnostic behavior, and the invariant checker against corrupted state.
- `tests/server_shared/EvidenceContent.spec.lua`: the shipped example catalog validates, is deeply frozen, is solo-viable and cannot be confirmed by a single report.

Run with `lune run tests/run`; CI must also run both Rojo builds. Not covered: any runtime integration (there is none in TTL-11A), `EvidenceService`, network and HUD (TTL-11B and later), and every Roblox Studio / multiplayer / mobile check.

## 21. Evidence service tests (TTL-11B)

Pure Lune specs, registered in `tests/run.lua`. `EvidenceService` is Roblox glue and cannot be required under Lune; all orchestration lives in the pure `EvidenceRuntime`, driven with the production `InteractionCore` and `RateLimiter` (so range, eligibility, participation, disabled prompts, busy/cooldown and rate limiting are enforced by the real code) plus fakes for the lifecycle, players, source objects, network and clock.
- `tests/server_shared/EvidenceRuntime.spec.lua`: initialization and failure with full rollback; valid discovery with authoritative ledger assertions; multi-player snapshots, joining and pulling; corroboration and confirmation policy; snapshot privacy; out-of-range, dead, non-participant and inactive-mission rejections; missing, unavailable, malformed, unknown and ambiguous sources; duplicate and flood handling; disconnects; failure isolation and healing; stop, restart and stale handlers.
- `tests/server_shared/EvidenceConfig.spec.lua`: configuration validation, derived interaction specs and prompt options against `InteractionCore.validateSpec` / `InteractionConfig.validatePromptOptions`, the generic prompt text, and the contract and rate-limit additions.

Run with `lune run tests/run`; CI must also run both Rojo builds. Not covered and not run: `EvidenceService` wiring, real prompts and replication, the authored evidence sources (none exist yet), mission teardown order and every Roblox Studio / multiplayer / mobile check. The Studio checklist is in `docs/TTL-11B_EVIDENCE_SERVICE.md` and is pending.
