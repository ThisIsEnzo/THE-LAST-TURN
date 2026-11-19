--!strict
-- Mission-only evidence -> objective mapping; never replicated.
return table.freeze({
    version = 1,
    mappings = table.freeze({
        table.freeze({ evidenceId = "COLD_SPOT", objectiveId = "DOCUMENT_COLD_SPOT", sourceToken = "evidence_cold_spot" }),
    }),
})
