# TTL-06 — Mission Lifecycle

Server-authoritative lifecycle of a MISSION server: from a fully assembled party to an active session, then termination, return to the HUB and cleanup.
Status: **IN REVIEW** — pure logic is covered by Lune tests; Roblox runtime behavior has **not** been validated (section 8).

## 1. Ownership

- `src/server_shared/MissionLifecycle/MissionLifecycleCore.lua` — pure state machine, context/config validation, session snapshot, invariants. No Roblox services, timers or globals.
- `src/mission/server/MissionLifecycle/MissionLifecycleService.lua` — Roblox integration: observes `MissionContextService`, starts registered mission systems once, ends the mission, marks players `RETURNING` through `PlayerStateService`, returns them to the HUB, cleans up.
- `src/mission/server/MissionLifecycle/MissionLifecycleConfig.lua` — timeouts and retry limits (validated at `init`).
- `HubPlaceId` remains in the existing server-only `MissionPlaces.lua` configuration. No client requests or remotes exist; clients cannot influence the lifecycle.

Mission lifecycle state is separate from individual player lifecycle (`PlayerStateService`).

## 2. State diagram

```
BOOTSTRAPPING -> WAITING_FOR_PLAYERS -> INITIALIZING -> ACTIVE -> ENDING -> RETURNING -> SHUTTING_DOWN -> CLOSED
                       |                     |            |         |           |
                       +--> ENDING (abort) <-+------------+         |           |
 every non-terminal state --> SHUTTING_DOWN (server closing) -------+-----------+
```

Allowed edges: BOOTSTRAPPING -> WAITING_FOR_PLAYERS, SHUTTING_DOWN; WAITING_FOR_PLAYERS -> INITIALIZING, ENDING, SHUTTING_DOWN; INITIALIZING -> ACTIVE, ENDING, SHUTTING_DOWN; ACTIVE -> ENDING, SHUTTING_DOWN; ENDING -> RETURNING, SHUTTING_DOWN; RETURNING -> SHUTTING_DOWN; SHUTTING_DOWN -> CLOSED. `CLOSED` is terminal. Repeating the current state is an idempotent no-op. Outcomes (not extra states): `COMPLETED`, `FAILED`, `ABORTED`, each with a validated reason token (`[A-Za-z0-9_-]`, 1-48 chars).

## 3. Startup flow

1. Bootstrap runs `NetworkService.init`, `PlayerStateService.init`, `MissionContextService.init`, then `MissionLifecycleService.init` (state `BOOTSTRAPPING` -> `WAITING_FOR_PLAYERS`).
2. The service subscribes to `MissionContextService.onStateChanged` (event driven, no polling) and also evaluates the current context once (it may already be `READY`).
3. `NO_CONTEXT`, `WAITING` and `INCOMPLETE` never start a mission. Late arrivals follow the TTL-05 rules and can still turn `INCOMPLETE` into `READY`.
4. On `READY`, `MissionLifecycleCore.submitContext` validates mission id, party id, leader, unique member list (1-8), expected mission type and that arrivals equal the expected set with none missing. Arrival order is irrelevant. An invalid context aborts the mission (`ABORTED/invalid_context`); it is never silently accepted. Submission can succeed only once (`already_initialized`), so duplicate readiness notifications cannot initialize twice.
5. State `INITIALIZING`: registered systems start in registration order inside `pcall`, before the mission becomes `ACTIVE`. A system is registered for cleanup before its `start` callback is entered. If startup fails or synchronously ends the mission, no later system starts; cleanup is deferred until the current `start` callback returns, then systems are stopped in reverse order exactly once. A failure aborts (`ABORTED/initialization_failed`) and never reaches `ACTIVE`.
6. If no valid context exists within `contextWaitTimeoutSeconds` the mission aborts (`ABORTED/context_timeout`).

## 4. Termination and return flow

`endMission(outcome, reason)` (server systems only): the first valid call wins and moves to `ENDING`; later calls (also from any later state) are idempotent and report the original outcome/reason. Invalid outcomes/reasons are rejected; it is rejected before the lifecycle exists and while still `BOOTSTRAPPING`.

On the first call: mission systems are stopped in reverse order (progression frozen). Each connected participant is moved to `RETURNING` via `PlayerStateService.transition` (never writing attributes, never back to `ALIVE`). A player whose transition is rejected is deliberately not teleported and remains in this server for diagnosis/recovery. The core enters `RETURNING`, then the return teleport starts for successfully transitioned players only:
- Destination is `MissionPlaces.HubPlaceId`, server-only. No reserved server is created. A small internal retry-correlation token is sent in teleport data; it is not used as gameplay state or trusted authority.
- `TeleportAsync` is wrapped in `pcall` (only that call). Each return attempt carries an internal, non-sensitive attempt token in `TeleportOptions` teleport data. `TeleportInitFailed` echoes that data in its retry options; only a failure matching the player's current token can consume retry budget, so late failures from earlier attempts are ignored. The HUB must ignore the `_ttl06ReturnAttemptId` field. On a synchronous error or a matching `TeleportInitFailed` for the HUB, each affected player is retried up to `returnMaxRetriesPerPlayer` times after `returnRetryDelaySeconds`, never when disconnected. Players that leave the server resolve their slot.
- Permanent failure logs a server diagnostic and leaves the player in this server (safe state); the mission is never restarted.
- The return ends when every slot is resolved or `returnTimeoutSeconds` passes, then final cleanup runs (`SHUTTING_DOWN` -> `CLOSED`).
- If `HubPlaceId` is `0` (unconfigured) the return fails safely at once: warning logged, players stay, lifecycle closes. It never pretends the return succeeded.

`shutdown()` / `BindToClose` run the same cleanup from any state and record `ABORTED/server_shutdown` when no result exists yet.

Cleanup is idempotent: connections and the context subscription are dropped, systems stopped, and a generation token is bumped so any delayed callback (retries, timeouts) becomes a no-op on a closed or restarted lifecycle.

## 5. Public service API

`init()`, `shutdown()`, `getState()`, `isActive()`, `getSession()` (copy: mission id, party id, leader, expected members, connected `participantUserIds`, start time, state, outcome/reason), `getOutcome()`, `endMission(outcome, reason)`, `onStateChanged(listener)`, `registerSystem({ name, start(session), stop? })` (only before `INITIALIZING`). Callers can never mutate internal session state.

## 6. Configuration

`MissionLifecycleConfig.lua`: `expectedMissionType` ("DEFAULT"; must match HUB `MissionTeleportConfig.missionType`), `contextWaitTimeoutSeconds` (120), `returnMaxRetriesPerPlayer` (2), `returnRetryDelaySeconds` (2), `returnTimeoutSeconds` (30). `MissionPlaces.lua` is the single server-only source for place ids; configure its existing `HubPlaceId` and `MissionPlaceId` values before real teleports can work.

## 7. Failure behavior (summary)

Invalid context, init failure or timeout -> `ABORTED` and return of successfully transitioned participants; rejected `RETURNING` transitions fail closed (player stays); duplicate `endMission` -> original result kept; player disconnects never block cleanup; retry exhaustion -> diagnostic, player stays; stale callbacks and stale teleport-failure events -> ignored by generation/attempt tokens. In ordinary Studio playtests no teleport data exists, so the context never becomes `READY` and the lifecycle aborts after `contextWaitTimeoutSeconds` and closes (expected).

## 8. Validation

Automated (Lune, `MissionLifecycleCore.spec.lua`): initial state, full graph matrix, invalid and skipped transitions, idempotency, READY-only startup, dense expected/arrival array validation (including malformed keys and holes), finite `startedAt`, duplicate initialization, COMPLETED/FAILED/ABORTED termination, abort during initialization/waiting, original-result preservation, terminal `CLOSED`, snapshot immutability, invariants, shutdown semantics, config validation. Not automated: service event wiring, reentrant system-start/stop behavior, timers, `TeleportService` attempt-token round-trip, and `PlayerStateService` integration.

Manual (Studio / published Experience) — NOT yet performed:
1. Studio MISSION playtest: lifecycle logs `WAITING_FOR_PLAYERS`, aborts and closes after the wait timeout; no errors.
2. Published Experience, HUB -> MISSION launch of a solo party: lifecycle reaches `ACTIVE` once; `getSession()` correct.
3. Party of 2-4 with staggered arrivals: no start until all arrived; one initialization.
4. Call `endMission("COMPLETED", ...)` from a test script: players with successful `RETURNING` transitions are teleported to the HUB, rejected transitions remain in the MISSION server, server closes; repeat call is a no-op. Verify `_ttl06ReturnAttemptId` is ignored by HUB gameplay.
5. Same with `FAILED` and an unconfigured `HubPlaceId` (players stay, diagnostic logged).
6. Disconnect a player during startup, active play and return; verify no stuck lifecycle.
7. Kill the server (shutdown) during `ACTIVE`: `ABORTED/server_shutdown`, no errors.

## 9. Known limitations

No objectives, rewards or persistence; no client notifications; return is best-effort (Roblox teleports are not atomic); `participantUserIds` is computed from current connections; a mission-level system registry is intentionally minimal; the hub return cannot be tested outside a published Experience.


## 10. Retry correlation note

Roblox's `TeleportInitFailed` event does not expose a numeric invocation ID. TTL-06 therefore places a unique attempt token in the return `TeleportOptions` teleport data and validates the echoed token on failure. This is internal routing metadata, not player progress or authority. HUB code must ignore the `_ttl06ReturnAttemptId` field. Live verification of the event round-trip remains part of the published-Experience checklist.
