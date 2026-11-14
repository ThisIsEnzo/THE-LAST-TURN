--!strict
-- Runtime greybox anchors for the objective interactions (TTL-09B, slice only). The repository has no Workspace mapping
-- or authored map, so the server builds one small anchored marker part per logical point id when the mission starts and
-- destroys the model when it stops. TTL-10 replaces this with tagged map parts behind the same `pointId -> BasePart`
-- lookup. Placement follows DoorFixture: in front of the first SpawnLocation (same orientation), deeper than the test
-- door and centered in a row; with no SpawnLocation the configured fallback is used. Placement is NOT verified in Studio.

local ObjectiveConfig = require(script.Parent.ObjectiveConfig)

export type Fixture = {
    model: Model,
    anchors: { [string]: BasePart }, -- logical point id -> anchor part
}

local ObjectiveFixture = {}

local function computeFrame(settings: ObjectiveConfig.Config): CFrame
    local fixture = settings.fixture
    local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
    if spawn ~= nil then
        local groundY = spawn.Position.Y - spawn.Size.Y / 2
        local rotation = spawn.CFrame - spawn.CFrame.Position
        local ahead = spawn.CFrame.Position + spawn.CFrame.LookVector * fixture.spawnDistanceStuds
        return CFrame.new(ahead.X, groundY, ahead.Z) * rotation
    end
    return CFrame.new(fixture.fallbackX, fixture.fallbackY, fixture.fallbackZ)
end

-- Raises on failure after destroying everything it created. `pointIds` is the ordered list of anchors to create.
function ObjectiveFixture.build(pointIds: { string }, settings: ObjectiveConfig.Config): Fixture
    local fixture = settings.fixture
    local frame = computeFrame(settings)
    local count = #pointIds

    local model = Instance.new("Model")
    model.Name = "MissionObjectiveAnchors"

    local built, result = pcall(function(): Fixture
        local anchors: { [string]: BasePart } = {}
        for index, pointId in ipairs(pointIds) do
            local offsetX = (index - (count + 1) / 2) * fixture.spacingStuds
            local part = Instance.new("Part")
            part.Name = pointId
            part.Anchored = true
            part.Size = Vector3.new(fixture.anchorSizeStuds, fixture.anchorSizeStuds, fixture.anchorSizeStuds)
            part.CFrame = frame * CFrame.new(offsetX, fixture.heightStuds, 0)
            part.Color = Color3.fromRGB(95, 120, 150)
            part.Material = Enum.Material.SmoothPlastic
            part.TopSurface = Enum.SurfaceType.Smooth
            part.BottomSurface = Enum.SurfaceType.Smooth
            part.Parent = model
            anchors[pointId] = part
        end
        model.Parent = workspace
        return { model = model, anchors = anchors }
    end)
    if not built then
        model:Destroy()
        error(result, 0)
    end
    return result :: Fixture
end

return ObjectiveFixture
