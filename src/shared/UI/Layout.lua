--!strict
-- Responsive layout classes for the HUB UI (pure, Lune-tested). The UI uses scale-based sizes plus these few metrics.

local Layout = {}

export type Metrics = {
    buttonHeight: number, -- pixels; compact uses larger touch targets
    textSmall: number,
    textBody: number,
    textTitle: number,
    padding: number,
    panelWidthScale: number, -- fraction of the screen width
    maxPanelWidth: number, -- pixels
}

Layout.Compact = "compact"
Layout.Regular = "regular"

-- Compact for phones and small windows: narrow or short viewports. Touch devices with a small short side also count.
function Layout.classify(width: any, height: any, isTouch: any): string
    if type(width) ~= "number" or type(height) ~= "number" or width ~= width or height ~= height or width <= 0 or height <= 0 then
        return Layout.Regular
    end
    if width < 720 or height < 480 then
        return Layout.Compact
    end
    if isTouch == true and math.min(width, height) < 600 then
        return Layout.Compact
    end
    return Layout.Regular
end

local COMPACT: Metrics = table.freeze({
    buttonHeight = 48,
    textSmall = 14,
    textBody = 16,
    textTitle = 22,
    padding = 10,
    panelWidthScale = 0.94,
    maxPanelWidth = 460,
})

local REGULAR: Metrics = table.freeze({
    buttonHeight = 40,
    textSmall = 14,
    textBody = 16,
    textTitle = 24,
    padding = 14,
    panelWidthScale = 0.4,
    maxPanelWidth = 420,
})

function Layout.metrics(class: string): Metrics
    if class == Layout.Compact then
        return COMPACT
    end
    return REGULAR
end

return Layout
