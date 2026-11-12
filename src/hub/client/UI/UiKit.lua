--!strict
-- Minimal UI helpers for the HUB client (theme, instance builders, buttons). Not a framework: just the few pieces the
-- party HUD and the mission terminal share. Dark, industrial, restrained accent colours.

local UiKit = {}

UiKit.Theme = {
    background = Color3.fromRGB(14, 16, 19),
    panel = Color3.fromRGB(24, 27, 32),
    panelRaised = Color3.fromRGB(34, 38, 45),
    border = Color3.fromRGB(62, 68, 78),
    text = Color3.fromRGB(226, 230, 234),
    textDim = Color3.fromRGB(148, 156, 166),
    accent = Color3.fromRGB(198, 152, 72),
    accentDark = Color3.fromRGB(88, 68, 34),
    danger = Color3.fromRGB(184, 70, 62),
    success = Color3.fromRGB(98, 154, 114),
    warning = Color3.fromRGB(206, 164, 64),
    info = Color3.fromRGB(116, 152, 182),
    disabled = Color3.fromRGB(46, 50, 58),
}

local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"

function UiKit.font(bold: boolean): Font
    if bold then
        return Font.new(FONT_FAMILY, Enum.FontWeight.Bold)
    end
    return Font.new(FONT_FAMILY, Enum.FontWeight.Medium)
end

-- Creates an Instance, applies properties and children, and parents it last.
function UiKit.create(className: string, properties: { [string]: any }?, children: { Instance }?): any
    local instance = Instance.new(className)
    local parent: any = nil
    for key, value in pairs(properties or {}) do
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

function UiKit.corner(radius: number): Instance
    return UiKit.create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function UiKit.stroke(color: Color3, thickness: number?): Instance
    return UiKit.create("UIStroke", { Color = color, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

function UiKit.padding(pixels: number): Instance
    local pad = UDim.new(0, pixels)
    return UiKit.create("UIPadding", { PaddingTop = pad, PaddingBottom = pad, PaddingLeft = pad, PaddingRight = pad })
end

function UiKit.list(spacing: number, horizontal: boolean?): Instance
    local direction = Enum.FillDirection.Vertical
    if horizontal then
        direction = Enum.FillDirection.Horizontal
    end
    return UiKit.create("UIListLayout", {
        FillDirection = direction,
        Padding = UDim.new(0, spacing),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
end

-- Removes every child except layout helpers (UIListLayout, UIPadding, ...), used before re-rendering a section.
function UiKit.clear(container: Instance)
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
end

function UiKit.label(properties: { [string]: any }): any
    local merged: { [string]: any } = {
        BackgroundTransparency = 1,
        TextColor3 = UiKit.Theme.text,
        FontFace = UiKit.font(false),
        TextSize = 16,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = true,
        RichText = false,
        Size = UDim2.new(1, 0, 0, 20),
    }
    for key, value in pairs(properties) do
        merged[key] = value
    end
    return UiKit.create("TextLabel", merged)
end

local VARIANTS: { [string]: { background: Color3, text: Color3 } } = {
    primary = { background = UiKit.Theme.accent, text = Color3.fromRGB(20, 16, 8) },
    secondary = { background = UiKit.Theme.panelRaised, text = UiKit.Theme.text },
    danger = { background = UiKit.Theme.danger, text = Color3.fromRGB(255, 240, 236) },
    success = { background = UiKit.Theme.success, text = Color3.fromRGB(10, 22, 14) },
}

-- Touch-friendly button. `Activated` covers mouse, touch and gamepad; nothing depends on hover.
function UiKit.button(text: string, variant: string, height: number, textSize: number, onActivated: (() -> ())?): any
    local style = VARIANTS[variant]
    if style == nil then
        style = VARIANTS.secondary
    end
    local button = UiKit.create("TextButton", {
        Text = text,
        AutoButtonColor = true,
        BackgroundColor3 = style.background,
        TextColor3 = style.text,
        FontFace = UiKit.font(true),
        TextSize = textSize,
        Size = UDim2.new(1, 0, 0, height),
        BorderSizePixel = 0,
        TextWrapped = true,
    }, { UiKit.corner(6) })
    if onActivated ~= nil then
        button.Activated:Connect(onActivated)
    end
    return button
end

-- Visually and functionally disables (or re-enables) a button created by UiKit.button.
function UiKit.setButtonEnabled(button: any, enabled: boolean, variant: string)
    local style = VARIANTS[variant]
    if style == nil then
        style = VARIANTS.secondary
    end
    button.Interactable = enabled
    button.AutoButtonColor = enabled
    if enabled then
        button.BackgroundColor3 = style.background
        button.TextColor3 = style.text
    else
        button.BackgroundColor3 = UiKit.Theme.disabled
        button.TextColor3 = UiKit.Theme.textDim
    end
end

function UiKit.toneColor(tone: string): Color3
    if tone == "error" then
        return UiKit.Theme.danger
    elseif tone == "warning" then
        return UiKit.Theme.warning
    elseif tone == "progress" then
        return UiKit.Theme.accent
    end
    return UiKit.Theme.info
end

-- Avatar head shot through a built-in thumbnail URL: no yielding call, no extra request logic.
function UiKit.avatar(userId: number, size: number): any
    return UiKit.create("ImageLabel", {
        BackgroundColor3 = UiKit.Theme.panelRaised,
        BorderSizePixel = 0,
        Size = UDim2.new(0, size, 0, size),
        Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId),
    }, { UiKit.corner(6) })
end

return UiKit
