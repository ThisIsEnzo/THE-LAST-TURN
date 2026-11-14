--!strict
-- Server-only configuration of ObjectiveService (TTL-09B). Plain numbers and strings plus one pure validator (no Roblox
-- APIs), so Lune tests load and validate exactly what ships. Nothing here is client-controlled.
--
-- The interaction settings feed InteractionCore specs (validated by the specs against InteractionCore.validateSpec);
-- the prompt texts feed InteractionService prompt options (<= 40 bytes). The fixture settings only place the runtime
-- greybox anchors (the repository has no authored map yet; TTL-10 replaces the fixture with tagged map parts).

export type Config = {
    interaction: { maxDistance: number, holdDuration: number, cooldown: number },
    prompt: { actionText: string },
    fixture: {
        spawnDistanceStuds: number,
        spacingStuds: number,
        anchorSizeStuds: number,
        heightStuds: number,
        fallbackX: number,
        fallbackY: number,
        fallbackZ: number,
    },
}

local ObjectiveConfig = {}

ObjectiveConfig.Values = table.freeze({
    interaction = table.freeze({
        maxDistance = 8, -- studs; PROVISIONAL, tuned in Studio together with InteractionConfig tolerance
        holdDuration = 0, -- seconds; UX only
        cooldown = 0.5, -- seconds; a slot fills once, so this only absorbs double triggers
    }),
    prompt = table.freeze({
        actionText = "Use",
    }),
    fixture = table.freeze({
        -- In front of the first SpawnLocation, deeper than the test door (which is 14 studs ahead), centered in a row.
        spawnDistanceStuds = 26,
        spacingStuds = 5,
        anchorSizeStuds = 2.5,
        heightStuds = 1.5,
        fallbackX = 0,
        fallbackY = 0,
        fallbackZ = -40,
    }),
})

local function isFiniteNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function inRange(value: any, min: number, max: number): boolean
    return isFiniteNumber(value) and value >= min and value <= max
end

local function onlyFields(value: any, allowed: { [string]: boolean }): boolean
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

-- Returns (true, nil) or (false, detail).
function ObjectiveConfig.validate(config: any): (boolean, string?)
    if not onlyFields(config, { interaction = true, prompt = true, fixture = true }) then
        return false, "config must contain interaction, prompt and fixture only"
    end
    local interaction = config.interaction
    if not onlyFields(interaction, { maxDistance = true, holdDuration = true, cooldown = true }) then
        return false, "interaction has missing or unknown fields"
    end
    if not inRange(interaction.maxDistance, 2, 15) then
        return false, "interaction.maxDistance must be in [2, 15]"
    end
    if not inRange(interaction.holdDuration, 0, 3) then
        return false, "interaction.holdDuration must be in [0, 3]"
    end
    if not inRange(interaction.cooldown, 0, 60) then
        return false, "interaction.cooldown must be in [0, 60]"
    end

    local prompt = config.prompt
    if not onlyFields(prompt, { actionText = true }) then
        return false, "prompt has missing or unknown fields"
    end
    local actionText = prompt.actionText
    if type(actionText) ~= "string" or #actionText < 1 or #actionText > 40 or string.find(actionText, "%c") ~= nil then
        return false, "prompt.actionText must be 1-40 bytes without control characters"
    end

    local fixture = config.fixture
    if not onlyFields(fixture, { spawnDistanceStuds = true, spacingStuds = true, anchorSizeStuds = true, heightStuds = true, fallbackX = true, fallbackY = true, fallbackZ = true }) then
        return false, "fixture has missing or unknown fields"
    end
    if not inRange(fixture.spawnDistanceStuds, 5, 200) then
        return false, "fixture.spawnDistanceStuds must be in [5, 200]"
    end
    if not inRange(fixture.spacingStuds, 3, 30) then
        return false, "fixture.spacingStuds must be in [3, 30]"
    end
    if not inRange(fixture.anchorSizeStuds, 1, 6) then
        return false, "fixture.anchorSizeStuds must be in [1, 6]"
    end
    if not inRange(fixture.heightStuds, 0.5, 10) then
        return false, "fixture.heightStuds must be in [0.5, 10]"
    end
    if not isFiniteNumber(fixture.fallbackX) or not isFiniteNumber(fixture.fallbackY) or not isFiniteNumber(fixture.fallbackZ) then
        return false, "fixture fallback coordinates must be finite numbers"
    end
    return true, nil
end

return ObjectiveConfig
