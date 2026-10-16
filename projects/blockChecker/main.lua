
local log = require("ccpm.log")

if not turtle then error("block-checker requires a turtle", 0) end

settings.define("blockChecker.allowed_blocks", {
    description = "Blocks the turtle must not dig",
    default = {
        "minecraft:stone",
        "ftbmaterials:monazite_stone_ore",
    },
    type = "table",
})

settings.define("blockChecker.delay", {
    description = "Seconds to wait between checks",
    default = 0.5,
    type = "number",
})

local currentCount = settings.get("totalBlocksBroken", 0)
local allowedBlocks = settings.get("blockChecker.allowed_blocks")
local delay = settings.get("blockChecker.delay")

local allow = {}
for _, block in ipairs(allowedBlocks) do allow[block] = true end

log.info("Starting block checker; total blocks broken: " .. currentCount)

while true do
    local found, block = turtle.inspectDown()
    if not found or not allow[block.name] then
        if turtle.digDown() then
            currentCount = currentCount + 1
            settings.set("totalBlocksBroken", currentCount)
            settings.save()
            log.info("Blocks broken: " .. currentCount)
        end
    end
    sleep(delay)
end
