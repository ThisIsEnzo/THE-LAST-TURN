--!strict
-- Builds the TTL-08C test door at runtime (server only). The repository has no Workspace mapping or place file, so
-- the fixture is created by the server when the mission starts and destroyed when it stops. It is placed in front of
-- the first SpawnLocation of the place (spawnDistanceStuds ahead, same orientation), or at the configured fallback
-- position when there is none; adjust DoorConfig.Values.fixture if that spot is wrong for the place.
--
-- Parts (all Anchored): two pillars, the door panel (the only moving part) and a small invisible interaction anchor
-- in front of the door that never moves, so the prompt position and the server-side distance stay stable while the
-- panel swings. The panel rotates about a hinge on its left edge between a closed and an open CFrame that are both
-- computed once, so both poses are deterministic.

local DoorConfig = require(script.Parent.DoorConfig)

export type Fixture = {
    model: Model,
    panel: BasePart,
    anchor: BasePart,
    closedCFrame: CFrame,
    openCFrame: CFrame,
}

local DoorFixture = {}

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.Size = size
    part.CFrame = cframe
    part.Color = color
    part.Material = material
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    return part
end

local function computeFrame(settings: DoorConfig.FixtureSettings): CFrame
    local halfHeight = settings.panelHeight / 2
    local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
    if spawn ~= nil then
        local groundY = spawn.Position.Y - spawn.Size.Y / 2
        local rotation = spawn.CFrame - spawn.CFrame.Position
        local ahead = spawn.CFrame.Position + spawn.CFrame.LookVector * settings.spawnDistanceStuds
        return CFrame.new(ahead.X, groundY + halfHeight, ahead.Z) * rotation
    end
    return CFrame.new(settings.fallbackX, settings.fallbackY + halfHeight, settings.fallbackZ)
end

-- Raises on failure after destroying everything it created.
function DoorFixture.build(settings: DoorConfig.FixtureSettings): Fixture
    local frame = computeFrame(settings)
    local width = settings.panelWidth
    local height = settings.panelHeight
    local halfHeight = height / 2

    local model = Instance.new("Model")
    model.Name = "MissionTestDoor"

    local built, result = pcall(function(): Fixture
        local pillarOffset = width / 2 + settings.pillarWidth / 2
        local pillarSize = Vector3.new(settings.pillarWidth, height, settings.panelThickness + 1)
        local pillarColor = Color3.fromRGB(110, 110, 115)

        local leftPillar = makePart("LeftPillar", pillarSize, frame * CFrame.new(-pillarOffset, 0, 0), pillarColor, Enum.Material.Concrete)
        local rightPillar = makePart("RightPillar", pillarSize, frame * CFrame.new(pillarOffset, 0, 0), pillarColor, Enum.Material.Concrete)
        local panel = makePart("DoorPanel", Vector3.new(width, height, settings.panelThickness), frame, Color3.fromRGB(110, 80, 55), Enum.Material.Wood)

        -- Stationary invisible interaction point: chest height, in front of the panel (toward the spawn).
        local anchor = makePart("InteractionAnchor", Vector3.new(1, 1, 1), frame * CFrame.new(0, 3 - halfHeight, 2.5), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
        anchor.Transparency = 1
        anchor.CanCollide = false
        anchor.CanTouch = false

        local hinge = frame * CFrame.new(-width / 2, 0, 0)
        local openCFrame = hinge * CFrame.Angles(0, math.rad(settings.openAngleDegrees), 0) * CFrame.new(width / 2, 0, 0)

        leftPillar.Parent = model
        rightPillar.Parent = model
        panel.Parent = model
        anchor.Parent = model
        model.Parent = workspace

        return {
            model = model,
            panel = panel,
            anchor = anchor,
            closedCFrame = frame,
            openCFrame = openCFrame,
        }
    end)
    if not built then
        model:Destroy()
        error(result, 0)
    end
    return result :: Fixture
end

return DoorFixture
