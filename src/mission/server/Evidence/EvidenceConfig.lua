--!strict
-- Server-only configuration of EvidenceService (TTL-11B). Plain numbers and strings plus one pure validator (no Roblox
-- APIs), so Lune tests load and validate exactly what ships. Nothing here is client-controlled.
--
-- The interaction settings feed InteractionCore specs (validated by the specs against InteractionCore.validateSpec); the
-- prompt texts feed InteractionService prompt options (<= 40 bytes) and are deliberately generic: the prompt is visible to
-- every client before the evidence is discovered, so it must not name the evidence.

export type Config = {
    interaction: { maxDistance: number, holdDuration: number, cooldown: number },
    prompt: { actionText: string, objectText: string },
    confirmWhenCorroborated: boolean,
}

local EvidenceConfig = {}

EvidenceConfig.Values = table.freeze({
    interaction = table.freeze({
        maxDistance = 8, -- studs; PROVISIONAL, tuned in Studio together with InteractionConfig tolerance
        holdDuration = 1.2, -- seconds; UX only (the server only sees the completed activation)
        cooldown = 1, -- seconds; a source is used once, so this only absorbs double triggers
    }),
    prompt = table.freeze({
        actionText = "Examine",
        objectText = "Strange sign",
    }),
    -- Policy: when corroboration reaches the definition's requirement, the service immediately asks EvidenceCore to confirm
    -- (the core still decides). Until another verification step exists (later tasks), turning this off means no evidence
    -- can become CONFIRMED.
    confirmWhenCorroborated = true,
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

local function isPromptText(value: any): boolean
    return type(value) == "string" and #value >= 1 and #value <= 40 and string.find(value, "%c") == nil
end

-- Returns (true, nil) or (false, detail).
function EvidenceConfig.validate(config: any): (boolean, string?)
    if not onlyFields(config, { interaction = true, prompt = true, confirmWhenCorroborated = true }) then
        return false, "config must contain interaction, prompt and confirmWhenCorroborated only"
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
    if not onlyFields(prompt, { actionText = true, objectText = true }) then
        return false, "prompt has missing or unknown fields"
    end
    if not isPromptText(prompt.actionText) or not isPromptText(prompt.objectText) then
        return false, "prompt texts must be 1-40 bytes without control characters"
    end
    if type(config.confirmWhenCorroborated) ~= "boolean" then
        return false, "confirmWhenCorroborated must be a boolean"
    end
    return true, nil
end

return EvidenceConfig
