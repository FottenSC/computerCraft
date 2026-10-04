-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=path/to/file&per_page=1
-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=src/components&sha=main&per_page=1
-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?per_page=1
-- https://api.github.com/repos/FottenSC/COMPUTERCRAFT/commits?path=src/components&sha=main&per_page=1

-- wget https://raw.githubusercontent.com/FottenSC/COMPUTERCRAFT/main/startup.lua

local body
local response
local repo = "FottenSC/COMPUTERCRAFT"
local updaterPath = "updater.lua"

print("\nChecking for updates...")
local commitUrl = "https://api.github.com/repos/" .. repo .. "/commits?path=" .. updaterPath .. "&per_page=1"
response = assert(http.get(commitUrl))

print("Response code: " .. response.getResponseCode())
body = assert(response.readAll())
response.close()

local json = assert(textutils.unserializeJSON(body))
local ghUpdaterCommit = assert(json[1].sha)
local updaterVersion = settings.get("updaterVersion", "EMPTY")

if(ghUpdaterCommit ~= updaterVersion) then
    print("Updating updater.lua to commit: " .. ghUpdaterCommit:sub(1, 7))
    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. ghUpdaterCommit .. "/" .. updaterPath

    local download = assert(http.get(url))
    local source = assert(download.readAll())
    download.close()

    local file = assert(fs.open(updaterPath, "w"))
    file.write(source)
    file.close()

    settings.set("updaterVersion", ghUpdaterCommit)
    settings.save()

    print("Update successful :)")
else
    print("updater.lua is up to date.")
end

shell.run(updaterPath)