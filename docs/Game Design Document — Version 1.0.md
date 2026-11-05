# THE LAST TURN
## Game Design Document — Version 1.0

**Status:** Approved Product Baseline  
**Platform:** Roblox  
**Genre:** Cooperative Paranormal Investigation / Survival Horror  
**Players:** 1–8  
**Target Session:** 15–20 minutes  
**Working Title:** THE LAST TURN

---

## 1. Product Vision

THE LAST TURN is a cooperative paranormal horror experience in which players enter supernatural environments controlled by an ancient cursed game.

Every mission is a new game. The location, paranormal entity, clues, events, and conditions change between sessions.

Players must investigate the environment, identify the entity, collect required objects, perform rituals, survive supernatural attacks, and complete the final objective.

The experience combines:
- Unpredictable adventure and event generation.
- Paranormal investigation.
- Supernatural communication and rituals.
- Cooperative survival.
- Dynamic entity behavior.
- Persistent player progression.

### Core promise

Every session creates a different supernatural experience. Players never know exactly what will happen next, and teamwork is essential to survival.

### Product differentiation

The central differentiator is the relationship between three systems:

1. The Game controls mission rules and events.
2. The Entity reacts to player behavior.
3. The Team discovers how to survive and complete the mission.

The experience must not become a simple collection of scripted jumpscares.

---

## 2. Target Audience

Primary audience:
- Roblox players interested in cooperative horror.
- Players who enjoy investigation and mystery.
- Groups of friends looking for replayable multiplayer experiences.
- Players who enjoy discovering hidden mechanics and secrets.

Secondary audience:
- Solo players.
- Content creators.
- Players interested in supernatural stories and collectibles.

The game must support both casual players and experienced horror players.

### Accessibility principles

- Simple controls.
- Short onboarding.
- Understandable objectives.
- Mobile-first interaction design.
- Readable UI.
- No requirement for microphone or voice chat.
- No requirement to have a full team.

---

## 3. Core Game Structure

### 3.1 Experience architecture

The experience consists of two main environments:

**HUB**
- Persistent social lobby.
- Player gathering.
- Party formation.
- Equipment selection.
- Progression and cosmetics.
- Mission matchmaking.
- Launching missions.

**MISSION**
- Separate server instance.
- One team per mission.
- Independent mission state.
- Randomized configuration.
- Mission completion and rewards.
- Return to HUB.

Players must never be able to modify another team's mission state.

### 3.2 Player capacity

Maximum party size: 8.

Recommended balancing baseline: 4 players.

The game must support 1, 2, 3, 4, 5, 6, 7, and 8 players without requiring a full party.

Mission difficulty must scale with player count without simply increasing enemy health or damage.

### 3.3 Camera

Hybrid camera:
- First Person.
- Third Person.
- Player-controlled switching.
- Both modes supported on PC and mobile.
- Camera transitions must not interfere with interaction, combat avoidance, or character movement.

The camera mode must never provide an unfair gameplay advantage.

---

## 4. Core Gameplay Loop

### Stage 1 — Preparation
Players gather in HUB, select equipment, and start a mission.

### Stage 2 — The First Turn
The cursed game generates a mission configuration:
- Location.
- Entity.
- Initial conditions.
- Mission objectives.
- Event modifiers.
- Clue distribution.

### Stage 3 — Investigation
Players explore, search for clues, discover anomalies, and collect resources.

### Stage 4 — Contact
Players can communicate with the entity using specialized equipment and ritual objects.

Contact increases supernatural activity and may reveal information or trigger danger.

### Stage 5 — The Hunt
The entity becomes increasingly dangerous.

Players must use discovered information and coordinate their actions.

### Stage 6 — Final Ritual
Players complete the final objective, activate the required sequence, and close the supernatural passage.

### Stage 7 — Results
The server evaluates mission performance, distributes rewards, records discoveries, and returns players to HUB.

The stages are logical gameplay phases, not necessarily a rigid sequence. Events may alter their order.

---

## 5. Mission Design

A standard mission should last approximately 15–20 minutes.

Target timing:
- Preparation: 1–2 minutes.
- Initial event: 1 minute.
- Investigation: 3–5 minutes.
- Contact: 3–4 minutes.
- Hunt: 3–5 minutes.
- Final objective: 2–3 minutes.
- Results: approximately 1 minute.

These are balancing targets, not mandatory timers.

### Mission objectives

Each mission contains:
- One primary objective.
- Several investigation objectives.
- Resource collection tasks.
- One final ritual or containment sequence.
- Optional bonus objectives.

### Cooperative contribution

All required resources must be shareable through team contribution.

For example, a final ritual may require:
- Three ritual objects.
- Two energy sources.
- One discovered clue.

Different players can collect and deliver different items.

No essential objective should require one specific player to collect every item.

### Mission outcomes

Possible outcomes:
- Successful containment.
- Successful escape with incomplete investigation.
- Partial success.
- Complete failure.

Surviving players and dead players receive rewards according to their contribution and mission result.

---

## 6. Entity System

Entities are supernatural opponents with distinct behavior, investigation clues, and countermeasures.

Each entity must define:
- Identity.
- Behavioral rules.
- Passive abilities.
- Active abilities.
- Investigation evidence.
- Hunting conditions.
- Countermeasures.
- Difficulty rating.
- Event interactions.

### Initial entity concepts

**THE WATCHER**
- Observes players.
- Becomes dangerous when directly observed.
- Can imitate distant silhouettes.
- Can appear in reflections.

Countermeasure: observation discipline and environmental investigation.

**THE MIMIC**
- Imitates sounds and voices.
- Produces false signals.
- Can imitate player-like behavior.
- Punishes careless separation.

Countermeasure: verification procedures and team communication.

**THE STATIC**
- Manipulates electrical systems.
- Disables equipment.
- Interacts with powered devices.
- Can use electrical infrastructure to move or manifest.

Countermeasure: managing electricity and controlling equipment usage.

These are initial design concepts. Final abilities must be validated through gameplay testing.

### Entity identification

Players should discover evidence and narrow down the possible entity type.

The investigation must reward observation and deduction rather than random guessing.

---

## 7. Entity Director

The Entity Director controls dynamic mission events.

It evaluates:
- Current mission phase.
- Entity activity.
- Player positions.
- Player count.
- Completed objectives.
- Current event history.
- Elapsed mission time.
- Mission difficulty.

It selects suitable events from an authored event pool.

Examples:
- Electrical interruption.
- False audio signal.
- Temporary environmental change.
- Entity manifestation.
- Unusual object movement.
- Unexpected objective modification.

The Director must respect:
- Event cooldowns.
- Maximum simultaneous threats.
- Mission fairness.
- Minimum reaction time.
- Player count.
- Mission state.

The Director must create tension without guaranteeing player failure.

No adaptive difficulty system should unfairly punish skilled players.

---

## 8. Ritual System

Rituals are cooperative interactions that connect investigation and mission completion.

Initial ritual mechanics:
- Discover required objects.
- Deliver objects to designated locations.
- Activate objects in a required sequence.
- Complete a shared interaction.
- Survive interruptions.
- Confirm ritual completion.

Ritual requirements must be data-driven.

Players must be able to contribute independently.

A ritual must provide clear feedback about:
- Required items.
- Completed steps.
- Missing requirements.
- Current progress.
- Interruptions.
- Completion state.

---

## 9. Ghost Mode

Death does not immediately remove a player from the mission.

After death:
- The player enters Ghost Mode.
- The player can observe surviving teammates.
- The player remains connected to the mission.
- The player has restricted interaction capabilities.
- The player cannot complete normal physical objectives.
- The player cannot directly damage or eliminate the entity.

Initial ghost capabilities:
- Spectator camera.
- Limited movement in ghost form.
- Limited supernatural perception.
- Optional communication through predefined signals.
- Access to restricted ghost-only information when designed as an objective mechanic.

Ghosts must not be able to reveal the entity's location or mission solutions without meaningful limitations.

Ghosts must not be able to collect physical objectives or bypass mission requirements.

Ghosts remain eligible for participation-based rewards.

Ghost Mode must work with one or multiple surviving players.

---

## 10. Player Equipment

Equipment is selected in HUB before a mission.

Initial equipment categories:

1. Detection — identifying anomalies.
2. Observation — recording supernatural activity.
3. Communication — interacting with entities.
4. Protection — temporary defensive tools.
5. Utility — lighting, power, and environmental interaction.

Initial MVP equipment target: 5–7 tools.

Equipment must have:
- Unique purpose.
- Clear interaction rules.
- Appropriate limitations.
- Mobile-compatible controls.
- Server-validated effects.

Avoid creating mandatory player classes.

Any player should be able to contribute regardless of their equipment choice.

---

## 11. Locations

Planned locations:

**THE ASYLUM**
- Initial MVP location.
- Hospital rooms.
- Corridors.
- Basement.
- Treatment areas.
- Storage areas.

**THE WOODS**
- Forest.
- Abandoned house.
- Ritual clearing.
- Outdoor exploration.

**THE FACILITY**
- Research laboratories.
- Containment chambers.
- Electrical systems.
- Restricted rooms.

**THE MANOR**
- Gothic mansion.
- Secret rooms.
- Family history.
- Hidden passages.

Only THE ASYLUM is required for MVP.

The initial map should support multiple randomized configurations and environmental states.

---

## 12. Progression

Persistent player progression:

- Player Level.
- Experience.
- Entity Codex.
- Equipment unlocks.
- Ritual discoveries.
- Achievements.
- Cosmetic collection.
- Mission statistics.

Progression must reward exploration, cooperation, and discovery.

Progression must not make new players significantly weaker than experienced players.

---

## 13. Monetization

Monetization must be non-pay-to-win.

Permitted directions:
- Character cosmetics.
- Equipment skins.
- Emotes.
- Cosmetic animations.
- Personal lobby decorations.
- VIP cosmetic benefits.
- Seasonal cosmetic collections.
- Private server options.

Avoid:
- Paid combat advantages.
- Stronger exclusive equipment.
- Paid revival advantages.
- Paid random loot mechanics.
- Gameplay requirements that force purchases.

All purchases and rewards must comply with current Roblox policies.

---

## 14. Audio and Atmosphere

Audio is a primary gameplay system.

Requirements:
- Directional environmental sounds.
- Distinct entity audio signatures.
- Contextual music.
- Audio cues for investigation.
- Silence as a tension mechanic.
- Distinct warning signals.
- Clear accessibility alternatives for essential audio information.

Essential gameplay information must not rely exclusively on hearing.

---

## 15. UI / UX

Required interfaces:
- Main HUB.
- Party interface.
- Equipment selection.
- Mission objectives.
- Inventory.
- Interaction prompts.
- Investigation interface.
- Entity Codex.
- Ritual progress.
- Ghost interface.
- Mission results.
- Settings.

UI must support:
- PC.
- Mobile.
- Tablet.
- Gamepad where practical.

The first five minutes must introduce gameplay through interaction rather than long tutorials.

---

## 16. MVP Scope

Initial public-release target:

- 1 HUB.
- 1 mission location.
- 3 entities.
- 5–7 equipment tools.
- 2–3 ritual variations.
- 15–20 events.
- 3 mission objective variations.
- 1–8 player support.
- Hybrid camera.
- Ghost Mode.
- Basic progression.
- Basic cosmetics.
- Core matchmaking and mission lifecycle.

Features outside this list require explicit scope approval.

---

## 17. Non-Goals for MVP

Not included:
- Large open world.
- Four complete locations.
- Dozens of entities.
- Complex story campaign.
- Advanced machine-learning AI.
- Mandatory voice chat.
- Competitive PvP.
- Trading economy.
- Large-scale crafting.
- Extensive player housing.

---

## 18. Quality Principles

Every feature must support at least one of:
- Replayability.
- Cooperation.
- Discovery.
- Tension.
- Player retention.
- Accessibility.

Avoid features that increase development complexity without meaningful player value.

The first priority is a fun, complete, replayable mission—not the quantity of content.

---

## 19. Product Success Criteria

Evaluate the game through:
- First-session completion.
- First five-minute bounce.
- Average session duration.
- Repeat play days.
- Party size distribution.
- Mission completion rate.
- Mission abandonment.
- Ghost participation.
- Return rate.
- Technical stability.

Do not judge product success by visits alone.

---

## 20. Change Management

This document is the approved baseline for THE LAST TURN v1.0.

Changes must be:
- Documented.
- Justified by design or technical requirements.
- Evaluated for impact on existing systems.
- Reflected in the roadmap.
- Reviewed before implementation.

The MVP scope must not expand automatically.

**End of GDD v1.0.**