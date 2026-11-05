--!strict
-- Shared type vocabulary. Server code remains authoritative for every transition.

export type PlayerLifecycle =
    "ALIVE"
    | "DEAD"
    | "GHOST"
    | "SPECTATING"
    | "RETURNING"

return {}
