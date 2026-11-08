# TTL-08B-B — Interaction Service & ProximityPrompt Integration

Status: **IMPLEMENTED, IN REVIEW.** Automated checks are listed in section 11 with their actual status; **Roblox Studio, multiplayer and mobile validation are pending** (section 12). This milestone is infrastructure only: no gameplay interaction (doors, clues, evidence, items, objectives, inventory), no client UI and no new RemoteEvent.

## 1. Purpose and architecture

`InteractionService` (`src/mission/server/Interaction/InteractionService.lua`, MISSION server only) wraps the pure `InteractionCore` (TTL-08B-A, see `TTL-08B-A_INTERACTION_CORE.md`) with the Roblox runtime.

```
ProximityPrompt.Triggered(player)      native prompt, created and parented by the server
        v
InteractionService                     builds a fresh authoritative context, limiter hook, handler hook
        v   store:activate(handle, context, hooks)
InteractionCore                        evaluate -> token -> evaluate -> reserve -> handler -> complete
        v
consumer handler (future systems)      synchronous, non-yielding
```

- Owns: the Core Store, the prompts it creates, their connections, the handle-to-resource mapping, the interaction `RateLimiter`.
- Does not own: gameplay effects or state, mission/player lifecycle, client feedback. It never decides anything from client data: the engine-supplied `Player` is the only trusted part of the event.
- `InteractionConfig.lua` holds the server-only tunables and the small pure helpers derived from them (validated by Lune tests).
- The activation transaction is **not** reimplemented here; it is delegated to `InteractionCore.activate`.

## 2. Public API (server only)

```lua
InteractionService.register(spec, target, handler) -> (handle?, reason?)
InteractionService.unregister(handle)              -> (ok, reason?)
InteractionService.setEnabled(handle, enabled)     -> (ok, reason?)
InteractionService.isReady()                       -> boolean
```

- `spec` is an `InteractionCore.Spec` (`id`, `maxDistance` 2..15, optional `holdDuration`, `cooldown`, `enabled`), validated by the Core (unique id, one registration per target).
- `target` must be a `BasePart` that is a descendant of `workspace`.
- `handler` is `(player: Player) -> boolean`; return `true` only when the effect was applied. `false` or an error applies no cooldown and releases the reservation.
- `register` reasons: `service_unavailable`, `invalid_handler`, `invalid_target`, `prompt_failed`, or a Core reason (`invalid_spec`, `invalid_target_key`, `duplicate_id`, `target_in_use`). A rejected call leaves no Core registration and no Roblox resource behind; if prompt creation fails after Core registration, the Core registration is rolled back.
- `unregister` destroys the prompt, disconnects its connections and invalidates the handle. A stale or foreign handle returns `invalid_handle` / `not_registered` and cannot touch another registration.
- `setEnabled` updates the Core first and the prompt's `Enabled` only if the Core accepted the change.
- The target's `Destroying` event removes its registration automatically (identity-guarded).

Example (a future consumer, from its own lifecycle `start()` callback):

```lua
local handle, reason = InteractionService.register(
    { id = "ExampleSlot", maxDistance = 8, cooldown = 2 },
    slotPart,
    function(player: Player): boolean
        return applyEffect(player) -- synchronous, non-yielding
    end
)
```

## 3. Registration lifecycle and ordering

`InteractionService.init()` registers one lifecycle system named `Interaction`. Bootstrap order:

```lua
NetworkService.init()
PlayerStateService.init()
MissionContextService.init()
MissionConfigService.init()
InteractionService.init()      -- after MissionConfigService, BEFORE MissionLifecycleService.init()
MissionLifecycleService.init()
DiagnosticHandshake.register("MISSION")
```

`MissionLifecycleService.init()` can start systems immediately when the context is already READY, and registration closes at that point, so `init()` must come first. Future consumer systems register after `Interaction`, therefore start after it (and register their interactions from their own `start()`), and stop before it (reverse order).

`start(session)` (inside the lifecycle's protected call): validates the configuration (an invalid one makes `start` throw, aborting the mission cleanly), copies `session.expectedUserIds` into a roster set (the session table itself is never retained or mutated), creates the Core Store and the limiter, connects `PlayerRemoving`, and only then marks the service ready.

`stop()` is idempotent and safe after a partial start: marks the service unavailable first, disconnects `PlayerRemoving`, removes every registration (disconnect connections, destroy prompt, unregister from Core), clears the Core Store and drops the Store, limiter and roster. Nothing survives mission shutdown. The service is one-shot per server lifetime, like the lifecycle itself.

## 4. Prompt configuration

Native `ProximityPrompt` created by the server and parented to the target (default Roblox presentation; no custom UI; other prompts and `ProximityPromptService` are untouched):

| Property | Value |
|---|---|
| `ActionText` / `ObjectText` | generic defaults from `InteractionConfig.Values.prompt` (`"Interact"` / empty) |
| `HoldDuration` | from the validated spec (UX only, never a security mechanism) |
| `MaxActivationDistance` | `maxDistance + distanceToleranceStuds` |
| `RequiresLineOfSight` | `false` (v1) |
| `ClickablePrompt` | `true` (touch and mouse) |
| `Enabled` | the registration's enabled state |

The prompt stays visible during a cooldown or while busy (the Core rejects those activations); cooldown UX is out of scope. The interaction id is never replicated.

## 5. Server-side validation (every activation)

`ProximityPrompt` is not the security boundary. Each `Triggered` builds a fresh Core context:

| Context field | Source |
|---|---|
| `missionActive` | `MissionLifecycleService.isActive()` |
| `isParticipant` | roster set built from `expectedUserIds` |
| `playerEligible` | `PlayerStateService.getState(player) == "ALIVE"` |
| `characterAvailable` | character in `workspace`, Humanoid present with health above 0, `HumanoidRootPart` present (no `WaitForChild`, nothing yields) |
| `targetAvailable` | target still has a parent and is a descendant of `workspace` |
| `distance` | server-measured `HumanoidRootPart`-to-target distance, adjusted by the tolerance (section 6) |
| `now` | `time()` (the same clock `NetworkService`/`RateLimiter` use) |

Before the Core is called, a callback is dropped if the service stopped, the registration was removed or replaced (generation and registration identity guards), or `player.Parent ~= Players`. Only `ALIVE` participants may interact; `DEAD`, `GHOST`, `SPECTATING`, `RETURNING`, unknown and unregistered players are rejected.

**Roster semantics.** `expectedUserIds` is the authoritative mission roster (fixed for the session). `participantUserIds` is only a snapshot of currently connected expected players and is not used for authorization; connectivity is implied by the live `Player` and the `Parent` check.

## 6. Distance and the provisional tolerance

The Core accepts `distance <= maxDistance`. The adapter makes the effective accepted radius `maxDistance + tolerance` **without changing the Core**: it passes `coreDistance(raw, tolerance) = max(0, raw - tolerance)`, and sets the prompt's `MaxActivationDistance` to the same `maxDistance + tolerance` (`InteractionConfig.effectiveRadius`). A raw distance that is not a finite number `>= 0` is passed through unchanged, so the Core rejects it as out of range; it is never turned into a valid one.

The tolerance (`InteractionConfig.Values.distanceToleranceStuds`, provisional **1 stud**, bounded 0..4) is a UX/engine-parity allowance for the difference between the engine's prompt distance reference and the server's `HumanoidRootPart`-to-target measurement. **It is not a security bypass and it is to be measured and tuned in Studio.** The numeric radii are identical, but exact parity between prompt visibility and server acceptance is not guaranteed.

## 7. Rate limiting

A dedicated `RateLimiter` instance (`RateLimiter.new(limits, time)`) lives in `InteractionService`; the activation hook is `limiter:tryConsume(player.UserId, "Interact")`, called by the Core after the first evaluation and before the reservation. Policy (`InteractionConfig.Values.rateLimit`): capacity 5, refill 2 tokens per second, **one shared `Interact` bucket per player across all interactions**, independent between players. Values are provisional and tunable after Studio testing.

It is separate from `NetworkService`'s remote limiter on purpose: that limiter is private, and `NetworkService.init()` requires every `NetworkConfig.RateLimits` action to be a declared remote request, whereas `Interact` is a native ProximityPrompt action. `NetworkConfig`, `NetworkService` and `RateLimiter` are unchanged.

`PlayerRemoving` clears the player's bucket immediately and again in `task.defer` (the `NetworkService` pattern); callbacks also reject players whose `Parent` is not `Players`.

## 8. Activation pipeline and handler contract

`InteractionCore.activate` performs: validate handle, evaluate, consume token, evaluate again, reserve busy, run the handler under `xpcall`, complete (release busy, cooldown only on a literal `true`). The adapter only supplies the hooks. Normal rejections are silent; a handler error is logged server-side with the interaction id (nothing is ever sent to clients); unexpected adapter-level rejections (`invalid_handle`, `invalid_context`, `invalid_hooks`, `hook_error`) are logged as warnings.

The handler is **synchronous, short and non-yielding**: no `task.wait`, `WaitForChild`, DataStore, teleport or other yielding call, no asynchronous work. This is a code-review contract; there is no runtime yield detection or cancellation. Asynchronous interactions would need a separate transaction/token-based design.

## 9. Cleanup summary

Unregister, target destruction and mission stop all go through one identity-guarded removal: disconnect connections, destroy the prompt, unregister from the Core. Stale callbacks (an old `Triggered`, an old handle, a removed registration) cannot affect a newer registration that reused the id or target. No RemoteEvent is created.

## 10. Known v1 limitations

- No line-of-sight validation (`RequiresLineOfSight = false`): a player within the radius can activate through thin walls.
- No custom interaction UI, no feedback notifications and no cooldown/busy visual state; dead or ghost players may temporarily see prompts they cannot use (the server rejects them).
- No gameplay consumers; prompt texts are generic defaults.
- The 1-stud tolerance, the rate-limit values and prompt behaviour on touch devices are provisional and unproven until Studio/mobile testing.
- Non-yielding handlers are enforced by review only.

## 11. Automated checks

Pure Lune coverage added: `tests/server_shared/InteractionConfig.spec.lua` (configuration validation, tolerance helpers against the real Core, the rate-limit policy with the real `RateLimiter`). `InteractionCore` tests (TTL-08B-A) are unchanged. `InteractionService` itself needs the Roblox runtime and has no Lune coverage.

Results at authoring time:

| Check | Status |
|---|---|
| `lune run tests/run` | **Not run** in the authoring environment (Lune unavailable); must pass in CI |
| `rojo build hub.project.json`, `rojo build mission.project.json` | **Not run** (Rojo unavailable); must pass in CI |
| Pure specs through an ad-hoc Lua 5.4 translation (not Luau, not a substitute) | 141 passed, 0 failed (SeededRandom, MissionConfigCore, InteractionCore, InteractionConfig) |
| Service and Bootstrap syntax | parse after annotation stripping only; not type-checked |

## 12. Manual Studio validation checklist (all **PENDING**; none performed)

Requires a published Experience (an ACTIVE mission cannot be reached in Studio), with a temporary, uncommitted consumer that registers a part before `MissionLifecycleService.init()` and a handler counting calls.

1. A registered BasePart displays a native ProximityPrompt. — pending
2. A player within the effective radius can activate it. — pending
3. A player outside the effective radius is rejected server-side. — pending
4. A non-participant is rejected. — pending
5. An `ALIVE` participant can activate. — pending
6. A `DEAD` participant cannot activate. — pending
7. A `GHOST` participant cannot activate. — pending
8. A `SPECTATING` participant cannot activate. — pending
9. A player without a valid character or `HumanoidRootPart` cannot activate. — pending
10. A disabled interaction cannot activate. — pending
11. A successful handler applies its configured cooldown. — pending
12. A failed handler (false or error) does not apply a new cooldown. — pending
13. A busy interaction cannot be activated concurrently. — pending
14. Rate limiting is shared across all interaction ids for the same player. — pending
15. Different players have independent rate-limit buckets. — pending
16. Unregistering an interaction removes its prompt and invalidates its handle. — pending
17. Destroying or removing the target prevents activation. — pending
18. Mission shutdown destroys all prompts and disconnects all service connections. — pending
19. No custom RemoteEvent is created for interactions. — pending
20. Touch interaction is usable on a mobile device. — pending

Also to measure while testing: prompt visibility versus server acceptance at the radius edge (tune the tolerance), `ClickablePrompt` behaviour on touch, hold duration comfort, and prompt selection with several nearby prompts.
