
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

if type(allowedBlocks) ~= "table" or #allowedBlocks == 0 then error("Configure a non-empty blockChecker.allowed_blocks list before running", 0) end
if type(delay) ~= "number" or delay ~= delay or delay < 0.05 or delay == math.huge then error("blockChecker.delay must be a finite number >= 0.05", 0) end
if type(currentCount) ~= "number" or currentCount < 0 or currentCount % 1 ~= 0 then error("Invalid totalBlocksBroken setting", 0) end
local allow = {}
for index = 1, #allowedBlocks do
    if type(allowedBlocks[index]) ~= "string" then error("blockChecker.allowed_blocks must be a contiguous array", 0) end
end
for index, block in pairs(allowedBlocks) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #allowedBlocks
        or type(block) ~= "string" or not block:match("^[%w_.%-]+:[%w_./%-]+$") then
        error("blockChecker.allowed_blocks must be an array of namespace:block names", 0)
    end
    allow[block] = true
end

log.info("Starting block checker; total blocks broken: " .. currentCount)

while true do
    local found, block = turtle.inspectDown()
    if found and not allow[block.name] then
        if turtle.digDown() then
            currentCount = currentCount + 1
            settings.set("totalBlocksBroken", currentCount)
            settings.save()
            log.info("Blocks broken: " .. currentCount)
        end
    end
    sleep(delay)
end
