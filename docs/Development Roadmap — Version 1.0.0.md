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
- TTL-08 Basic Interaction — IN PROGRESS: TTL-08B-A (pure `InteractionCore` + Lune specs) merged per the project owner (PR #11); TTL-08B-B (`InteractionService`, native ProximityPrompt integration, Bootstrap, no gameplay consumers) IN REVIEW — `lune run tests/run` and both Rojo builds must pass in CI; Roblox Studio, multiplayer and mobile validation pending (see docs/TTL-08B-B_INTERACTION_SERVICE.md)
- TTL-09 Objectives
- TTL-10 First Mission Map

### Phase 3 — Investigation & Rituals
- TTL-11 Evidence System
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
