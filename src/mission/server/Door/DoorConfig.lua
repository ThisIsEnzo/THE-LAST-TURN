--!strict
-- Server-only configuration of the first gameplay consumer of the interaction infrastructure (TTL-08C): one test
-- door. Plain numbers, strings and pure helpers only (no Roblox APIs), so Lune tests can validate exactly what ships.
-- Nothing here is client-controlled and there is deliberately no generic door framework.

export type InteractionSettings = {
    id: string,
    maxDistance: number, -- studs, accepted activation radius (the interaction service adds its own tolerance)
    holdDuration: number, -- seconds; UX only
    cooldown: number, -- seconds; must be >= door.transitionSeconds
    actionText: string,
    objectText: string,
}

export type DoorSettings = {
    initialState: string, -- "Closed" | "Open"
    transitionSeconds: number,
}

export type FixtureSettings = {
    panelWidth: number,
    panelHeight: number,
    panelThickness: number,
    pillarWidth: number,
    openAngleDegrees: number, -- hinge swing; the sign chooses the swing direction
    spawnDistanceStuds: number, -- the fixture is placed this far in front of the first SpawnLocation, if any
    fallbackX: number, -- used when the place has no SpawnLocation
    fallbackY: number, -- ground height
    fallbackZ: number,
}

export type Config = {
    enabled: boolean,
    interaction: InteractionSettings,
    door: DoorSettings,
    fixture: FixtureSettings,
}

local DoorConfig = {}

DoorConfig.Values = table.freeze({
    -- Set to false (or replace the fixture) once a real map door exists; with false the consumer registers nothing.
    enabled = true,

    interaction = table.freeze({
        id = "TestDoor",
        maxDistance = 8,
        holdDuration = 0,
        cooldown = 1, -- covers the 0.6 s transition so a door cannot be toggled mid-swing
        actionText = "Use",
        objectText = "Door",
    }),

    door = table.freeze({
        initialState = "Closed",
        transitionSeconds = 0.6,
    }),

    -- The test fixture is built at runtime by the server (the repository has no Workspace mapping or place file).
    fixture = table.freeze({
        panelWidth = 6,
        panelHeight = 8,
        panelThickness = 0.5,
        pillarWidth = 1,
        openAngleDegrees = 90,
        spawnDistanceStuds = 14,
        fallbackX = 0,
        fallbackY = 0,
        fallbackZ = -20,
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

local function isText(value: any, minBytes: number): boolean
    return type(value) == "string" and #value >= minBytes and #value <= 40 and string.find(value, "%c") == nil
end

-- Returns (true, nil) or (false, detail). The door settings themselves are validated by DoorCore.validateConfig and
-- the interaction settings by InteractionCore.validateSpec when they are used; this checks the shape, the fixture
-- numbers and the cross-field rule cooldown >= transitionSeconds. Tests cross-check the three against each other.
function DoorConfig.validate(config: any): (boolean, string?)
    if not onlyFields(config, { enabled = true, interaction = true, door = true, fixture = true }) then
        return false, "config must contain enabled, interaction, door and fixture only"
    end
    if type(config.enabled) ~= "boolean" then
        return false, "enabled must be a boolean"
    end

    local interaction = config.interaction
    if not onlyFields(interaction, { id = true, maxDistance = true, holdDuration = true, cooldown = true, actionText = true, objectText = true }) then
        return false, "interaction has missing or unknown fields"
    end
    local id = interaction.id
    if type(id) ~= "string" or #id < 1 or #id > 64 or string.match(id, "^[%w_%-]+$") == nil then
        return false, "interaction.id must be a 1-64 character token"
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
    if not isText(interaction.actionText, 1) or not isText(interaction.objectText, 0) then
        return false, "interaction texts must be strings of at most 40 bytes without control characters"
    end

    local door = config.door
    if not onlyFields(door, { initialState = true, transitionSeconds = true }) or not isFiniteNumber(door.transitionSeconds) then
        return false, "door has missing or invalid fields"
    end
    if interaction.cooldown < door.transitionSeconds then
        return false, "interaction.cooldown must be at least door.transitionSeconds"
    end

    local fixture = config.fixture
    local fixtureFields = {
        panelWidth = true,
        panelHeight = true,
        panelThickness = true,
        pillarWidth = true,
        openAngleDegrees = true,
        spawnDistanceStuds = true,
        fallbackX = true,
        fallbackY = true,
        fallbackZ = true,
    }
    if not onlyFields(fixture, fixtureFields) then
        return false, "fixture has unknown fields"
    end
    if
        not inRange(fixture.panelWidth, 2, 12)
        or not inRange(fixture.panelHeight, 4, 16)
        or not inRange(fixture.panelThickness, 0.2, 2)
        or not inRange(fixture.pillarWidth, 0.5, 3)
        or not inRange(fixture.spawnDistanceStuds, 4, 60)
        or not inRange(fixture.fallbackX, -10000, 10000)
        or not inRange(fixture.fallbackY, -10000, 10000)
        or not inRange(fixture.fallbackZ, -10000, 10000)
    then
        return false, "fixture dimensions or placement out of range"
    end
    if not isFiniteNumber(fixture.openAngleDegrees) or math.abs(fixture.openAngleDegrees) < 30 or math.abs(fixture.openAngleDegrees) > 120 then
        return false, "fixture.openAngleDegrees must have an absolute value in [30, 120]"
    end
    return true, nil
end

-- The InteractionCore.Spec for the door (a fresh table each call).
function DoorConfig.interactionSpec(config: Config): { [string]: any }
    return {
        id = config.interaction.id,
        maxDistance = config.interaction.maxDistance,
        holdDuration = config.interaction.holdDuration,
        cooldown = config.interaction.cooldown,
    }
end

-- The per-interaction prompt texts for InteractionService.register's options argument.
function DoorConfig.promptOptions(config: Config): { [string]: any }
    return {
        actionText = config.interaction.actionText,
        objectText = config.interaction.objectText,
    }
end

return DoorConfig
