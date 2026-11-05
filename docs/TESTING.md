# THE LAST TURN — Testing Strategy

## 1. Testing principle

A successful Luau test or Rojo build is not proof that a Roblox multiplayer experience works. Report each validation layer separately and never claim a test that was not run.

## 2. Test layers

| Layer | What it validates | Evidence |
|---|---|---|
| Pure Luau tests | State machines, rules, config validation, calculations | Test output |
| Service tests | Server modules with controlled dependencies/mocks | Test output and setup |
| Static checks | Formatting, lint, type diagnostics where configured | Tool output |
| Rojo build | Files map into expected DataModel | Build command/output |
| Studio single-client | Real Roblox Instances, prompts, UI, lifecycle | Manual checklist |
| Studio multi-client | Replication, party flow, races, multiplayer objectives | Player count + checklist |
| Device tests | Mobile controls, performance, UI readability | Device and observations |
| Playtests | Comprehension, fairness, tension, replay intent | Tester notes and observed issues |

## 3. Required lifecycle scenarios

As systems are implemented, test applicable cases:
- Normal start, completion and failure.
- Solo and 2–4 player runs; later verify 5–8.
- Player disconnect during each major phase.
- Player death, Ghost transition and spectator behavior.
- Party leader disconnect before launch.
- Teleport failure and retry.
- Reset/cleanup with delayed tasks pending.
- Required resource carrier dies or disconnects.
- Duplicate interaction and duplicate reward request.
- Invalid, stale and rate-limited remote requests.

## 4. PR validation report

Every implementation PR must state:
- Automated tests run and exact result.
- Static checks run and exact result.
- Rojo build/sync result where relevant.
- Studio tests run, including client count.
- Tests not run and why.
- Known risks and manual follow-up.

## 5. MVP release test gate

Before public release:
- Complete multiple consecutive missions without softlocks.
- Validate all supported party sizes or document tested range and remaining risk.
- Test on representative mobile and PC devices.
- Verify server authority for objectives, evidence, death, rewards and purchases.
- Verify persistence failure/retry and duplicate reward handling if progression is enabled.
- Resolve all critical and high-severity blockers affecting mission completion, security or data integrity.
