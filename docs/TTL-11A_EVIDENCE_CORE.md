# TTL-11A — EvidenceCore

Status: implemented on `feat/ttl-11a-evidence-core`, pending PR review and merge. Automated checks: pending CI (`lune run tests/run`, both Rojo builds). **Roblox Studio, multiplayer and mobile validation: not applicable yet (no runtime integration exists) and not performed.**

Scope: the first slice of the Evidence System (TTL-11): a pure, deterministic core. Out of scope: `EvidenceService`, network, HUD, equipment, rituals, entities, map or objective changes (TTL-11B and later). Gameplay rules followed: evidence truth is server-owned; false signals may exist but need a fair verification method; progress is possible without voice chat (`docs/GAMEPLAY_RULES.md` section 4).

## Responsibility

`EvidenceCore` owns one mission's evidence ledger and the rules that move evidence through its states. It decides nothing about who may investigate, where clues are, which evidence an entity produces or how anything is shown: callers pass eligibility and attribution in, and receive plain results. It has no Roblox dependency, no side effects, no timers (time is injected) and keeps no `Player` references (contributors are `UserId` numbers).

## Files

| File | Role |
|---|---|
| `src/server_shared/Evidence/EvidenceCatalog.lua` | Domain types, deterministic validation of evidence definitions, `compile` to a frozen plan. |
| `src/server_shared/Evidence/EvidenceCore.lua` | Runtime ledger, state machine, progress, invariants. |
| `src/mission/server/Evidence/EvidenceContent.lua` | Example catalog (data only, mission-agnostic). |
| `tests/server_shared/Evidence{Catalog,Core,Content}.spec.lua` | Lune specs, registered in `tests/run.lua`. |

Pure modules in this repository do not require each other, so `EvidenceCore.new` receives the compiled plan instead of requiring the catalog (same convention as `ObjectiveCore` / `ObjectiveGraph`).

## Domain model

| Concept | Where | Meaning |
|---|---|---|
| Evidence type / category | `category` token on a definition | A free classification token (`ELECTRICAL`, `AUDIO`, ...), not a closed enum: new missions and entities add categories as data. |
| Evidence definition | `EvidenceDefinition` | `id`, `category`, `title`, `description`, `confirmation = { distinctSources }`. |
| Observation | `observe` | One accepted sighting of one evidence from one authored source (`sourceId`) by one contributor. |
| Confirmation | `confirm` | The explicit verification step; allowed only when enough distinct sources agree. |
| Investigation progress | `getProgress` | Shared, ledger-derived counts and ratios. |

The fair verification method is built in: evidence is confirmed by corroboration from **distinct sources**, so one possibly false signal can never confirm anything alone, and repeating or re-reporting the same clue never helps.

```lua
export type EvidenceDefinition = {
    id: string,        -- ^[A-Z][A-Z0-9_]*$, <= 32, unique
    category: string,  -- same token rules
    title: string,     -- 1..48 bytes, valid UTF-8, no control characters (incl. C1)
    description: string, -- 1..140 bytes, same rules
    confirmation: { distinctSources: number }, -- integer 1..8
}
export type EvidenceContent = { version: number, evidence: { EvidenceDefinition } } -- 1..32 definitions, dense array
```

## State model

```
UNKNOWN --observe--> OBSERVED --confirm--> CONFIRMED   (terminal)
```

`EvidenceCore.Transitions` is the explicit table (`UNKNOWN -> {OBSERVED}`, `OBSERVED -> {CONFIRMED}`, `CONFIRMED -> {}`); a spec drives 400 pseudo-random commands and checks every observed state change against it and that states never move backwards.

- `observe` records `(sourceId, observerId, at)`. The first accepted observation moves UNKNOWN to OBSERVED; later observations from other sources only add corroboration (state unchanged). A source counts once per evidence whoever reports it (`duplicate_observation`).
- `confirm` requires OBSERVED and at least `distinctSources` distinct sources, otherwise `not_observed` / `insufficient_observations`. A confirmed entry rejects everything (`already_confirmed`); the first confirmer keeps the attribution.
- There is deliberately no "dismissed", "false signal" or "retract" state in this slice (deferred, see below).

## Validation

- **Catalog** (`EvidenceCatalog.validate`, returns `(ok, code, subject)`; order: structure, then identity; first offender in definition order): content table shape, unknown fields, version, list density and size, id and category tokens, bounded valid text, confirmation shape and `distinctSources`, duplicate ids. It never mutates or freezes the caller's table; `compile` returns a frozen deep copy.
- **Commands**: fixed rejection precedence for `observe`: context, contributor, eligibility, evidence id, evidence, source id, confirmed, duplicate, source limit; for `confirm`: context, contributor, eligibility, evidence id, evidence, confirmed, not observed, insufficient. Contributors must be integer `UserId`s in `[1, 2^53 - 1]`; `context` is `{ eligible: boolean, now: finite number }`.
- **Bounds**: an entry tracks at most 16 distinct sources (`source_limit`), so memory and later payloads stay bounded.
- **State and progress consistency** (`checkInvariants`): UNKNOWN has no observations, OBSERVED at least one, CONFIRMED at least `distinctSources` plus a confirmer, sources are unique and match the source set, unconfirmed entries carry no confirmation data, the revision is a non-negative integer and the progress counts add up. The specs run it after every command and against deliberately corrupted state.

Every mutation is atomic (validate first, then plain assignments); a rejected command changes nothing and does not advance the revision, which rises by exactly one per applied command.

## Public API

```lua
EvidenceCatalog.validate(content) -> (ok, code?, subject?)
EvidenceCatalog.compile(content) -> (plan?, code?, subject?)
EvidenceCatalog.isToken(value) -> boolean
EvidenceCatalog.Limits / PlanKind

EvidenceCore.new(plan, now) -> Store            -- raises on an invalid plan or clock
Store:observe(evidenceId, sourceId, observerId, { eligible, now }) -> CommandResult
Store:confirm(evidenceId, confirmerId, { eligible, now }) -> CommandResult
Store:getState(id) / getEntry(id) / getEntries() / getProgress() / getRevision() / checkInvariants()
EvidenceCore.States / Transitions / Reasons / MaxSourcesPerEvidence / MaxUserId

CommandResult = { ok, reason?, changed, changes = { { kind = "OBSERVATION" | "STATE", evidenceId, sourceId?, userId?, from?, to? } } }
Progress = { total, unknown, observed, confirmed, confirmedRatio, corroborationRatio }
```

`getEntry` / `getEntries` / `getProgress` return fresh copies. `getEntry` includes the per-observation attribution (`sourceId`, `observerId`, `at`) for credit and diagnostics; a replicable, privacy-safe snapshot (which must not reveal UNKNOWN evidence, source ids or contributors) is a TTL-11B decision.

**Progress.** Shared by the whole team and derived from the ledger only, so it does not depend on who contributed (a spec checks a solo run against a four-player run): `confirmedRatio = confirmed / total`; `corroborationRatio = sum(min(sourceCount, required)) / sum(required)` gives partial credit that is capped per evidence, so duplicates and sources beyond the requirement can never inflate it.

## Example catalog

`EvidenceContent` ships four mission-agnostic example definitions: `COLD_SPOT` (ENVIRONMENTAL, 2 sources), `STATIC_INTERFERENCE` (ELECTRICAL, 2), `MOVED_OBJECT` (PHYSICAL, 1), `VOICE_ECHO` (AUDIO, 3). They are placeholders for tests and integration, not the final entity evidence tables.

## Tests

`EvidenceCatalog.spec` (14), `EvidenceCore.spec` (34) and `EvidenceContent.spec` (6): initial state; valid transitions; invalid transitions; duplicate observations and confirmations; unknown ids; invalid definitions, contexts, contributors and sources; fixed rejection precedence; progress calculations; shared progress; solo viability; bounds; atomicity (a hostile context aborts before any mutation); revision; copy semantics; determinism; a pseudo-random state-machine property test; the invariant checker against corruption; the shipped catalog. Counts are from a local Lua 5.4 shim run (see `docs/TESTING.md` section 20); `lune run tests/run` and the Rojo builds have not been run in the authoring environment.

## Deferred

- **TTL-11B:** `EvidenceService` (MISSION lifecycle system), authored evidence sources in the world, server-side eligibility and rate limiting, the replicable snapshot and its privacy rules, and the network contract.
- **TTL-11C:** client ledger / HUD.
- **TTL-11D:** integration with objectives (evidence-driven completion signals) and with the entity evidence tables.
- Later: false-signal and refutation states, equipment-gated observation (TTL-12), paranormal communication (TTL-13), per-entity evidence sets and narrowing of possibilities, difficulty scaling of `distinctSources`, contribution summaries for results and rewards.
