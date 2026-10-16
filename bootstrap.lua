-- One-shot manager installer for CC:Tweaked. Packages and reboot are opt-in.
local args, options, positional = {...}, {}, {}
local flags = {startup=true, reboot=true}
local allowed = {repo=true, branch=true, version=true, commit=true, startup=true, reboot=true}
if args[1] == "--help" or args[1] == "-h" then
    print("bootstrap [package] [options]")
    print("Default: manager only, latest stable release.")
    print("--repo owner/repo")
    print("--branch name | --version 1.2.3 | --commit SHA")
    print("--startup  Select the package for boot")
    print("--reboot   Reboot after installation")
    return
end
local index = 1
while index <= #args do
    local value = args[index]
    if value:sub(1, 2) == "--" then
        local key = value:sub(3)
        assert(allowed[key], "Unknown option " .. value)
        assert(options[key] == nil, "Duplicate option " .. value)
        if flags[key] then options[key] = true else
            index = index + 1
            assert(args[index] and args[index]:sub(1, 1) ~= "-", "Missing value for " .. value)
            options[key] = args[index]
        end
    else positional[#positional + 1] = value end
    index = index + 1
end
assert(#positional <= 2, "Usage: bootstrap [package] [options]. Try --help.")
local packageName = positional[1]
if packageName then assert(packageName:match("^[a-z0-9][a-z0-9%._%-]*$"), "Invalid package name") end
assert(not options.startup or packageName, "--startup requires a package")
if positional[2] then assert(not options.branch, "Duplicate branch"); options.branch = positional[2] end
local selector, selections
selections = 0
for _, kind in ipairs({"branch", "version", "commit"}) do
    if options[kind] then selector={kind=kind, value=options[kind]}; selections=selections+1 end
end
assert(selections <= 1, "Choose one of --branch, --version, or --commit")
selector = selector or {kind="stable", value="latest"}
local repository = options.repo or "FottenSC/computerCraft"
assert(repository:match("^[A-Za-z0-9][A-Za-z0-9%-]*/[A-Za-z0-9%._%-]+$") and not repository:match("/%.%.?$"), "Invalid repository")
if selector.kind == "commit" then assert(#selector.value == 40 and selector.value:match("^[0-9a-fA-F]+$"), "Commit must be a full 40-character SHA") end
if selector.kind == "version" then assert(selector.value:match("^v?%d+%.%d+%.%d+[%w%.%-]*$"), "Invalid version") end
assert(http, "The HTTP API is disabled. Enable it in the CC:Tweaked server config.")

local function download(url)
    local response, reason, failedResponse = http.get(url, {["User-Agent"]="ccpm-bootstrap/1"}, true)
    response = response or failedResponse
    if not response then error("Download failed: " .. tostring(reason), 0) end
    local code = response.getResponseCode()
    local ok, body = pcall(response.readAll)
    response.close()
    if not ok then error("Could not read download: " .. tostring(body), 0) end
    if code < 200 or code >= 300 then
        error("HTTP " .. code .. ". Stable installs need a published release. For development use --branch main.", 0)
    end
    return body
end
local function encode(value)
    return (value:gsub("([^%w%-_%.~])", function(c) return ("%%%02X"):format(string.byte(c)) end))
end
print("Installing ccpm from " .. repository .. " (" .. selector.kind .. " " .. selector.value .. ")...")
local selected = {kind=selector.kind, value=selector.value}
if selector.kind == "stable" then
    local release = textutils.unserializeJSON(download("https://api.github.com/repos/" .. repository .. "/releases/latest"))
    assert(type(release) == "table" and type(release.tag_name) == "string" and release.tag_name:match("^v%d+%.%d+%.%d+$")
        and not release.draft and not release.prerelease, "No stable ccpm release is available")
    selected = {kind="version", value=release.tag_name:sub(2)}
end
local commit = selected.value
if selected.kind ~= "commit" then
    local reference = selected.kind == "version" and ("refs/tags/v" .. selected.value:gsub("^v", "")) or ("refs/heads/" .. selected.value)
    local result = textutils.unserializeJSON(download("https://api.github.com/repos/" .. repository .. "/commits/" .. encode(reference)))
    assert(type(result)=="table" and type(result.sha)=="string", "Invalid GitHub commit response")
    commit = result.sha
end
assert(#commit == 40 and commit:match("^[0-9a-fA-F]+$"), "Invalid GitHub commit SHA")
commit = commit:lower()
local base = "https://raw.githubusercontent.com/" .. repository .. "/" .. commit .. "/"
local manager, startup = download(base .. "ccpm.lua"), download(base .. "startup.lua")
local installer = assert(load(startup, "@startup.lua", "t", _ENV))("--installer")
installer.withLock(function() installer.install(manager, startup, {schema=1, repo=repository, selector=selector, commit=commit}) end)
if packageName then
    local command = {"/ccpm.lua", "install", packageName, "--repo", repository, "--commit", commit}
    if options.startup then command[#command+1] = "--startup" end
    if not shell.execute(table.unpack(command)) then error("ccpm installed; package installation failed. Run ccpm doctor.", 0) end
end
print("ccpm installed. Next: ccpm available")
print("Inspect boot settings: ccpm set")
if options.reboot then os.reboot() end
