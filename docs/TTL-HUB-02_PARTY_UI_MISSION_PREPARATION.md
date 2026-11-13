# TTL-HUB-02 — Party UI & Mission Preparation

**Status:** Implemented on the PR branch; review fixes in progress. **Not validated in Roblox Studio.** Do not treat CI, pure tests or ad-hoc mocks as proof of real multiplayer, UI or teleport behavior.

## 1. Scope

Deliver the first player-facing HUB loop:

1. A player enters the HUB and receives their server-created solo party.
2. Players can inspect the squad, invite other HUB players, accept/decline invitations, leave and (as leader) kick members.
3. The Mission Preparation board opens a terminal for THE ASYLUM.
4. Only the current leader can request launch.
5. The existing TTL-05 service validates and teleports the party to its reserved MISSION server.

This task does not add matchmaking, another party backend, multiple mission selection, ready-check, inventory/shop, monetization or new HUB geometry.

## 2. Architecture

- `src/shared/Party/PartyView.lua`: pure client-side mirror and view model; never authoritative.
- `src/shared/Mission/LaunchView.lua`: pure launch presentation state.
- `src/shared/UI/Messages.lua`, `Layout.lua`: player-facing safe text and responsive metrics.
- `src/hub/client/Party/PartyController.lua`: subscribes to existing party notifications, sends existing party requests, handles correlated action results and bounded no-response recovery.
- `src/hub/client/Mission/MissionLaunchController.lua`: subscribes to the existing launch status and sends `MissionLaunch` with no payload.
- `src/hub/client/UI/PartyHud.lua`, `MissionTerminal.lua`, `UiKit.lua`: presentation only.
- `src/hub/client/Bootstrap.client.lua`: starts controllers and UI.

Controllers expose idempotent start/destroy behavior and clean up their connections. The UI is event-driven; it does not continuously poll.

## 3. Existing systems reused

TTL-HUB-02 reuses:
- TTL-04 `PartyService` / `PartyCore` and the existing `PartyInvite`, `PartyRespondInvite`, `PartyLeave`, `PartyKick`, and `PartyRequestSnapshot` requests.
- TTL-05 `MissionTeleportService` and its payload-less `MissionLaunch` request / `MissionLaunchStatus` notification.
- The existing Mission Preparation board in the HUB greybox.

No new request endpoint is introduced. One additive server-to-client notification, `PartyActionResult`, acknowledges invite and invitation-response requests.

## 4. Party action acknowledgement protocol

`PartyInvite` now carries `{ targetUserId, requestId }`; `PartyRespondInvite` carries `{ inviterUserId, accept, requestId }`. The client-generated positive integer `requestId` is only a correlation value. It is not a user identity, permission, party id or security token.

The HUB server:
1. Validates the exact request schema and existing rate limit.
2. Resolves the target/inviter from connected Players; it never trusts a client-supplied Player object.
3. Calls the existing `PartyService` / `PartyCore` operation.
4. Sends `PartyActionResult` only to the requesting player, with `action`, `requestId`, the relevant subject user id, `ok`, and an optional rejection reason.

This covers missing/disconnected targets and PartyCore rejection reasons such as `not_leader`, `party_full`, `already_invited`, `too_many_invites`, `no_invite`, `invite_expired` and `target_in_party`. The server's existing rules are not weakened.

The client reports “Invitation sent” only after a positive acknowledgement. A rejection clears the optimistic outgoing state or restores an invitation response row to an actionable state, then maps the reason to safe player-facing text. Unknown server reasons receive generic copy; raw codes, ids, tokens and errors are not displayed.

If no acknowledgement arrives within 5 seconds, the client clears the pending UI state and explains that the action was not confirmed. This is a UI recovery timeout, not cancellation or rollback: a server operation may still complete. A late acknowledgement is ignored once its pending request has expired.

## 5. Party UI behavior

- Shows squad members, display names, leader and local-player markers, size/capacity.
- Invite controls are presented as hints based on the latest server snapshot; the server remains the authority.
- Incoming invitations show accept/decline and a countdown when received live.
- Invitation end notifications drive accepted/declined/expired/cancelled/superseded feedback.
- Leave and kick controls are shown only when locally appropriate; all requests are revalidated server-side.
- Leader reassignment and member departure are rendered from new snapshots.
- Duplicate-click locks are UX safeguards only.

A snapshot-restored invitation has no client countdown because the server's `expiresAt` uses a server clock domain. The server still validates its actual expiry.

## 6. Mission Preparation terminal

The terminal is attached client-side to the existing Mission Preparation board. It displays THE ASYLUM, current squad state and launch feedback. A non-leader sees that they are waiting for the leader; the leader can request launch. The request carries no mission, place, party or player parameters. The server resolves all launch facts using the existing TTL-05 implementation.

The UI maps only actual `MissionLaunchStatus` values to player-facing messages. It does not expose reserved-server ids, teleport tokens, raw error details or internal codes. Existing client-side recovery timeouts prevent a permanently stuck panel but do not imply the server launch was cancelled.

## 7. Layout and input

The UI uses compact/regular layout metrics, safe-area-aware screen placement, touch-sized controls and activated input rather than hover-only affordances. Both portrait and landscape mobile layouts still require Studio/device validation. The client-side ProximityPrompt and board text are presentation conveniences, not server authority.

## 8. Automated validation

Pure tests cover the party mirror, launch view, message mapping and layout helper. The acknowledgement handler itself depends on Roblox RemoteEvents and is not proven by pure tests. CI must report:
- `lune run tests/run`
- `rojo build hub.project.json`
- `rojo build mission.project.json`

Do not mark any command as passed unless its output/workflow is available. Ad-hoc Lua translations or fake-service checks are supplementary evidence only, not Luau/Lune or Roblox runtime validation.

## 9. Known limitations

- A no-response timeout cannot determine whether the server processed an action; it only releases the client UI and ignores late acknowledgements.
- Snapshot-restored invitations cannot display an accurate countdown from the server-clock timestamp.
- Invite/kick/leave UI locks do not replace server validation. The new acknowledgement specifically covers invite and accept/decline; membership-changing actions are confirmed by subsequent party snapshots.
- Mission teleport and reserved-server arrival require a published Experience with valid PlaceIds.
- The panel does not freeze character movement. The client-side prompt/board display depends on the existing greybox board path.
- Visual polish, animations, sound and mission selection are outside this task.

## 10. Manual Studio checklist — all PENDING

Use Studio Local Server with at least two clients for party flows. A published Experience with the MISSION place configured is required for real reserved-server teleport validation.

1. Solo join: HUD shows a one-player leader squad.
2. Invite another connected player; inviter sees success only after server acknowledgement.
3. Invite a disconnected/unknown target through a controlled test; rejection is visible and the candidate can be retried.
4. Invite while not leader; server rejection is shown and no false success appears.
5. Invite when party is full; server rejection is shown.
6. Invite when the target's pending-invite quota is reached; rejection is shown and optimistic state clears.
7. Target receives invitation and sees countdown.
8. Target accepts; both clients show the same resulting party and no stale invite.
9. Target attempts accept while already in a multi-member party; server rejection is shown and invitation row becomes actionable again where still valid.
10. Target declines; inviter sees the decline and can invite again.
11. Leave an invitation until expiry; both sides receive the expected expiry behavior.
12. Leader kicks a member; member returns to a solo party.
13. Leader leaves/disconnects; remaining party receives the new leader snapshot.
14. Non-leader opens Mission Preparation and cannot start; leader can open and start.
15. Entire party receives launch feedback and arrives in the same reserved MISSION server.
16. Teleport failure/retry and delayed/no acknowledgement recovery behave safely; repeat on mobile portrait and landscape with readable text and reachable controls.

Record the Studio version, client count, device/emulator, result and any console errors when completing this checklist. Until then, every item remains pending.
