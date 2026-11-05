# THE LAST TURN — Technical Specification v1.0

**Status:** Approved technical baseline  
**Related:** [GDD](./Game%20Design%20Document%20%E2%80%94%20Version%201.0.md), [Architecture](./ARCHITECTURE.md), [Gameplay Rules](./GAMEPLAY_RULES.md), [Roadmap](./Development%20Roadmap%20%E2%80%94%20Version%201.0.0.md)

## 1. Technical goals

Build a maintainable Roblox experience for 1–8 players, supporting a persistent social HUB and isolated mission sessions. Prioritize a complete, replayable mission over framework complexity or content volume.

Non-goals for the initial implementation: machine-learning AI, large open-world streaming, trading, crafting, competitive PvP, complex procedural map generation, and premature monetization infrastructure.

## 2. Platform and toolchain

- Roblox Studio and Luau.
- Rojo 7.6.1 for filesystem-to-DataModel synchronization.
- Rokit for pinned developer tools.
- GitHub for source control and PR review.
- TestEZ or an equivalent Luau test runner when introduced.
- StyLua and Selene may be added during bootstrap; do not block initial documentation work on them.

Pin exact versions in the repository. Tool upgrades require a separate, reviewable change. Roblox services and APIs must be checked against current Roblox documentation during implementation.

## 3. Experience topology

The Roblox experience contains two Places:

### HUB Place
Owns social and pre-mission flows:
- Player arrival and safe lobby state.
- Party creation, membership and leader.
- Equipment loadout selection.
- Match launch request.
- Persistent profile loading/saving.
- Post-mission result presentation.

### MISSION Place
A reserved server instance per party/match:
- Mission initialization and configuration.
- Mission state machine and objectives.
- Investigation/evidence.
- Entity AI and event Director.
- Ritual sequence.
- Player death and Ghost Mode.
- Results and return teleport.

A mission server must never share mutable mission state with another match. Use TeleportService reserved servers for isolated sessions; use MemoryStoreService only where cross-server matchmaking/coordination is actually required. Teleport failure, retry and party recovery must be designed, not assumed away.

## 4. Runtime service boundaries

Suggested server modules (introduce incrementally, not as empty scaffolding):

- **PartyService (HUB):** party membership, leader, capacity and leave/disconnect handling.
- **MatchmakingService (HUB):** validates party and allocates mission server.
- **TeleportServiceAdapter:** isolates Roblox teleport calls and failure handling.
- **PlayerDataService (HUB):** profile schema, load/save, retries and session locking strategy.
- **MissionService (MISSION):** mission lifecycle and authoritative phase.
- **MissionConfigService (MISSION):** validated, seeded mission configuration.
- **ObjectiveService (MISSION):** objective requirements, progress and completion.
- **InteractionService (MISSION):** server-validated interaction requests.
- **InvestigationService (MISSION):** evidence discovery and evidence ledger.
- **InventoryService (MISSION):** mission equipment and resource ownership.
- **RitualService (MISSION):** ritual steps, prerequisites, interruption and completion.
- **EntityService / EntityAIService (MISSION):** entity configuration and behavior.
- **DirectorService (MISSION):** event selection, cooldowns and fairness constraints.
- **GhostService (MISSION):** alive/dead/ghost/spectator transitions and allowed actions.
- **RewardService (MISSION):** calculates result payload; profile persistence remains owned by PlayerDataService.

Avoid one giant manager module. Avoid creating generic abstractions before a second real use case exists.

## 5. Mission state machine

Initial authoritative states:

`WAITING → INITIALIZING → INVESTIGATION → CONTACT → HUNT → FINAL_OBJECTIVE → COMPLETED / FAILED → RETURNING`

Rules:
- Only the server changes mission phase.
- Every transition has explicit allowed predecessor states.
- Phase entry/exit is idempotent.
- Delayed tasks and event callbacks must verify the mission generation/session token before mutating state.
- Reset and shutdown cancel or invalidate pending work.
- Events may change pacing, but must not bypass required prerequisites or terminal-state rules.

## 6. Entity AI and Director

Entity behavior uses a server-authoritative finite state machine (FSM), initially:
`DORMANT → OBSERVING → INVESTIGATING → MANIFESTING → HUNTING → COOLDOWN`.

The actual transition graph is entity-specific and data-driven. Entity configs define evidence, perception, abilities, hunt conditions, cooldowns and counterplay. The first concepts are The Watcher, The Mimic and The Static; their final mechanics remain subject to playtesting.

DirectorService selects authored events using mission phase, entity state, player count/positions, objective progress, event history, elapsed time and difficulty. Enforce cooldowns, event limits, safe reaction windows, valid phase constraints and counterplay. The Director creates pressure; it must not secretly guarantee a team wipe.

Keep AI decisions on the server. Clients may receive presentation cues, never authoritative entity position or hidden state unless explicitly allowed by a designed mechanic.

## 7. Networking and security

- Server owns mission phase, objective progress, evidence truth, inventory, damage/death, rewards and purchases.
- Treat every client remote payload as untrusted.
- Validate player state, distance, target instance, item ownership, phase, cooldown, rate and argument types on the server.
- Never accept client-provided reward amounts, evidence conclusions, entity health/state or objective completion.
- Keep remotes narrow and purpose-specific; do not expose arbitrary server method dispatch.
- Rate-limit interaction and communication requests.
- Client UI is a projection of server state, not the source of truth.
- Avoid broadcasting hidden information to all clients and attempting to hide it only in UI.

## 8. Player lifecycle and Ghost Mode

Model lifecycle explicitly: ALIVE, DEAD, GHOST, SPECTATING, RETURNING. Define legal transitions and cleanup for character removal, respawn, disconnect, teleport and mission termination.

Ghosts may observe and use carefully limited ghost-only perception/signals. They cannot collect physical items, complete physical objectives, damage the entity or disclose unrestricted hidden information. Ghost rules must be enforced server-side. Spectating is a presentation mode and is not synonymous with being dead.

## 9. Persistence and rewards

Do not add persistent data until the profile schema and failure strategy are specified. When introduced:
- Use versioned profile schema and safe defaults.
- Handle DataStore throttling, transient errors and retry backoff.
- Prevent concurrent session writes/lost updates with an appropriate session-lock strategy.
- Make reward grants idempotent.
- Never save every frame or every interaction.
- Test shutdown and player-leave save paths.
- Keep mission state ephemeral; persist only account-level progression and entitlements.

## 10. Performance and device support

Target PC, mobile and tablet from the start; gamepad where practical. Avoid per-frame server loops where event-driven updates suffice. Bound AI perception work, pathfinding frequency, active sound/effect count and replicated state. Test low-end mobile devices before public release. Hybrid camera modes must not reveal information or grant an unfair tactical advantage.

## 11. Suggested repository layout

Adopt this structure in TTL-01 when the Places and Rojo mapping are ready:

```
docs/
src/
  shared/
    config/
    types/
    utilities/
  hub/
    server/
    client/
  mission/
    server/
    client/
  assets/
tests/
  shared/
  hub/
  mission/
```

Keep shared modules free of server-only secrets and authoritative decisions. The exact Rojo project files should map the HUB and MISSION Place separately; do not use a single-place mapping as a substitute for the two-Place topology.

## 12. Definition of Done

A task is done only when:
- Its acceptance criteria are met.
- Server/client ownership is respected.
- Relevant pure tests or automated checks pass.
- Rojo build/sync is checked when project files are affected.
- Studio validation is explicitly reported as run, not run, or blocked.
- Disconnect, reset, death and failure paths are considered where relevant.
- Documentation and roadmap status are updated.
- No unrelated scope was added.
