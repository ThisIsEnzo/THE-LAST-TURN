# TTL-07 — Mission Configuration

Authoritative, deterministic configuration of one MISSION session: the MISSION server generates a seed and derives every configuration choice from it.

Status: **MERGED** — PR #9 merged as `5285885981c6aab23ff5f0df332cd1b002ef6969`. CI validated both Rojo builds and the Lune suite (200 passed, 0 failed). Roblox Studio / published-Experience runtime validation remains pending.

## 1. Ownership

- src/server_shared/MissionConfig/SeededRandom.lua — pure FNV-1a hashing, isolated xorshift32 streams and bias-free integer selection.
- src/server_shared/MissionConfig/MissionConfigCore.lua — pure validation and deterministic selection; returns one frozen MissionConfig. The random source is injected so the module remains dependency-free under both Roblox and Lune.
- src/mission/server/MissionConfig/MissionContent.lua — static, deeply frozen content; v1 contains THE ASYLUM only.
- src/mission/server/MissionConfig/MissionConfigService.lua — MISSION integration, seed generation, configuration ownership and lifecycle registration.
- src/mission/server/Bootstrap.server.lua — initializes MissionConfigService immediately before MissionLifecycleService.

Unchanged: TeleportPayload v1, MissionLifecycleCore/Service, MissionContextService, NetworkContract and HUB. No remotes: seed and content must never be sent to clients.

## 2. Lifecycle integration

MissionConfigService.init() registers MissionConfig with MissionLifecycleService before MissionLifecycleService.init(). Registration order is startup order, so this is the first system. During INITIALIZING, start(session) reads only missionId and missionType, generates the seed and builds the configuration synchronously. The lifecycle catches failures, aborts with ABORTED / initialization_failed, stops started systems and returns players to HUB. The shared mutable session snapshot is neither mutated nor retained.

## 3. Seed

Generated once per mission in start(), only after a validated READY context: Random.new():NextInteger(1, 2147483647). It is validated by SeededRandom.isValidSeed, stored only in the frozen config and never replicated. The creation log includes missionId, seed, location and contentVersion for reproducibility.

## 4. Deterministic algorithm

Same seed + same content + same inputs produce the same configuration. Algorithm changes require review and updated golden vectors.

- hash32(text): FNV-1a 32-bit (offset 0x811C9DC5, prime 0x01000193).
- fmix32(h): MurmurHash3 finalizer.
- Stream state: fmix32(hash32(label) XOR fmix32(seed)); zero is replaced with 1.
- Step: xorshift32 (13, 17, 5); output domain is 1..2^32-1.
- nextInteger(min, max): rejection sampling over the actual nonzero output domain; no modulo bias. Supported range size is 1..4294967295; 2^32 values are rejected.
- Arithmetic stays within exact double integer precision; shifts use bit32.
- Each selection stage has an independent label (initially config.location), so adding a later stage does not advance or alter earlier streams.
- Location ids are sorted before selection; content table iteration order cannot affect the result. Content changes require a content version bump.

## 5. Configuration schema (v1)

```lua
export type MissionConfig = {
    schemaVersion: number,
    contentVersion: number,
    missionId: string,
    missionType: string,
    seed: number, -- server-only
    locationId: string,
}
```

Content validation fails closed: plain table with exactly version and locations; version is an integer in 1..2147483647; locations is a dense array of 1..64 entries, each exactly { id }, with valid unique ids. Unknown fields, holes, dictionaries, metatables, empty lists and duplicates are rejected.

## 6. Public service API and consumer contract

MissionConfigService.init(), getConfig(): MissionConfig?, isReady(): boolean.

- getConfig() returns nil before start and after stop. The returned config is frozen.
- Clearing the service reference does not revoke references held by consumers; every consumer must clear its own reference in stop.
- Systems stop in reverse registration order, so dependents stop before MissionConfigService and may still read config during their stop.
- A dependent system that finds getConfig() == nil in start must throw so the mission aborts cleanly.

## 7. Failure behavior

- Invalid static content is logged in init(); start throws and the mission aborts with initialization_failed.
- Invalid seed/session identity or rejected input follows the same abort path.
- Registration refusal indicates incorrect bootstrap order and raises immediately.
- Duplicate start fails closed.
- If the mission ends before this system starts, no config is created; otherwise stop clears it.
- All work is synchronous; no generation token is needed unless asynchronous work is introduced.

## 8. Validation

CI on the merged PR ran both Rojo builds and `lune run tests/run`: **200 passed, 0 failed**.

The Lune suite covers hash and finalizer known-answer vectors, golden xorshift32 outputs across seeds/labels (including a forced zero initial state), nextInteger results including rejection sampling and maximum range, range validation, stream isolation, global RNG independence, content/input validation, order independence, selection vectors, input immutability, deep freezing, injected-random contract and shipped content validity.

Requires Roblox Studio / a published Experience (not validated):
1. Open both Rojo projects and verify MissionConfig folders map correctly.
2. MISSION without teleport context: no config; lifecycle times out on context_timeout.
3. Published solo HUB → MISSION: exactly one config log; getConfig() is non-nil while ACTIVE and stable across calls.
4. Party of 2–4 with staggered arrivals: exactly one config.
5. Two separate missions: independent seeds.
6. Empty locations failure injection: initialization_failed, players return to HUB, no config; then revert.
7. endMission and shutdown while ACTIVE: getConfig() is nil afterwards.
8. Confirm clients cannot access seed or content.

## 9. Known limitations

- THE ASYLUM is the only location, so production selection is currently degenerate.
- Engine Random may produce the same seed on separate servers; that only repeats a harmless configuration.
- Lifecycle passes the same mutable session snapshot to all systems; consumers must treat it as read-only.
- Failure reason remains generic initialization_failed; details are in server logs.
- Studio cannot reach READY without teleport; a development-only context injection would be a separate approved task.
