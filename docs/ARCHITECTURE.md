# THE LAST TURN — Architecture Overview

**Status:** Architecture baseline v1.0  
**Purpose:** Define system ownership and boundaries before gameplay implementation.

## 1. Deployment model

```mermaid
flowchart TD
    Client[Roblox Player Client] --> Hub[HUB Place Server]
    Hub --> Party[Party Service]
    Hub --> Match[Matchmaking / Reservation]
    Match --> Teleport[Teleport to Reserved Server]
    Teleport --> Mission[MISSION Place Server]
    Mission --> Results[Mission Result Payload]
    Results --> Return[Return Teleport to HUB]
    Return --> Profile[HUB Profile / Progression]
```

Each party receives an isolated mission server. A mission instance owns its own entity, Director, objective and evidence state. No cross-match mutable state is permitted.

## 2. Authority boundaries

| Concern | Authority | Client responsibility |
|---|---|---|
| Party membership | HUB server | Display party state, request actions |
| Match allocation | HUB server | Show launch/teleport status |
| Mission phase | MISSION server | Render phase and objectives |
| Evidence truth | MISSION server | Present discovered evidence |
| Inventory/resources | MISSION server | Request valid interactions |
| Entity AI/Director | MISSION server | Render replicated cues |
| Death/Ghost permissions | MISSION server | Camera and ghost controls |
| Rewards/profile | Server-side persistence flow | Display confirmed results |

A client request is never proof that an action succeeded.

## 3. Mission composition

```mermaid
flowchart LR
    Mission[MissionService] --> Objectives[ObjectiveService]
    Mission --> Evidence[InvestigationService]
    Mission --> Ritual[RitualService]
    Mission --> Entity[EntityAIService]
    Director[DirectorService] --> Entity
    Director --> Events[Authored Event Pool]
    Entity --> Threat[Threat / Manifestation]
    Ghost[GhostService] --> Lifecycle[Player Lifecycle]
    Interaction[InteractionService] --> Objectives
    Interaction --> Evidence
    Interaction --> Ritual
```

MissionService owns phase transitions and coordinates subsystems. Subsystems own their own state and expose narrow APIs. Avoid circular dependencies; pass explicit dependencies during construction.

## 4. Mission lifecycle

- Create a unique mission session identifier and configuration seed.
- Validate joining players and initialize character/state.
- Start mission systems only after initialization succeeds.
- Enter phases through a guarded transition API.
- On completion/failure, freeze objective progression and calculate one result.
- Invalidate delayed callbacks and clean up connections/tasks.
- Teleport players back with bounded retry and a safe fallback message.

## 5. Data and configuration

Keep content configuration separate from runtime state:
- Entity definitions: authored evidence, abilities, behavior parameters.
- Event definitions: eligibility, phase constraints, cooldown, effects.
- Objective definitions: prerequisites, required contributions, completion conditions.
- Ritual definitions: steps, items and interruption behavior.
- Mission configuration: chosen location/entity/modifiers and deterministic seed.

Validate configuration at startup. A malformed config should fail safely with a useful server log, not softlock a live mission.

## 6. Cross-place contracts

The HUB-to-MISSION teleport payload should contain only validated, minimal data:
- schema version;
- opaque match/session identifier;
- party member identifiers;
- selected loadout identifiers;
- mission seed/config identifier;
- leader or matchmaking metadata required by the mission.

Do not trust arbitrary client-supplied teleport data. Validate membership and session on arrival. Never include secrets or long-lived credentials.

Mission result payload should be compact and versioned. The HUB validates the returning player/session before applying progression. Duplicate result delivery must not duplicate rewards.

## 7. Failure and recovery

Explicitly handle:
- Party leader disconnects before launch.
- Player disconnects during teleport.
- Reserved server allocation or teleport failure.
- Player arrives late or with invalid session data.
- Mission server shuts down unexpectedly.
- Player dies while objectives are active.
- All living players die.
- Player leaves while carrying a required resource.
- Mission completes while a player is teleporting.
- Result payload is missing, stale or delivered twice.

Each feature PR must cover the failure cases relevant to its scope. Do not attempt to solve every future failure mode with speculative framework code.

## 8. Network boundaries (TTL-02)

HUB and MISSION use identical networking conventions.

| Location | Contents | Visible to client |
|---|---|---|
| `ReplicatedStorage.Shared.Network` | `NetworkContract` (remote names, protocol version), `ClientNetwork`, diagnostic client | Yes (names only; not secrets, not authorization) |
| `ReplicatedStorage.Network.Requests` | Client -> server RemoteEvents, created by the server at startup | Yes |
| `ReplicatedStorage.Network.Notifications` | Server -> client RemoteEvents, created by the server at startup | Yes |
| `ServerStorage.ServerShared.Network` | `NetworkService`, `Validator`, `RateLimiter`, `NetworkConfig`, `DiagnosticHandshake` | No (server-only) |

Request pipeline (all client requests are untrusted):

1. Roblox supplies the `Player`; payloads never carry identity. Requests from players already leaving are dropped.
2. Per-player, per-request token-bucket rate limit (`NetworkConfig.RateLimits`). Rejected requests never reach the handler.
3. Schema validation (types, required/optional fields, string length, numeric bounds, no unexpected fields, no extra arguments). Failure is logged on the server and nothing is sent back.
4. A handler registered by server code for a name declared in `NetworkContract.Requests` runs in `pcall`.

Rules: one purpose-specific remote per request or notification; no generic dispatch; clients cannot create or register endpoints; `NetworkService.init()` is idempotent and runs in each server bootstrap before dependent systems; per-player limiter state is removed on `PlayerRemoving`. The `ClientReady` / `HandshakeAck` pair is a removable diagnostic and grants no authority.

## 9. Player lifecycle (TTL-03)

`PlayerStateService` (server-only, `ServerStorage.ServerShared.Player`) is shared by HUB and MISSION. Rules and storage live in the pure `PlayerStateCore`; the service only adds Roblox event handling. It initializes after `NetworkService.init()` in both bootstraps.

| State | Meaning |
|---|---|
| ALIVE | Alive and actively participating (initial state of every registered player) |
| DEAD | Died; post-death flow pending or being resolved |
| GHOST | In the ghost participation state |
| SPECTATING | Observing other players; not participating |
| RETURNING | Leaving the mission / returning to the HUB; terminal for the current lifecycle |

Allowed transitions (all others rejected; repeating the current state is an idempotent no-op):

```
ALIVE      -> DEAD, RETURNING
DEAD       -> GHOST, SPECTATING, RETURNING
GHOST      -> SPECTATING, RETURNING
SPECTATING -> RETURNING
RETURNING  -> (none)
```

There is intentionally no transition back to ALIVE; a future mission/respawn design decides how a new participation lifecycle begins.

- **Authority:** only server code calls `transition`. There is no remote and no client-supplied state. Transition reasons stay on the server (`onStateChanged` listeners).
- **Replication:** the server sets the Player attribute `LifecycleState` (name in `PlayerLifecycle.StateAttribute`). Clients read it with `player:GetAttribute` / `GetAttributeChangedSignal`; client-side writes do not replicate to the server and never affect authority. Trade-off: Player attributes replicate to all clients, so other players can see each player's state. Move to a per-player remote if a design requires hiding it.
- **Character handling:** lifecycle state is independent of the character. `CharacterAdded`/`CharacterRemoving` only (re)bind `Humanoid.Died`; they never change or reset state. Each character gets a token; callbacks from replaced characters are ignored. A missing Humanoid is awaited via `ChildAdded` (no wait loop) and the connection ends with the character. `Humanoid.Died` moves ALIVE -> DEAD only; death events in other states are ignored.
- **Cleanup:** `PlayerRemoving` disconnects all player/character connections and removes the state. `shutdown()` clears everything, including attributes; `init()` and `shutdown()` are idempotent.
- **Not included:** Ghost abilities, spectator camera/UI, respawn/revive, party, mission lifecycle, teleport, persistence.

## 10. Party System (TTL-04, HUB only)

Ownership: the pure `PartyCore` (`ServerStorage.ServerShared.Party`, no Roblox services) owns party data and every rule; `PartyService` (`ServerScriptService.Party`, HUB server only) owns Roblox integration: `PlayerAdded`/`PlayerRemoving`, remote handlers, invitation timers and notifications. MISSION does not initialize it. Party membership exists only in the current HUB server (no cross-server state, no MemoryStore).

Rules:
- Every connected HUB player is in exactly one party; joining creates a solo party (player is leader). Server-generated unique ids (never reused). Capacity 1-8 (`Constants.Experience.MaxPartySize`), enforced at invite time and again at acceptance.
- Only the leader invites or kicks. A leader cannot invite or kick themselves. Kicked or leaving players get a new solo party (leaving while solo is a no-op).
- Leader leaves or disconnects: leadership moves to the earliest-joined remaining member (members are kept in join order). Empty parties are destroyed.
- Invitations: pending record inviter -> target tied to the inviter's party, expiring after `inviteTtlSeconds` (60 s, `PartyConfig`). Duplicate pending invitation for the same pair is rejected; pending counts are capped per target (8) and per inviter (16). Several different leaders may invite the same target; whichever is accepted first wins and the rest end as "superseded". Acceptance is rejected if the target is in a multi-member party (it never silently moves/disbands a party), the invite expired, or the party is full (invite is kept so it can be retried). Invitations are never proof of membership; they are cancelled when the inviter leaves/changes party or either side disconnects, and expired lazily on use and by a per-invite timer (no polling loop).
- Disconnect: membership, leadership and all invitations from/to the player are cleaned up in one core call; `PartyCore.validateInvariants` (used in tests) proves no orphaned party, membership or invite remains.

Networking (TTL-02 conventions, `NetworkContract`): requests `PartyInvite {targetUserId}`, `PartyRespondInvite {inviterUserId, accept}`, `PartyLeave`, `PartyKick {targetUserId}`, `PartyRequestSnapshot` (client pulls its snapshot after connecting its listener, since a push at join can be missed); notifications `PartySnapshot` (to each party member: partyId, leaderUserId, ordered members with displayName; recipient-specific `pendingInvites` included on snapshot pull/individual delivery only), `PartyInviteReceived` (target only), `PartyInviteEnded` (inviter and target only; reason accepted/declined/expired/cancelled/superseded). Pending invitations are never included in a party-wide shared payload. Clients never send party ids, membership or leader identity; the requesting `Player` comes from Roblox; targets are resolved from connected players. Rejections are not reported to the requesting client yet (UI task). Because the contract is shared, MISSION creates these remotes but registers no handlers.

TTL-05 boundary: Mission Teleport reads parties through `getParty`, `getMembers`, `getLeader` and `onPartyChanged`; it must not mutate party state except through the public service API. No matchmaking, teleport, party UI or chat is part of TTL-04.

## 11. Mission Teleport (TTL-05, HUB → MISSION)

`MissionTeleportService` (HUB only) consumes `PartyService.getParty` and `PlayerStateService.getState` through their public APIs. Its pure `LaunchCoordinator` owns one in-flight launch per party, snapshots and revalidates membership, creates a server-generated mission ID and `TeleportOptions.ReservedServerId` GUID, and sends the group with `TeleportService:TeleportAsync`. Retries use the original `TeleportOptions` supplied by `TeleportInitFailed` and are bounded per player; group transfer is not atomic.

MISSION `MissionContextService` validates the destination place and reserved-server environment, then validates each player's server-side `GetJoinData()` origin (`SourcePlaceId` must be the configured HUB PlaceId and `SourceGameId` must match the current Experience) before accepting the versioned teleport payload. `ArrivalCore` coordinates staggered arrivals and exposes `NO_CONTEXT / WAITING / READY / INCOMPLETE` state; it does not start gameplay.

Configuration lives in server-only `MissionPlaces.lua`: owner must set both `HubPlaceId` and `MissionPlaceId` to real places in the same published Experience. Zero keeps launch/arrival disabled. Real teleport validation requires a published Experience and Roblox client; Lune tests and Rojo builds do not validate Roblox teleport runtime.
## 12. Mission Lifecycle (TTL-06, MISSION only)

MissionLifecycleService (ServerScriptService.MissionLifecycle) owns the mission lifecycle on top of the pure MissionLifecycleCore (ServerStorage.ServerShared.MissionLifecycle). It initializes after MissionContextService, starts a mission only from a validated READY arrival context, and ends it through the server-side endMission(outcome, reason) (idempotent; first result wins). Ending freezes progression, moves participants to RETURNING through PlayerStateService, returns them to MissionPlaces.HubPlaceId with bounded retries and cleans up with generation-guarded callbacks.

States: BOOTSTRAPPING -> WAITING_FOR_PLAYERS -> INITIALIZING -> ACTIVE -> ENDING -> RETURNING -> SHUTTING_DOWN -> CLOSED.

No remotes, no client authority. Details, diagram, API and manual checklist: docs/TTL-06_MISSION_LIFECYCLE.md.