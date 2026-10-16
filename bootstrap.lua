-- One-shot installer for CC:Tweaked.
-- Usage: wget run <raw bootstrap URL> [package] [branch]

local args = { ... }
local packageName = args[1] or "block-checker"
local branch = args[2] or "main"
local repository = "FottenSC/computerCraft"

if packageName == "--help" or packageName == "-h" then
    print("Usage: bootstrap [package] [branch]")
    print("Default: block-checker on main")
    print("block-checker requires a turtle.")
    print("Installs ccpm, enables startup, then reboots.")
    return
end
if #args > 2 or not packageName:match("^[a-z0-9][a-z0-9%._%-]*$")
    or branch == "" or branch:sub(1, 1) == "-" then
    error("Usage: bootstrap [package] [branch]. Try --help.", 0)
end
if packageName == "block-checker" and not turtle then
    error("block-checker requires a turtle. Run bootstrap on a turtle or choose another program.", 0)
end

if not http then
    error("The HTTP API is disabled. Enable it in the CC:Tweaked server config.", 0)
end

local function download(url)
    local response, reason, failedResponse = http.get(url, { ["User-Agent"] = "ccpm-bootstrap/1" }, true)
    response = response or failedResponse
    if not response then error("Download failed: " .. tostring(reason), 0) end

    local code = response.getResponseCode()
    local ok, body = pcall(response.readAll)
    response.close()
    if not ok then error("Could not read download: " .. tostring(body), 0) end
    if code < 200 or code >= 300 then
        error("Download failed with HTTP " .. code, 0)
    end

    return body
end

print("Installing ccpm from " .. repository .. "@" .. branch .. "...")
local reference = ("refs/heads/" .. branch):gsub("([^%w%-_%.~])", function(character)
    return ("%%%02X"):format(string.byte(character))
end)
local resolved = textutils.unserializeJSON(download("https://api.github.com/repos/" .. repository .. "/commits/" .. reference))
assert(type(resolved) == "table" and type(resolved.sha) == "string"
    and #resolved.sha == 40 and resolved.sha:match("^[0-9a-fA-F]+$"), "Invalid GitHub commit response")
local base = "https://raw.githubusercontent.com/" .. repository .. "/" .. resolved.sha .. "/"
local manager, startup = download(base .. "ccpm.lua"), download(base .. "startup.lua")
local installer = assert(load(startup, "@startup.lua", "t", _ENV))("--installer")
installer.withLock(function() installer.install(manager, startup) end)

settings.set("ccpm.default_repo", repository)
settings.set("shell.allow_startup", true)
if not settings.save() then error("Could not save /.settings; installation will not reboot.", 0) end

local installed = shell.execute("/ccpm.lua", "install", packageName,
    "--repo", repository, "--branch", branch, "--startup")
if not installed then error("ccpm was installed, but the package install failed.", 0) end

print("Installed. Rebooting into " .. packageName .. "...")
sleep(1)
os.reboot()
