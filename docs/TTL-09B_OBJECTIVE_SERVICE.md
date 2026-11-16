# TTL-09B — ObjectiveService Integration

Status: implemented in PR (pending review and merge). Automated checks: pending CI (`lune run tests/run`, both Rojo builds). **Roblox Studio, multiplayer and mobile validation: pending, none performed.**

Source of truth: `docs/TTL-09_OBJECTIVE_SYSTEM.md` (sections 3, 7, 8, 11) and the merged TTL-09A core.

## Scope

Server-side integration of `ObjectiveGraph` / `ObjectiveCore` into the MISSION runtime. Out of scope: HUD and client controller (TTL-09C), team-wipe handling, extraction policy (`EXTRACT` is a dev placeholder), inventory / evidence / ritual, new content.

## Components

| File | Role |
|---|---|
| `src/server_shared/Objective/ObjectiveRuntime.lua` | Pure orchestration with injected ports: compiles the content once, owns the `ObjectiveCore`, registers one interaction per slot, reconciles prompts, publishes snapshots, answers pulls, reports a resolution to the lifecycle. Lune-tested. |
| `src/mission/server/Objective/ObjectiveService.lua` | Roblox glue: wires real services into the runtime, builds the anchors, registers the pull request and the lifecycle system `Objective`. |
| `src/mission/server/Objective/ObjectiveConfig.lua` | Server-only interaction and prompt tunables with a pure validator (the fixture section was removed in TTL-10). |
| ~~`ObjectiveFixture.lua`~~ | Removed in TTL-10: anchors now come from the authored map (tag `ObjectivePoint`, attribute `PointId`), see `docs/TTL-10_FIRST_MISSION_MAP.md`. |
| `NetworkContract` / `NetworkConfig` | `ObjectiveRequestSnapshot` (no payload, rate limit 3 / 0.5 per s) and `ObjectiveSnapshot` (full snapshot). |
| `mission/server/Bootstrap.server.lua` | `ObjectiveService.init()` after `DoorInteractionService.init()`, before `MissionLifecycleService.init()`. |

## Flow

1. `InteractionService` validates the activation (mission ACTIVE, roster, ALIVE, character, target, distance, rate limit, busy, cooldown).
2. The slot handler (a closure carrying only ids and a generation) re-checks lifecycle active, connected roster member and `ALIVE`, then calls `ObjectiveCore:contribute`.
3. When the command is applied: prompts are reconciled from Core state, one snapshot per connected participant is sent, and a resolution (if any) is reported to the lifecycle through `endMission`, deferred, generation-guarded, and only while the lifecycle is still ACTIVE.
4. The handler returns true only for an applied change, so rejected or duplicate activations consume no cooldown and publish nothing.

## Behavior notes

- Snapshots: sent at start (clients may not be listening yet) and after every applied command; a pull answers only the requester with the current revision. Consumers accept only strictly newer revisions (initial value -1).
- A REQUIRED slot that cannot be anchored or registered aborts the mission start (rollback, ABORTED / initialization_failed). An OPTIONAL objective is cancelled with `binding_failed` and the mission continues; if the Core cannot cancel it (it is still LOCKED) the start aborts, because the Core only defines cancel from AVAILABLE / IN_PROGRESS.
- Prompt updates never change Core state; a failed update is retried by the next reconcile.
- The lifecycle keeps ownership of mission state. The runtime only calls `isActive` and `endMission`.
- Known gaps: a total team wipe does not end the mission (separate mission-outcome component, design 11.5); the anchor placement of the authored map (TTL-10) is unverified in Studio; prompt distance and tolerance are provisional.

## Studio checklist (all pending)

1. Six anchors appear in a row in front of the spawn, clear of the test door; native prompts show "Use" with the slot label.
2. Only available objectives show prompts; locked ones do not.
3. Filling slots updates prompts and unlocks the dependent objective exactly once.
4. Two players on the same slot: exactly one fill.
5. DEAD / GHOST / SPECTATING players cannot contribute.
6. A contributor leaving after a fill does not roll back progress.
7. Finishing the optional objective does not end the mission; finishing the required path ends it once (COMPLETED / objectives_complete) and returns players.
8. Abort or shutdown removes prompts, anchors and the request handler; no late snapshots.
9. `ObjectiveRequestSnapshot` spam is rate limited; a second pull is harmless.
10. Solo, 2 and 4 players; later 8.
