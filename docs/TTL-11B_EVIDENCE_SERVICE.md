# TTL-11B — EvidenceService

Status: implemented on `feat/ttl-11b-evidence-service` (stacked on TTL-11A), pending PR review and merge. Automated checks: pending CI (`lune run tests/run`, both Rojo builds). **Roblox Studio, multiplayer and mobile validation: pending, none performed.**

Source of truth: `docs/TTL-11A_EVIDENCE_CORE.md` (the ledger and its rules), `docs/TTL-09B_OBJECTIVE_SERVICE.md` (the integration pattern this follows). `EvidenceCore`, `EvidenceCatalog` and `EvidenceContent` are unchanged.

## Architecture

| File | Role |
|---|---|
| `src/server_shared/Evidence/EvidenceRuntime.lua` | Pure orchestration with injected ports: compiles the catalog once, owns the `EvidenceCore`, indexes the authored sources, registers one interaction per source, reconciles prompts, publishes snapshots, answers pulls. Lune-tested. |
| `src/mission/server/Evidence/EvidenceService.lua` | Roblox glue: discovers the tagged source parts, wires the real services into the runtime, registers the snapshot pull request and ONE mission lifecycle system `Evidence`. |
| `src/mission/server/Evidence/EvidenceConfig.lua` | Server-only interaction, prompt and policy settings with a pure validator. |
| `NetworkContract` / `NetworkConfig` | `EvidenceRequestSnapshot` (no payload, rate limit 3 / 0.5 per s) and `EvidenceSnapshot` (privacy-safe snapshot). |
| `mission/server/Bootstrap.server.lua` | `EvidenceService.init()` after `ObjectiveService.init()`, before `MissionLifecycleService.init()`. |

The runtime contains no state-transition or validation rule: every rule (distinct sources, duplicates, confirmation requirements, terminal states, bounds) is `EvidenceCore`'s. The runtime only decides what the world supplies (which source, which player, which eligibility) and what is published.

## Discovery flow (clients never name evidence)

1. The authored map contains evidence **sources**: parts tagged `EvidenceSource` with string attributes `EvidenceId` and `SourceId` (an optional `Available = false` attribute disables one). The service finds them server-side (`CollectionService:GetTagged`, only parts in the Workspace). Clients never supply sources, positions or ids.
2. For every valid source the runtime registers one server-created interaction through the existing `InteractionService` (ids `EVD_<n>` in sorted `EvidenceId/SourceId` order; short tokens, revealing nothing). Prompt texts are generic ("Examine" / "Strange sign") because the prompt is visible to everyone before anything is discovered.
3. `InteractionService` validates every activation first (mission ACTIVE, roster, ALIVE, character, target, server-measured distance, shared rate limit, busy, cooldown).
4. The handler, a closure carrying only server-known ids, re-checks: lifecycle active, connected roster member, world object available, then calls `EvidenceCore:observe(evidenceId, sourceId, userId, { eligible = alive, now })`. The evidence id and source id come from the registration, never from the player.
5. Policy (`confirmWhenCorroborated`, default on): after an applied observation the runtime asks `EvidenceCore:confirm`; the core decides (it rejects until enough distinct sources agree). The explicit core step is kept; until another verification step exists, switching the policy off means nothing can become CONFIRMED.
6. Applied: prompts are reconciled from the ledger (a used source and every source of confirmed evidence is disabled) and **one** snapshot per connected participant is sent, however many core commands the activation applied. The handler returns true only for an applied observation, so duplicates and rejections consume no cooldown and publish nothing.

## Remote communication contract

| Name | Direction | Payload |
|---|---|---|
| `EvidenceRequestSnapshot` | client -> server | none (`args = {}`), rate limited 3 burst / 0.5 per second. Pull after the listener is connected. |
| `EvidenceSnapshot` | server -> client | `{ v = 1, revision, total, evidence = { { id, title, category, state, sources, required } } }` |

There is no discovery, confirmation or progress request: those happen through server-created interactions. Clients accept only strictly newer revisions (the revision is the core's, +1 per applied core command; an activation that also confirms advances it by two). A pull answers only the requester with the current revision.

**Privacy.** Only discovered evidence (OBSERVED or CONFIRMED) is listed; UNKNOWN evidence is omitted and only the total count is public. Never sent: source ids, contributor or confirmer ids, positions, anchors, timestamps, rejection reasons. Titles come from the server-only catalog and are sent only after discovery.

## Security validation

Every item is enforced on the server, mostly by existing infrastructure: mission membership and state, evidence exists in the catalog (sources for unknown evidence are never bound), the world object exists and is available (checked by `InteractionService` as `targetAvailable` and again by the handler), player alive and eligible, server-measured distance, valid source (it is the registration's own), duplicates and invalid transitions (`EvidenceCore`: a source counts once per evidence whoever reports it), and throttling (shared per-player interaction bucket 5 / 2 per s, a per-registration cooldown, and the pull's bucket). Ambiguous sources (the same `EvidenceId/SourceId` on two objects) are used by neither; malformed ids are ignored; all of it is logged. Client-supplied positions, distances, states or progress do not exist in the protocol.

## Lifecycle

`init()` registers the system (idempotent, logs invalid configuration or content). `start(session)` runs while INITIALIZING and throws on invalid content or roster (mission aborts); unbindable, ambiguous or missing sources are not fatal (evidence is optional content) and are logged, including evidence that can never be confirmed with the bound sources. `stop()` unregisters every prompt and the request handler, invalidates every captured handler (generation guard) and drops the ledger, so a new mission starts at revision 0 with no inherited state and no duplicate registrations. A player who disconnects keeps their contribution in the team ledger, stops receiving snapshots and can pull again when back.

## Tests

`tests/server_shared/EvidenceRuntime.spec.lua` (39) drives the real runtime with the **real** `InteractionCore` and `RateLimiter` plus fakes, and asserts authoritative ledger state (not just that something was sent): valid discovery; a second player and a late joiner receive the team state; corroboration and confirmation by policy; privacy of the snapshot and prompts; out of range, dead, non-roster and inactive-mission rejections; missing, unavailable, malformed, unknown and ambiguous sources; duplicates and flood throttling; disconnects; delivery and prompt failures with healing; stop, restart, repeated cycles and stale handlers. `EvidenceConfig.spec.lua` (7) covers the configuration and the contract additions. See `docs/TESTING.md` section 21. Mutation checks showed the specs fail when the availability, lifecycle, roster or generation guards are removed. These ran in a local Lua 5.4 shim; `lune run tests/run` and the Rojo builds have not been run in the authoring environment.

## Limitations and deferred

- **The map has no evidence sources yet.** TTL-10 authored only the objective anchors; with no `EvidenceSource` parts the service starts, logs that no source is bound and registers no prompt. Placing sources (and their generator and validator support) is a follow-up; it is the only thing that makes the feature visible in Studio.
- The `Available` attribute is read at each activation; the prompt visibility is refreshed only after applied commands, so it can be momentarily stale but never exploitable.
- No client ledger or HUD (TTL-11C), no objective integration or entity evidence tables (TTL-11D), no false-signal or refutation states, no equipment gating.
- Prompt distance and hold time are provisional until tuned in Studio.

## Studio checklist (all pending)

1. Add a few `EvidenceSource` parts (anchored, tagged, with `EvidenceId` / `SourceId` attributes) in the MISSION place and start a mission; prompts appear only at them and show the generic text.
2. Use a source: nothing happens to other sources; the used prompt disappears for everyone; a second player's client receives the update after pulling.
3. Use enough distinct sources: the evidence ends CONFIRMED and its remaining prompts disappear; using one source repeatedly changes nothing.
4. DEAD / GHOST / SPECTATING players, players outside the roster and players out of range cannot discover anything.
5. Leave and rejoin mid-mission: team progress remains; the pull restores the snapshot.
6. End the mission and start another: no inherited evidence, no duplicate prompts.
7. Spam a prompt and the pull request: both are throttled.
