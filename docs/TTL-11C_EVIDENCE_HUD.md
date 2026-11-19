# TTL-11C — Evidence HUD

Status: MERGED to `master` (PR #28). CI for the merged head passed both Rojo builds and `lune run tests/run` (743 passed, 0 failed). **Roblox Studio, multiplayer and mobile validation: pending, none performed.**

Source of truth: `docs/TTL-11B_EVIDENCE_SERVICE.md` (the replicated state) and `docs/TTL-09C_OBJECTIVE_HUD.md` (the client pattern this follows). The server schema and network contract are used unchanged.

## Responsibilities

The HUD shows the team's shared investigation state and nothing else: how much evidence has been discovered, which, and how well corroborated. It never discovers, confirms or counts anything itself and cannot cause any request other than the payload-less snapshot pull.

| Module | Kind | Role |
|---|---|---|
| `src/shared/Evidence/EvidenceView.lua` | pure | Validates and mirrors the last accepted `EvidenceSnapshot`: revision rule, view model, transition events. Same interface as `ObjectiveView`. |
| `src/shared/Objective/ObjectiveController.lua` | pure, injected ports (existing, unchanged) | Listener-before-pull synchronization, bounded retries, cleanup. Generic over the injected view, so it drives `EvidenceView` as is; nothing is duplicated. |
| `src/shared/Evidence/EvidencePresenter.lua` | pure, injected ports | Render state, journal open/closed flag, one UI instance, toast logic, cleanup. |
| `src/shared/UI/Messages.lua` | pure (extended) | Fixed strings: header, status words, category formatting, sightings, transition lines. Titles are server text. |
| `src/mission/client/Evidence/EvidenceNetwork.lua` | Roblox | The only module touching the evidence remotes; builds the real ports and the controller. |
| `src/mission/client/Evidence/EvidenceHud.lua` | Roblox | The UI port: draws the render state; binds the journal key. Never talks to a remote. |
| `src/mission/client/Bootstrap.client.lua` | Roblox | Starts controller and HUD, each in its own protected call. |

## Data flow and synchronization

`EvidenceSnapshot` (server) -> `EvidenceNetwork` listener -> `ObjectiveController` -> `EvidenceView` (validate, revision rule) -> controller notifies -> `EvidencePresenter` builds the render state -> `EvidenceHud` draws. The listener is connected first and the controller pulls the current snapshot once it is ready (`EvidenceRequestSnapshot`), so a player who joins a mission in progress is initialized from the current ledger. Revisions start at -1; only strictly newer revisions are applied, duplicates (a pull racing a broadcast) and stale payloads change nothing and cause no render or notification. The first snapshot is a baseline: evidence the team already knew is shown but never announced.

## Information disclosure

The snapshot (TTL-11B) lists only discovered evidence plus the mission's evidence total; the client defends this boundary too: an entry in state UNKNOWN makes the whole payload malformed (the last valid state is kept), unknown fields are dropped, and ids are used only as diff keys. The HUD displays only: title (server text), category (formatted), status word, and "n of m sightings" for unconfirmed multi-source evidence. It never displays ids, source ids, contributors, positions or counts of undiscovered evidence beyond the server-supplied total, and the empty journal is a single neutral line ("Nothing found yet.") with no placeholder rows. The counter is "EVIDENCE 2 / 4" using the server's total; if the server sent none it shows only the discovered count. The snapshot has no description field, so none is shown (adding one would be a server change and is not done here).

## Player-facing behavior and controls

- A small translucent pill at the top centre, below the Roblox top bar, shows the counter; it appears after the first valid snapshot.
- Tap/click the pill, or press **J**, to open or close the journal (a CLOSE button also closes it). J is not used by any existing binding (the interaction key is E). The key is bound with `ContextActionService` only while the HUD exists, handles only the key press, and is unbound on destroy; it does not fire while a text box has focus.
- The journal drops down under the pill, at most 40 percent of the screen height, scrolls, and shows only discovered evidence in server order. State is always also a word (OBSERVED / CONFIRMED), never colour alone.
- Discovery feedback: one short line (two at most) for new or newly confirmed evidence, shown 3.5 s, no sound, no flashing, no input capture. Several discoveries in one snapshot share one notification; progress inside an entry only updates the counter text.

## Lifecycle and cleanup

`EvidencePresenter.start` is idempotent, and the HUD does not depend on the character (`ResetOnSpawn = false`, no character listeners), so a respawn can neither duplicate nor drop it. `destroy` unsubscribes, destroys the UI (which unbinds the key and removes the ScreenGui) and closes the journal; stale callbacks and late snapshots are inert; `ObjectiveController.destroy` cancels the subscription and forgets the mirrored state, so an unsynced model renders as hidden. The Bootstrap does not call them: there is no mission-end signal on the client other than the return teleport, which removes the client scripts.

## Tests and limitations

Pure specs: `tests/shared/EvidenceView.spec.lua` (21), `tests/shared/EvidencePresenter.spec.lua` (24, running the real controller, view, presenter and Messages with fake ports) and the extended `tests/shared/Messages.spec.lua` (see `docs/TESTING.md` section 22). Mutation checks showed the specs fail when idempotent start, unsubscription or UNKNOWN rejection are removed. These ran in a local Lua 5.4 shim; `lune run tests/run` and the Rojo builds have not been run in the authoring environment.

Known limitations: `EvidenceHud` rendering and the key binding are untested outside Studio (placement, sizes and colours are unmeasured on real devices; the top-centre position may need tuning next to the player list or chat); the palette is copied because `UiKit` lives in the HUB client folder; the shared controller's log lines carry an "[Objective]" prefix; no sounds, icons or animations; no per-source or location information by design; the HUD stays empty until evidence sources exist in the map (a TTL-11B follow-up).

## Deferred

Final visual design, audio, icons, richer transitions, objective or ritual integration (TTL-11D), a journal framework, localization, `UiKit` consolidation.

## Studio checklist (all pending)

1. Start a mission: no pill until the first snapshot, then "EVIDENCE 0 / n" (n from the server).
2. Discover evidence with two players: both counters and journals update once, one notification each, no duplicate rows.
3. Press J / tap the pill: the journal opens and closes; typing in chat does not toggle it; movement, sprint and the interaction key are unaffected.
4. Join late or rejoin: the journal shows the current evidence without notifications for the old entries.
5. Respawn several times: still exactly one HUD (`EvidenceHud` ScreenGui) and one set of events.
6. Mobile: pill and CLOSE tap targets, readability, no overlap with the thumbstick, chat or the player list.
7. End the mission and start another: no stale UI; the new mission starts empty.
