--!strict
-- Shared lifecycle vocabulary. Server code remains authoritative for every transition.
-- Meanings (see docs/ARCHITECTURE.md):
--   ALIVE      actively participating
--   DEAD       died; post-death flow pending or being resolved
--   GHOST      ghost participation state
--   SPECTATING observing other players, not participating
--   RETURNING  leaving the mission / returning to the HUB (terminal)

export type PlayerLifecycle =
    "ALIVE"
    | "DEAD"
    | "GHOST"
    | "SPECTATING"
    | "RETURNING"

local PlayerLifecycleVocabulary = {
    States = table.freeze({
        ALIVE = "ALIVE",
        DEAD = "DEAD",
        GHOST = "GHOST",
        SPECTATING = "SPECTATING",
        RETURNING = "RETURNING",
    }),

    -- Server-owned Player attribute that projects the current state to clients (read-only for clients).
    StateAttribute = "LifecycleState",
}

return table.freeze(PlayerLifecycleVocabulary)
