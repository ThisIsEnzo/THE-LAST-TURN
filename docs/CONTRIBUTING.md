# Contributing to THE LAST TURN

## 1. Ownership

- **Project owner:** final product decisions, Roblox Studio validation and merge approval.
- **ChatGPT:** product/technical documentation, architecture, bounded repository edits, code review and task specifications.
- **Claude Code:** focused implementation tasks requiring local repository/toolchain access. Claude does not merge PRs or expand scope independently.

Do not delegate straightforward documentation or review work when it can be completed directly.

## 2. Task and branch rules

- Every change references a roadmap task ID (TTL-xx) or an explicitly approved Phase 0 task.
- One coherent task per PR.
- Branch from the latest `master`.
- Use descriptive branch names, e.g. `feature/ttl-01-project-bootstrap`.
- Keep PRs small and avoid unrelated formatting or refactors.
- Do not start dependent work until prerequisite changes are merged.

## 3. PR description

Every PR includes:
- Task ID and roadmap link.
- Problem and intended outcome.
- Scope included and explicitly excluded.
- Files/systems changed.
- Acceptance criteria checklist.
- Tests actually run and results.
- Studio validation status (not run / run, with client count).
- Known limitations and follow-up tasks.

## 4. Review and merge

- A PR being open or green does not mean it is approved.
- Review the actual diff, not only the PR description.
- Check server authority, lifecycle cleanup, mobile implications and scope.
- Do not merge without explicit project-owner approval.
- Update roadmap status only after merge and required validation.
- If Studio validation is still pending, mark the task as merged-but-unverified rather than fully complete.

## 5. Claude Code task instructions

Claude must:
1. Read the relevant GDD, Technical Specification and task acceptance criteria.
2. Work only on the assigned task and branch.
3. Avoid architecture changes unless explicitly requested.
4. Never claim tests/build/Studio checks that were not executed.
5. Report exact files changed, commit SHA, commands/tests and results.
6. Open a PR; do not merge it.
