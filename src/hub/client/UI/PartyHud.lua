--!strict
-- Party HUD (TTL-HUB-02): a compact "SQUAD" button, the squad panel (members, leader, kick, leave, invite players),
-- incoming invitations, a launch status banner and short toasts. Presentation only: it renders what PartyController
-- and MissionLaunchController mirror from the server and forwards clicks to them; it decides nothing.
--
-- Rendering is event driven (controller change notifications, a screen size change); the whole UI is rebuilt from the
-- current view model (at most 8 members), coalesced into one render per frame. No per-frame loops. start() is
-- idempotent and destroy() removes the UI and every connection.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Layout = require(Shared:WaitForChild("UI"):WaitForChild("Layout"))
local UiKit = require(script.Parent.UiKit)

local Theme = UiKit.Theme

local PartyHud = {}

local started = false
local screenGui: any = nil
local connections: { RBXScriptConnection } = {}
local unsubscribers: { () -> () } = {}
local party: any = nil
local launch: any = nil
local panelOpen = false
local renderQueued = false
local toastCount = 0

local refs: { [string]: any } = {}

local function metrics(): Layout.Metrics
    local size = Vector2.new(1280, 720)
    if screenGui ~= nil then
        size = screenGui.AbsoluteSize
    end
    return Layout.metrics(Layout.classify(size.X, size.Y, UserInputService.TouchEnabled))
end

local function card(parent: Instance, layoutOrder: number, strokeColor: Color3?): any
    local frame = UiKit.create("Frame", {
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = layoutOrder,
        Parent = parent,
    }, { UiKit.corner(8), UiKit.stroke(strokeColor or Theme.border, 1), UiKit.padding(10), UiKit.list(6) })
    return frame
end

local function textLine(parent: Instance, text: string, size: number, color: Color3, bold: boolean, order: number): any
    return UiKit.label({
        Text = text,
        TextSize = size,
        TextColor3 = color,
        FontFace = UiKit.font(bold),
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = order,
        Parent = parent,
    })
end

-- Sections ------------------------------------------------------------------------------------------------------------

local function buildInviteCards(parent: Instance, vm: any, m: Layout.Metrics, firstOrder: number)
    for index, invite in ipairs(vm.incomingInvites) do
        local box = card(parent, firstOrder + index, Theme.accent)
        textLine(box, string.upper(invite.displayName) .. " INVITES YOU TO THEIR SQUAD", m.textBody, Theme.text, true, 1)
        local detail = "Join their squad for the next mission."
        if invite.state == "expired" then
            detail = "This invitation has expired."
        elseif invite.state == "responding" then
            detail = "Answering..."
        elseif invite.secondsRemaining ~= nil then
            detail = string.format("Expires in %d s.", math.ceil(invite.secondsRemaining))
        end
        textLine(box, detail, m.textSmall, Theme.textDim, false, 2)
        local row = UiKit.create("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, m.buttonHeight),
            LayoutOrder = 3,
            Parent = box,
        }, { UiKit.list(8, true) })
        local usable = invite.state == "pending"
        local accept = UiKit.button("ACCEPT", "success", m.buttonHeight, m.textBody, function()
            party.respond(invite.inviterUserId, true)
        end)
        accept.Size = UDim2.new(0.5, -4, 1, 0)
        accept.Parent = row
        UiKit.setButtonEnabled(accept, usable, "success")
        local decline = UiKit.button("DECLINE", "secondary", m.buttonHeight, m.textBody, function()
            party.respond(invite.inviterUserId, false)
        end)
        decline.Size = UDim2.new(0.5, -4, 1, 0)
        decline.Parent = row
        UiKit.setButtonEnabled(decline, usable, "secondary")
    end
end

local function buildLaunchCard(parent: Instance, launchView: any, m: Layout.Metrics, order: number)
    if launchView == nil or launchView.phase == "idle" then
        return
    end
    local tone = UiKit.toneColor(launchView.tone)
    local box = card(parent, order, tone)
    textLine(box, launchView.title, m.textBody, tone, true, 1)
    local text = launchView.text
    if launchView.subjectUserId ~= nil then
        local player = Players:GetPlayerByUserId(launchView.subjectUserId)
        if player ~= nil then
            text = player.DisplayName .. ": " .. text
        end
    end
    textLine(box, text, m.textSmall, Theme.text, false, 2)
end

local function buildMemberRow(parent: Instance, member: any, m: Layout.Metrics, order: number)
    local rowHeight = math.max(52, m.buttonHeight + 8)
    local row = UiKit.create("Frame", {
        BackgroundColor3 = Theme.panelRaised,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, rowHeight),
        LayoutOrder = order,
        Parent = parent,
    }, { UiKit.corner(6), UiKit.padding(6) })
    local avatar = UiKit.avatar(member.userId, rowHeight - 12)
    avatar.Parent = row

    local tag = "OPERATOR"
    local tagColor = Theme.textDim
    if member.isLeader then
        tag = "LEADER"
        tagColor = Theme.accent
    end
    if member.isLocal then
        tag = tag .. "  -  YOU"
    end
    local textWidth = -(rowHeight - 12 + 10)
    if member.canKick then
        textWidth = textWidth - 78
    end
    local info = UiKit.create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, rowHeight - 12 + 10, 0, 0),
        Size = UDim2.new(1, textWidth, 1, 0),
    }, { UiKit.list(0) })
    info.Parent = row
    textLine(info, member.displayName, m.textBody, Theme.text, true, 1).Size = UDim2.new(1, 0, 0, m.textBody + 4)
    textLine(info, tag, m.textSmall - 2, tagColor, true, 2).Size = UDim2.new(1, 0, 0, m.textSmall)

    if member.canKick then
        local kick = UiKit.button("KICK", "danger", rowHeight - 12, m.textSmall, function()
            party.kick(member.userId)
        end)
        kick.AnchorPoint = Vector2.new(1, 0)
        kick.Position = UDim2.new(1, 0, 0, 0)
        kick.Size = UDim2.new(0, 70, 1, 0)
        kick.Parent = row
    end
end

local function buildInviteList(parent: Instance, m: Layout.Metrics, order: number)
    local candidates = party.getCandidates()
    local box = card(parent, order, Theme.border)
    textLine(box, "INVITE PLAYERS", m.textSmall, Theme.accent, true, 1)
    local shown = 0
    for index, candidate in ipairs(candidates) do
        if candidate.state ~= "member" then
            shown += 1
            local row = UiKit.create("Frame", {
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, m.buttonHeight),
                LayoutOrder = 10 + index,
                Parent = box,
            })
            UiKit.label({
                Text = candidate.displayName,
                TextSize = m.textBody,
                Size = UDim2.new(1, -96, 1, 0),
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = row,
            })
            local label, variant, enabled = "INVITE", "primary", true
            if candidate.state == "invited" then
                label, variant, enabled = "INVITED", "secondary", false
            elseif candidate.state == "blocked_full" then
                label, variant, enabled = "FULL", "secondary", false
            elseif candidate.state == "busy" then
                label, variant, enabled = "...", "secondary", false
            end
            local button = UiKit.button(label, variant, m.buttonHeight - 4, m.textSmall, function()
                party.invite(candidate.userId)
            end)
            button.AnchorPoint = Vector2.new(1, 0.5)
            button.Position = UDim2.new(1, 0, 0.5, 0)
            button.Size = UDim2.new(0, 90, 0, m.buttonHeight - 4)
            button.Parent = row
            UiKit.setButtonEnabled(button, enabled, variant)
        end
    end
    if shown == 0 then
        textLine(box, "No other players in the facility.", m.textSmall, Theme.textDim, false, 2)
    end
end

local function buildPanel(content: Instance, vm: any, launchView: any, m: Layout.Metrics)
    local order = 0
    local function nextOrder(): number
        order += 10
        return order
    end
    -- Header.
    local header = card(content, nextOrder(), Theme.border)
    textLine(header, "SQUAD", m.textTitle, Theme.text, true, 1)
    textLine(header, string.format("%d / %d operators", vm.size, vm.maxSize), m.textSmall, Theme.textDim, false, 2)

    -- While the panel covers the top of the screen, invitations and the launch status are shown here.
    buildInviteCards(content, vm, m, nextOrder())
    order += #vm.incomingInvites + 1
    buildLaunchCard(content, launchView, m, nextOrder())

    for index, member in ipairs(vm.members) do
        buildMemberRow(content, member, m, nextOrder() + index)
    end
    order += #vm.members + 1

    if not vm.localIsLeader and vm.hasParty then
        local note = card(content, nextOrder(), Theme.border)
        textLine(note, "Only the squad leader can invite players, remove members and start the mission.", m.textSmall, Theme.textDim, false, 1)
    end
    if vm.canLeave then
        local leave = UiKit.button("LEAVE SQUAD", "secondary", m.buttonHeight, m.textBody, function()
            party.leave()
        end)
        leave.LayoutOrder = nextOrder()
        leave.Parent = content
    end
    if vm.canInvite then
        buildInviteList(content, m, nextOrder())
    end
end

-- Rendering ---------------------------------------------------------------------------------------------------------

local function render()
    renderQueued = false
    if not started or screenGui == nil then
        return
    end
    local vm = party.getViewModel()
    local launchView = launch.getView()
    if vm == nil then
        return
    end
    local m = metrics()

    -- Toggle button.
    local label = string.format("SQUAD %d/%d", vm.size, vm.maxSize)
    if vm.localIsLeader then
        label = "LEADER  " .. label
    end
    if #vm.incomingInvites > 0 then
        label = label .. "  (!)"
    end
    local toggle = refs.toggle
    toggle.Text = label
    toggle.Size = UDim2.new(0, 190, 0, m.buttonHeight)
    toggle.Position = UDim2.new(0, m.padding, 0, m.padding)
    toggle.TextSize = m.textSmall
    if #vm.incomingInvites > 0 then
        toggle.BackgroundColor3 = Theme.accentDark
    else
        toggle.BackgroundColor3 = Theme.panelRaised
    end

    -- Panel.
    local panel = refs.panel
    panel.Visible = panelOpen
    refs.panelSize.MaxSize = Vector2.new(m.maxPanelWidth, 100000)
    panel.Size = UDim2.new(m.panelWidthScale, 0, 0.72, 0)
    panel.Position = UDim2.new(0, m.padding, 0, m.padding * 2 + m.buttonHeight)
    UiKit.clear(refs.panelContent)
    if panelOpen then
        buildPanel(refs.panelContent, vm, launchView, m)
    end

    -- Status stack (top centre): invitations and launch status while the panel is closed.
    local stack = refs.stack
    stack.Position = UDim2.new(0.5, 0, 0, m.padding * 2 + m.buttonHeight)
    refs.stackSize.MaxSize = Vector2.new(m.maxPanelWidth, 100000)
    UiKit.clear(stack)
    if not panelOpen then
        buildInviteCards(stack, vm, m, 0)
        buildLaunchCard(stack, launchView, m, 100)
    end
    stack.Visible = not panelOpen

    refs.toasts.Position = UDim2.new(0.5, 0, 0, m.padding * 2 + m.buttonHeight + 4)
end

local function queueRender()
    if renderQueued or not started then
        return
    end
    renderQueued = true
    task.defer(render)
end

-- Toasts ---------------------------------------------------------------------------------------------------------------

local function showToast(notice: { tone: string, text: string })
    if not started or refs.toasts == nil then
        return
    end
    local m = metrics()
    if toastCount >= 4 then
        local oldest = refs.toasts:FindFirstChildWhichIsA("Frame")
        if oldest ~= nil then
            oldest:Destroy()
            toastCount -= 1
        end
    end
    toastCount += 1
    local toast = UiKit.create("Frame", {
        BackgroundColor3 = Theme.panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Parent = refs.toasts,
    }, { UiKit.corner(6), UiKit.stroke(UiKit.toneColor(notice.tone), 1), UiKit.padding(8) })
    textLine(toast, notice.text, m.textSmall, Theme.text, false, 1)
    task.delay(4, function()
        if toast.Parent ~= nil then
            toast:Destroy()
            toastCount = math.max(0, toastCount - 1)
        end
    end)
end

-- Lifecycle -----------------------------------------------------------------------------------------------------------

-- `partyController` and `launchController` are the two controllers; both must already be started.
function PartyHud.start(partyController: any, launchController: any)
    if started then
        return
    end
    started = true
    party = partyController
    launch = launchController

    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    screenGui = UiKit.create("ScreenGui", {
        Name = "HubPartyUi",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 5,
        ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
        Parent = playerGui,
    })

    refs.toggle = UiKit.button("SQUAD", "secondary", 40, 14, function()
        panelOpen = not panelOpen
        queueRender()
    end)
    refs.toggle.AnchorPoint = Vector2.new(0, 0)
    refs.toggle.Parent = screenGui
    UiKit.create("UIStroke", { Color = Theme.border, Thickness = 1, Parent = refs.toggle })

    refs.panelSize = UiKit.create("UISizeConstraint", { MaxSize = Vector2.new(420, 100000) })
    refs.panelContent = UiKit.create("ScrollingFrame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, 0),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, { UiKit.list(8), UiKit.padding(8) })
    refs.panel = UiKit.create("Frame", {
        Name = "SquadPanel",
        BackgroundColor3 = Theme.background,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 20,
        Parent = screenGui,
    }, { UiKit.corner(8), UiKit.stroke(Theme.border, 1), refs.panelSize, refs.panelContent })

    refs.stackSize = UiKit.create("UISizeConstraint", { MaxSize = Vector2.new(420, 100000) })
    refs.stack = UiKit.create("Frame", {
        Name = "StatusStack",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0),
        Size = UDim2.new(0.9, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Parent = screenGui,
    }, { UiKit.list(8), refs.stackSize })

    refs.toasts = UiKit.create("Frame", {
        Name = "Toasts",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0),
        Size = UDim2.new(0.9, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = 30,
        Parent = screenGui,
    }, { UiKit.list(6), UiKit.create("UISizeConstraint", { MaxSize = Vector2.new(420, 100000) }) })

    table.insert(connections, screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRender))
    table.insert(unsubscribers, party.onChanged(queueRender))
    table.insert(unsubscribers, launch.onChanged(queueRender))
    table.insert(unsubscribers, party.onNotice(showToast))
    queueRender()
end

function PartyHud.destroy()
    started = false
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, unsubscribe in ipairs(unsubscribers) do
        unsubscribe()
    end
    table.clear(unsubscribers)
    if screenGui ~= nil then
        screenGui:Destroy()
        screenGui = nil
    end
    table.clear(refs)
    party = nil
    launch = nil
    panelOpen = false
    renderQueued = false
    toastCount = 0
end

return PartyHud
