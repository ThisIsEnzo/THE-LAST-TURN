# Phase 0 — Pre-production Checklist

**Purpose:** Make the repository and Roblox development environment reproducible before feature implementation.
**Status:** In progress. Repository/toolchain foundation and Roblox Experience/Places are in place; Studio smoke test and workflow validation remain owner-dependent.

| ID | Preparation activity | Exit criteria | Status |
|---|---|---|---|
| P0-01 | Product baseline | GDD v1.0 approved and linked from README | DONE |
| P0-02 | Technical baseline | Technical spec, architecture, gameplay rules and testing docs merged | DONE |
| P0-03 | Repository workflow | Branch/PR/review rules and ignore/editor settings merged | DONE |
| P0-04 | Rojo project bootstrap | Separate HUB and MISSION project files build successfully | DONE |
| P0-05 | Toolchain reproducibility | Pinned Rojo/Lune toolchain is declared and CI builds validate the projects | DONE |
| P0-06 | Roblox Experience | Experience created and owner confirms access | DONE |
| P0-07 | HUB Place | HUB Place created; PlaceId recorded in project configuration | DONE |
| P0-08 | MISSION Place | MISSION Place created; PlaceId recorded in project configuration | DONE |
| P0-09 | Studio smoke test | Both Rojo projects sync/open in Studio without mapping errors | BLOCKED — owner action |
| P0-10 | First workflow validation | A small source change is synced to both places and verified | BLOCKED — owner action |

## Rules

- Do not invent ExperienceId or PlaceIds. The project owner supplies the actual IDs after creating the Roblox Experience and Places.
- Do not mark Studio validation complete based only on a successful Rojo build.
- Reserved-server teleport implementation may be developed with a safe disabled configuration, but live validation requires both real PlaceIds and a published Experience.
- Phase 0 is complete only when all ten activities are DONE or explicitly waived by the project owner.

## Current boundary

The HUB and MISSION Places and their IDs are now configured. P0-09 (Studio smoke test) and P0-10 (end-to-end workflow validation) remain open until the owner verifies them in Studio.
