--!strict
-- Example evidence catalog (TTL-11A, docs/TTL-11A_EVIDENCE_CORE.md). MISSION server only; never replicated. Plain data: no
-- logic and no Roblox APIs, so Lune tests load and validate exactly what ships. Deeply frozen. Bump `version` when it changes.
--
-- This is a generic, mission-agnostic starter catalog, NOT the final entity evidence tables: which evidence an entity can
-- produce (the data-driven entity configs) and where clues appear on a map (authored sources) are later tasks. The core
-- treats categories and ids as free tokens, so new missions only add data here.
--
-- Each definition says how many DISTINCT authored sources must observe it before it can be confirmed (design: the fair
-- verification method; one possibly false signal never confirms anything alone).

local function evidence(id: string, category: string, title: string, description: string, distinctSources: number)
    return table.freeze({
        id = id,
        category = category,
        title = title,
        description = description,
        confirmation = table.freeze({ distinctSources = distinctSources }),
    })
end

return table.freeze({
    version = 1,
    evidence = table.freeze({
        evidence("COLD_SPOT", "ENVIRONMENTAL", "Cold spot", "The air turns unnaturally cold in one place.", 2),
        evidence("STATIC_INTERFERENCE", "ELECTRICAL", "Static interference", "Electronics hiss and drop out near the presence.", 2),
        evidence("MOVED_OBJECT", "PHYSICAL", "Moved object", "Something was moved while nobody was looking.", 1),
        evidence("VOICE_ECHO", "AUDIO", "Voice echo", "A voice answers from where nobody is standing.", 3),
    }),
})
