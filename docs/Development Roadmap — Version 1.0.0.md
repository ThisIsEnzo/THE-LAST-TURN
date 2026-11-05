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
- P0-04 Rojo project bootstrap — IN REVIEW
- P0-05 Toolchain reproducibility — READY
- P0-06 Roblox Experience — BLOCKED (owner action)
- P0-07 HUB Place — BLOCKED (owner action)
- P0-08 MISSION Place — BLOCKED (owner action)
- P0-09 Studio smoke test — BLOCKED (owner action)
- P0-10 Workflow validation — BLOCKED (owner action)

### Phase 1 — Core Foundation
- TTL-01 Project Bootstrap — IN REVIEW (HUB/MISSION Rojo mappings and server entry points)
- TTL-02 Networking Foundation — IN REVIEW (code-level implementation; Roblox Studio validation NOT performed)
- TTL-03 Player State
- TTL-04 Party System
- TTL-05 Mission Teleport

### Phase 2 — Playable Mission
- TTL-06 Mission Lifecycle
- TTL-07 Mission Configuration
- TTL-08 Basic Interaction
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

Phase completion is determined by acceptance criteria, not the number of merged PRs.

**End of Development Roadmap v1.0.**