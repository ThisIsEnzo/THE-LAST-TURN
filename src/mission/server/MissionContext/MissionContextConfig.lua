--!strict
-- MISSION arrival tuning (server-only).

return table.freeze({
    arrivalTimeoutSeconds = 45, -- after the first valid arrival; then missing players are reported, not invented
})
