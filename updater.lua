

local whiteListBlock = "minecraft:netherrack"

while true do
    local success, data = turtle.inspectDown()
    if success then
        if data.name ~= whiteListBlock then
            print("Detected block below: " .. data.name .. ". Digging...")
            turtle.digDown()
        end
    end
    sleep(0.5)
end


