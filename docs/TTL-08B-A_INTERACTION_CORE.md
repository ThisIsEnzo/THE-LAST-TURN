# TTL-08B-A — Pure Interaction Core

Status: **implemented, automated checks only.** TTL-08B-B (the `InteractionService` adapter, prompts, Bootstrap integration) is **not** part of this change, and nothing here has been validated in Roblox Studio or a published Experience.

`src/server_shared/Interaction/InteractionCore.lua` is a pure Luau module (no Roblox services, Instances, timers or globals). Every fact about the world arrives in the `context` of each call; the rate limiter and the effect arrive as hooks. The future adapter owns player/mission lifecycle, character lookup, distance calculation, prompts, feedback and the `RateLimiter`.

## Store API

```lua
local store = InteractionCore.new(dependencies?)   -- { onHandlerError: (id, serial, message) -> ()? }

store:register(spec, targetKey) -> (handle?, reason?, detail?)
store:unregister(handle)        -> (ok, reason?)
store:setEnabled(handle, bool)  -> (ok, reason?)
store:isRegistered(handle)      -> boolean
store:getState(handle)          -> State?            -- a copy, never the internal record
store:evaluate(handle, context) -> { ok, reason? }   -- non-mutating
store:activate(handle, context, hooks) -> ActivationResult
store:count()                   -> number
store:clear()
```

`spec`: `id` (required, `^[%w_%-]+$`, 1..64), `maxDistance` (required, 2..15 studs), `holdDuration` (0..3 s, default 0, UX only), `cooldown` (0..60 s, default 0), `enabled` (boolean, default true). Absent optional fields get the documented defaults; an invalid provided value is always rejected, never coerced. Unknown fields (including `targetKey`, which is the second argument) are rejected. `targetKey` must be a table or userdata (compared by identity; strings and numbers would be name-based and are rejected).

A failed `register` creates no record, reserves no target and consumes no serial. Reasons: `invalid_spec`, `invalid_target_key`, `duplicate_id` (checked before the target), `target_in_use`.

## RegistrationHandle

`register` returns a **frozen** table `{ id, serial }` issued by the Store. Validity is decided by exact table identity (the Store keeps the active handles and a weak set of retired ones); the visible fields are informational. A forged or copied table with the same fields, a handle from another Store, or a non-table is `invalid_handle`; a handle this Store issued that was unregistered or cleared is `not_registered`. Serials start at 1, increase strictly and are never reused for the Store's lifetime, including across `clear()`. Every mutation requires a valid handle (there is no ID-only operation). `unregister` is not idempotent: a second call returns `(false, "not_registered")`.

## Evaluation (`evaluate`)

Handle check, then context check (`invalid_context` when a fact is not a boolean or `now` is not finite), then the first failing rule in this fixed order:

`target_unavailable`, `mission_inactive`, `not_participant`, `player_not_eligible`, `character_unavailable`, `disabled`, `busy`, `cooldown`, `out_of_range`.

`context`: `missionActive`, `isParticipant`, `playerEligible` (the adapter reports "ALIVE" as a boolean), `characterAvailable`, `targetAvailable`, `distance`, `now`. `distance` is in range when finite, `>= 0` and `<= maxDistance` (the exact boundary is in range); a missing, NaN, infinite or negative distance is never in range. Evaluation never reserves, consumes or changes anything.

## Activation pipeline (`activate`)

1. Validate the handle (and the hooks, `invalid_hooks`).
2. `evaluate`. A rejection here consumes no token.
3. `hooks.consumeToken()`; only a literal `true` passes (otherwise `rate_limited`; a throwing hook is `hook_error`). Nothing is reserved yet, so a rejection cannot leave the registration busy. The token is not refunded if the next step fails.
4. `evaluate` again (state may have changed). A failure here skips the handler.
5. Reserve `busy`.
6. `hooks.handler()` inside `xpcall`. Only a literal `true` is success. `false`, any other value or an error is a failure (`handler_failed`); errors never escape and are reported in `handlerError` (and to `onHandlerError`, itself protected).
7. Complete: release `busy` exactly once; on success with `cooldown > 0`, `cooldownEndsAt = now + cooldown`. A failure leaves any existing cooldown unchanged.

If the registration was unregistered, cleared or replaced while the handler ran, nothing is completed or mutated and the result has `stale = true`. Completion is decided by the identity of the original record, never by the id, so an old activation can never touch a newer registration that reused the id or the target.

`ActivationResult`: `ok`, `reason?`, `executed`, `stale`, `cooldownEndsAt?`, `handlerError?`.

## Handler contract

The handler is **synchronous, short and non-yielding**: no `task.wait`, `WaitForChild`, DataStore, teleport or other yielding call and no asynchronous work. This is a mandatory consumer contract enforced by code review; the Core has no runtime yield detection or cancellation. If a handler yields anyway, the registration stays busy until it returns and the identity guards still protect newer registrations. Asynchronous interactions would need a separate transaction/token-based design.

## Clock

Time is `context.now`, supplied by the adapter (the project's injected `time` clock); the Core never reads a clock and creates no timers. The cooldown applies while `now < cooldownEndsAt` (the exact end is eligible) and starts from the activation's `now`. The clock is never clamped: a backward clock can only make an active cooldown last longer, never shorter. An invalid `now` (not a number, NaN, infinity) is `invalid_context` and cannot bypass a cooldown. A zero cooldown records nothing, so it never blocks, even if the clock moves backwards.

## Cleanup

`unregister` removes the registration, releases its target and id and retires the handle. `clear()` retires every handle, releases every target and id, drops busy/cooldown state and keeps the serial counter. The Store holds no player-specific state.

## Reasons

`invalid_handle`, `not_registered`, `invalid_context`, `target_unavailable`, `mission_inactive`, `not_participant`, `player_not_eligible`, `character_unavailable`, `disabled`, `busy`, `cooldown`, `out_of_range`, `rate_limited`, `handler_failed`, `hook_error`, `invalid_hooks`, `invalid_spec`, `invalid_target_key`, `invalid_enabled`, `duplicate_id`, `target_in_use`. They are for logs and tests, never shown to players.

## Scope and limits

Not included: `InteractionService`, `ProximityPrompt`, Bootstrap integration, remotes, client UI, effective-distance tolerance (the adapter may add it to the distance fact or to `maxDistance`), server line-of-sight validation, Studio validation. Tests: `tests/server_shared/InteractionCore.spec.lua`.
