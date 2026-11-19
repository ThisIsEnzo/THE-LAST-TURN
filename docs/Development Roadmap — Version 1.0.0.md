# THE LAST TURN
## Development Roadmap — Version 1.0

**Status:** Approved  
**Priority:** MVP First  
**Total Phases:** 8  
**Total Planned Tasks:** 36

## Production Rules

- All tasks must have unique IDs.
- Every implementation task must have acceptance criteria.
- Every PR must reference its task ID.
- No unapproved scope expansion.
- ChatGPT performs architecture, documentation, implementation where feasible, and review.
- Claude Code receives focused implementation tasks.
- The project owner approves product decisions, Roblox Studio validation, and merges.

## Phase Overview

| Phase | Name | Tasks | Weight |
|---|---|---:|---:|
| 0 | Pre-production | 10 preparation activities | 5% |
| 1 | Core Foundation | TTL-01–05 | 15% |
| 2 | Playable Mission | TTL-06–10 | 15% |
| 3 | Investigation & Rituals | TTL-11–14 | 15% |
| 4 | Entities & Director | TTL-15–20 | 15% |
| 5 | Progression & Content | TTL-21–26 | 12% |
| 6 | Polish & Optimization | TTL-27–31 | 10% |
| 7 | Alpha, Beta & Launch | TTL-32–36 | 13% |

## Task Registry

### Phase 0 — Pre-production
See [Phase 0 Checklist](./PHASE_0_CHECKLIST.md) for P0-01–P0-10, exit criteria and owner-dependent tasks.

- P0-01 Product baseline — DONE
- P0-02 Technical baseline — DONE
- P0-03 Repository workflow — DONE
- P0-04 Rojo project bootstrap — DONE (HUB/MISSION mappings and entry points merged)
- P0-05 Toolchain reproducibility — DONE (pinned toolchain and CI builds validated)
- P0-06 Roblox Experience — DONE (owner-confirmed Creator Dashboard Experience)
- P0-07 HUB Place — DONE (owner-confirmed PlaceId `121295396016500`; configured)
- P0-08 MISSION Place — DONE (owner-confirmed PlaceId `117948903725370`; configured)
- P0-09 Studio smoke test — BLOCKED (owner action)
- P0-10 Workflow validation — BLOCKED (owner action)

### Phase 1 — Core Foundation
- TTL-01 Project Bootstrap — DONE (merged; Roblox Studio runtime validation remains an owner task)
- TTL-02 Networking Foundation — DONE (merged; Roblox Studio runtime validation NOT performed)
- TTL-03 Player State — DONE (merged; Roblox Studio validation NOT performed)
- TTL-04 Party System — DONE (merged; Roblox Studio multiplayer/runtime validation remains pending)
- TTL-05 Mission Teleport — DONE (merged; automated checks passed on PR head; live reserved-server teleport validation remains pending)

### Phase 2 — Playable Mission
- TTL-06 Mission Lifecycle — DONE (merged; Lune coverage exists, but final review-hardening head had no reported CI run; Roblox runtime and return-teleport validation remain pending; PlaceIds are configured)
- TTL-07 Mission Configuration — DONE (PR #9 merged; CI passed both Rojo builds and `lune run tests/run` with 200 passed, 0 failed; Studio/published-Experience runtime validation remains pending)
- TTL-08 Basic Interaction — IN PROGRESS: TTL-08B-A (pure `InteractionCore` + Lune specs) merged (PR #11); TTL-08B-B (`InteractionService`, native ProximityPrompt integration, Bootstrap, no gameplay consumers) MERGED (PR #12); TTL-08C (server-authoritative test door via InteractionService, pure `DoorCore`, runtime fixture) MERGED (PR #13; head workflow run #42 passed). Roblox Studio/published-Experience validation remains pending (see docs/TTL-08C_DOOR_INTERACTION.md).
- TTL-HUB-01 HUB Greybox — DONE (PR #14 merged and visually checked by the project owner in Studio; this remains prototype geometry, not final art).
- TTL-HUB-02 Party UI & Mission Preparation — PR #15 MERGED; follow-up PR #19 MERGED (server-authoritative invite/response acknowledgements, rejection recovery and implementation documentation). CI passed (HUB/MISSION Rojo builds; 378 Lune tests; workflow runs #59/#60); Studio multiplayer, mobile and published teleport validation remain pending.
- TTL-09 Objectives — IN PROGRESS (milestones 09A–09C complete; TTL-09 as a whole remains open for later extensions). Design merged ([TTL-09 design](./TTL-09_OBJECTIVE_SYSTEM.md)). TTL-09A (pure objective core: `ObjectiveGraph`, `ObjectiveCore`, first-slice `ObjectiveContent`, Lune specs), TTL-09B (server integration: `ObjectiveRuntime`, `ObjectiveService`, snapshot network contract, [TTL-09B doc](./TTL-09B_OBJECTIVE_SERVICE.md)) and TTL-09C (client presentation: pure `ObjectiveView` and `ObjectiveController`, `ObjectiveNetwork` wiring, `ObjectiveHud`, [TTL-09C doc](./TTL-09C_OBJECTIVE_HUD.md)) are MERGED to `master` (PRs #21, #22, #23; TTL-09C merge commit `c30904223222e8d0ded1180707dc32fa7ee78d49`). CI workflows #68 and #71 passed for 09A and 09B respectively (both HUB/MISSION Rojo builds and Lune tests); CI was not run for the 09C PR according to its PR validation notes. Project owner reports the 09C implementation works in practice. Luau strict-mode diagnostics and full mobile/real multiplayer validation evidence are still not recorded. Later extensions 09D–09F remain deferred to their actual consumers (09D dynamic events when Entity Director/another first consumer is ready; 09E branching/signals for Evidence/Ritual/mission variation; 09F advanced cooperation for Equipment/Ritual). Team-wipe handling remains a separate mission-level component (design section 11.5). Extraction policy (11.6) must be approved before TTL-10; the current EXTRACT interaction is only a development placeholder. TTL-09 is not complete.
- TTL-10 First Mission Map — IN REVIEW (PR #25, branch `feat/map-ttl-10-first-mission-map`). THE ASYLUM greybox is implemented as static Rojo JSON models under `src/mission/world`; objective anchors are discovered from authored `ObjectivePoint` / `PointId` parts and the runtime objective fixture was removed. CI passed on PR head `add8a6a`: `build-places` successfully built both HUB and MISSION places with Rojo 7.6.1 and ran the pure Luau test suite; `Validate THE ASYLUM greybox geometry and objective anchors` also passed (map validator plus 24 Python regression tests). These are automated build/validation results, not Roblox Studio runtime validation. Studio, mobile and multiplayer checks remain pending (owner task; checklist in the [TTL-10 doc](./TTL-10_FIRST_MISSION_MAP.md)). TTL-09A–09C remain complete and TTL-09 as a whole remains open for later extensions; `EXTRACT` is still a dev placeholder and its final policy still needs product-owner approval.

### Phase 3 — Investigation & Rituals
- TTL-11 Evidence System — IN PROGRESS. TTL-11A (EvidenceCore/Catalog), TTL-11B (EvidenceRuntime/Service) and TTL-11C (Evidence HUD, PR #28 merged) are in master. TTL-11D adds trusted SIGNAL completion, a mission-scoped confirmation callback and EvidenceObjectiveBridge; the Ritual integration is a read-only CONFIRMED-evidence contract only. Automated Lune/Rojo and Roblox Studio validation must be tracked separately. TTL-11D also authors two COLD_SPOT sources in TreatmentRoom and QuarantineWard; the map validator checks source attributes, uniqueness, catalog counts and reachability. Studio/multiplayer validation remains pending.
- TTL-12 Equipment System
- TTL-13 Paranormal Communication
- TTL-14 Ritual System

### Phase 4 — Entities & Director
- TTL-15 Entity Framework
- TTL-16 The Watcher
- TTL-17 The Mimic
- TTL-18 The Static
- TTL-19 Entity Director
- TTL-20 Threat Balancing

### Phase 5 — Progression & Content
- TTL-21 Ghost Mode
- TTL-22 Camera System
- TTL-23 Player Data
- TTL-24 Entity Codex
- TTL-25 Rewards
- TTL-26 Cosmetic Foundation

### Phase 6 — Polish & Optimization
- TTL-27 Audio Design
- TTL-28 Visual Polish
- TTL-29 UI/UX
- TTL-30 Mobile Optimization
- TTL-31 Performance & Security

### Phase 7 — Alpha, Beta & Launch
- TTL-32 Internal Alpha
- TTL-33 Closed Playtest
- TTL-34 Balance & Retention
- TTL-35 Monetization
- TTL-36 Public Release

## Release Gates

**Gate 1 — Playable Prototype**
- Players can enter a mission.
- Mission objectives work.
- Mission can be completed.
- Server correctly handles player state.

**Gate 2 — Core Game**
- Investigation works.
- Rituals work.
- At least one complete entity works.
- Mission has replayable variations.

**Gate 3 — Content Complete**
- Three entities.
- Director.
- Ghost Mode.
- Progression.
- Core UI.

**Gate 4 — Release Candidate**
- Mobile and PC testing.
- Security review.
- Data persistence validation.
- Closed playtesting.
- Critical bug resolution.

**Gate 5 — Public Release**
- Store presentation.
- Monetization.
- Analytics.
- Public launch.
- Update pipeline.

## Scope Control

The initial public version must remain within the approved GDD MVP.

Any new feature must be evaluated for:
1. Player value.
2. Development cost.
3. Dependencies.
4. Impact on release date.
5. Impact on existing systems.

Features that do not improve the core experience should be postponed.

## Project Status Tracking

Every task must have one status:

- BACKLOG
- READY
- IN PROGRESS
- IN REVIEW
- BLOCKED
- DONE

A task may be marked DONE when its implementation is merged; keep automated, Roblox Studio and playtest validation evidence explicit in the task notes. A phase is complete only when its exit criteria have evidence, not merely because its PRs are merged.

**End of Development Roadmap v1.0.**
