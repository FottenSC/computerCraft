
local currentCount = settings.get("totalBlocksBroken", 0)
local whiteListBlock = "minecraft:netherrack"
print("Starting block digger...")
print("Total blocks broken: " .. currentCount)

while true do
    local success, data = turtle.inspectDown()
    if success then
        if data.name ~= whiteListBlock then
            turtle.digDown()
            currentCount = currentCount + 1
            settings.set("totalBlocksBroken", currentCount)
            settings.save()

            print("Current total: " .. currentCount)
        end
    end
    sleep(0.5)
end


