--!strict
-- Server-only configuration of ObjectiveService (TTL-09B). Plain numbers and strings plus one pure validator (no Roblox
-- APIs), so Lune tests load and validate exactly what ships. Nothing here is client-controlled.
--
-- The interaction settings feed InteractionCore specs (validated by the specs against InteractionCore.validateSpec);
-- the prompt texts feed InteractionService prompt options (<= 40 bytes). The objective anchors come from the authored
-- map (tag `ObjectivePoint`, attribute `PointId`; see ObjectiveAnchors), not from this config.

export type Config = {
    interaction: { maxDistance: number, holdDuration: number, cooldown: number },
    prompt: { actionText: string },
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
    if not onlyFields(config, { interaction = true, prompt = true }) then
        return false, "config must contain interaction and prompt only"
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

    return true, nil
end

return ObjectiveConfig
