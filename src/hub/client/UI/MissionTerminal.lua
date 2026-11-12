--!strict
-- Mission Terminal (TTL-HUB-02): the in-world mission preparation station. A CLIENT-SIDE ProximityPrompt on the blank
-- board of the Mission Preparation room (HubEnvironment.MissionPreparation.Furniture.BoardScreen, TTL-HUB-01) opens a
-- terminal panel showing THE ASYLUM, the squad and the launch status, with a Start button for the squad leader. The
-- board's own display text is also updated locally ("THE ASYLUM / SQUAD n/8 / status").
--
-- Presentation only. The prompt only opens a panel on THIS client (no server involvement, no gameplay effect). The
-- launch itself is MissionLaunchController.requestLaunch(): the existing payload-less MissionLaunch request; whether it is
-- allowed (leader, party valid, mission configured) is decided by the server. Only one mission exists in this task:
-- there is no mission selection and the mission type stays server-side.
--
-- start() is idempotent and destroy() removes the UI, the prompt and every connection.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Config"):WaitForChild("Constants"))
local Layout = require(Shared:WaitForChild("UI"):WaitForChild("Layout"))
local UiKit = require(script.Parent.UiKit)

local Theme = UiKit.Theme
local LOG_PREFIX = "[THE LAST TURN][MissionTerminal]"

local MISSION = {
    title = "THE ASYLUM",
    tag = "CLASSIFIED INVESTIGATION",
    description = "Abandoned. Sealed. Still occupied. Something inside keeps the lights burning and the doors closed. "
        .. "Your squad has one task: go in, find out why, and come back.",
}

local MissionTerminal = {}

local started = false
local screenGui: any = nil
local prompt: any = nil
local boardLabel: any = nil
local connections: { RBXScriptConnection } = {}
local unsubscribers: { () -> () } = {}
local party: any = nil
local launch: any = nil
local isOpen = false
local renderQueued = false
local refs: { [string]: any } = {}

local function metrics(): Layout.Metrics
    local size = Vector2.new(1280, 720)
    if screenGui ~= nil then
        size = screenGui.AbsoluteSize
    end
    return Layout.metrics(Layout.classify(size.X, size.Y, UserInputService.TouchEnabled))
end

local function text(parent: Instance, content: string, size: number, color: Color3, bold: boolean, order: number): any
    return UiKit.label({
        Text = content,
        TextSize = size,
        TextColor3 = color,
        FontFace = UiKit.font(bold),
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = order,
        Parent = parent,
    })
end

local function section(parent: Instance, order: number, strokeColor: Color3?): any
    return UiKit.create("Frame", {
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = order,
        Parent = parent,
    }, { UiKit.corner(8), UiKit.stroke(strokeColor or Theme.border, 1), UiKit.padding(12), UiKit.list(8) })
end

local function infoRow(parent: Instance, name: string, value: string, valueColor: Color3, m: Layout.Metrics, order: number)
    local row = UiKit.create("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, m.textBody + 6),
        LayoutOrder = order,
        Parent = parent,
    })
    UiKit.label({ Text = name, TextSize = m.textSmall, TextColor3 = Theme.textDim, Size = UDim2.new(0.5, 0, 1, 0), Parent = row })
    UiKit.label({
        Text = value,
        TextSize = m.textBody,
        TextColor3 = valueColor,
        FontFace = UiKit.font(true),
        TextXAlignment = Enum.TextXAlignment.Right,
        Size = UDim2.new(0.5, 0, 1, 0),
        Position = UDim2.new(0.5, 0, 0, 0),
        Parent = row,
    })
end

local function memberRow(parent: Instance, member: any, m: Layout.Metrics, order: number)
    local rowHeight = math.max(48, m.buttonHeight)
    local row = UiKit.create("Frame", {
        BackgroundColor3 = Theme.panelRaised,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, rowHeight),
        LayoutOrder = order,
        Parent = parent,
    }, { UiKit.corner(6), UiKit.padding(6) })
    UiKit.avatar(member.userId, rowHeight - 12).Parent = row
    local tag = "OPERATOR"
    local tagColor = Theme.textDim
    if member.isLeader then
        tag = "LEADER"
        tagColor = Theme.accent
    end
    if member.isLocal then
        tag = tag .. "  -  YOU"
    end
    local info = UiKit.create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, rowHeight - 12 + 10, 0, 0),
        Size = UDim2.new(1, -(rowHeight - 12 + 10), 1, 0),
    }, { UiKit.list(0) })
    info.Parent = row
    UiKit.label({ Text = member.displayName, TextSize = m.textBody, FontFace = UiKit.font(true), Size = UDim2.new(1, 0, 0, m.textBody + 4), LayoutOrder = 1, Parent = info })
    UiKit.label({ Text = tag, TextSize = m.textSmall - 2, TextColor3 = tagColor, FontFace = UiKit.font(true), Size = UDim2.new(1, 0, 0, m.textSmall), LayoutOrder = 2, Parent = info })
end

-- The Start button's text/state, derived from the server-mirrored state (the server decides whether a launch happens).
local function startButtonState(vm: any, launchView: any): (string, boolean)
    if launchView.busy then
        return "DEPLOYING...", false
    end
    if not vm.localIsLeader then
        return "WAITING FOR LEADER", false
    end
    local label = "START MISSION"
    if launchView.phase == "failed" or launchView.phase == "rejected" then
        label = "TRY AGAIN"
    end
    return label, launch.canRequest()
end

local function updateBoard(vm: any, launchView: any)
    if boardLabel == nil or boardLabel.Parent == nil or vm == nil then
        return
    end
    local status = "READY"
    if launchView.busy then
        status = "DEPLOYING"
    elseif launchView.mission == "unavailable" then
        status = "UNAVAILABLE"
    end
    boardLabel.Text = string.format("THE ASYLUM\nSQUAD %d/%d  -  %s", vm.size, vm.maxSize, status)
end

local function render()
    renderQueued = false
    if not started or screenGui == nil then
        return
    end
    local vm = party.getViewModel()
    local launchView = launch.getView()
    if vm == nil or launchView == nil then
        return
    end
    updateBoard(vm, launchView)
    screenGui.Enabled = isOpen
    if not isOpen then
        return
    end

    local m = metrics()
    local panel = refs.panel
    local widthScale = 0.5
    if m.panelWidthScale >= 0.9 then
        widthScale = 0.96 -- compact screens: almost the full width
    end
    panel.Size = UDim2.new(widthScale, 0, 0.88, 0)
    refs.panelSize.MaxSize = Vector2.new(620, 100000)

    local content = refs.content
    UiKit.clear(content)

    -- Mission card.
    local mission = section(content, 10, Theme.accentDark)
    text(mission, MISSION.tag, m.textSmall - 1, Theme.accent, true, 1)
    text(mission, MISSION.title, m.textTitle + 6, Theme.text, true, 2)
    text(mission, MISSION.description, m.textBody, Theme.textDim, false, 3)
    local availability = "READY FOR DEPLOYMENT"
    local availabilityColor = Theme.success
    if launchView.mission == "unavailable" then
        availability = "UNAVAILABLE"
        availabilityColor = Theme.danger
    end
    infoRow(mission, "OPERATORS", string.format("%d / %d", vm.size, Constants.Experience.MaxPartySize), Theme.text, m, 4)
    infoRow(mission, "STATUS", availability, availabilityColor, m, 5)

    -- Squad.
    local squad = section(content, 20, Theme.border)
    text(squad, "SQUAD", m.textSmall, Theme.accent, true, 1)
    for index, member in ipairs(vm.members) do
        memberRow(squad, member, m, 1 + index)
    end
    if vm.hasParty and vm.size == 1 then
        text(squad, "You are deploying alone. Invite players from the SQUAD button to bring a team.", m.textSmall, Theme.textDim, false, 20)
    end

    -- Launch status or a hint.
    local status = section(content, 30, Theme.border)
    if launchView.phase ~= "idle" then
        local tone = UiKit.toneColor(launchView.tone)
        UiKit.create("UIStroke", { Color = tone, Thickness = 1, Parent = status })
        text(status, launchView.title, m.textBody, tone, true, 1)
        local body = launchView.text
        if launchView.subjectUserId ~= nil then
            local player = Players:GetPlayerByUserId(launchView.subjectUserId)
            if player ~= nil then
                body = player.DisplayName .. ": " .. body
            end
        end
        text(status, body, m.textSmall, Theme.text, false, 2)
    elseif vm.localIsLeader then
        text(status, "You are the squad leader. Start the mission when your squad is ready.", m.textSmall, Theme.textDim, false, 1)
    else
        text(status, "Only the squad leader can start the mission. Wait for the leader.", m.textSmall, Theme.textDim, false, 1)
    end

    -- Footer buttons (always visible; the content above scrolls on small screens).
    local label, enabled = startButtonState(vm, launchView)
    local start = refs.startButton
    start.Text = label
    start.TextSize = m.textBody
    UiKit.setButtonEnabled(start, enabled, "primary")
    refs.footer.Size = UDim2.new(1, 0, 0, m.buttonHeight + 24)
    refs.content.Size = UDim2.new(1, 0, 1, -(m.buttonHeight + 24))
    refs.closeButton.TextSize = m.textBody
end

local function queueRender()
    if renderQueued or not started then
        return
    end
    renderQueued = true
    task.defer(render)
end

local function setOpen(open: boolean)
    isOpen = open
    queueRender()
end

-- World integration --------------------------------------------------------------------------------------------------

-- The board exists only if the HUB greybox is loaded; wait for it without blocking the rest of the UI.
local function attachToBoard()
    local environment = workspace:WaitForChild("HubEnvironment", 30)
    local preparation = environment and environment:WaitForChild("MissionPreparation", 30)
    local furniture = preparation and preparation:WaitForChild("Furniture", 30)
    local board = furniture and furniture:WaitForChild("BoardScreen", 30)
    if board == nil or not started then
        if started then
            warn(string.format("%s HubEnvironment.MissionPreparation.Furniture.BoardScreen not found: the terminal cannot be opened.", LOG_PREFIX))
        end
        return
    end

    local display = board:FindFirstChild("Display")
    local label = display and display:FindFirstChild("Text")
    if label ~= nil and label:IsA("TextLabel") then
        boardLabel = label
    end

    -- Created on this client only: it exists for the local player and nobody else.
    prompt = UiKit.create("ProximityPrompt", {
        Name = "MissionTerminalPrompt",
        ActionText = "Open mission terminal",
        ObjectText = "THE ASYLUM",
        HoldDuration = 0,
        MaxActivationDistance = 22,
        RequiresLineOfSight = false,
        ClickablePrompt = true,
        KeyboardKeyCode = Enum.KeyCode.E,
        GamepadKeyCode = Enum.KeyCode.ButtonX,
        Parent = board,
    })
    table.insert(connections, prompt.Triggered:Connect(function()
        setOpen(true)
    end))
    queueRender()
end

-- Lifecycle ---------------------------------------------------------------------------------------------------------

function MissionTerminal.start(partyController: any, launchController: any)
    if started then
        return
    end
    started = true
    party = partyController
    launch = launchController

    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    screenGui = UiKit.create("ScreenGui", {
        Name = "MissionTerminal",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 8,
        ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
        Enabled = false,
        Parent = playerGui,
    })

    local dim = UiKit.create("Frame", {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.45,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, 0),
        Active = true,
        Parent = screenGui,
    })
    refs.dim = dim

    refs.panelSize = UiKit.create("UISizeConstraint", { MaxSize = Vector2.new(620, 100000) })
    refs.content = UiKit.create("ScrollingFrame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, -64),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, { UiKit.list(10), UiKit.padding(10) })

    refs.startButton = UiKit.button("START MISSION", "primary", 44, 16, function()
        launch.requestLaunch()
    end)
    refs.startButton.Size = UDim2.new(0.62, -6, 1, 0)
    refs.closeButton = UiKit.button("CLOSE", "secondary", 44, 16, function()
        setOpen(false)
    end)
    refs.closeButton.Size = UDim2.new(0.38, -6, 1, 0)
    refs.footer = UiKit.create("Frame", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, 64),
    }, { UiKit.padding(10), UiKit.list(12, true) })
    refs.startButton.Parent = refs.footer
    refs.closeButton.Parent = refs.footer

    refs.panel = UiKit.create("Frame", {
        Name = "TerminalPanel",
        BackgroundColor3 = Theme.background,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0.62, 0, 0.88, 0),
        Parent = screenGui,
    }, { UiKit.corner(10), UiKit.stroke(Theme.accentDark, 2), refs.panelSize, refs.content, refs.footer })

    table.insert(connections, screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRender))
    table.insert(unsubscribers, party.onChanged(queueRender))
    table.insert(unsubscribers, launch.onChanged(queueRender))
    task.spawn(attachToBoard)
    queueRender()
end

function MissionTerminal.destroy()
    started = false
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, unsubscribe in ipairs(unsubscribers) do
        unsubscribe()
    end
    table.clear(unsubscribers)
    if prompt ~= nil then
        prompt:Destroy()
        prompt = nil
    end
    if screenGui ~= nil then
        screenGui:Destroy()
        screenGui = nil
    end
    boardLabel = nil
    table.clear(refs)
    party = nil
    launch = nil
    isOpen = false
    renderQueued = false
end

return MissionTerminal
