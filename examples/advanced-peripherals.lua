-- VS Code example for Advanced Peripherals 0.7.62b / Minecraft 1.21.1.
-- Type "bridge." or "scanner." and press Ctrl+Space to inspect their methods.
-- Running this example only queries devices; it does not export or craft items.
local bridge = assert(peripheral.find("me_bridge"), "Attach an ME bridge first")
local items, reason = bridge.getItems()
if items then
    for _, item in ipairs(items) do
        print(item.name, item.count)
    end
else
    printError(reason)
end

local scanner = peripheral.find("geo_scanner")
if scanner then
    local cost, scanError = scanner.cost(4)
    if cost then print("Scan cost:", cost) else printError(scanError) end
end

-- For a known device on a named side, an editor type assertion also works:
-- local sideBridge = assert(peripheral.wrap("back")) --[[@as AP.MEBridge]]
-- local sideItems, sideError = sideBridge.getItems()
