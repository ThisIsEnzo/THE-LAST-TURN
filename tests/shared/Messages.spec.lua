--!strict
local Harness = require("../Harness")
local Messages = require("../../src/shared/UI/Messages")
local Layout = require("../../src/shared/UI/Layout")

local test, expectTrue, expectFalse, expectEqual = Harness.test, Harness.expectTrue, Harness.expectFalse, Harness.expectEqual

local STATUSES = {
    "accepted",
    "already_in_progress",
    "not_leader",
    "invalid_party",
    "preparation_failed",
    "teleport_failed",
    "retrying",
    "launch_initiated",
    "partial_failure",
}
local TONES = { info = true, progress = true, warning = true, error = true }

test("every actual launch status has a complete message", function()
    for _, status in ipairs(STATUSES) do
        local message = Messages.launch(status, nil, 1, 3)
        expectTrue(#message.title > 0, status)
        expectTrue(#message.text > 0, status)
        expectTrue(TONES[message.tone] == true, status)
    end
end)

test("player-facing text never contains the raw code, ids or error details", function()
    local codes = { "reserved-server-0123456789", "token_abcdef", "Exception: attempt to index nil", "stack traceback:" }
    for _, status in ipairs(STATUSES) do
        for _, code in ipairs(codes) do
            local message = Messages.launch(status, code, 1, 3)
            expectTrue(string.find(message.text, code, 1, true) == nil, status .. " text leaks " .. code)
            expectTrue(string.find(message.title, code, 1, true) == nil, status .. " title leaks " .. code)
        end
    end
    local unknown = Messages.launch("something_else", "secret", nil, nil)
    expectTrue(string.find(unknown.text, "secret", 1, true) == nil)
    expectEqual(unknown.title, "UNEXPECTED RESPONSE")
end)

test("the client recovery texts are defined", function()
    expectEqual(Messages.NoResponse.tone, "error")
    expectEqual(Messages.LaunchTimedOut.tone, "error")
end)

test("invitation endings read naturally for both roles", function()
    for _, reason in ipairs({ "accepted", "declined", "expired", "cancelled", "superseded" }) do
        local target = Messages.inviteEnded(reason, "target")
        local inviter = Messages.inviteEnded(reason, "inviter")
        expectTrue(string.find(target, "{name}", 1, true) ~= nil, reason)
        expectTrue(string.find(inviter, "{name}", 1, true) ~= nil, reason)
        expectTrue(target ~= inviter, reason)
    end
    expectEqual(Messages.inviteEnded("accepted", "inviter"), "{name} joined your squad.")
    expectEqual(Messages.inviteEnded("surprise", "target"), "{name}'s invitation ended.")
    expectEqual(Messages.inviteEnded(nil, "inviter"), "Your invitation to {name} ended.")
end)

test("blocked invitations and squad events have messages", function()
    for _, reason in ipairs({ "not_leader", "party_full", "already_in_party", "already_invited", "self", "busy", "other" }) do
        expectTrue(#Messages.inviteBlocked(reason) > 0, reason)
    end
    expectEqual(Messages.partyEvent("leader_changed", true), "You are now the squad leader.")
    expectEqual(Messages.partyEvent("leader_changed", false), "{name} is now the squad leader.")
    expectEqual(Messages.partyEvent("member_left"), "{name} left the squad.")
    expectEqual(Messages.partyEvent("nope"), "The squad changed.")
end)

test("party action rejection reasons are translated without exposing raw codes", function()
    local cases = {
        { "not_leader", "Only the squad leader can do that." },
        { "party_full", "The squad is full." },
        { "unknown_target", "That player is no longer in this server." },
        { "no_invite", "That invitation is no longer available." },
        { "invite_expired", "That invitation has expired." },
        { "target_in_party", "Leave your current squad before accepting another invitation." },
    }
    for _, case in ipairs(cases) do
        expectEqual(Messages.partyActionFailure(case[1]), case[2], case[1])
    end
    expectTrue(Messages.partyActionFailure("private_internal_error") ~= "private_internal_error")
end)

test("fill substitutes the name literally", function()
    expectEqual(Messages.fill("{name} joined.", "Alex"), "Alex joined.")
    expectEqual(Messages.fill("{name} and {name}", "%1"), "%1 and %1", "pattern characters in names are harmless")
    expectEqual(Messages.fill("No placeholder.", "Alex"), "No placeholder.")
end)

-- Layout --------------------------------------------------------------------------------------------------------------------------

test("layout classes: phones and small windows are compact, large screens regular", function()
    expectEqual(Layout.classify(1920, 1080, false), "regular")
    expectEqual(Layout.classify(1280, 720, false), "regular")
    expectEqual(Layout.classify(390, 844, true), "compact", "portrait phone")
    expectEqual(Layout.classify(844, 390, true), "compact", "landscape phone")
    expectEqual(Layout.classify(700, 900, false), "compact", "narrow window")
    expectEqual(Layout.classify(1280, 470, false), "compact", "short window")
    expectEqual(Layout.classify(1024, 768, true), "regular", "tablet")
    expectEqual(Layout.classify(1000, 580, true), "compact", "small touch screen")
end)

test("invalid viewport sizes fall back to regular", function()
    for _, bad in ipairs({ 0, -5, 0 / 0 }) do
        expectEqual(Layout.classify(bad, 800, false), "regular")
        expectEqual(Layout.classify(800, bad, false), "regular")
    end
    expectEqual(Layout.classify("x", 800, false), "regular")
    expectEqual(Layout.classify(nil, nil, nil), "regular")
end)

test("compact metrics use touch-friendly sizes", function()
    local compact, regular = Layout.metrics("compact"), Layout.metrics("regular")
    expectTrue(compact.buttonHeight >= 44, "touch targets of at least 44 px")
    expectTrue(compact.textBody >= 14 and compact.textSmall >= 14)
    expectTrue(compact.panelWidthScale > regular.panelWidthScale)
    expectEqual(Layout.metrics("anything").buttonHeight, regular.buttonHeight)
    expectTrue(table.isfrozen(compact))
    expectFalse(table.isfrozen({}))
end)
