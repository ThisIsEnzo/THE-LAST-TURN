--!strict
-- Objective HUD (TTL-09C): a compact, restrained tracker in the top-left corner (below the Roblox top bar, clear of the
-- thumbstick and action buttons) plus one short transition line. Presentation only: it renders the state that
-- ObjectiveController mirrors from the server, in the server's order, and forwards nothing anywhere. It has no remote,
-- no request and no way to change an objective; the only interaction is a local expand/collapse toggle.
--
-- Collapsed: one line per actionable objective (title and "n/m" progress when more than one contribution is needed;
-- OPTIONAL objectives are dimmed and tagged), at most 3 lines on compact screens and 4 on regular ones, plus "+N more".
-- Expanded (tap the header; no hover anywhere): every objective the server sent, with status, description and the
-- contribution slots. Required objectives are plain, optional ones carry the OPTIONAL tag and a dimmer colour; state is
-- always also written as a word, never colour alone. No large or centered panel, no sound, no per-frame work: the UI is
-- rebuilt only when a snapshot is accepted or the screen size changes, coalesced into one render per frame.
--
-- The panel is hidden until the first valid snapshot and whenever the server sent no objectives. start() is idempotent and
-- destroy() removes the UI and every connection. Visual polish (fonts, icons, motion, audio) is deliberately deferred.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Layout = require(Shared:WaitForChild("UI"):WaitForChild("Layout"))
local Messages = require(Shared:WaitForChild("UI"):WaitForChild("Messages"))
local ObjectiveView = require(Shared:WaitForChild("Objective"):WaitForChild("ObjectiveView"))

-- Same dark industrial palette as the HUB UI (UiKit.Theme). UiKit lives in the HUB client folder, which the MISSION place
-- does not contain; moving it to src/shared is a separate follow-up, not part of this task.
local Theme = {
    panel = Color3.fromRGB(18, 20, 24),
    border = Color3.fromRGB(62, 68, 78),
    text = Color3.fromRGB(226, 230, 234),
    textDim = Color3.fromRGB(148, 156, 166),
    accent = Color3.fromRGB(198, 152, 72),
    danger = Color3.fromRGB(184, 70, 62),
    success = Color3.fromRGB(98, 154, 114),
    info = Color3.fromRGB(116, 152, 182),
}

local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"
local TOAST_SECONDS = 3.5
local MAX_TOAST_LINES = 2
local MARGIN = 10

local ObjectiveHud = {}

local started = false
local screenGui: any = nil
local panel: any = nil
local toastLabel: any = nil
local connections: { RBXScriptConnection } = {}
local unsubscribers: { () -> () } = {}
local controllerRef: any = nil
local expanded = false
local renderQueued = false
local toastToken = 0

local function font(bold: boolean): Font
    if bold then
        return Font.new(FONT_FAMILY, Enum.FontWeight.Bold)
    end
    return Font.new(FONT_FAMILY, Enum.FontWeight.Medium)
end

local function create(className: string, properties: { [string]: any }, children: { Instance }?): any
    local instance = Instance.new(className)
    local parent: any = nil
    for key, value in pairs(properties) do
        if key == "Parent" then
            parent = value
        else
            (instance :: any)[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = instance
    end
    if parent ~= nil then
        instance.Parent = parent
    end
    return instance
end

local function label(parent: Instance, text: string, size: number, color: Color3, bold: boolean, order: number): any
    return create("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextSize = size,
        TextColor3 = color,
        FontFace = font(bold),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        RichText = false,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = order,
        Parent = parent,
    })
end

local function metrics(): (Layout.Metrics, boolean)
    local size = Vector2.new(1280, 720)
    if screenGui ~= nil then
        size = screenGui.AbsoluteSize
    end
    local class = Layout.classify(size.X, size.Y, UserInputService.TouchEnabled)
    return Layout.metrics(class), class == Layout.Compact
end

local function stateColor(entry: any): Color3
    if entry.state == "COMPLETED" then
        return Theme.success
    elseif entry.state == "FAILED" then
        return Theme.danger
    elseif entry.isActionable then
        return Theme.accent
    end
    return Theme.textDim
end

local function titleColor(entry: any): Color3
    if entry.isOptional or entry.isLocked or entry.state == "CANCELLED" then
        return Theme.textDim
    end
    return Theme.text
end

local function progressText(entry: any): string
    if entry.hasProgress then
        return string.format("%d/%d", entry.filled, entry.required)
    end
    return ""
end

-- One collapsed-tracker line: "Title  2/3" or "Title  optional".
local function trackedLine(entry: any): string
    local parts = { entry.title }
    local progress = progressText(entry)
    if progress ~= "" then
        table.insert(parts, progress)
    end
    local tag = Messages.objectiveTag(entry.importance)
    if tag ~= "" then
        table.insert(parts, string.lower(tag))
    end
    return table.concat(parts, "  ")
end

local function renderExpandedEntry(container: Instance, entry: any, order: number, textBody: number, textSmall: number)
    local card = create("Frame", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = order,
        Parent = container,
    }, {
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
    local header = trackedLine(entry)
    label(card, header, textBody, titleColor(entry), true, 1)
    label(card, Messages.objectiveStatus(entry.state), textSmall, stateColor(entry), true, 2)
    if #entry.description > 0 and not entry.isTerminal then
        label(card, entry.description, textSmall, Theme.textDim, false, 3)
    end
    if entry.hasProgress and not entry.isTerminal and not entry.isLocked then
        for index, slot in ipairs(entry.slots) do
            local mark = "[ ] "
            local color = Theme.textDim
            if slot.filled then
                mark = "[x] "
                color = Theme.success
            end
            label(card, mark .. slot.label, textSmall, color, false, 3 + index)
        end
    end
end

local function render()
    renderQueued = false
    if not started or panel == nil or controllerRef == nil then
        return
    end
    for _, child in ipairs(panel:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    local model = controllerRef:getViewModel()
    if not model.synced or #model.entries == 0 then
        panel.Visible = false
        return
    end
    panel.Visible = true

    local m, compact = metrics()
    local maxLines = 4
    if compact then
        maxLines = 3
    end

    -- Header: the only control (a local expand/collapse toggle; 48 px touch target on compact screens).
    local counts = ""
    if model.requiredTotal > 0 then
        counts = string.format("  %d/%d", model.requiredDone, model.requiredTotal)
    end
    local toggle = "[+]"
    if expanded then
        toggle = "[-]"
    end
    local header = create("TextButton", {
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = Messages.ObjectiveHeader .. counts .. "  " .. toggle,
        TextSize = m.textSmall,
        TextColor3 = Theme.textDim,
        FontFace = font(true),
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1, 0, 0, m.buttonHeight),
        LayoutOrder = 1,
        Parent = panel,
    })
    header.Activated:Connect(function()
        expanded = not expanded
        ObjectiveHud.refresh()
    end)

    local body = create("Frame", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = 2,
        Parent = panel,
    }, {
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    if expanded then
        for index, entry in ipairs(model.entries) do
            renderExpandedEntry(body, entry, index, m.textBody, m.textSmall)
        end
    else
        local shown, hidden = ObjectiveView.tracked(model, maxLines)
        for index, entry in ipairs(shown) do
            label(body, trackedLine(entry), m.textBody, titleColor(entry), not entry.isOptional, index)
        end
        if #shown == 0 then
            label(body, Messages.objectiveStatus("COMPLETED"), m.textSmall, Theme.textDim, false, 1)
        end
        local more = Messages.objectiveMore(hidden)
        if more ~= "" then
            label(body, more, m.textSmall, Theme.textDim, false, #shown + 1)
        end
    end
end

local function queueRender()
    if renderQueued or not started then
        return
    end
    renderQueued = true
    task.defer(render)
end

function ObjectiveHud.refresh()
    queueRender()
end

local function toastColor(kind: string): Color3
    if kind == "COMPLETED" then
        return Theme.success
    elseif kind == "FAILED" then
        return Theme.danger
    elseif kind == "UNLOCKED" then
        return Theme.accent
    end
    return Theme.info
end

-- One short line (two at most) that disappears by itself; never takes input and is not a panel.
local function showToast(events: { any })
    if not started or toastLabel == nil then
        return
    end
    local lines: { string } = {}
    local color = Theme.info
    for _, event in ipairs(events) do
        if #lines >= MAX_TOAST_LINES then
            break
        end
        local text = Messages.objectiveEvent(event.kind, event.title)
        if text ~= "" then
            if #lines == 0 then
                color = toastColor(event.kind)
            end
            table.insert(lines, text)
        end
    end
    if #lines == 0 then
        return
    end
    toastToken += 1
    local token = toastToken
    toastLabel.Text = table.concat(lines, "\n")
    toastLabel.TextColor3 = color
    toastLabel.Visible = true
    task.delay(TOAST_SECONDS, function()
        if started and token == toastToken and toastLabel ~= nil then
            toastLabel.Visible = false
        end
    end)
end

-- `controller` is the ObjectiveController (or anything with getViewModel / onChanged / onTransition). Idempotent.
function ObjectiveHud.start(controller: any)
    if started then
        return
    end
    started = true
    controllerRef = controller
    expanded = false

    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
    if playerGui == nil then
        started = false
        controllerRef = nil
        warn("[THE LAST TURN][MISSION] ObjectiveHud: PlayerGui is not available.")
        return
    end

    screenGui = create("ScreenGui", {
        Name = "ObjectiveHud",
        ResetOnSpawn = false,
        IgnoreGuiInset = false, -- start below the Roblox top bar
        DisplayOrder = 5,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = playerGui,
    })

    local column = create("Frame", {
        Name = "Column",
        BackgroundTransparency = 1,
        Position = UDim2.new(0, MARGIN, 0, MARGIN),
        Size = UDim2.new(0, 280, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Parent = screenGui,
    }, {
        create("UISizeConstraint", { MaxSize = Vector2.new(320, math.huge) }),
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    -- A translucent, small panel: it never covers the center of the screen and the world stays visible through it.
    panel = create("Frame", {
        Name = "Panel",
        BackgroundColor3 = Theme.panel,
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        LayoutOrder = 1,
        Parent = column,
    }, {
        create("UICorner", { CornerRadius = UDim.new(0, 8) }),
        create("UIStroke", { Color = Theme.border, Thickness = 1, Transparency = 0.4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
        create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    toastLabel = create("TextLabel", {
        Name = "Toast",
        BackgroundTransparency = 1,
        Text = "",
        TextSize = 15,
        TextColor3 = Theme.info,
        FontFace = font(true),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        Active = false,
        LayoutOrder = 2,
        Parent = column,
    })

    table.insert(connections, screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRender))
    table.insert(unsubscribers, controller:onChanged(queueRender))
    table.insert(unsubscribers, controller:onTransition(showToast))
    queueRender()
end

function ObjectiveHud.destroy()
    started = false
    renderQueued = false
    toastToken += 1
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, unsubscribe in ipairs(unsubscribers) do
        pcall(unsubscribe)
    end
    table.clear(unsubscribers)
    if screenGui ~= nil then
        screenGui:Destroy()
    end
    screenGui = nil
    panel = nil
    toastLabel = nil
    controllerRef = nil
    expanded = false
end

return ObjectiveHud
