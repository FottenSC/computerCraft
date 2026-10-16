-- ccpm: a GitHub-backed package manager for CC:Tweaked.
-- Packages are described by ccpm-package.json and installed from immutable commits.

local args = { ... }
local unpack = table.unpack or unpack

local CCPM_ROOT = "/.ccpm"
local STORE_ROOT = CCPM_ROOT .. "/store"
local STAGING_ROOT = CCPM_ROOT .. "/staging"
local STATE_PATH = CCPM_ROOT .. "/state.json"
local REPAIR_PATH = CCPM_ROOT .. "/cache-repair.json"
local MANIFEST_NAME = "ccpm-package.json"
local DEFAULT_REPOSITORY = "FottenSC/computerCraft"

settings.define("ccpm.default_repo", {
    description = "Default GitHub owner/repository used by ccpm",
    default = DEFAULT_REPOSITORY,
    type = "string",
})
settings.define("ccpm.auto_update", {
    description = "Update branch-tracked ccpm packages during startup",
    default = true,
    type = "boolean",
})
settings.define("ccpm.startup_package", {
    description = "Installed package to run after ccpm startup",
    default = "",
    type = "string",
})

local function fail(message, level)
    error(tostring(message), (level or 1) + 1)
end

-- CraftOS tabs share _G. Acquisition does not yield, and a reboot clears it.
local function withLock(callback)
    if _G.__ccpm_write_lock then fail("Another ccpm command is in progress; retry when it finishes", 1) end
    _G.__ccpm_write_lock = true
    local ok, result = pcall(callback)
    _G.__ccpm_write_lock = nil
    if not ok then error(result, 0) end
    return result
end

local function readFile(path)
    local handle, reason = fs.open(path, "rb")
    if not handle then
        if fs.exists(path) then fail(reason or ("Cannot read " .. path), 1) end
        return nil
    end
    local ok, value = pcall(handle.readAll)
    handle.close()
    if not ok then error(value, 0) end
    return value
end

local function writeFile(path, value)
    local directory = fs.getDir(path)
    if directory ~= "" then fs.makeDir(directory) end
    local handle, reason = fs.open(path, "wb")
    if not handle then fail(reason or ("Cannot write " .. path), 1) end
    local ok, writeError = pcall(handle.write, value)
    handle.close()
    if not ok then error(writeError, 0) end
end

local function decodeJson(value, description)
    -- Preserve nulls so malformed fields cannot disappear during decoding.
    local ok, result = pcall(textutils.unserializeJSON, value, { parse_null = true })
    if not ok or type(result) ~= "table" then
        fail("Invalid JSON in " .. description, 1)
    end
    local function rejectNulls(item)
        if item == textutils.json_null then fail("Unexpected JSON null in " .. description, 1) end
        if type(item) == "table" then
            for _, child in pairs(item) do rejectNulls(child) end
        end
    end
    rejectNulls(result)
    return result
end

local function defaultState()
    return { schema = 1, roots = {}, packages = {} }
end

local recoverCacheRepair
local function loadState()
    recoverCacheRepair()
    -- A shutdown between the two moves in saveState leaves only the backup.
    if not fs.exists(STATE_PATH) and fs.exists(STATE_PATH .. ".old") then
        fs.move(STATE_PATH .. ".old", STATE_PATH)
    end
    local raw = readFile(STATE_PATH)
    if not raw then return defaultState() end
    local state = decodeJson(raw, STATE_PATH)
    if state.schema ~= 1 or type(state.roots) ~= "table" or type(state.packages) ~= "table" then
        fail("Unsupported or corrupt ccpm state file", 1)
    end
    return state
end

local function saveSettings(changes)
    local previous = {}
    for name, value in pairs(changes) do
        previous[name] = settings.get(name)
        settings.set(name, value)
    end
    local ok, saved = pcall(settings.save)
    if not ok or not saved then
        for name in pairs(changes) do
            if previous[name] == nil then settings.unset(name) else settings.set(name, previous[name]) end
        end
        fail("Could not save /.settings: " .. (ok and "settings.save returned false" or tostring(saved)), 1)
    end
end

local function saveState(state)
    fs.makeDir(CCPM_ROOT)
    local temporary = STATE_PATH .. ".new"
    local backup = STATE_PATH .. ".old"
    writeFile(temporary, textutils.serializeJSON(state))

    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(STATE_PATH) then fs.move(STATE_PATH, backup) end
    local ok, reason = pcall(fs.move, temporary, STATE_PATH)
    if not ok then
        if fs.exists(backup) then fs.move(backup, STATE_PATH) end
        fail("Could not commit package state: " .. tostring(reason), 1)
    end
    -- The state is committed. A leftover backup must not make a caller reuse
    -- its stale in-memory snapshot after a successful commit.
    if fs.exists(backup) then
        local cleaned, cleanupError = pcall(fs.delete, backup)
        if not cleaned then printError("State committed; backup cleanup pending: " .. tostring(cleanupError)) end
    end
end

local function sortedKeys(value)
    local result = {}
    for key in pairs(value or {}) do result[#result + 1] = key end
    table.sort(result)
    return result
end

local function urlEncode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(character)
        return ("%%%02X"):format(string.byte(character))
    end))
end

local function request(url)
    if not http then fail("The HTTP API is disabled in the CC:Tweaked config", 1) end
    local response, reason, failedResponse = http.get(url, {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "ccpm/1",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }, true)
    response = response or failedResponse
    if not response then fail("HTTP request failed: " .. tostring(reason), 1) end

    local code = response.getResponseCode()
    local readOk, body = pcall(response.readAll)
    response.close()
    if not readOk then fail("Could not read HTTP response: " .. tostring(body), 1) end
    if code < 200 or code >= 300 then
        local message = ""
        local ok, json = pcall(textutils.unserializeJSON, body)
        if ok and type(json) == "table" and type(json.message) == "string" then message = ": " .. json.message end
        fail("HTTP " .. code .. " for " .. url .. message, 1)
    end
    return body
end

local function validateRepository(repository)
    if type(repository) ~= "string" or not repository:match("^[A-Za-z0-9][A-Za-z0-9%-]*/[A-Za-z0-9%._%-]+$")
        or repository:match("/%.%.?$") then
        fail("Repository must be in owner/name form", 1)
    end
end

local function validVersion(value)
    return type(value) == "string" and (value:match("^[0-9]+%.[0-9]+%.[0-9]+$")
        or value:match("^[0-9]+%.[0-9]+%.[0-9]+%-[0-9A-Za-z%.%-]+$"))
end

local function isArray(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    for index = 1, count do if value[index] == nil then return false end end
    return true
end

local function validateRelativePath(path, label)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:sub(-1) == "/"
        or path:find("\\", 1, true) or path:find("//", 1, true)
        or not path:match("^[%w%._%-%/]+$")
        or path == "." or path:match("^%./") or path:match("/%./") or path:match("/%.$")
        or path:match("^%.%.$") or path:match("^%.%./")
        or path:match("/%.%./") or path:match("/%.%.$") then
        fail("Unsafe " .. label .. ": " .. tostring(path), 1)
    end
end

local function safeName(value)
    return (value:gsub("[^%w%._%-]", "_"))
end

local commitCache = {}
local function resolveCommit(repository, selector)
    validateRepository(repository)
    if type(selector.value) ~= "string" or selector.value == "" then
        fail("Selector must be a non-empty string", 1)
    end
    if selector.kind == "commit" then
        if not selector.value:match("^[0-9a-fA-F]+$") or #selector.value ~= 40 then
            fail("Commit must be an exact 40-character hexadecimal SHA", 1)
        end
        return selector.value:lower()
    end

    if selector.kind ~= "branch" and selector.kind ~= "version" then fail("Invalid selector kind", 1) end
    if selector.kind == "version" and not validVersion(selector.value:gsub("^v", "")) then
        fail("Version must look like 1.2.3", 1)
    end
    local cacheKey = repository .. ":" .. selector.kind .. ":" .. selector.value
    if commitCache[cacheKey] then return commitCache[cacheKey] end

    local reference = selector.value
    if selector.kind == "version" and not reference:match("^v") then reference = "v" .. reference end
    reference = (selector.kind == "version" and "refs/tags/" or "refs/heads/") .. reference
    local url = "https://api.github.com/repos/" .. repository .. "/commits/" .. urlEncode(reference)
    local result = decodeJson(request(url), "GitHub commit response")
    if type(result.sha) ~= "string" or #result.sha ~= 40 or not result.sha:match("^[0-9a-fA-F]+$") then
        fail("GitHub did not return a commit for " .. repository .. "@" .. reference, 1)
    end
    commitCache[cacheKey] = result.sha:lower()
    return commitCache[cacheKey]
end

local manifestCache = {}

local function getManifest(repository, commit)
    local key = repository .. "@" .. commit
    if manifestCache[key] then return manifestCache[key] end
    local url = "https://raw.githubusercontent.com/" .. repository .. "/" .. commit .. "/" .. MANIFEST_NAME
    local manifest = decodeJson(request(url), repository .. "/" .. MANIFEST_NAME)
    if manifest.schema ~= 1 or type(manifest.packages) ~= "table" then
        fail("Unsupported package manifest in " .. repository .. "@" .. commit:sub(1, 7), 1)
    end
    manifestCache[key] = manifest
    return manifest
end

local function parseDependency(parentRepository, parentCommit, dependencyName, specification)
    if specification == "*" then
        return parentRepository, { kind = "commit", value = parentCommit }
    elseif type(specification) == "string" then
        return parentRepository, { kind = "version", value = specification }
    elseif type(specification) == "table" then
        local repository = specification.repo
        if repository == nil then repository = parentRepository end
        local choices = {
            branch = specification.branch,
            version = specification.version,
            commit = specification.commit,
        }
        local kind, value
        for candidate, candidateValue in pairs(choices) do
            if candidateValue ~= nil then
                if kind then fail("Dependency " .. dependencyName .. " has multiple selectors", 1) end
                kind, value = candidate, candidateValue
            end
        end
        if not kind then fail("Dependency " .. dependencyName .. " has no selector", 1) end
        return repository, { kind = kind, value = value }
    end
    fail("Invalid dependency specification for " .. dependencyName, 1)
end

local function validatePackage(name, packageDefinition)
    if type(name) ~= "string" or not name:match("^[a-z0-9][a-z0-9%._%-]*$") then
        fail("Invalid package name " .. tostring(name), 1)
    end
    if type(packageDefinition) ~= "table" then fail("Invalid package " .. name, 1) end
    if packageDefinition.kind ~= "program" and packageDefinition.kind ~= "library" then
        fail("Package " .. name .. " must be a program or library", 1)
    end
    if not validVersion(packageDefinition.version) then
        fail("Package " .. name .. " has an invalid version", 1)
    end
    if not isArray(packageDefinition.files) or #packageDefinition.files == 0 then
        fail("Package " .. name .. " has no files", 1)
    end
    if packageDefinition.kind == "program" then
        validateRelativePath(packageDefinition.entrypoint, "entrypoint")
    end
    local targets = {}
    for _, file in ipairs(packageDefinition.files) do
        if type(file) ~= "table" then fail("Invalid file in package " .. name, 1) end
        validateRelativePath(file.source, "source path")
        validateRelativePath(file.target, "target path")
        if file.target:match("^[^/]+") == ".complete" or file.target:match("^[^/]+") == ".package.json" then
            fail("Package " .. name .. " uses reserved target " .. file.target, 1)
        end
        if targets[file.target] then fail("Duplicate target " .. file.target .. " in " .. name, 1) end
        targets[file.target] = true
    end
    for target in pairs(targets) do
        local prefix = ""
        for segment in target:gmatch("[^/]+") do
            prefix = prefix == "" and segment or (prefix .. "/" .. segment)
            if prefix ~= target and targets[prefix] then
                fail("Conflicting targets " .. prefix .. " and " .. target .. " in " .. name, 1)
            end
        end
    end
    if packageDefinition.kind == "program" and not targets[packageDefinition.entrypoint] then
        fail("Entrypoint is not a file target in package " .. name, 1)
    end
    if packageDefinition.dependencies ~= nil and type(packageDefinition.dependencies) ~= "table" then
        fail("Invalid dependencies in package " .. name, 1)
    end
    for dependencyName in pairs(packageDefinition.dependencies or {}) do
        if type(dependencyName) ~= "string" or not dependencyName:match("^[a-z0-9][a-z0-9%._%-]*$") then
            fail("Invalid dependency name in package " .. name, 1)
        end
    end
end

local function moduleNames(targets)
    local names = {}
    local function add(name)
        -- require translates every dot to '/', so dotted basenames such as
        -- README.txt are data files, not module providers.
        if name ~= "" and not name:find(".", 1, true) then names[name] = true end
    end
    for _, target in ipairs(targets) do
        add(target)
        local name = target:match("^(.*)%.lua$")
        if name then
            add(name)
            local directory = name:match("^(.*)/init$")
            if directory then add(directory) end
        end
    end
    return sortedKeys(names)
end

local function validateModuleProviders(graph)
    local providers, versions = {}, {}
    for _, key in ipairs(sortedKeys(graph)) do
        local node = graph[key]
        local identity = node.repo .. ":" .. node.name
        if versions[identity] and versions[identity] ~= node.commit then
            fail("Conflicting commits for " .. identity .. " in one dependency graph", 1)
        end
        versions[identity] = node.commit
        local names = node.modules
        if not names then
            -- Older lockfiles did not record module names.
            local targets = {}
            local function visit(directory, prefix)
                for _, name in ipairs(fs.list(directory)) do
                    local relative = prefix .. name
                    if fs.isDir(directory .. "/" .. name) then
                        visit(directory .. "/" .. name, relative .. "/")
                    elseif relative ~= ".complete" and relative ~= ".package.json" then
                        targets[#targets + 1] = relative
                    end
                end
            end
            visit(node.path, "")
            names = moduleNames(targets)
        end
        for _, name in ipairs(names) do
            if providers[name] and providers[name] ~= key then
                fail("Conflicting module " .. name .. " provided by " .. providers[name] .. " and " .. key, 1)
            end
            providers[name] = key
        end
    end
end

local function nodeKey(repository, commit, packageName)
    return repository .. "@" .. commit .. ":" .. packageName
end

local function packagePath(repository, commit, packageName)
    return STORE_ROOT .. "/" .. safeName(repository) .. "/" .. commit .. "/" .. safeName(packageName)
end

recoverCacheRepair = function()
    local raw = readFile(REPAIR_PATH)
    if not raw then return end
    local journal = decodeJson(raw, REPAIR_PATH)
    validateRelativePath(journal.relative, "cache recovery path")
    local repository, commit, name = journal.relative:match("^([A-Za-z0-9_%.%-]+)/([0-9a-f]+)/([a-z0-9][a-z0-9%._%-]*)$")
    if not repository or #commit ~= 40 then fail("Invalid cache recovery journal", 1) end
    local path = STORE_ROOT .. "/" .. journal.relative
    local backup = CCPM_ROOT .. "/backups/" .. journal.relative
    if fs.exists(backup) then
        if fs.exists(path) then fs.delete(path) end
        fs.makeDir(fs.getDir(path))
        fs.move(backup, path)
    elseif not fs.exists(path) then
        fail("Cache recovery requires a missing backup: " .. backup, 1)
    end
    fs.delete(REPAIR_PATH)
end

local function resolveGraph(repository, selector, packageName, graph, visiting)
    local commit = resolveCommit(repository, selector)
    local key = nodeKey(repository, commit, packageName)
    if graph[key] then
        if selector.kind == "version" and graph[key].version ~= selector.value:gsub("^v", "") then
            fail("Package " .. packageName .. " version does not match requested release " .. selector.value, 1)
        end
        return key, commit
    end
    if visiting[key] then fail("Circular dependency involving " .. packageName, 1) end
    visiting[key] = true

    local manifest = getManifest(repository, commit)
    local definition = manifest.packages[packageName]
    if not definition then
        fail("Package " .. packageName .. " does not exist in " .. repository .. "@" .. commit:sub(1, 7), 1)
    end
    validatePackage(packageName, definition)
    if selector.kind == "version" and definition.version ~= selector.value:gsub("^v", "") then
        fail("Package " .. packageName .. " version does not match requested release " .. selector.value, 1)
    end

    local dependencies = {}
    for _, dependencyName in ipairs(sortedKeys(definition.dependencies)) do
        local dependencyRepository, dependencySelector = parseDependency(
            repository, commit, dependencyName, definition.dependencies[dependencyName])
        local dependencyKey = resolveGraph(
            dependencyRepository, dependencySelector, dependencyName, graph, visiting)
        dependencies[#dependencies + 1] = dependencyKey
    end

    local targets = {}
    for _, file in ipairs(definition.files) do targets[#targets + 1] = file.target end
    graph[key] = {
        name = packageName,
        repo = repository,
        commit = commit,
        version = definition.version,
        kind = definition.kind,
        entrypoint = definition.entrypoint,
        path = packagePath(repository, commit, packageName),
        dependencies = dependencies,
        modules = moduleNames(targets),
        definition = definition,
    }
    visiting[key] = nil
    return key, commit
end

local function installNode(node)
    local completeMarker = node.path .. "/.complete"
    local complete = not fs.isDir(completeMarker) and readFile(completeMarker) == node.commit
    if complete then
        for _, file in ipairs(node.definition.files) do
            if not fs.exists(node.path .. "/" .. file.target) or fs.isDir(node.path .. "/" .. file.target) then
                complete = false
                break
            end
        end
    end
    if complete then return end

    local staging = STAGING_ROOT .. node.path:sub(#STORE_ROOT + 1)
    if fs.exists(staging) then fs.delete(staging) end
    fs.makeDir(staging)

    for _, file in ipairs(node.definition.files) do
        local url = "https://raw.githubusercontent.com/" .. node.repo .. "/" .. node.commit .. "/" .. file.source
        local target = staging .. "/" .. file.target
        print("  " .. node.name .. ": " .. file.target)
        local body = request(url)
        if file.target:match("%.lua$") or file.target == node.entrypoint then
            local compiled, syntaxError = load(body, "@" .. file.target, "t", {})
            if not compiled then fail("Invalid Lua in " .. node.name .. "/" .. file.target .. ": " .. tostring(syntaxError), 1) end
        end
        writeFile(target, body)
    end

    writeFile(staging .. "/.package.json", textutils.serializeJSON({
        name = node.name,
        repo = node.repo,
        commit = node.commit,
        version = node.version,
        kind = node.kind,
    }))
    writeFile(staging .. "/.complete", node.commit)

    fs.makeDir(fs.getDir(node.path))
    if not fs.exists(node.path) then fs.move(staging, node.path) return end

    local relative = node.path:sub(#STORE_ROOT + 2)
    local backup = CCPM_ROOT .. "/backups/" .. relative
    if fs.exists(backup) then fs.delete(backup) end
    fs.makeDir(fs.getDir(backup))
    writeFile(REPAIR_PATH .. ".new", textutils.serializeJSON({ relative = relative }))
    fs.move(REPAIR_PATH .. ".new", REPAIR_PATH)
    local ok, reason = pcall(function()
        fs.move(node.path, backup)
        fs.move(staging, node.path)
        fs.delete(REPAIR_PATH) -- Commit the repaired directory before cleanup.
    end)
    if not ok then
        local restored, recoveryError = pcall(recoverCacheRepair)
        fail(tostring(reason) .. (restored and "" or ("; cache recovery pending: " .. tostring(recoveryError))), 1)
    end
    if fs.exists(backup) then fs.delete(backup) end
end

local function installRoot(state, packageName, repository, selector, resolvedCommit, requireProgram)
    print(("Resolving %s from %s (%s %s)..."):format(
        packageName, repository, selector.kind, selector.value))
    local graph = {}
    local resolutionSelector = selector
    if resolvedCommit then resolutionSelector = { kind = "commit", value = resolvedCommit } end
    local rootKey, commit = resolveGraph(repository, resolutionSelector, packageName, graph, {})
    if selector.kind == "version" and graph[rootKey].version ~= selector.value:gsub("^v", "") then
        fail("Package version does not match requested release " .. selector.value, 1)
    end

    if (requireProgram or settings.get("ccpm.startup_package") == packageName) and graph[rootKey].kind ~= "program" then
        fail("Startup package must be a program: " .. packageName, 1)
    end

    validateModuleProviders(graph)
    for _, key in ipairs(sortedKeys(graph)) do installNode(graph[key]) end

    -- File contents are shared, but each root owns its dependency resolutions.
    -- Legacy unscoped nodes remain readable and are never overwritten here.
    local prefix = packageName .. "|"
    local nextState = { schema = 1, roots = {}, packages = {} }
    for name, root in pairs(state.roots) do nextState.roots[name] = root end
    for key, node in pairs(state.packages) do nextState.packages[key] = node end
    for key, node in pairs(graph) do
        node.definition = nil
        for index, dependency in ipairs(node.dependencies) do
            node.dependencies[index] = prefix .. dependency
        end
        nextState.packages[prefix .. key] = node
    end
    rootKey = prefix .. rootKey
    nextState.roots[packageName] = {
        name = packageName,
        repo = repository,
        selector = selector,
        resolved = commit,
        node = rootKey,
    }
    saveState(nextState)
    state.roots, state.packages = nextState.roots, nextState.packages
    print(("Installed %s %s at %s"):format(
        packageName, state.packages[rootKey].version, commit:sub(1, 7)))
end

local function updateRoot(state, name, force)
    local root = state.roots[name]
    if not root then fail("Package is not installed: " .. name, 1) end
    if root.selector.kind ~= "branch" then
        print(name .. " is pinned; skipping")
        return false
    end
    local commit = resolveCommit(root.repo, root.selector)
    if not force and commit == root.resolved and state.packages[root.node] then
        print(name .. " is already at " .. commit:sub(1, 7))
        return false
    end
    installRoot(state, name, root.repo, root.selector, commit)
    return true
end

local function parseOptions(values, startAt, allowed)
    local positional, options = {}, {}
    local index = startAt or 1
    while index <= #values do
        local value = values[index]
        if value:sub(1, 2) == "--" then
            local key = value:sub(3)
            if not allowed[key] then fail("Unknown option --" .. key, 1) end
            if options[key] ~= nil then fail("Duplicate option --" .. key, 1) end
        end
        if value == "--startup" then
            options.startup = true
        elseif value:sub(1, 2) == "--" then
            local key = value:sub(3)
            index = index + 1
            if index > #values or values[index]:sub(1, 2) == "--" then fail("Missing value for --" .. key, 1) end
            options[key] = values[index]
        else
            positional[#positional + 1] = value
        end
        index = index + 1
    end
    return positional, options
end

local function selectorFromOptions(options, defaultBranch)
    local found = {}
    for _, kind in ipairs({ "branch", "version", "commit" }) do
        if options[kind] then found[#found + 1] = kind end
    end
    if #found > 1 then fail("Choose only one of --branch, --version, or --commit", 1) end
    local kind = found[1] or "branch"
    return { kind = kind, value = options[kind] or defaultBranch or "main" }
end

local function collectLibraryPaths(state, nodeKeyValue, paths, visited)
    if visited[nodeKeyValue] then return end
    visited[nodeKeyValue] = true
    local node = state.packages[nodeKeyValue]
    if not node then fail("Lockfile refers to a missing package: " .. nodeKeyValue, 1) end
    for _, dependencyKey in ipairs(node.dependencies or {}) do
        collectLibraryPaths(state, dependencyKey, paths, visited)
    end
    paths[#paths + 1] = node.path .. "/?"
    paths[#paths + 1] = node.path .. "/?.lua"
    paths[#paths + 1] = node.path .. "/?/init.lua"
end

local function runPackage(state, name, programArguments)
    local root = state.roots[name]
    if not root then fail("Package is not installed: " .. name, 1) end
    local node = state.packages[root.node]
    if not node then fail("Installed package metadata is missing for " .. name, 1) end
    if node.kind ~= "program" then fail(name .. " is a library and cannot be run", 1) end

    local entrypoint = node.path .. "/" .. node.entrypoint
    if not fs.exists(entrypoint) then fail("Entrypoint is missing: " .. entrypoint, 1) end

    -- os.run replaces the metatable, so shell-local APIs must be direct fields.
    local packageShell = setmetatable({
        getRunningProgram = function() return (entrypoint:gsub("^/", "")) end,
    }, { __index = shell })
    local programArg = { [0] = entrypoint }
    for index, value in ipairs(programArguments or {}) do programArg[index] = value end
    local environment = setmetatable({ shell = packageShell, multishell = multishell, arg = programArg }, { __index = _ENV })
    local requireFactory = require("cc.require")
    environment.require, environment.package = requireFactory.make(environment, node.path)
    local paths = {}
    local visited, graph = {}, {}
    collectLibraryPaths(state, root.node, paths, visited)
    for key in pairs(visited) do graph[key] = state.packages[key] end
    validateModuleProviders(graph)
    environment.package.path = table.concat(paths, ";") .. ";" .. environment.package.path

    local ok, reason = os.run(environment, entrypoint, unpack(programArguments or {}))
    if not ok then fail(reason or (name .. " exited with an error"), 1) end
end

local function display(lines)
    local message = table.concat(lines, "\n")
    local _, y = term.getCursorPos()
    textutils.pagedPrint(message, math.max(0, y - 2))
end

local helpTopics = {
    install = {
        "ccpm install <name> [options]", "",
        "--repo owner/repo", "  Default: " .. settings.get("ccpm.default_repo"),
        "Choose one source:", "  --branch name (default: main)",
        "  --version 1.2.3 (tag v1.2.3)", "  --commit <40-character SHA>",
        "--startup", "  Run this program at boot.", "",
        "Dependencies install automatically.", "Run it now: ccpm run <name>",
    },
    update = {"ccpm update [name]", "", "Update one or all installed packages.",
        "Only branch-tracked packages change.", "Pinned versions and commits stay fixed."},
    pin = {"ccpm pin <name> --version 1.2.3", "ccpm pin <name> --commit <SHA>", "",
        "Install and pin a release or commit.", "Use a full 40-character commit SHA.",
        "Resume updates: ccpm track <name>"},
    track = {"ccpm track <name> [branch]", "", "Install from a branch and follow it.",
        "Default branch: main", "Boot updates follow auto-update setting."},
    run = {"ccpm run <name> [args...]", "", "Run an installed program.",
        "Arguments after the name go to it.", "Libraries cannot be run directly.",
        "Hold Ctrl+T to stop a running program."},
    remove = {"ccpm remove <name>", "", "Remove an installed package selection.",
        "Its cached files remain on disk.", "If selected for startup, disable it.",
        "Other installed packages are retained."},
    list = {"ccpm list", "", "Show installed packages, their sources,",
        "pinned/tracking state and startup choice.", "Dependencies are included with each root",
        "and are not listed separately."},
    available = {"ccpm available [options]", "", "List packages in a repository.",
        "--repo owner/repo", "Choose one source:", "  --branch name (default: main)",
        "  --version 1.2.3", "  --commit <40-character SHA>",
        "Default repo: " .. settings.get("ccpm.default_repo")},
    set = {"ccpm set", "  Show current boot settings.", "ccpm set auto-update <on|off>",
        "  Check tracked packages at boot.", "ccpm set startup <name|off>",
        "  Choose a program or disable launch.", "", "Changes are saved in /.settings."},
    ["self-update"] = {"ccpm self-update [branch]", "", "Update ccpm and its startup script.",
        "Default branch: main", "Repo: " .. settings.get("ccpm.default_repo"), "Installed packages are updated separately",
        "with ccpm update."},
    startup = {"ccpm startup", "", "Check for updates, then launch the",
        "selected program. Normally run at boot.", "Inspect boot settings with ccpm set."},
}

local function printHelp(topic)
    if topic and topic ~= "help" then
        if not helpTopics[topic] then fail("Unknown help topic: " .. topic .. ". Run 'ccpm help'.", 1) end
        display(helpTopics[topic])
        return
    end
    display({
        "ccpm - GitHub package manager", "", "ccpm <command> [arguments]", "",
        "available    Browse packages", "install      Install a package",
        "list         Inspect installed packages", "run          Run a program",
        "update       Update tracked packages", "pin          Keep a release or commit",
        "track        Follow a branch", "remove       Remove a package",
        "set          Boot settings", "self-update  Update ccpm itself", "",
        "Details: ccpm help <command>", "Example: ccpm help install",
        "Also: ccpm <command> --help",
    })
end

local function startupNotice(name)
    print("Startup program: " .. name)
    if settings.get("shell.allow_startup", true) == false then
        print("CraftOS startup is disabled. Enable it:")
        print("set shell.allow_startup true")
    else
        print("Runs at the next boot.")
    end
end

local function commandInstall()
    local positional, options = parseOptions(args, 2, {repo=true, branch=true, version=true, commit=true, startup=true})
    local name = positional[1]
    if not name or #positional ~= 1 then fail("Usage: ccpm install <name> [options]", 1) end
    local repository = options.repo or settings.get("ccpm.default_repo")
    validateRepository(repository)
    local selector = selectorFromOptions(options, "main")
    local state = loadState()
    installRoot(state, name, repository, selector, nil, options.startup)
    if options.startup then
        saveSettings({ ["ccpm.startup_package"] = name })
        startupNotice(name)
    end
    print("Inspect: ccpm list")
    if state.packages[state.roots[name].node].kind == "program" then print("Run: ccpm run " .. name) end
end

local function commandUpdate()
    local state = loadState()
    local name = args[2]
    if name then
        updateRoot(state, name, false)
        return
    end
    if not next(state.roots) then
        print("No packages installed. Browse with 'ccpm available'.")
        return
    end
    local failures = {}
    for _, rootName in ipairs(sortedKeys(state.roots)) do
        local root = state.roots[rootName]
        if root.selector.kind == "branch" then
            local ok, reason = pcall(updateRoot, state, rootName, false)
            if not ok then
                failures[#failures + 1] = rootName .. ": " .. tostring(reason)
                printError("Could not update " .. rootName .. ": " .. tostring(reason))
            end
        else
            print(rootName .. " is pinned; skipping")
        end
    end
    if #failures > 0 then fail("One or more packages could not be updated", 1) end
end

local function commandPin()
    local positional, options = parseOptions(args, 3, {version=true, commit=true})
    if #positional ~= 0 then fail("Unexpected arguments to pin", 1) end
    local name = args[2]
    if not name then fail("Usage: ccpm pin <name> --version x|--commit sha", 1) end
    if options.branch then fail("Use 'ccpm track' to follow a branch", 1) end
    local selector = selectorFromOptions(options)
    if selector.kind == "branch" then fail("Pin requires --version or --commit", 1) end
    local state = loadState()
    local root = state.roots[name]
    if not root then fail("Package is not installed: " .. name, 1) end
    installRoot(state, name, root.repo, selector)
end

local function commandTrack()
    local name, branch = args[2], args[3] or "main"
    if not name then fail("Usage: ccpm track <name> [branch]", 1) end
    local state = loadState()
    local root = state.roots[name]
    if not root then fail("Package is not installed: " .. name, 1) end
    installRoot(state, name, root.repo, { kind = "branch", value = branch })
end

local function commandRun()
    local name = args[2]
    if not name then fail("Usage: ccpm run <name> [args...]", 1) end
    local programArguments = {}
    for index = 3, #args do programArguments[#programArguments + 1] = args[index] end
    runPackage(withLock(loadState), name, programArguments)
end

local function commandRemove()
    local name = args[2]
    if not name then fail("Usage: ccpm remove <name>", 1) end
    local state = loadState()
    if not state.roots[name] then fail("Package is not installed: " .. name, 1) end
    if settings.get("ccpm.startup_package") == name then
        saveSettings({ ["ccpm.startup_package"] = "" })
    end
    state.roots[name] = nil
    saveState(state)
    print("Removed " .. name .. " (cached files were retained for rollback)")
end

local function commandList()
    -- Release the write lock before the pager waits for user input.
    local state = withLock(loadState)
    local names = sortedKeys(state.roots)
    if #names == 0 then
        print("No packages installed. Browse with 'ccpm available'.")
        return
    end
    local lines = { "Installed packages: " .. #names }
    local startup = settings.get("ccpm.startup_package")
    for _, name in ipairs(names) do
        local root = state.roots[name]
        local node = state.packages[root.node]
        local version = node and node.version or "?"
        lines[#lines + 1] = ""
        lines[#lines + 1] = name .. " " .. version
        lines[#lines + 1] = "  " .. (node and node.kind or "unknown") .. (startup == name and " | startup" or "")
        lines[#lines + 1] = "  Repo: " .. root.repo
        local selected = root.selector.kind == "commit" and root.selector.value:sub(1, 7) or root.selector.value
        lines[#lines + 1] = root.selector.kind == "branch" and ("  Tracking: " .. selected)
            or ("  Pinned " .. root.selector.kind .. ": " .. selected)
        lines[#lines + 1] = "  Installed: " .. root.resolved:sub(1, 7)
    end
    display(lines)
end

local function commandAvailable()
    local positional, options = parseOptions(args, 2, {repo=true, branch=true, version=true, commit=true})
    if #positional ~= 0 then fail("Unexpected arguments to available", 1) end
    local repository = options.repo or settings.get("ccpm.default_repo")
    local selector = selectorFromOptions(options, "main")
    local commit = resolveCommit(repository, selector)
    local manifest = getManifest(repository, commit)
    local names = sortedKeys(manifest.packages)
    local lines = {"Packages in " .. repository, selector.kind .. ": " .. selector.value .. " @ " .. commit:sub(1, 7)}
    if #names == 0 then lines[#lines + 1] = "No packages in this manifest." end
    for _, name in ipairs(names) do
        local packageDefinition = manifest.packages[name]
        validatePackage(name, packageDefinition)
        lines[#lines + 1] = ""
        lines[#lines + 1] = name .. " " .. packageDefinition.version
        lines[#lines + 1] = "  " .. packageDefinition.kind
        if type(packageDefinition.description) == "string" then lines[#lines + 1] = "  " .. packageDefinition.description end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Install: ccpm install <name>"
    lines[#lines + 1] = "Use the same --repo and source options."
    display(lines)
end

local function parseBoolean(value)
    if value == "on" or value == "true" or value == "yes" then return true end
    if value == "off" or value == "false" or value == "no" then return false end
    fail("Expected on or off", 1)
end

local function commandSet()
    local key, value = args[2], args[3]
    if not key then
        local startup = settings.get("ccpm.startup_package")
        print("Startup program: " .. (startup ~= "" and startup or "off"))
        print("Auto-update: " .. (settings.get("ccpm.auto_update") and "on" or "off"))
        print("CraftOS startup: " .. (settings.get("shell.allow_startup", true) and "on" or "off"))
        print("Default repo: " .. settings.get("ccpm.default_repo"))
        print("Change: ccpm help set")
    elseif key == "auto-update" and value then
        saveSettings({ ["ccpm.auto_update"] = parseBoolean(value) })
        print("Automatic startup updates are " .. (settings.get("ccpm.auto_update") and "on" or "off"))
    elseif key == "startup" and value then
        if value == "off" then value = "" end
        if value ~= "" then
            local state = loadState()
            local root = state.roots[value]
            if not root then fail("Package is not installed: " .. value, 1) end
            if state.packages[root.node].kind ~= "program" then fail("Startup package must be a program", 1) end
        end
        saveSettings({ ["ccpm.startup_package"] = value })
        if value == "" then print("Startup program disabled") else startupNotice(value) end
    else
        fail("Usage: ccpm set auto-update <on|off> | ccpm set startup <name|off>", 1)
    end
end

local function commandSelfUpdate()
    local branch = args[2] or "main"
    local repository = settings.get("ccpm.default_repo")
    local commit = resolveCommit(repository, { kind = "branch", value = branch })
    local base = "https://raw.githubusercontent.com/" .. repository .. "/" .. commit .. "/"
    local manager, startup = request(base .. "ccpm.lua"), request(base .. "startup.lua")
    local installer = assert(load(startup, "@startup.lua", "t", _ENV))("--installer")
    installer.install(manager, startup)
    print("Updated ccpm to " .. commit:sub(1, 7))
end

local function commandStartup()
    local state = withLock(function()
        local state = loadState()
        if settings.get("ccpm.auto_update") then
            for _, name in ipairs(sortedKeys(state.roots)) do
                if state.roots[name].selector.kind == "branch" then
                    local ok, reason = pcall(updateRoot, state, name, false)
                    if not ok then
                        printError("Update failed for " .. name .. "; using installed version: " .. tostring(reason))
                        state = loadState()
                    end
                end
            end
        end
        return state
    end)

    local startupPackage = settings.get("ccpm.startup_package")
    if startupPackage and startupPackage ~= "" then
        print("Starting " .. startupPackage .. "...")
        runPackage(state, startupPackage, {})
    end
end

local commands = {
    install = commandInstall,
    update = commandUpdate,
    pin = commandPin,
    track = commandTrack,
    run = commandRun,
    remove = commandRemove,
    list = commandList,
    available = commandAvailable,
    set = commandSet,
    ["self-update"] = commandSelfUpdate,
    startup = commandStartup,
    help = function() printHelp(args[2]) end,
}

local command = args[1] or "help"
if command == "--help" or command == "-h" then command = "help" end
local handler = commands[command]
if not handler then
    error("ccpm: Unknown command '" .. command .. "'. Run 'ccpm help'.", 0)
end

local ok, reason = xpcall(function()
    -- Only intercept help in command position; program arguments stay intact.
    if #args == 2 and (args[2] == "--help" or args[2] == "-h") then return printHelp(command) end
    local maximum = { update=2, track=3, remove=2, list=1, set=3, ["self-update"]=2, startup=1, help=2 }
    if maximum[command] and #args > maximum[command] then fail("Unexpected arguments to " .. command, 1) end
    if command == "run" or command == "startup" or command == "help" or command == "available" or command == "list" then
        return handler()
    end
    return withLock(handler)
end, function(problem)
    return tostring(problem):gsub("^.-:%d+:%s*", "")
end)
if not ok then
    -- CraftOS prints an uncaught error and returns failure to shell.execute.
    -- Printing here too would show every command error twice.
    error("ccpm: " .. reason .. "\nHelp: ccpm help " .. command, 0)
end
