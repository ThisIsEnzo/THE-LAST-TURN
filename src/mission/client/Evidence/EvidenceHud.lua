--!strict
-- Evidence HUD UI port (TTL-11C): the Roblox half of the evidence presentation. EvidencePresenter (pure) decides WHAT to show
-- and calls the four functions below; this module only draws it. It has no remote, no request and no state of its own beyond
-- its instances: it cannot discover, confirm or change evidence.
--
-- Layout: a small translucent pill at the top centre ("EVIDENCE 2 / 4", just the count when the server sent no total) below
-- the Roblox top bar, an optional journal that drops down from it (only discovered evidence: title, category, status and, for
-- multi-sighting evidence, "1 of 2 sightings"; a single "Nothing found yet." line when empty, never a placeholder row), and one
-- short transition line. Nothing covers the centre of the screen; the journal is at most 40 percent of the screen height and
-- scrolls. State is always also written as a word, never colour alone.
--
-- Controls: tap or click the pill, or press J (not used by any existing binding; the interaction key is E). The key is bound
-- through ContextActionService only while the HUD exists and only reacts to the key press, so it never captures other input or
-- text entry. destroy() unbinds it and removes the ScreenGui. The ScreenGui has ResetOnSpawn = false and nothing here listens to
-- characters, so a respawn neither duplicates nor drops the HUD.
-- Placement, sizes and colours are unverified on real devices (Studio checklist in docs/TTL-11C_EVIDENCE_HUD.md).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Layout = require(Shared:WaitForChild("UI"):WaitForChild("Layout"))

-- Same dark industrial palette as the other HUDs (UiKit.Theme lives in the HUB client folder, which the MISSION place does not
-- contain; consolidating it into src/shared is a separate follow-up).
local Theme = {
    panel = Color3.fromRGB(18, 20, 24),
    border = Color3.fromRGB(62, 68, 78),
    text = Color3.fromRGB(226, 230, 234),
    textDim = Color3.fromRGB(148, 156, 166),
    accent = Color3.fromRGB(198, 152, 72),
    success = Color3.fromRGB(98, 154, 114),
    info = Color3.fromRGB(116, 152, 182),
}

local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"
local TOAST_SECONDS = 3.5
local ACTION_NAME = "EvidenceJournalToggle"
local TOGGLE_KEY = Enum.KeyCode.J

export type Handle = {
    gui: ScreenGui,
    pill: TextButton,
    journal: Frame,
    list: ScrollingFrame,
    title: TextLabel,
    closeButton: TextButton,
    toast: TextLabel,
    connections: { RBXScriptConnection },
    toastToken: number,
    destroyed: boolean,
}

local EvidenceHud = {}

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

local function metrics(gui: ScreenGui): (Layout.Metrics, Vector2)
    local size = gui.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then
        size = Vector2.new(1280, 720)
    end
    return Layout.metrics(Layout.classify(size.X, size.Y, UserInputService.TouchEnabled)), size
end

-- UI port -------------------------------------------------------------------------------------------------------------

-- `callbacks` = { toggle, close } (from EvidencePresenter). Returns the handle the presenter passes back to the other calls.
function EvidenceHud.create(callbacks: { [string]: () -> () }): Handle
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
    if playerGui == nil then
        error("PlayerGui is not available")
    end

    local gui = create("ScreenGui", {
        Name = "EvidenceHud",
        ResetOnSpawn = false,
        IgnoreGuiInset = false, -- start below the Roblox top bar
        DisplayOrder = 4,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = playerGui,
    })

    local column = create("Frame", {
        Name = "Column",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 8),
        Size = UDim2.new(0, 320, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Parent = gui,
    }, {
        create("UISizeConstraint", { MaxSize = Vector2.new(340, math.huge) }),
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })

    local pill = create("TextButton", {
        Name = "Counter",
        AutoButtonColor = false,
        BackgroundColor3 = Theme.panel,
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
        Text = "",
        TextSize = 14,
        TextColor3 = Theme.text,
        FontFace = font(true),
        AutomaticSize = Enum.AutomaticSize.X,
        Size = UDim2.new(0, 0, 0, 36),
        Visible = false,
        LayoutOrder = 1,
        Parent = column,
    }, {
        create("UICorner", { CornerRadius = UDim.new(0, 8) }),
        create("UIStroke", { Color = Theme.border, Thickness = 1, Transparency = 0.4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
        create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }),
    })

    local journal = create("Frame", {
        Name = "Journal",
        BackgroundColor3 = Theme.panel,
        BackgroundTransparency = 0.2,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        LayoutOrder = 2,
        Parent = column,
    }, {
        create("UICorner", { CornerRadius = UDim.new(0, 8) }),
        create("UIStroke", { Color = Theme.border, Thickness = 1, Transparency = 0.4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
        create("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local title = label(journal, "", 14, Theme.textDim, true, 1)
    local list = create("ScrollingFrame", {
        Name = "Entries",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 160),
        LayoutOrder = 2,
        Parent = journal,
    }, {
        create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
    local closeButton = create("TextButton", {
        Name = "Close",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        Text = "CLOSE",
        TextSize = 14,
        TextColor3 = Theme.textDim,
        FontFace = font(true),
        Size = UDim2.new(1, 0, 0, 36),
        LayoutOrder = 3,
        Parent = journal,
    })

    local toast = create("TextLabel", {
        Name = "Toast",
        BackgroundTransparency = 1,
        Text = "",
        TextSize = 15,
        TextColor3 = Theme.info,
        FontFace = font(true),
        TextWrapped = true,
        AutomaticSize = Enum.AutomaticSize.Y,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        Active = false,
        LayoutOrder = 3,
        Parent = column,
    })

    local connections: { RBXScriptConnection } = {}
    table.insert(connections, pill.Activated:Connect(callbacks.toggle))
    table.insert(connections, closeButton.Activated:Connect(callbacks.close))

    -- J toggles the journal. Only the key press is handled (and sunk); everything else passes through untouched, and
    -- ContextActionService does not deliver keys while a text box has focus.
    ContextActionService:BindAction(ACTION_NAME, function(_name: string, inputState: Enum.UserInputState)
        if inputState == Enum.UserInputState.Begin then
            callbacks.toggle()
            return Enum.ContextActionResult.Sink
        end
        return Enum.ContextActionResult.Pass
    end, false, TOGGLE_KEY)

    return { gui = gui, pill = pill, journal = journal, list = list, title = title, closeButton = closeButton, toast = toast, connections = connections, toastToken = 0, destroyed = false }
end

-- `state` is an EvidencePresenter RenderState.
function EvidenceHud.render(handle: Handle, state: any)
    if handle.destroyed then
        return
    end
    local m, screen = metrics(handle.gui)
    handle.pill.Visible = state.visible
    handle.pill.Text = state.counter
    handle.pill.TextSize = m.textSmall
    handle.pill.Size = UDim2.new(0, 0, 0, m.buttonHeight - 8)

    handle.journal.Visible = state.visible and state.journalOpen
    handle.title.Text = state.journalTitle
    handle.title.TextSize = m.textSmall
    handle.closeButton.Size = UDim2.new(1, 0, 0, m.buttonHeight - 8)
    handle.list.Size = UDim2.new(1, 0, 0, math.floor(math.min(0.4 * screen.Y, 40 + 64 * math.max(#state.entries, 1))))

    for _, child in ipairs(handle.list:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    if not state.journalOpen then
        return
    end
    if #state.entries == 0 then
        label(handle.list, state.emptyText, m.textBody, Theme.textDim, false, 1)
        return
    end
    for index, entry in ipairs(state.entries) do
        local card = create("Frame", {
            BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y,
            Size = UDim2.new(1, -8, 0, 0),
            LayoutOrder = index,
            Parent = handle.list,
        }, {
            create("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
        })
        label(card, entry.title, m.textBody, Theme.text, true, 1)
        local statusColor = Theme.accent
        if entry.isConfirmed then
            statusColor = Theme.success
        end
        label(card, entry.category .. "  -  " .. entry.status, m.textSmall, statusColor, true, 2)
        if entry.progress ~= "" then
            label(card, entry.progress, m.textSmall, Theme.textDim, false, 3)
        end
    end
end

-- `toast` = { kind, lines }: one short line (two at most) that disappears by itself; never takes input.
function EvidenceHud.toast(handle: Handle, toast: any)
    if handle.destroyed then
        return
    end
    handle.toastToken += 1
    local token = handle.toastToken
    handle.toast.Text = table.concat(toast.lines, "\n")
    if toast.kind == "CONFIRMED" then
        handle.toast.TextColor3 = Theme.success
    else
        handle.toast.TextColor3 = Theme.accent
    end
    handle.toast.Visible = true
    task.delay(TOAST_SECONDS, function()
        if not handle.destroyed and token == handle.toastToken then
            handle.toast.Visible = false
        end
    end)
end

function EvidenceHud.destroy(handle: Handle)
    if handle.destroyed then
        return
    end
    handle.destroyed = true
    handle.toastToken += 1
    ContextActionService:UnbindAction(ACTION_NAME)
    for _, connection in ipairs(handle.connections) do
        connection:Disconnect()
    end
    table.clear(handle.connections)
    handle.gui:Destroy()
end

return EvidenceHud
