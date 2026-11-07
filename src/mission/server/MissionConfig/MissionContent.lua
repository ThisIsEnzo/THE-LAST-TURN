--!strict
-- Static mission content (MISSION server only; never replicated). Plain data: no logic and no Roblox APIs, so
-- Lune tests can load and validate exactly what ships. Deeply frozen: the table, the `locations` array and every
-- location definition. Validated by MissionConfigCore.validateContent (ids: [A-Z][A-Z0-9_]*, at most 32 characters,
-- unique). Bump `version` whenever the content changes in a way that could alter a selection.
--
-- THE ASYLUM is the only MVP location (GDD). More locations are added here together with their maps.

local ASYLUM = table.freeze({ id = "ASYLUM" })

return table.freeze({
    version = 1,
    locations = table.freeze({ ASYLUM }),
})
