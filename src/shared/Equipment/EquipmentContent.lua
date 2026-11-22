--!strict
-- Shared, immutable item definitions consumed by HUB UI and validated independently by both servers.
-- All initial equipment is free and mission-local; this file contains no behavior or Roblox APIs.
local function item(id: string, category: string, action: string, title: string, description: string)
    return table.freeze({ id = id, category = category, action = action, title = title, description = description })
end

return table.freeze({
    version = 1,
    items = table.freeze({
        item("EMF_READER", "DETECTION", "SCAN", "EMF Reader", "Detect electrical anomalies."),
        item("THERMOMETER", "DETECTION", "SCAN", "Thermometer", "Detect cold spots and thermal anomalies."),
        item("FIELD_CAMERA", "OBSERVATION", "CAPTURE", "Field Camera", "Capture directional physical disturbances."),
        item("SPIRIT_BOX", "COMMUNICATION", "SCAN", "Spirit Box", "Listen for audio phenomena."),
        item("UTILITY_FLASHLIGHT", "UTILITY", "TOGGLE_LIGHT", "Utility Flashlight", "A server-controlled source of light."),
    }),
})
