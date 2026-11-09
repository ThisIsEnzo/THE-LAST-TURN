# TTL-08C — Door Interaction (first gameplay consumer)

Status: **IMPLEMENTED, IN REVIEW.** `lune run tests/run`, both Rojo builds and all Roblox Studio / multiplayer / mobile validation are **pending**. Not Studio-validated.

## 1. Goal

Prove the TTL-08B interaction pipeline with one server-authoritative door toggling Closed/Open through `InteractionService`. No second interaction system, door framework, RemoteEvent or networking changes.

## 2. Architecture

```
ProximityPrompt (native, created on the stationary interaction anchor)
 -> InteractionService / InteractionCore (mission, roster, ALIVE, character, target,
    server distance, rate limit, busy and cooldown validation)
 -> DoorInteractionService handler (synchronous, non-yielding)
 -> DoorCore.planToggle -> start tween (not awaited) -> DoorCore.commitToggle
```

| Module | Role |
|---|---|
| `src/server_shared/Door/DoorCore.lua` | Pure door state machine; Lune-tested. |
| `src/mission/server/Door/DoorConfig.lua` | Server-only config and pure validation; Lune-tested. |
| `src/mission/server/Door/DoorFixture.lua` | Runtime test-door fixture. |
| `src/mission/server/Door/DoorInteractionService.lua` | Lifecycle consumer, registration, handler, movement and cleanup. |

The client never controls door state; it only sees replicated panel movement.

## 3. Door state machine

Logical states: `Closed`, `Open`. `planToggle(now)` is non-mutating and returns the planned state or rejection (`transitioning`, `invalid_time`). `commitToggle(expected, now)` applies only the expected valid transition; rejection leaves state unchanged.

A toggle flips logical state and opens a transition window based on a deadline on an injected clock—not a tween event—so a missing tween completion cannot permanently lock the door. Invalid time fails closed; backward time can only extend the transition. Movement is applied between planning and commit; movement failure does not change logical state.

## 4. Registration and prompt

`DoorInteractionService.init()` registers its lifecycle system during Bootstrap after `InteractionService.init()` and before `MissionLifecycleService.init()`. In its `start()`, after InteractionService starts, it builds the fixture and calls:

```lua
InteractionService.register(
    DoorConfig.interactionSpec(Config),
    fixture.anchor,
    handleInteract,
    DoorConfig.promptOptions(Config)
)
```

The handler returns true only for an applied toggle (cooldown applies), false otherwise. TTL-08C adds optional `options = { actionText?, objectText? }` to `InteractionService.register`, validated by pure `InteractionConfig.validatePromptOptions`; omission retains generic prompt text. No door-specific code enters InteractionService; InteractionCore is unchanged.

## 5. Server-authoritative behaviour

- State and movement are server-owned; no remote exists.
- Eligibility checks remain entirely in InteractionService/InteractionCore.
- The anchored panel moves between deterministic closed/open CFrames; a TweenService tween starts but is not awaited. A guarded delayed callback snaps to the exact final pose. Tween creation failure falls back to an instant move.
- The invisible interaction anchor remains stationary while the panel swings.

## 6. Concurrency and spam

The InteractionCore cooldown (1 s, at least the 0.6 s transition) and DoorCore transition deadline protect the door. Core busy/cooldown serialization means at most one concurrent toggle wins.

## 7. Lifecycle and failure handling

- Registration occurs in lifecycle `start()`, after InteractionService is ready.
- The demo door is optional: fixture/config/registration failure logs a warning, cleans partial resources and lets the mission continue without it.
- `stop()` is idempotent: cancels tween, snaps panel to logical pose, unregisters while InteractionService is alive, destroys fixture and clears references. Guarded delayed callbacks become no-ops.
- Target destruction removes registration; missing panel or movement failure returns false without changing state.
- Invalid character, non-participant, non-ALIVE player and out-of-range activation are rejected upstream.

## 8. Test fixture and Studio setup

There is no place file and `mission.project.json` has no Workspace mapping. The server builds `MissionTestDoor` at runtime (pillars, panel, invisible anchor), positions it 14 studs from the first SpawnLocation or configured fallback, and destroys it on stop. Its placement has not been verified.

An ACTIVE mission cannot be reached in a plain Studio playtest because arrival context never becomes READY. Test by publishing and starting a mission through HUB teleport. No additional scripts are required. Set `DoorConfig.Values.enabled = false` to disable the fixture.

## 9. Automated tests

Pure Lune specs: `DoorCore.spec.lua` covers toggles, invalid transitions/states, busy deadline, boundary/backward/invalid clock and config. `DoorConfig.spec.lua` validates shipped config against DoorCore, InteractionCore and prompt rules, including cooldown/transition constraints. `InteractionConfig.spec.lua` includes prompt-options tests.

| Check | Status at authoring |
|---|---|
| `lune run tests/run` | Not run in authoring environment; CI must pass |
| Both Rojo builds | Not run in authoring environment; CI must pass |
| Ad-hoc Lua 5.4 translation (not Luau substitute) | 169 passed, 0 failed |
| Roblox service/fixture/Bootstrap | Parse after annotation stripping only; not type-checked/executed |

## 10. Studio validation checklist (all pending)

Requires a published Experience started through HUB:

1. Door appears in MISSION.
2. Prompt appears within configured distance and disappears outside it.
3. ALIVE participant opens and closes door.
4. Two participants do not corrupt state.
5. Dead player and non-participant cannot interact.
6. Spam during transition is rejected.
7. Shutdown cleans prompt/registration and leaves a valid pose.
8. PC interaction works.
9. Mobile interaction works.
10. Verify swing direction, clearance, tween smoothness and prompt text (`Use` / `Door`).

None of these validations has been performed.

## 11. Known limitations

- Runtime spawn-relative fixture; position unverified.
- No collision handling for players in swing path, sound or state-dependent prompt text.
- One global prompt/cooldown; no locks, power or objective integration.
- Server tween smoothness is untuned; client animation may be a future refinement.
- TTL-08B limitations remain: no LOS validation, no feedback UI, provisional 1-stud tolerance and rate limit.
