# TTL-11D — Evidence → Objectives Integration

**Status:** implementation candidate on `feat/ttl-11d-evidence-objective-integration`. The Asylum map now authors two COLD_SPOT sources and the offline validator checks their tags, attributes, uniqueness, catalog membership, source count, room placement and interaction reach. CI must be rerun on the latest head. Roblox Studio, multiplayer and mobile validation have not been performed.

## Scope

TTL-11D connects confirmed evidence to optional objective progress. Only a real `OBSERVED → CONFIRMED` transition triggers a mapped objective. `UNKNOWN` and `OBSERVED` never satisfy objectives. Evidence is not consumed. This adds the minimum trusted `SIGNAL` completion kind; branching, alternatives and exclusive groups remain deferred to TTL-09E. RitualService is not implemented.

## Ownership and flow

`EvidenceRuntime` emits a mission-scoped callback after EvidenceCore accepts confirmation and the regular snapshot broadcast has been attempted. `EvidenceService` exposes this callback only to server modules. `EvidenceObjectiveBridge` maps evidence id to objective id and a server-authored source token. `ObjectiveService.completeBySignal` delegates to `ObjectiveRuntime.applySignal`, which uses the existing `afterApplied` path: reconcile prompts, broadcast the objective snapshot, and defer mission resolution through the lifecycle API.

There is no client remote for confirmation or SIGNAL completion. Client input cannot supply evidence ids, objective ids or source tokens. Subscriber exceptions are isolated from the evidence ledger and snapshot broadcast. Subscriptions are removed on stop; bridge callbacks carry a generation guard. A failed/rejected objective completion is logged and can be retried; successful forwarding is deduplicated.

## SIGNAL contract

```lua
completion = {
    kind = "SIGNAL",
    signal = { sourceToken = "server_authored_token" },
}
```

Tokens are bounded to 48 characters and restricted to `[A-Za-z0-9_-]`. They live in server-only content and are never replicated. SLOTS definitions cannot contain a signal; SIGNAL definitions cannot contain slots. `completeBySignal(objectiveId, sourceToken, now)` validates time, objective identity, completion kind and token, then checks state. A wrong token rejects. A correct duplicate is an idempotent no-op. A new completion uses the existing dependency cascade and mission-resolution evaluation.

## Existing HUD snapshot compatibility

The current client `ObjectiveView` requires `required >= 1` and exactly that many slot projections. A SIGNAL objective has no interaction slots, so the snapshot presents one display-only step: `required = 1`, `filled = 1` only when COMPLETED, and one display-only slot. This does not register an interaction or convert the completion mechanism to SLOTS.

## First mapping

The first mapping is optional and does not affect required progression:

- Evidence: `COLD_SPOT`
- Objective: `DOCUMENT_COLD_SPOT`
- Token: `evidence_cold_spot`

## Authored COLD_SPOT sources

| SourceId | Room | Position (studs) |
|---|---|---|
| `COLD_SPOT_TREATMENT` | TreatmentRoom | (-34.8, 4.5, -6.0) |
| `COLD_SPOT_QUARANTINE` | QuarantineWard | (34.8, 4.5, -42.0) |

Both parts are tagged `EvidenceSource` and carry `EvidenceId = COLD_SPOT` plus their unique `SourceId`. The catalog requires two distinct sources. The map validator checks source validity, count, room placement and interaction reach. Server startup cross-validates mapped evidence IDs, objective kinds and signal tokens.

## Lifecycle

Bootstrap initializes ObjectiveService and EvidenceService, then the bridge service, all before MissionLifecycleService.init(). The bridge therefore starts after the Evidence and Objective runtimes, and stops first in reverse order while EvidenceService is still alive. The bridge drops its deduplication state on stop.

## Ritual contract (documentation only)

A future server-side RitualService may read `EvidenceService.getEvidenceState(evidenceId)`. Only `CONFIRMED` satisfies an evidence requirement. Reads are non-consuming and repeatable; RitualService must not access or mutate EvidenceCore directly. Missing ids or an unavailable service fail closed. Ritual completion uses its own trusted server-side path. TTL-11D adds no RitualService or ritual remote.

## Validation and limits

Pure tests cover SIGNAL validation/completion, token rejection, idempotency, snapshot projection, evidence confirmation callback behavior/isolation/cleanup, and bridge mapping/forwarding. Python map regression tests cover missing/invalid evidence sources. CI must rerun Lune, both Rojo builds and the greybox validation workflow. Roblox Studio, multiplayer and mobile checks remain pending.
