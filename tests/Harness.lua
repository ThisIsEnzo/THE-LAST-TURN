--!strict
-- Minimal test harness for pure Luau modules (no external framework). Run with Lune: `lune run tests/run`.

local Harness = {}

local results = { passed = 0, failed = 0, failures = {} :: { string } }

function Harness.test(name: string, fn: () -> ())
    local ok, err = pcall(fn)
    if ok then
        results.passed += 1
    else
        results.failed += 1
        table.insert(results.failures, name .. "\n    " .. tostring(err))
    end
end

function Harness.expectEqual(actual: any, expected: any, label: string?)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s", label and (label .. ": ") or "", tostring(expected), tostring(actual)), 2)
    end
end

function Harness.expectTrue(value: any, label: string?)
    if value ~= true then
        error((label or "expected true") .. " (got " .. tostring(value) .. ")", 2)
    end
end

function Harness.expectFalse(value: any, label: string?)
    if value ~= false then
        error((label or "expected false") .. " (got " .. tostring(value) .. ")", 2)
    end
end

function Harness.expectError(fn: () -> (), label: string?)
    if pcall(fn) then
        error((label or "expected an error") .. " but none was raised", 2)
    end
end

function Harness.results()
    return results
end

return Harness
