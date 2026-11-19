--!strict
-- Static objective content for the first vertical slice (TTL-09A, docs/TTL-09_OBJECTIVE_SYSTEM.md section 14.1).
-- MISSION server only; never replicated. Plain data: no logic and no Roblox APIs, so Lune tests load and validate exactly
-- what ships (ObjectiveGraph.validate / compile). Deeply frozen. Bump `version` when the content changes.
--
-- Illustrative mission fragment, not the final ASYLUM script:
--   RESTORE_POWER (REQUIRED, three slots, any player, any order, solo-completable) -> OPEN_WING (REQUIRED)
--   -> EXTRACT (REQUIRED, DEV PLACEHOLDER) ; FIND_RECORDS (OPTIONAL, independent, nothing depends on it).
--
-- EXTRACT is objective content only. It is NOT the extraction rule: how extraction completes (any player, all living
-- players, quorum, timeout) is a product decision that needs owner approval before TTL-10 (design section 11.6). The
-- single slot exists only so the lifecycle path can be exercised; it must not be used to judge cooperative play.
--
-- `pointId` is a logical anchor id resolved by a later binder (a runtime fixture in TTL-09B, tagged map parts in
-- TTL-10); it is never a part name or path. Every slot has its own anchor.

local function slot(id: string, pointId: string, label: string)
    return table.freeze({ id = id, pointId = pointId, label = label })
end

local RESTORE_POWER = table.freeze({
    id = "RESTORE_POWER",
    importance = "REQUIRED",
    title = "Restore power",
    description = "Bring the asylum's electrical power back online.",
    completion = table.freeze({
        kind = "SLOTS",
        slots = table.freeze({
            slot("FUSE_A", "POWER_FUSE_A", "Fuse box A"),
            slot("FUSE_B", "POWER_FUSE_B", "Fuse box B"),
            slot("FUSE_C", "POWER_FUSE_C", "Fuse box C"),
        }),
    }),
})

local OPEN_WING = table.freeze({
    id = "OPEN_WING",
    importance = "REQUIRED",
    requires = table.freeze({ allOf = table.freeze({ "RESTORE_POWER" }) }),
    title = "Open the wing",
    description = "Unlock access to the sealed wing.",
    completion = table.freeze({
        kind = "SLOTS",
        slots = table.freeze({
            slot("ACCESS_PANEL", "WING_ACCESS_PANEL", "Wing access panel"),
        }),
    }),
})

-- DEV PLACEHOLDER (see header): not the extraction rule.
local EXTRACT = table.freeze({
    id = "EXTRACT",
    importance = "REQUIRED",
    requires = table.freeze({ allOf = table.freeze({ "OPEN_WING" }) }),
    title = "Escape",
    description = "Reach the extraction point.",
    completion = table.freeze({
        kind = "SLOTS",
        slots = table.freeze({
            slot("EXTRACTION_POINT", "EXTRACTION_POINT", "Extraction point"),
        }),
    }),
})

local FIND_RECORDS = table.freeze({
    id = "FIND_RECORDS",
    importance = "OPTIONAL",
    title = "Find the records",
    description = "Search for patient records. Optional.",
    completion = table.freeze({
        kind = "SLOTS",
        slots = table.freeze({
            slot("RECORDS_CABINET", "RECORDS_CABINET", "Records cabinet"),
        }),
    }),
})

-- TTL-11D optional objective: completed by the trusted server bridge after COLD_SPOT is CONFIRMED.
local DOCUMENT_COLD_SPOT = table.freeze({
    id = "DOCUMENT_COLD_SPOT",
    importance = "OPTIONAL",
    title = "Document cold spot",
    description = "Confirm a cold spot to document the phenomenon.",
    completion = table.freeze({
        kind = "SIGNAL",
        signal = table.freeze({ sourceToken = "evidence_cold_spot" }),
    }),
})

return table.freeze({
    version = 2,
    objectives = table.freeze({ RESTORE_POWER, OPEN_WING, EXTRACT, FIND_RECORDS, DOCUMENT_COLD_SPOT }),
})