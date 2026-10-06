
local currentCount = settings.get("totalBlocksBroken", 0)
-- local whiteListBlock = "minecraft:sand"
-- local whiteListBlock = "minecraft:netherrack"
local whiteListBlockList = {
    "minecraft:stone",
    -- "ftbmaterials:platinum_stone_ore",
    "ftbmaterials:uranium_stone_ore",
}
print("Starting block digger...")
print("Total blocks broken: " .. currentCount)

while true do
    local success, data = turtle.inspectDown()
    local doDig = true
    if success then
        for index, block in ipairs(whiteListBlockList) do
            if data.name == block then
                doDig = false
                break
            end
        end
    end

    if(doDig) then
        turtle.digDown()
        currentCount = currentCount + 1
        settings.set("totalBlocksBroken", currentCount)
        settings.save()

        print("Current total: " .. currentCount)
    end

    sleep(0.5)
end


