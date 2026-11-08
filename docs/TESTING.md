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
