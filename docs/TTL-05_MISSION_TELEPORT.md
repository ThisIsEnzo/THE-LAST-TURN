# TTL-05 — Mission Teleport

Server-authoritative transport of a whole HUB party into one private (reserved) MISSION server.
Status: **IN REVIEW** — pure logic and Rojo mappings only; real teleportation has **not** been tested (see section 9).

## 1. HUB launch flow

1. A client fires the payload-less `MissionLaunch` request (TTL-02: rate limited, `args = {}`, so extra arguments are rejected). Identity is the `Player` from the remote callback.
2. `LaunchCoordinator.requestLaunch` (pure) validates, in order: MISSION PlaceId configured, requester connected, requester has a party (via `PartyService.getParty`), requester is the party leader, no launch already active for the party, party size 1-8 with unique, consistent members, every member connected, every member in lifecycle `ALIVE` (via `PlayerStateService.getState`), no member still pending in another launch.
3. It takes the party lock, snapshots the members, generates the mission id and reserved-server id (`HttpService:GenerateGUID(false)`, once per launch), builds the payload, then **revalidates** party identity/leader/members, connectivity and lifecycle. A change cancels the launch (`party_changed`) and releases the lock.
4. State becomes `TELEPORTING`, members are notified (`accepted`), and `TeleportService:TeleportAsync(placeId, players, options)` is called with `ReservedServerId` and the payload as teleport data. Only that call is wrapped in `pcall`.
5. Players leaving the server resolve their slot; the launch finishes when no slot is pending.

The client never supplies PlaceId, reserved server id, party, members, mission type or mission id.

## 2. MISSION arrival flow

`MissionContextService` (server-only) runs for every player on `PlayerAdded` (and existing players at init):
- Environment check (`ArrivalCore.checkEnvironment`): `game.PlaceId` equals the configured MISSION PlaceId, `game.PrivateServerId` is non-empty and `game.PrivateServerOwnerId == 0` (reserved server). Otherwise every arrival is rejected.
- `player:GetJoinData().TeleportData` is validated with `TeleportPayload.validate` (fail closed).
- `ArrivalCore.arrive`: the first valid arrival creates the context; later arrivals must match mission id, party id, leader, mission type and member set exactly, and be listed members. Duplicates are idempotent; unexpected or conflicting players are never added.
- Rejected players are logged (code only, never payload or ids) and kicked, except in Studio (where no teleport data exists, so playtests are not kicked).
- States: `NO_CONTEXT` -> `WAITING` -> `READY` (everyone arrived) or `INCOMPLETE` (arrival timeout, default 45 s, with the missing UserIds listed; late valid arrivals can still complete it). `getContext()` returns a copy; later systems must check `state`. No gameplay starts.

## 3. Payload schema (version 1)

| Field | Type / rule |
|---|---|
| `schemaVersion` | must equal 1 |
| `missionId` | string 1-64, `[A-Za-z0-9-]` |
| `partyId` | string 1-32, `[A-Za-z0-9_-]` |
| `partyLeaderUserId` | integer 1..2^53-1, must be in `memberUserIds` |
| `memberUserIds` | array of 1-8 unique integers 1..2^53-1, no holes |
| `missionType` | string 1-32, `[A-Za-z0-9_-]` (server constant `DEFAULT`) |
| `createdAt` | integer epoch seconds 0..4102444800 (informational) |

Unexpected fields, wrong types, oversize arrays and duplicates are rejected. The reserved-server id and any secrets are never in the payload. Teleport data is not proof of authorization; the MISSION environment check is the second factor and exact cross-player agreement the third.

## 4. Launch state lifecycle

`PREPARING` (snapshot, ids, revalidation) -> `TELEPORTING` -> finished as `COMPLETED` (nobody failed), `PARTIAL_FAILURE` (some failed, some left) or `FAILED` (all failed). Finished launches are removed immediately, so a party's lock can never leak: it is released on completion, failure, synchronous teleport error, revalidation failure, or after `launchTimeoutSeconds` (60 s) for unresolved members. One active launch per party; different parties are independent.

## 5. Retry and partial-failure behavior

- Synchronous `TeleportAsync` error: launch fails, all members are notified (`teleport_failed`), lock released, **no automatic retry**.
- `TeleportService.TeleportInitFailed` is tracked per player against the active launch. The event's `ReservedServerId` must equal the launch's; otherwise it is ignored (other/newer launches are never touched).
- Retries use the `TeleportOptions` from the event (same destination, never a new reserved server), at most `maxRetriesPerPlayer` (2) per player with `retryDelaySeconds` (2) between attempts. A retry call that errors counts as another attempt. Disconnected players are not retried. A failure event carrying no options cannot be retried and fails the player.
- At the limit the player gets `teleport_failed`, remaining members get `partial_failure`, and the lock is released once nothing is pending.

**Guarantees / non-guarantees.** Roblox group teleports are not atomic: some members can arrive while others fail. This system guarantees one reserved destination per launch, bounded retries to that same destination, no retry of players who left, and no leaked lock. It cannot guarantee that all members arrive, cannot tell a successful transfer from a disconnect (both resolve the slot), and does not reunite a split party; failed players stay in the HUB (their old party membership is unaffected) and the leader could launch again, which creates a **new** mission.

## 6. Networking contract

Request: `MissionLaunch` (no payload; rate limit capacity 2, refill 0.2/s). Notification: `MissionLaunchStatus { status, code?, attempt?, maxAttempts?, failedUserId? }`, sent only to the requester (rejections) or the launching party members. `status`: `accepted`, `already_in_progress`, `not_leader`, `invalid_party`, `preparation_failed`, `teleport_failed`, `retrying`, `launch_initiated`, `partial_failure`. `code` is a short internal reason for diagnostics/UI (never an id). MISSION shares the contract but registers no `MissionLaunch` handler.

## 7. Configuration (owner action required)

- `src/server_shared/MissionTeleport/MissionPlaces.lua`: set `MissionPlaceId` to the real MISSION PlaceId (same Experience as the HUB). `0` = disabled: the HUB logs a warning and answers `preparation_failed`/`mission_not_configured`; MISSION rejects arrivals. No id was invented.
- `src/hub/server/MissionTeleport/MissionTeleportConfig.lua`: mission type, retries, delay, launch timeout. `src/mission/server/MissionContext/MissionContextConfig.lua`: arrival timeout.
- Both Places must be published in the same Experience and API/teleport access enabled for the Experience.
- Note: `docs/PHASE_0_CHECKLIST.md` says teleport work should wait for known PlaceIds (P0-07/P0-08 still BLOCKED). This task was explicitly requested with a safe disabled state; those checklist items remain unchanged.

## 8. Security boundaries

Client chooses nothing; every remote is rate limited and validated; handlers run server-side only; party data comes from `PartyService`'s public API (PartyCore is never touched); reserved ids are not logged, replicated or put in teleport data; MISSION fails closed on bad data and never adds players to a mismatching context.

## 9. Automated vs manual validation

Automated (Lune, pure): payload schema, arrival coordination and environment rules, launch validation, duplicate/independent launches, unique ids, preparation changes, sync failure, `TeleportInitFailed` handling, same-destination retry, retry limit, disconnect during retry, cleanup/no stale locks. Not automated: everything touching Roblox (`TeleportService`, `GetJoinData`, reserved-server properties, remotes, timers). Teleporting does not work in ordinary Studio playtests.

### Manual checklist (published Experience, Roblox client) — NOT yet performed

1. Set the real HUB and MISSION PlaceIds (`MissionPlaces.lua`); publish both places to the same Experience.
2. Join the HUB from the Roblox client; confirm the log shows no "not configured" warning.
3. Solo launch: arrives in a reserved MISSION server; `MissionContextService.getState()` is `READY`.
4. Party of 2: both arrive in the **same** server; same `missionId`/`partyId`; state `READY`.
5. Party of 4: same checks; arrivals may be staggered (`WAITING` then `READY`).
6. Non-leader fires `MissionLaunch`: receives `not_leader`; nothing teleports.
7. Leader double-fires: second request gets `already_in_progress`; only one server is created.
8. Disconnect a member during launch (where practical): launch completes for the others, no stuck lock afterwards.
9. Two separate parties launch from the same HUB: they land in **different** reserved servers.
10. Join the MISSION place directly (not via teleport): player is rejected/kicked (fail closed).
11. Wait past the arrival timeout with a missing member: state `INCOMPLETE`, missing UserId listed.
12. Simulate/observe a teleport failure if possible (e.g. unavailable place) and confirm `retrying` then `teleport_failed`, with the lock released.

## 10. Known limitations

No matchmaking, persistence, reconnect or crash recovery; partial group transfer is possible (section 5); successful transfer is inferred from the player leaving; invalid arrivals in MISSION are kicked rather than returned to the HUB; clients cannot choose a mission type; no UI.
