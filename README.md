# THE LAST TURN

A Roblox cooperative paranormal investigation / survival horror experience.

**Product baseline:** [Game Design Document v1.0](docs/Game%20Design%20Document%20%E2%80%94%20Version%201.0.md)  
**Development plan:** [Development Roadmap v1.0](docs/Development%20Roadmap%20%E2%80%94%20Version%201.0.0.md)

## Project status

The repository contains the approved product baseline, HUB/MISSION Rojo projects, and merged foundation systems TTL-01 through TTL-07: networking, player state, parties, mission teleport, mission lifecycle and deterministic mission configuration. The core playable mission loop is not implemented yet. Merged infrastructure and passing automated checks are not equivalent to a Studio-validated or playable experience.

## Core product decisions

- 1–8 players; balance baseline: 4.
- One persistent HUB and isolated mission server instances.
- Hybrid first-/third-person camera.
- Death transitions into a restricted Ghost Mode.
- Balanced cooperative horror; solo play remains supported.
- MVP location: THE ASYLUM.
- Non-pay-to-win monetization.

## Documentation

| Document | Purpose |
|---|---|
| [GDD](docs/Game%20Design%20Document%20%E2%80%94%20Version%201.0.md) | Approved player experience and product scope |
| [Roadmap](docs/Development%20Roadmap%20%E2%80%94%20Version%201.0.0.md) | Phases, tasks, release gates |
| [Technical Specification](docs/TECHNICAL_SPEC.md) | Implementation requirements and service boundaries |
| [Architecture](docs/ARCHITECTURE.md) | Runtime topology, state ownership, data flow |
| [Gameplay Rules](docs/GAMEPLAY_RULES.md) | Testable rules and initial balancing constraints |
| [Testing Strategy](docs/TESTING.md) | Test layers and evidence requirements |
| [Contributing](docs/CONTRIBUTING.md) | Branch, PR, review and ownership workflow |
| [Release Plan](docs/RELEASE_PLAN.md) | Alpha, beta and public-launch gates |

## Toolchain

- Roblox Studio
- Rojo 7.6.1
- Rokit as the toolchain manager

Versions are pinned in `rokit.toml` where known. Do not upgrade tools as part of an unrelated gameplay task. HUB and MISSION Rojo project mappings are present. The owner-confirmed Experience and PlaceIds are configured; Studio smoke testing and live teleport validation remain outstanding.

## Development principles

1. Server-authoritative gameplay and rewards.
2. Small, reviewable changes; one roadmap task per PR.
3. No scope expansion without approval.
4. Do not claim Studio or multiplayer validation unless it was actually run.
5. ChatGPT owns product documentation, architecture, feasible repository edits and reviews. Claude Code receives focused implementation work that requires local tooling.
6. The project owner approves product decisions, Studio validation and merges.

## Current stage

**Phase 2 — Playable Mission.** TTL-07 Mission Configuration is merged; its automated validation passed (both Rojo builds and 200 Lune tests). Roblox Studio / published-Experience runtime validation remains pending. The next task is TTL-08 Basic Interaction, beginning with a design-only pass. Phase 0's P0-09 Studio smoke test and P0-10 workflow validation also remain open. See the roadmap and release plan for exit criteria.
