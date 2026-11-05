# THE LAST TURN — Gameplay Rules Baseline

**Status:** Design constraints v1.0  
**Note:** Numbers below are initial design targets, not final balance values. Validate them through playtests.

## 1. Session and party

- Party size: 1–8.
- Balance baseline: 4 players.
- Solo play must remain completable; do not require simultaneous actions that make solo impossible.
- Mission target: 15–20 minutes.
- No player should be the sole mandatory carrier of all required resources.

## 2. Mission phases

Initial phase order:
1. WAITING
2. INITIALIZING
3. INVESTIGATION
4. CONTACT
5. HUNT
6. FINAL_OBJECTIVE
7. COMPLETED or FAILED
8. RETURNING

Phases express mission progression, not mandatory fixed-duration timers. Authored events may alter pacing but cannot skip objective prerequisites or resurrect a terminal mission.

## 3. Cooperative objectives

- Every required resource has a clear source, destination and delivery confirmation.
- Multiple players can contribute separate items to the same team objective.
- Progress is team-owned, not tied to the player who first interacted.
- If a carrier dies or disconnects, required progress must remain recoverable.
- A required item must never become permanently inaccessible.
- UI communicates required, delivered and remaining contributions.

## 4. Investigation and evidence

- Evidence must be discoverable through a readable action or environmental clue.
- Evidence truth is server-owned.
- False signals may exist, but the game must provide a fair verification method.
- A player should be able to make progress without voice chat.
- The investigation should narrow possibilities; random guessing must not be the optimal strategy.

## 5. Threat and fairness

- Threat escalation should be legible through cues and behavior.
- Every dangerous ability needs counterplay, a warning, or a deliberate risk/reward tradeoff.
- Avoid unavoidable damage immediately after a teleport, respawn or forced camera transition.
- Director events must respect cooldowns, phase eligibility and reaction windows.
- Difficulty scaling should change pressure, coordination and objective complexity—not only health/damage.
- Solo and small parties must not be punished by mechanics that assume eight players.

## 6. Death and Ghost Mode

- Death does not immediately remove a player from the mission.
- Ghost actions are explicitly allow-listed.
- Ghosts cannot perform physical pickups, delivery, damage or normal objective interactions.
- Ghost information must not bypass investigation for living players.
- Ghost participation may count toward rewards, but reward calculation must not encourage intentional death.

## 7. Equipment

- Target 5–7 tools for MVP.
- Each tool has one clear purpose, limitation and interaction feedback.
- Tools must have usable mobile controls.
- No equipment is mandatory for a specific player class.
- Tool effects that affect mission truth or threat are server-validated.

## 8. Accessibility

- No microphone or voice chat requirement.
- Essential audio information has a visual or textual alternative.
- Important interactions are not dependent on tiny hit targets.
- Objective and interaction state remains readable on mobile.
- Camera mode must not create a gameplay advantage.
