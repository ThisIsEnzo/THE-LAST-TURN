# TTL-09C — Objective HUD & Client Controller

Status: implemented on `feature/ttl-09c-objective-hud`, pending PR review and merge. Automated checks: pending CI (`lune run tests/run`, both Rojo builds). **Roblox Studio, mobile and real multiplayer validation: pending, none performed.**

Source of truth: `docs/TTL-09_OBJECTIVE_SYSTEM.md` (section 8) and the merged TTL-09A/09B (`docs/TTL-09B_OBJECTIVE_SERVICE.md`). The server schema and network contract are used unchanged.

## Architecture

| Module | Kind | Role |
|---|---|---|
| `src/shared/Objective/ObjectiveView.lua` | pure | Validates and mirrors the last accepted `ObjectiveSnapshot`; revision rule; view model; tracker selection; transition events. No remote, no Instance, no clock. |
| `src/shared/Objective/ObjectiveController.lua` | pure, injected ports | Client orchestration: connect listener, pull, retry, malformed handling, listeners, cleanup. |
| `src/mission/client/Objective/ObjectiveNetwork.lua` | Roblox | The only module touching the objective remotes; builds the real ports and the controller. |
| `src/mission/client/Objective/ObjectiveHud.lua` | Roblox | Presentation only. Never talks to a remote. |
| `src/shared/UI/Messages.lua` | pure (extended) | Fixed HUD strings (header, status words, OPTIONAL tag, transition lines). Titles, descriptions and slot labels are server text. |
| `src/mission/client/Bootstrap.client.lua` | Roblox | Starts the controller and the HUD, each in its own protected call. |

There is no second objective state model: the view is a validated copy of the server snapshot and nothing else. Pure modules do not require each other, so the controller receives the view module and every collaborator through `deps` (same convention as the server runtime). The HUB `UiKit` is not available in the MISSION place, so the HUD carries a few local helpers and the same palette; moving `UiKit` to `src/shared` is a separate follow-up.

## Snapshot synchronization

- Contract (unchanged): notification `ObjectiveSnapshot` (full snapshot), request `ObjectiveRequestSnapshot` (no payload). The client can cause no other request, and no remote can complete, fail or change an objective.
- Order: the listener is connected first; only when the port reports it ready does the controller pull once. The server pushes at mission start (possibly before the listener exists, hence the pull) and after every applied command.
- Revision rule (`ObjectiveView`): `lastRevision` starts at -1; a payload is applied only if its revision is strictly greater. Equal revisions are duplicates (a pull racing a broadcast) and lower ones are stale: both change nothing and emit no notification. The first server snapshot has revision 0.
- Malformed payloads (wrong version, bad revision, non-array or oversized lists, invalid entries, duplicate ids, progress that disagrees with its slots, control characters, oversized text) are rejected as a whole; the last valid state is kept and nothing is fabricated.
- Fresh pulls: while no valid snapshot was accepted the controller pulls again after 4 s, at most 3 pulls in total (matching the server burst of 3); a malformed payload triggers at most 2 throttled refreshes (minimum 2 s apart) until a valid snapshot resets the budget. No polling otherwise: snapshots are complete, so a missed intermediate revision needs no repair.

## Visibility rules

The client renders exactly the entries of the latest accepted snapshot, in the server's order; it never re-ranks. Hidden objectives are omitted by the server until revealed, so the client cannot show what it was not sent; a later snapshot is authoritative for what is present. Fields such as anchor ids, contributor ids or internal reasons are not in the snapshot and the view drops any unknown field. The panel is hidden until the first valid snapshot and whenever the server sent no objectives. The first snapshot is a baseline: it produces no transition messages.

## HUD behavior

- Collapsed tracker (top-left, below the Roblox top bar, translucent, never centered): the actionable objectives (`AVAILABLE` / `IN_PROGRESS`) in server order, at most 3 lines on compact screens and 4 on regular ones, "n/m" when more than one contribution is needed, OPTIONAL objectives dimmed and tagged, "+N more" for overflow. Header shows the required-objective count.
- Expanded (tap the header; no hover): every objective with a status word (ACTIVE, IN PROGRESS, LOCKED, DONE, FAILED, UNAVAILABLE), description and per-slot progress. State is never conveyed by colour alone.
- Transitions: one short line (two at most) for unlocked, completed, failed or cancelled objectives, shown 3.5 s, no input, no sound, no flashing. Progress inside an objective only updates the counter.
- Touch: 48 px header target on compact screens (`Layout`), no per-frame work, one coalesced render per accepted snapshot or screen-size change.

## Lifecycle and cleanup

`ObjectiveController.start()` is idempotent; `destroy()` disconnects the listener, cancels the retry timer, clears listeners and the mirror, and a generation guard makes late deliveries, timers and ready signals from an older run inert. `ObjectiveHud.destroy()` removes the UI and every connection. The Bootstrap does not call them: there is no mission-teardown signal on the client other than the return teleport, which removes the client scripts. All remote waits run on their own thread with ClientNetwork's 10 s timeout.

## Tests and limitations

Pure specs: `ObjectiveView.spec`, `ObjectiveController.spec`, the extended `Messages.spec` (see `docs/TESTING.md`, section 18). Not covered by any automated test: HUD rendering, real remotes, Bootstrap, teardown. Known limitations: placement and sizes are unmeasured on real devices; no localization; no scrolling for the expanded list beyond the engine's default (at most 32 entries are possible); a client that never receives a valid snapshot shows nothing and logs a warning.

## Deferred

Final visual design (typography, iconography, motion, audio), a journal/briefing/map, objective markers in the world, `UiKit` consolidation, localization, per-contributor display, and anything depending on later server features (alternatives, signals, extraction policy).

## Studio checklist (all pending)

1. The panel appears only after the mission starts and shows the four slice objectives in server order; `FIND_RECORDS` is dimmed and tagged OPTIONAL.
2. Filling fuse slots updates "n/3" for every player; completing `RESTORE_POWER` announces it and `OPEN_WING` becomes active.
3. Joining late or reconnecting shows the current state after the single pull; killing the listener race (client slower than server) still ends synced.
4. Locked objectives show as LOCKED in the expanded list and are not tracked.
5. Mobile: header tap target, readability, no overlap with thumbstick, jump button or top bar; compact vs regular classification.
6. Toasts appear and disappear; nothing blocks input; no persistent obstruction.
7. After the mission ends or the client leaves, no stale UI remains.
8. Multiplayer (2, 4 players): identical state on all clients.
