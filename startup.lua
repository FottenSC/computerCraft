

-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=path/to/file&per_page=1
-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=src/components&sha=main&per_page=1
-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?per_page=1

-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=src/components&sha=main&per_page=1

local repo = "FottenSC/COMPUTERCRAFT"
local updaterPath = "updater.lua"

print("Updating...")


local shellComnad = shell.run("wget https://raw.githubusercontent.com/" .. repo .. "/main/" .. updaterPath)
local currentUpdaterCommit = shell.run(shellComnad)


local updaterCommit = settings.get("updaterCommit")


if(currentUpdaterCommit ~= updaterCommit) then
    print("Updating updater.lua to commit: " .. currentUpdaterCommit)
    shell.run("wget https://raw.githubusercontent.com/" .. repo .. "/main/" .. updaterPath .. " " .. updaterPath)
    settings.set("updaterCommit", currentUpdaterCommit)
    print("Updated updater.lua to commit: " .. currentUpdaterCommit)
else
    print("updater.lua is up to date.")
end

