-- Integration smoke test for ccpm's CC:Tweaked-facing behavior.
-- CI runs this under Lua 5.2 with a small in-memory CraftOS mock.

local cjson = require("cjson")
local hostRequire = require
local root = os.getenv("CCPM_TEST_ROOT") or "."
local commit = string.rep("a", 40)
local remoteCommit = commit
turtle = {}

local files, directories = {}, { [""] = true, ["/"] = true }

local function parent(path)
    return path:match("^(.*)/[^/]+$") or ""
end

local function makeDirectory(path)
    if path == "" then return end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        if current == "" or current == "/" then current = current .. part else current = current .. "/" .. part end
        directories[current] = true
    end
end

fs = {}
function fs.exists(path) return files[path] ~= nil or directories[path] == true end
function fs.isDir(path) return directories[path] == true end
function fs.list(path)
    local result, seen = {}, {}
    for _, entries in ipairs({ files, directories }) do
        for key in pairs(entries) do
            if parent(key) == path and not seen[key] then
                result[#result + 1] = key:match("[^/]+$")
                seen[key] = true
            end
        end
    end
    table.sort(result)
    return result
end
function fs.copy(source, target)
    assert(files[source], "missing copy source " .. source)
    assert(not fs.exists(target), "copy target exists " .. target)
    makeDirectory(parent(target))
    files[target] = files[source]
end
function fs.getDir(path) return parent(path) end
function fs.makeDir(path) makeDirectory(path) end
function fs.delete(path)
    files[path], directories[path] = nil, nil
    local prefix = path .. "/"
    for key in pairs(files) do if key:sub(1, #prefix) == prefix then files[key] = nil end end
    for key in pairs(directories) do if key:sub(1, #prefix) == prefix then directories[key] = nil end end
end
function fs.move(source, target)
    assert(not fs.exists(target), "move target exists " .. target)
    if files[source] ~= nil then
        makeDirectory(parent(target))
        files[target], files[source] = files[source], nil
        return
    end
    assert(directories[source], "missing move source " .. source)
    makeDirectory(target)
    local prefix = source .. "/"
    local fileKeys, directoryKeys = {}, {}
    for key in pairs(files) do fileKeys[#fileKeys + 1] = key end
    for key in pairs(directories) do directoryKeys[#directoryKeys + 1] = key end
    for _, key in ipairs(fileKeys) do
        if key:sub(1, #prefix) == prefix then
            files[target .. key:sub(#source + 1)] = files[key]
            files[key] = nil
        end
    end
    for _, key in ipairs(directoryKeys) do
        if key:sub(1, #prefix) == prefix then
            directories[target .. key:sub(#source + 1)] = true
            directories[key] = nil
        end
    end
    directories[source] = nil
end
function fs.open(path, mode)
    if mode == "r" or mode == "rb" then
        if files[path] == nil then return nil end
        return { readAll = function() return files[path] end, close = function() end }
    end
    if mode == "w" or mode == "wb" then
        makeDirectory(parent(path))
        local buffer = ""
        return {
            write = function(value) buffer = buffer .. value end,
            close = function() files[path] = buffer end,
        }
    end
    error("unsupported open mode " .. tostring(mode))
end

local settingValues = {}
settings = {}
function settings.define(name, options)
    if settingValues[name] == nil then settingValues[name] = options.default end
end
function settings.get(name, fallback)
    if settingValues[name] == nil then return fallback end
    return settingValues[name]
end
function settings.set(name, value) settingValues[name] = value end
function settings.unset(name) settingValues[name] = nil end
function settings.save() return true end

textutils = {
    unserializeJSON = function(value) return cjson.decode(value) end,
    json_null = cjson.null,
    serializeJSON = function(value)
        -- CraftOS rejects repeated table identities, even without a cycle.
        local seen = {}
        local function visit(item)
            if type(item) ~= "table" then return end
            assert(not seen[item], "Cannot serialize table with repeated entries")
            seen[item] = true
            for _, child in pairs(item) do visit(child) end
        end
        visit(value)
        return cjson.encode(value)
    end,
    formatTime = function() return "12:00" end,
    pagedPrint = function(message)
        assert(not _G.__ccpm_write_lock, "paging must not hold the manager lock")
        print(message)
    end,
}
term = {getCursorPos=function() return 1, 1 end}

local function hostRead(relative)
    local handle = assert(io.open(root .. "/" .. relative, "rb"))
    local value = handle:read("*a")
    handle:close()
    return value
end

-- GitHub commit responses contain nullable metadata even for valid commits.
-- Keep this shape in both HTTP fixtures so every branch/tag operation sees it.
local function githubCommitResponse(sha)
    return cjson.encode({
        sha = sha,
        author = cjson.null,
        committer = cjson.null,
        commit = { verification = {
            verified = false, reason = "unsigned",
            signature = cjson.null, payload = cjson.null, verified_at = cjson.null,
        } },
    })
end

local requestCount = 0
http = {}
function http.get(url, _, binary)
    assert(binary == true, "downloads must preserve raw bytes")
    requestCount = requestCount + 1
    local body
    if url:match("/releases/latest$") then
        body = cjson.encode({tag_name="v1.0.0", draft=false, prerelease=false})
    elseif url:find("api.github.com", 1, true) then
        body = githubCommitResponse(remoteCommit)
    else
        local requestedCommit, relative = url:match("/([0-9a-f]+)/(.+)$")
        assert(relative, "unexpected URL " .. url)
        if requestedCommit ~= commit then return nil, "simulated incomplete deployment" end
        body = hostRead(relative)
    end
    return {
        getResponseCode = function() return 200, "OK" end,
        readAll = function() return body end,
        close = function() end,
    }
end

local errors = {}
function printError(value) errors[#errors + 1] = tostring(value) end
function sleep() end

local lastRun, executePrograms
os.run = function(environment, entrypoint, ...)
    assert(not _G.__ccpm_write_lock, "programs must run outside the manager lock")
    -- Match CraftOS: os.run discards the caller-provided fallback metatable.
    setmetatable(environment, { __index = _G })
    lastRun = { environment = environment, entrypoint = entrypoint, arguments = { ... } }
    if executePrograms then return pcall(assert(load(files[entrypoint], "@" .. entrypoint, "t", environment)), ...) end
    return true
end

require = function(name)
    if name == "cc.require" then
        return {
            make = function(environment, directory)
                local package = { path = directory .. "/?.lua;" .. directory .. "/?/init.lua", loaded = {} }
                return function(module)
                    if package.loaded[module] then return package.loaded[module] end
                    local name = module:gsub("%.", "/")
                    for pattern in package.path:gmatch("[^;]+") do
                        local path = pattern:gsub("%?", name)
                        if files[path] then
                            local result = assert(load(files[path], "@" .. path, "t", environment))()
                            if result == nil then result = true end
                            package.loaded[module] = result
                            return result
                        end
                    end
                    error("module not found: " .. module)
                end, package
            end,
        }
    end
    return hostRequire(name)
end

-- Run the same scenarios against pinned upstream cc.require and os.run in CI.
-- Only platform I/O and event delivery remain mocked in this pass.
local upstreamDirectory = os.getenv("CCPM_UPSTREAM_DIR")
if upstreamDirectory then
    local hostLoadfile = loadfile
    loadfile = function(path, mode, environment)
        if files[path] then return load(files[path], "@" .. path, mode, environment or _G) end
        return hostLoadfile(path, mode, environment or _G)
    end
    fs.combine = function(first, second)
        local path = (second or ""):sub(1, 1) == "/" and second or (first .. "/" .. (second or ""))
        local parts = {}
        for part in path:gmatch("[^/]+") do
            if part == ".." then table.remove(parts)
            elseif part ~= "." then parts[#parts + 1] = part end
        end
        return table.concat(parts, "/")
    end
    local expected = assert(loadfile(upstreamDirectory .. "/expect.lua"))()
    local factoryEnv = setmetatable({require=function(name)
        assert(name == "cc.expect")
        return expected
    end}, {__index=_G})
    local factory = assert(loadfile(upstreamDirectory .. "/require.lua", "t", factoryEnv))()
    require = function(name)
        if name == "cc.require" then return factory end
        return hostRequire(name)
    end
    local handle = assert(io.open(upstreamDirectory .. "/bios.lua", "rb"))
    local bios = handle:read("*a")
    handle:close()
    local implementation = assert(bios:match("(function os%.run.-)\nlocal tAPIsLoading"))
    local apiEnvironment = setmetatable({os={}, expect=expected.expect}, {__index=_G})
    assert(load(implementation, "@upstream-os.run", "t", apiEnvironment))()
    local mockedRun = os.run
    os.run = function(environment, entrypoint, ...)
        if not executePrograms then return mockedRun(environment, entrypoint, ...) end
        assert(not _G.__ccpm_write_lock)
        lastRun = {environment=environment, entrypoint=entrypoint, arguments={...}}
        return apiEnvironment.os.run(environment, entrypoint, ...)
    end
end

local shellAPI = { dir = function() return "/" end }
local multishellAPI = { getCurrent = function() return 1 end }
local cliEnvironment = setmetatable({ shell = shellAPI, multishell = multishellAPI }, { __index = _G })
local function ccpm(...)
    local chunk = assert(loadfile(root .. "/ccpm.lua", "t", cliEnvironment))
    return chunk(...)
end

ccpm("install", "block-checker", "--repo", "FottenSC/computerCraft", "--branch", "main", "--startup")
assert(settingValues["ccpm.startup_package"] == "block-checker")
assert(fs.exists("/.ccpm/state.json"))
assert(fs.exists("/.ccpm/store/FottenSC_computerCraft/" .. commit .. "/block-checker/main.lua"))
assert(fs.exists("/.ccpm/store/FottenSC_computerCraft/" .. commit .. "/ccpm-log/ccpm/log.lua"))

local state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots["block-checker"].selector.kind == "branch")
assert(state.roots["block-checker"].resolved == commit)

local beforeUpdate = requestCount
ccpm("update", "block-checker")
assert(requestCount == beforeUpdate + 1, "an unchanged update should only resolve the branch once")

ccpm("pin", "block-checker", "--version", cjson.decode(hostRead("ccpm-package.json")).packages["block-checker"].version)
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots["block-checker"].selector.kind == "version")

ccpm("run", "block-checker", "example")
assert(lastRun and lastRun.entrypoint:match("block%-checker/main.lua$"))
assert(lastRun.arguments[1] == "example")
assert(lastRun.environment.package.path:find("ccpm%-log/%?%.lua"))

ccpm("track", "block-checker", "main")
settingValues["ccpm.auto_update"] = true
lastRun = nil
ccpm("startup")
assert(lastRun, "startup should launch the selected package")
assert(#errors == 0, table.concat(errors, "\n"))

-- A branch may move to a commit whose files cannot be downloaded. Startup must
-- retain and run the previous lock instead of activating a partial install.
remoteCommit = string.rep("b", 40)
lastRun = nil
ccpm("startup")
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots["block-checker"].resolved == commit)
assert(lastRun and lastRun.entrypoint:find(commit, 1, true))
assert(#errors == 1 and errors[1]:find("using installed version", 1, true))

-- Regression fixtures use synthetic repositories while exercising the real CLI.
local testManifest, failDownload
local function resetFixture()
    files, directories = {}, { [""] = true, ["/"] = true }
    settingValues, errors, lastRun = {}, {}, nil
    remoteCommit, failDownload = commit, false
    executePrograms = false
    _G.__ccpm_startup_ran, _G.__ccpm_write_lock = nil, nil
end

local function program(dependencies)
    return {
        kind = "program", version = "1.0.0", entrypoint = "main.lua",
        files = {{ source = "main.lua", target = "main.lua" }},
        dependencies = dependencies or {},
    }
end

local function library(name, dependencies)
    return { kind = "library", version = "1.0.0",
        files = {{ source = name .. ".lua", target = name .. ".lua" }}, dependencies = dependencies or {} }
end

http.get = function(url, _, binary)
    assert(binary == true, "downloads must preserve raw bytes")
    local body
    if url:match("/releases/latest$") then
        body = cjson.encode({tag_name="v1.0.0", draft=false, prerelease=false})
    elseif url:find("api.github.com", 1, true) then
        body = githubCommitResponse(remoteCommit)
    elseif url:match("ccpm%-package.json$") then
        body = cjson.encode(testManifest)
    elseif failDownload then
        return nil, "simulated file download failure"
    else
        body = "return true"
    end
    return {
        getResponseCode = function() return 200 end,
        readAll = function() return body end,
        close = function() end,
    }
end

-- Nullable metadata must not weaken validation of the required commit SHA.
for _, response in ipairs({
    {}, {sha=cjson.null}, {sha=false}, {sha=12}, {sha={}},
    {sha=""}, {sha="abc123"}, {sha=string.rep("g", 40)},
}) do
    resetFixture()
    remoteCommit = response.sha
    local ok, reason = pcall(ccpm, "install", "foo", "--branch", "main")
    assert(not ok and reason:find("GitHub did not return a commit", 1, true), tostring(reason))
    assert(not fs.exists("/.ccpm/state.json") and not _G.__ccpm_write_lock)
end

-- Valid package names must not overlap temporary download directories, even
-- when the new installation fails after staging has been created.
resetFixture()
testManifest = { schema = 1, packages = { foo = program(), ["foo.staging"] = program() } }
ccpm("install", "foo.staging", "--commit", commit)
local originalLock = files["/.ccpm/state.json"]
failDownload = true
assert(not pcall(ccpm, "install", "foo", "--commit", commit))
assert(files["/.ccpm/state.json"] == originalLock)
ccpm("run", "foo.staging")
failDownload = false
ccpm("install", "foo", "--commit", commit)
ccpm("run", "foo.staging")
ccpm("run", "foo")

-- A shared library's branch dependency may resolve differently for two roots.
-- Each root must retain its own lock, including roots from the old key format.
for _, legacy in ipairs({ false, true }) do
    resetFixture()
    testManifest = { schema = 1, packages = {
        root1 = program({ shared = "*" }),
        root2 = program({ shared = "*" }),
        shared = library("shared", { extra = { repo = "other/repo", branch = "main" } }),
        extra = library("extra"),
    } }
    remoteCommit = string.rep("b", 40)
    ccpm("install", "root1", "--commit", commit)
    state = cjson.decode(files["/.ccpm/state.json"])
    if legacy then
        local legacyPackages = {}
        for key, node in pairs(state.packages) do
            for index, dependency in ipairs(node.dependencies) do
                node.dependencies[index] = dependency:gsub("^root1|%d+|", "")
            end
            legacyPackages[(key:gsub("^root1|%d+|", ""))] = node
        end
        state.packages = legacyPackages
        state.roots.root1.node = state.roots.root1.node:gsub("^root1|%d+|", "")
        files["/.ccpm/state.json"] = cjson.encode(state)
    end
    local originalRoot = state.roots.root1.node
    local originalShared = state.packages[originalRoot].dependencies[1]
    local originalExtra = state.packages[originalShared].dependencies[1]
    remoteCommit = string.rep("c", 40)
    ccpm("install", "root2", "--commit", commit)
    state = cjson.decode(files["/.ccpm/state.json"])
    assert(state.roots.root1.node == originalRoot)
    assert(state.packages[originalShared].dependencies[1] == originalExtra)
    local newShared = state.packages[state.roots.root2.node].dependencies[1]
    local newExtra = state.packages[newShared].dependencies[1]
    assert(state.packages[newExtra].commit == remoteCommit)
    ccpm("run", "root1")
    assert(lastRun.environment.package.path:find(string.rep("b", 40), 1, true))
    assert(not lastRun.environment.package.path:find(remoteCommit, 1, true))
    ccpm("run", "root2")
    assert(lastRun.environment.package.path:find(remoteCommit, 1, true))
end

-- Simulate a shutdown after the old lock is moved away but before the new lock
-- is activated. Startup must recover the old install, not the pending .new.
resetFixture()
testManifest = { schema = 1, packages = { foo = program(), bar = program() } }
ccpm("install", "foo", "--commit", commit, "--startup")
originalLock = files["/.ccpm/state.json"]
files["/.ccpm/state.json.new"] = cjson.encode({ schema = 1, roots = {}, packages = {} })
fs.move("/.ccpm/state.json", "/.ccpm/state.json.old")
ccpm("startup")
assert(lastRun and lastRun.entrypoint:match("/foo/main.lua$"))
assert(files["/.ccpm/state.json"] == originalLock)
assert(not fs.exists("/.ccpm/state.json.old"))
ccpm("install", "bar", "--commit", commit)
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots.foo and state.roots.bar)
assert(not fs.exists("/.ccpm/state.json.new"))

-- If activation finished but backup cleanup did not, prefer the current lock.
files["/.ccpm/state.json.old"] = originalLock
ccpm("run", "bar")
assert(lastRun.entrypoint:match("/bar/main.lua$"))

-- Real module execution and shell-only APIs survive os.run's environment reset.
resetFixture()
testManifest = { schema = 1, packages = { foo = program({ helper = "*" }), helper = library("helper") } }
ccpm("install", "foo", "--commit", commit)
state = cjson.decode(files["/.ccpm/state.json"])
local node = state.packages[state.roots.foo.node]
local helper = state.packages[node.dependencies[1]]
files[helper.path .. "/helper.lua"] = "return {answer=42}"
files[node.path .. "/main.lua"] = "assert(shell.dir() == '/'); assert(multishell.getCurrent() == 1); assert(require('helper').answer == 42)"
executePrograms = true
ccpm("run", "foo")
-- Older lockfiles without the new module inventory are checked from disk.
for _, package in pairs(state.packages) do package.modules = nil end
files["/.ccpm/state.json"] = cjson.encode(state)
ccpm("run", "foo")

-- Pinned updates neither consult a moving tag nor change the lockfile.
resetFixture()
testManifest = { schema = 1, packages = { foo = program() } }
ccpm("install", "foo", "--version", "1.0.0")
originalLock = files["/.ccpm/state.json"]
local fixtureGet = http.get
http.get = function() error("Pinned updates must not access the network") end
ccpm("update", "foo")
ccpm("update")
assert(files["/.ccpm/state.json"] == originalLock)
http.get = fixtureGet

-- Invalid pins are rejected before any network access or state mutation.
for _, invalid in ipairs({ "main", "abc123", string.rep("g", 40), "" }) do
    http.get = function() error("Invalid commit reached the network") end
    local ok, reason = pcall(ccpm, "pin", "foo", "--commit", invalid)
    assert(not ok and (reason:find("Commit must") or reason:find("Selector must")))
    assert(files["/.ccpm/state.json"] == originalLock)
end
http.get = fixtureGet
testManifest.packages.foo.dependencies = { helper = { commit = "main" } }
testManifest.packages.helper = library("helper")
assert(not pcall(ccpm, "install", "foo", "--commit", commit))
assert(files["/.ccpm/state.json"] == originalLock)

-- Conflicting modules/versions must fail before downloading files or activation.
for _, collision in ipairs({ "helper.lua", "helper/init.lua" }) do
    resetFixture()
    testManifest = { schema = 1, packages = { foo = program(), helper = library("helper") } }
    ccpm("install", "foo", "--commit", commit)
    originalLock = files["/.ccpm/state.json"]
    testManifest.packages.foo.dependencies = { helper = "*" }
    testManifest.packages.foo.files[2] = { source = collision, target = collision }
    local ok, reason = pcall(ccpm, "install", "foo", "--commit", commit)
    assert(not ok and reason:find("Conflicting module"))
    assert(files["/.ccpm/state.json"] == originalLock)
end
resetFixture()
testManifest = { schema = 1, packages = {
    foo = program({ a = "*", b = "*" }),
    a = library("a", { shared = { commit = string.rep("b", 40) } }),
    b = library("b", { shared = { commit = string.rep("c", 40) } }),
    shared = library("shared"),
} }
local accepted, conflict = pcall(ccpm, "install", "foo", "--commit", commit)
assert(not accepted and conflict:find("Conflicting"))
assert(not fs.exists("/.ccpm/state.json"))
-- A diamond using the same locked provider remains supported.
testManifest.packages.b.dependencies.shared.commit = string.rep("b", 40)
ccpm("install", "foo", "--commit", commit)
-- Ordinary data filenames shared across isolated packages are not modules.
testManifest.packages.a.files[2] = { source = "README.txt", target = "README.txt" }
testManifest.packages.b.files[2] = { source = "README.txt", target = "README.txt" }
ccpm("install", "foo", "--commit", commit)

-- Another tab attempts installation while the first command waits for HTTP.
resetFixture()
testManifest = { schema = 1, packages = { foo = program(), bar = program() } }
local attempted = false
http.get = function(...)
    if not attempted then
        attempted = true
        local ok, reason = pcall(ccpm, "install", "bar", "--commit", commit)
        assert(not ok and reason:find("in progress"))
    end
    return fixtureGet(...)
end
ccpm("install", "foo", "--commit", commit)
http.get = fixtureGet
ccpm("install", "bar", "--commit", commit)
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots.foo and state.roots.bar)
failDownload = true
remoteCommit = string.rep("b", 40)
assert(not pcall(ccpm, "track", "foo", "main"))
assert(not _G.__ccpm_write_lock, "failed commands must release the lock")
failDownload = false
ccpm("list")

-- Binary payloads survive both download and filesystem write unchanged.
resetFixture()
testManifest = { schema = 1, packages = { foo = program() } }
testManifest.packages.foo.files[2] = { source = "asset.bin", target = "asset.bin" }
local bytes = {}
for byte = 0, 255 do bytes[#bytes + 1] = string.char(byte) end
local payload = table.concat(bytes)
http.get = function(url, headers, binary)
    if url:match("asset.bin$") then
        assert(binary == true)
        return { getResponseCode = function() return 200 end, readAll = function() return payload end, close = function() end }
    end
    return fixtureGet(url, headers, binary)
end
local originalOpen = fs.open
fs.open = function(path, mode)
    if path:match("asset.bin$") and mode:sub(1, 1) == "w" then assert(mode == "wb") end
    return originalOpen(path, mode)
end
ccpm("install", "foo", "--commit", commit)
assert(files["/.ccpm/store/FottenSC_computerCraft/" .. commit .. "/foo/asset.bin"] == payload)
http.get, fs.open = fixtureGet, originalOpen

-- Installer tests exercise the same transaction used by bootstrap/self-update.
local startupSource = hostRead("startup.lua")
local managerSource = hostRead("ccpm.lua")
local oldManager, oldStartup = "-- ccpm: old manager\nreturn true", startupSource .. "\n-- old startup"
local function seedRuntime()
    resetFixture()
    files["/ccpm.lua"], files["/startup/10-ccpm.lua"] = oldManager, oldStartup
    makeDirectory("/startup")
    files["/startup.lua"] = "-- user startup\nreturn true"
    http.get = function(url, headers, binary)
        assert(binary == true)
        local body
        if url:match("/ccpm.lua$") then body = managerSource
        elseif url:match("/startup.lua$") then body = startupSource
        else return fixtureGet(url, headers, binary) end
        assert(url:find(commit, 1, true), "runtime downloads must use one immutable commit")
        return { getResponseCode = function() return 200 end, readAll = function() return body end, close = function() end }
    end
end
local function unchangedRuntime()
    assert(files["/ccpm.lua"] == oldManager)
    assert(files["/startup/10-ccpm.lua"] == oldStartup)
    assert(files["/startup.lua"] == "-- user startup\nreturn true")
end
seedRuntime()
local runtimeGet = http.get
http.get = function(url, ...)
    if url:match("/startup.lua$") then return nil, "second download failed" end
    return runtimeGet(url, ...)
end
assert(not pcall(ccpm, "self-update"))
unchangedRuntime()

local originalMove, originalCopy, originalDelete = fs.move, fs.copy, fs.delete
for _, target in ipairs({ "/ccpm.lua", "/startup/10-ccpm.lua", "/.ccpm/runtime.json" }) do
    seedRuntime()
    fs.move = function(source, destination)
        if destination == target then error("activation failed") end
        return originalMove(source, destination)
    end
    assert(not pcall(ccpm, "self-update"))
    unchangedRuntime()
    assert(not fs.exists("/.ccpm/runtime-update/pending.json"))
    fs.move = originalMove
end
seedRuntime()
fs.copy = function() error("backup disk full") end
assert(not pcall(ccpm, "self-update"))
unchangedRuntime()
fs.copy = originalCopy
ccpm("self-update")
assert(files["/ccpm.lua"] == managerSource and files["/startup/10-ccpm.lua"] == startupSource)
assert(not fs.exists("/.ccpm/runtime-update"))

-- If rollback fails too, keep the journal/backups and recover on the next boot.
seedRuntime()
fs.move = function(source, target)
    if target == "/ccpm.lua" then error("activation failure") end
    return originalMove(source, target)
end
fs.copy = function(source, target)
    if target == "/ccpm.lua" then error("recovery unavailable until reboot") end
    return originalCopy(source, target)
end
assert(not pcall(ccpm, "self-update"))
assert(fs.exists("/.ccpm/runtime-update/pending.json"))
assert(files["/.ccpm/runtime-update/ccpm.lua.old"] == oldManager)
fs.move, fs.copy = originalMove, originalCopy
local recoveryLaunched = false
local recoveryEnvironment = setmetatable({ shell = { run = function()
    unchangedRuntime()
    recoveryLaunched = true
    return true
end } }, { __index = _G })
assert(load(files["/startup/00-ccpm-recovery.lua"], "@startup", "t", recoveryEnvironment))()
assert(recoveryLaunched and not fs.exists("/.ccpm/runtime-update/pending.json"))

-- Stop the coroutine after each active-file mutation to model power loss,
-- bypassing pcall cleanup. Reboot invokes whichever startup entrypoint survives.
for crashAt = 1, 6 do
    seedRuntime()
    local mutations = 0
    local function checkpoint(path)
        if path == "/ccpm.lua" or path == "/startup/10-ccpm.lua" or path == "/.ccpm/runtime.json" or path == "/.ccpm/runtime-update/pending.json" then
            mutations = mutations + 1
            if mutations == crashAt then coroutine.yield("power loss") end
        end
    end
    fs.move = function(source, destination)
        originalMove(source, destination)
        if destination ~= "/.ccpm/runtime-update/pending.json" then checkpoint(destination) end
    end
    fs.delete = function(path) originalDelete(path); checkpoint(path) end
    local task = coroutine.create(function() ccpm("self-update") end)
    local ok, reason = coroutine.resume(task)
    assert(ok and reason == "power loss", tostring(reason))
    fs.move, fs.delete = originalMove, originalDelete
    _G.__ccpm_write_lock, _G.__ccpm_startup_ran = nil, nil
    local launches = 0
    local bootEnv = setmetatable({ shell = { run = function()
        assert(not _G.__ccpm_write_lock)
        launches = launches + 1
        return true
    end } }, { __index = _G })
    local boot = files["/startup/00-ccpm-recovery.lua"] or files["/startup/10-ccpm.lua"]
    assert(load(boot, "@boot", "t", bootEnv))()
    if files["/startup/00-ccpm-recovery.lua"] then
        assert(load(files["/startup/00-ccpm-recovery.lua"], "@hook", "t", bootEnv))()
    end
    assert(launches == 1)
    if crashAt < 6 then unchangedRuntime()
    else assert(files["/ccpm.lua"] == managerSource and files["/startup/10-ccpm.lua"] == startupSource) end
    assert(not fs.exists("/.ccpm/runtime-update/pending.json"))
end

-- Bootstrap shares the transactional installer and leaves the lock free when
-- handing off to the installed manager.
seedRuntime()
local installs, reboots = 0, 0
local oldReboot = os.reboot
os.reboot = function() reboots = reboots + 1 end
local bootstrapEnvironment = setmetatable({ turtle = {}, shell = { execute = function(path, command)
    assert(path == "/ccpm.lua" and command == "install")
    assert(not _G.__ccpm_write_lock)
    installs = installs + 1
    return true
end } }, { __index = _G })
for _, failure in ipairs({ "download", "activation", "syntax" }) do
    seedRuntime()
    local bootstrapGet = http.get
    http.get = function(url, ...)
        if failure == "download" and url:match("/startup.lua$") then return nil, "download failed" end
        if failure == "syntax" and url:match("/ccpm.lua$") then
            return { getResponseCode = function() return 200 end,
                readAll = function() return "this is not valid Lua!" end, close = function() end }
        end
        return bootstrapGet(url, ...)
    end
    fs.move = function(source, target)
        if failure == "activation" and target == "/ccpm.lua" then error("activation failed") end
        return originalMove(source, target)
    end
    assert(not pcall(assert(loadfile(root .. "/bootstrap.lua", "t", bootstrapEnvironment))))
    unchangedRuntime()
    assert(installs == 0 and reboots == 0)
    fs.move = originalMove
end
seedRuntime()
assert(loadfile(root .. "/bootstrap.lua", "t", bootstrapEnvironment))()
assert(installs == 0 and reboots == 0)
assert(loadfile(root .. "/bootstrap.lua", "t", bootstrapEnvironment))("block-checker", "--branch", "main", "--startup", "--reboot")
assert(installs == 1 and reboots == 1)
assert(files["/ccpm.lua"] == managerSource and files["/startup/10-ccpm.lua"] == startupSource)
os.reboot, http.get = oldReboot, fixtureGet

-- Preserve program identity and arguments without mutating the invoking shell.
resetFixture()
testManifest = {schema=1, packages={foo=program()}}
shellAPI.getRunningProgram = function() return "ccpm.lua" end
ccpm("install", "foo", "--commit", commit)
state = cjson.decode(files["/.ccpm/state.json"])
local programPath = state.packages[state.roots.foo.node].path .. "/main.lua"
files[programPath] = [[
    assert(shell.getRunningProgram() == arg[0]:gsub("^/", ""))
    assert(shell.getRunningProgram():match("/foo/main.lua$"))
    assert(arg[1] == "two words" and arg[2] == "--flag")
    local a, b = ...
    assert(a == arg[1] and b == arg[2])
]]
executePrograms = true
ccpm("run", "foo", "two words", "--flag")
assert(shellAPI.getRunningProgram() == "ccpm.lua")

-- Persistence errors must propagate and restore the previous in-memory value.
local originalSave = settings.save
for _, failure in ipairs({"false", "error"}) do
    settingValues["ccpm.auto_update"] = true
    settings.save = function()
        if failure == "error" then error("disk full") end
        return false
    end
    local ok, reason = pcall(ccpm, "set", "auto-update", "off")
    assert(not ok and reason:find("Could not save"))
    assert(settingValues["ccpm.auto_update"] == true)
    settingValues["ccpm.startup_package"] = "foo"
    originalLock = files["/.ccpm/state.json"]
    assert(not pcall(ccpm, "remove", "foo"))
    assert(files["/.ccpm/state.json"] == originalLock)
    assert(settingValues["ccpm.startup_package"] == "foo")
end
settings.save = originalSave
seedRuntime()
settings.save = function() return false end
local previousReboots, previousInstalls = reboots, installs
os.reboot = function() reboots = reboots + 1 end
assert(loadfile(root .. "/bootstrap.lua", "t", bootstrapEnvironment))()
assert(reboots == previousReboots and installs == previousInstalls)
settings.save, os.reboot, http.get = originalSave, oldReboot, fixtureGet

-- Do not silently turn a misspelled pin into a branch-tracking install.
resetFixture()
testManifest = {schema=1, packages={foo=program(), helper=library("helper")}}
for _, command in ipairs({
    {"install", "foo", "--comit", commit},
    {"install", "foo", "--commit", "--startup"},
    {"install", "foo", "--branch", "main", "--branch", "other"},
    {"install", "foo", "unexpected"},
    {"available", "unexpected"}, {"update", "foo", "unexpected"},
    {"install", "foo", "--version", "main"},
    {"install", "foo", "--repo", "owner/.."},
}) do
    assert(not pcall(ccpm, table.unpack(command)))
    assert(not fs.exists("/.ccpm/state.json"))
end
ccpm("install", "foo", "--repo", "owner/.github", "--commit", commit)
originalLock = files["/.ccpm/state.json"]
assert(not pcall(ccpm, "install", "helper", "--commit", commit, "--startup"))
assert(files["/.ccpm/state.json"] == originalLock)
ccpm("install", "helper", "--commit", commit)
assert(not pcall(ccpm, "set", "startup", "helper"))

-- Both the graph and a release's declared version must be validated before activation.
resetFixture()
testManifest = {schema=1, packages={foo=program()}}
ccpm("install", "foo", "--commit", commit)
originalLock = files["/.ccpm/state.json"]
testManifest.packages.foo.version = "2.0.0"
assert(not pcall(ccpm, "pin", "foo", "--version", "1.0.0"))
assert(files["/.ccpm/state.json"] == originalLock)
testManifest.packages.foo.version = "1.0.0"
remoteCommit = string.rep("b", 40)
http.get = function(url, headers, binary)
    if url:match("/main.lua$") then
        return {getResponseCode=function() return 200 end, readAll=function() return "not valid Lua!" end, close=function() end}
    end
    return fixtureGet(url, headers, binary)
end
assert(not pcall(ccpm, "track", "foo", "main"))
assert(files["/.ccpm/state.json"] == originalLock)
http.get = fixtureGet

-- Resolve each moving reference once per transaction, even in a diamond graph.
resetFixture()
testManifest = {schema=1, packages={
    foo=program({a="*", b="*"}),
    a=library("a", {shared={repo="other/repo", branch="main"}}),
    b=library("b", {shared={repo="other/repo", branch="main"}}),
    shared=library("shared"),
}}
local resolutions = 0
http.get = function(url, ...)
    if url:find("api.github.com", 1, true) then
        assert(url:find("refs%%2Fheads%%2Fmain"))
        resolutions = resolutions + 1
        remoteCommit = string.rep(resolutions == 1 and "b" or "c", 40)
    end
    return fixtureGet(url, ...)
end
ccpm("install", "foo", "--commit", commit)
assert(resolutions == 1)
http.get = fixtureGet

-- Recover cached packages after errors and hard power loss, without dropping
-- the lockfile or the previously runnable entrypoint.
local function seedRepair()
    resetFixture()
    testManifest = {schema=1, packages={foo=program()}}
    testManifest.packages.foo.files[2] = {source="optional.bin", target="optional.bin"}
    ccpm("install", "foo", "--commit", commit)
    local saved = cjson.decode(files["/.ccpm/state.json"])
    local path = saved.packages[saved.roots.foo.node].path
    files[path .. "/optional.bin"] = nil
    executePrograms = true
    ccpm("run", "foo")
    return path, files["/.ccpm/state.json"]
end
local repairDirectory, repairLock = seedRepair()
local failedOnce = false
fs.move = function(source, target)
    if target == repairDirectory and source:find("/staging/", 1, true) and not failedOnce then
        failedOnce = true
        error("cache activation failed")
    end
    return originalMove(source, target)
end
assert(not pcall(ccpm, "install", "foo", "--commit", commit))
assert(files["/.ccpm/state.json"] == repairLock and files[repairDirectory .. "/main.lua"])
ccpm("run", "foo")
fs.move = originalMove
for crashAt = 1, 4 do
    repairDirectory, repairLock = seedRepair()
    local mutations = 0
    local function checkpoint()
        mutations = mutations + 1
        if mutations == crashAt then coroutine.yield("power loss") end
    end
    fs.move = function(source, target)
        originalMove(source, target)
        if target == "/.ccpm/cache-repair.json" or source == repairDirectory or target == repairDirectory then checkpoint() end
    end
    fs.delete = function(path)
        originalDelete(path)
        if path == "/.ccpm/cache-repair.json" then checkpoint() end
    end
    local task = coroutine.create(function() ccpm("install", "foo", "--commit", commit) end)
    local ok, reason = coroutine.resume(task)
    assert(ok and reason == "power loss", tostring(reason))
    fs.move, fs.delete = originalMove, originalDelete
    _G.__ccpm_write_lock = nil
    ccpm("run", "foo")
    assert(files["/.ccpm/state.json"] == repairLock)
    assert(fs.exists(repairDirectory .. "/optional.bin") == (crashAt == 4))
    assert(not fs.exists("/.ccpm/cache-repair.json"))
end

-- HTTP handles are always closed, including when reading their bodies fails.
resetFixture()
local closed = false
http.get = function()
    return {getResponseCode=function() return 200 end, readAll=function() error("read failed") end, close=function() closed=true end}
end
assert(not pcall(ccpm, "available"))
assert(closed and not _G.__ccpm_write_lock)
http.get = fixtureGet
-- A cached graph node still has to satisfy each incoming version selector.
resetFixture()
testManifest = {schema=1, packages={
    foo=program({a="*", b="*"}),
    a=library("a", {shared="*"}),
    b=library("b", {shared="2.0.0"}),
    shared=library("shared"),
}}
assert(not pcall(ccpm, "install", "foo", "--commit", commit))
assert(not fs.exists("/.ccpm/state.json"))

-- CraftOS must preserve JSON nulls for validation, including trailing array
-- elements which would otherwise disappear and look like valid file lists.
local originalDecode, originalNull = textutils.unserializeJSON, textutils.json_null
textutils.json_null = {}
textutils.unserializeJSON = function(_, options)
    assert(options and options.parse_null)
    return {schema=1, packages={foo={version="1.0.0", kind="program", entrypoint="main.lua",
        files={{source="main.lua", target="main.lua"}, textutils.json_null}}}}
end
local nullOk, nullError = pcall(ccpm, "install", "foo", "--commit", commit)
assert(not nullOk and nullError:find("Unexpected JSON null"))
textutils.unserializeJSON, textutils.json_null = originalDecode, originalNull

-- State write and activation failures retain the previously runnable lock.
local originalOpen = fs.open
for _, failure in ipairs({"open", "write", "close", "move"}) do
    resetFixture()
    testManifest = {schema=1, packages={foo=program()}}
    ccpm("install", "foo", "--branch", "main")
    originalLock = files["/.ccpm/state.json"]
    remoteCommit = string.rep("b", 40)
    local closedHandle = false
    fs.open = function(path, mode)
        if path ~= "/.ccpm/state.json.new" or mode ~= "wb" then return originalOpen(path, mode) end
        if failure == "open" then return nil, "disk full" end
        local handle = originalOpen(path, mode)
        local write, close = handle.write, handle.close
        handle.write = function(value)
            if failure == "write" then write("partial"); error("disk full") end
            write(value)
        end
        handle.close = function()
            closedHandle = true
            close()
            if failure == "close" then error("flush failed") end
        end
        return handle
    end
    fs.move = function(source, target)
        if failure == "move" and source == "/.ccpm/state.json.new" then error("commit failed") end
        originalMove(source, target)
    end
    assert(not pcall(ccpm, "update", "foo"))
    assert(files["/.ccpm/state.json"] == originalLock and not _G.__ccpm_write_lock)
    if failure ~= "open" then assert(closedHandle) end
    fs.open, fs.move = originalOpen, originalMove
    executePrograms = true
    ccpm("run", "foo")
end

-- Cleanup errors after a commit must not let later updates overwrite that
-- committed root with an obsolete in-memory snapshot.
resetFixture()
testManifest = {schema=1, packages={foo=program(), bar=program()}}
ccpm("install", "foo", "--branch", "main")
ccpm("install", "bar", "--branch", "main")
remoteCommit = string.rep("b", 40)
local failedCleanup = false
fs.delete = function(path)
    if path == "/.ccpm/state.json.old" and not failedCleanup then
        failedCleanup = true
        error("backup cleanup failed")
    end
    originalDelete(path)
end
ccpm("update")
fs.delete = originalDelete
state = cjson.decode(files["/.ccpm/state.json"])
assert(failedCleanup and state.roots.foo.resolved == remoteCommit and state.roots.bar.resolved == remoteCommit)
assert(not _G.__ccpm_write_lock)
-- Help is available offline and never opens state, writes settings, or takes
-- the mutation lock. Package arguments which happen to be --help are forwarded.
local hostPrint, savedPagedPrint = print, textutils.pagedPrint
local output = {}
print = function(value) output[#output + 1] = tostring(value or "") end
textutils.pagedPrint = function(message)
    assert(not _G.__ccpm_write_lock)
    output[#output + 1] = message
end
local function outputContains(value) return table.concat(output, "\n"):find(value, 1, true) end
resetFixture()
http.get = function() error("help must not request the network") end
settings.save = function() error("help must not save settings") end
fs.open = function() error("help must not open state") end
for _, command in ipairs({{}, {"--help"}, {"help", "install"}, {"install", "--help"}, {"available", "--help"}}) do
    output = {}
    ccpm(table.unpack(command))
    assert(#output > 0)
end
assert(outputContains("--version") and outputContains("--commit"))
output = {}
ccpm("set")
assert(outputContains("Startup program: off") and outputContains("Auto-update: on"))
fs.open, settings.save, http.get = originalOpen, originalSave, fixtureGet
output = {}
ccpm("update")
assert(outputContains("No packages installed") and outputContains("ccpm available"))
local errorCount = #errors
local typoOk, typoError = pcall(ccpm, "udpate")
assert(not typoOk and typoError:find("ccpm help", 1, true) and #errors == errorCount)

testManifest = {schema=1, packages={foo=program()}}
ccpm("install", "foo", "--commit", commit, "--startup")
output = {}
ccpm("list")
assert(outputContains("Pinned commit:") and outputContains("program | startup") and outputContains("Repo:"))
assert(not _G.__ccpm_write_lock)
ccpm("run", "foo", "--help")
assert(lastRun.arguments[1] == "--help")
settingValues["shell.allow_startup"] = false
output = {}
ccpm("set", "startup", "foo")
assert(outputContains("set shell.allow_startup true"))

-- Test actual CraftOS word wrapping and paging at turtle and computer sizes.
-- The fixture records each screen before scrolling so output remains inspectable.
if upstreamDirectory then
    testManifest.packages.bar, testManifest.packages.baz = program(), program()
    ccpm("install", "bar", "--branch", "main")
    ccpm("install", "baz", "--branch", "main")
    local terminalFixture = assert(loadfile(root .. "/tests/terminal_fixture.lua"))()
    for _, size in ipairs({{39, 13}, {51, 19}}) do
        local fixture = terminalFixture(upstreamDirectory, size[1], size[2])
        local savedTerm = term
        term, print, textutils.pagedPrint = fixture.term, fixture.print, fixture.pagedPrint
        ccpm("help")
        if size[2] == 13 then assert(fixture.prompts() > 0, "long help must pause before scrolling away") end
        ccpm("help", "install")
        ccpm("list")
        ccpm("available")
        assert(fixture.prompts() > 0, "long listings must pause before scrolling away")
        local transcript = fixture.transcript()
        assert(transcript:find("Pinned commit:", 1, true))
        assert(transcript:find("--startup", 1, true))
        assert(transcript:find("program | startup", 1, true))
        local snapshotDirectory = os.getenv("CCPM_UX_SNAPSHOTS")
        if snapshotDirectory then
            local file = assert(io.open(snapshotDirectory .. "/" .. size[1] .. "x" .. size[2] .. ".txt", "w"))
            file:write(transcript)
            file:close()
        end
        fixture.terminateOnPrompt()
        assert(not pcall(ccpm, "list"))
        assert(not _G.__ccpm_write_lock and fixture.term.current() == fixture.native)
        term, print, textutils.pagedPrint = savedTerm, hostPrint, savedPagedPrint
    end
    -- The real CraftOS os.run should display a manager failure exactly once.
    files["/ccpm.lua"] = hostRead("ccpm.lua")
    executePrograms = true
    errorCount = #errors
    assert(not os.run(cliEnvironment, "/ccpm.lua", "udpate"))
    assert(#errors == errorCount + 1)
end
print, textutils.pagedPrint = hostPrint, savedPagedPrint

-- Bootstrap help needs no network. Hardware checks use package requirements.
http.get = function() error("bootstrap must not request the network") end
local bootstrapWithoutTurtle = setmetatable({turtle=false}, {__index=bootstrapEnvironment})
assert(loadfile(root .. "/bootstrap.lua", "t", bootstrapWithoutTurtle))("--help")
http.get = fixtureGet

-- A hardware failure does not activate a package, even when installed by SHA.
resetFixture()
testManifest = {schema=1, packages={foo=program()}}
testManifest.packages.foo.requires = {turtle=true}
turtle = nil
local deviceOk, deviceError = pcall(ccpm, "install", "foo", "--commit", commit)
assert(not deviceOk and deviceError:find("requires a turtle", 1, true))
assert(not files["/.ccpm/state.json"])
turtle = {}

-- Stable defaults never fall back to an untested moving branch.
resetFixture()
testManifest = {schema=1, packages={foo=program()}}
local requested = {}
http.get = function(url, ...)
    requested[#requested+1] = url
    return fixtureGet(url, ...)
end
ccpm("install", "foo")
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots.foo.selector.kind == "stable")
assert(requested[1]:match("/releases/latest$") and requested[2]:find("refs%%2Ftags%%2Fv1.0.0"))
local stableLock = files["/.ccpm/state.json"]
http.get = function() return {getResponseCode=function() return 404 end, readAll=function() return '{}' end, close=function() end} end
assert(not pcall(ccpm, "update", "foo"))
assert(files["/.ccpm/state.json"] == stableLock)
http.get = fixtureGet

-- Rollback and pruning retain both dependency graphs, without network access.
resetFixture()
testManifest = {schema=1, packages={foo=program({helper="*"}), helper=library("helper")}}
ccpm("install", "foo", "--branch", "main")
local firstCommit = commit
remoteCommit = string.rep("b", 40)
ccpm("update", "foo")
local secondCommit = remoteCommit
remoteCommit = string.rep("c", 40)
ccpm("update", "foo")
state = cjson.decode(files["/.ccpm/state.json"])
local activePath = state.packages[state.roots.foo.node].path
local previousPath = state.packages[state.roots.foo.previous.node].path
http.get = function() error("offline command requested network") end
local beforePrune = files["/.ccpm/state.json"]
ccpm("prune", "--dry-run")
assert(files["/.ccpm/state.json"] == beforePrune)
ccpm("prune")
assert(fs.exists(activePath) and fs.exists(previousPath))
assert(not fs.exists("/.ccpm/store/FottenSC_computerCraft/" .. firstCommit .. "/foo"))
ccpm("rollback", "foo")
state = cjson.decode(files["/.ccpm/state.json"])
assert(state.roots.foo.resolved == secondCommit and state.roots.foo.selector.kind == "commit")
executePrograms = true
ccpm("run", "foo")
ccpm("version")
ccpm("info", "foo")
ccpm("doctor")
ccpm("prune")
ccpm("rollback", "foo")
assert(cjson.decode(files["/.ccpm/state.json"]).roots.foo.resolved == remoteCommit)
http.get = fixtureGet

-- An unrelated startup survives install, self-update and uninstall.
seedRuntime()
ccpm("self-update", "--commit", commit)
assert(files["/.ccpm/previous-runtime/ccpm.lua"] == oldManager)
ccpm("uninstall")
assert(not fs.exists("/ccpm.lua") and not fs.exists("/startup/10-ccpm.lua"))
assert(files["/startup.lua"] == "-- user startup\nreturn true")

-- Migrating the old ccpm wrapper saves it permanently, without double launch.
seedRuntime()
files["/startup.lua"] = oldStartup
ccpm("self-update", "--commit", commit)
assert(not fs.exists("/startup.lua") and files["/.ccpm/legacy-startup.lua"] == oldStartup)

-- Corrupt future-version journals must not touch unrelated startup files.
seedRuntime()
files["/.ccpm/runtime-update/pending.json"] = cjson.encode({schema=3, ["ccpm.lua"]=false, ["startup.lua"]=false})
local installer = assert(load(startupSource, "@installer", "t", _ENV))("--installer")
assert(not pcall(installer.recover))
unchangedRuntime()

-- Invalid block-checker settings fail before any physical action.
for _, configuration in ipairs({
    {allowed={}, delay=0.5}, {allowed={"stone"}, delay=0.5},
    {allowed={"minecraft:stone"}, delay=-1}, {allowed={"minecraft:stone"}, delay=math.huge},
    {allowed={"minecraft:stone"}, delay=0.5, count=math.huge},
}) do
    local physicalCalls = 0
    local environment = setmetatable({
        require=function() return {info=function() end} end,
        settings={define=function() end, get=function(name, fallback)
            if name == "blockChecker.allowed_blocks" then return configuration.allowed end
            if name == "blockChecker.delay" then return configuration.delay end
            return configuration.count or fallback
        end},
        turtle={inspectDown=function() physicalCalls=physicalCalls+1; error("physical action") end},
    }, {__index=_G})
    assert(not pcall(assert(load(hostRead("projects/blockChecker/main.lua"), "@block-checker", "t", environment))))
    assert(physicalCalls == 0)
end
print("ccpm runtime tests: ok")
