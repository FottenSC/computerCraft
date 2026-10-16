-- ccpm runtime recovery and startup.
-- Installed as /startup/10-ccpm.lua; user startup files are preserved.
local mode = ...
local transaction = "/.ccpm/runtime-update"
local pending = transaction .. "/pending.json"
local recoveryHook = "/startup/00-ccpm-recovery.lua"
local bootHook = "/startup/10-ccpm.lua"
local signature = "-- ccpm runtime recovery and startup."
local paths = { ["ccpm.lua"] = "/ccpm.lua", ["startup.lua"] = bootHook,
    ["runtime.json"] = "/.ccpm/runtime.json" }

local function readFile(path)
    local handle = fs.open(path, "rb")
    if not handle then return nil end
    local ok, body = pcall(handle.readAll)
    handle.close()
    if not ok then error(body, 0) end
    return body
end

local function writeFile(path, body)
    fs.makeDir(fs.getDir(path))
    local handle = assert(fs.open(path, "wb"))
    local ok, reason = pcall(handle.write, body)
    handle.close()
    if not ok then error(reason, 0) end
end

local function withLock(callback)
    if _G.__ccpm_write_lock then error("Another ccpm command is in progress; retry when it finishes", 0) end
    _G.__ccpm_write_lock = true
    local ok, result = pcall(callback)
    _G.__ccpm_write_lock = nil
    if not ok then error(result, 0) end
    return result
end

local function owned(path, prefix)
    local body = readFile(path)
    prefix = prefix or signature
    return body and body:sub(1, #prefix) == prefix
end

local function cleanup()
    if fs.exists(recoveryHook) and owned(recoveryHook) then fs.delete(recoveryHook) end
    if fs.exists(transaction) then fs.delete(transaction) end
end

local function recover()
    if not fs.exists(pending) then return end
    local journal = textutils.unserializeJSON(assert(readFile(pending)))
    assert(type(journal) == "table", "Invalid ccpm runtime recovery journal")
    assert(journal.schema == nil or journal.schema == 2, "Unsupported ccpm runtime recovery journal")
    -- Accept journals written by the original installer during migration.
    local targets = journal.schema == 2 and paths or { ["ccpm.lua"]="/ccpm.lua", ["startup.lua"]="/startup.lua" }
    for name in pairs(targets) do
        assert(type(journal[name]) == "boolean", "Invalid ccpm runtime recovery journal")
        if journal[name] then assert(fs.exists(transaction .. "/" .. name .. ".old"), "Missing runtime backup") end
    end
    for name, path in pairs(targets) do
        if fs.exists(path) then fs.delete(path) end
        if journal[name] then fs.copy(transaction .. "/" .. name .. ".old", path) end
    end
    fs.delete(pending)
    cleanup()
end

local function install(manager, startup, metadata)
    assert(load(manager, "@ccpm.lua", "t", _ENV))
    assert(load(startup, "@startup.lua", "t", _ENV))
    recover()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        error("/startup is a file. Back it up and move it to /startup.lua before installing ccpm.", 0)
    end
    for _, path in ipairs({ recoveryHook, bootHook }) do
        if fs.exists(path) and (fs.isDir(path) or not owned(path)) then error("Startup hook path is already in use: " .. path, 0) end
    end
    if fs.exists("/ccpm.lua") and not owned("/ccpm.lua", "-- ccpm:") then
        error("/ccpm.lua already exists and is not owned by ccpm; move it before installing.", 0)
    end
    cleanup()
    local bodies = { ["ccpm.lua"] = manager, ["startup.lua"] = startup,
        ["runtime.json"] = textutils.serializeJSON(metadata or {schema=1, source="unknown"}) }
    local journal = {schema=2}
    for name, path in pairs(paths) do
        if fs.exists(path) and fs.isDir(path) then error("Runtime path is a directory: " .. path, 0) end
        journal[name] = fs.exists(path)
        writeFile(transaction .. "/" .. name .. ".new", bodies[name])
        if journal[name] then fs.copy(path, transaction .. "/" .. name .. ".old") end
    end
    writeFile(recoveryHook, startup)
    writeFile(pending .. ".new", textutils.serializeJSON(journal))
    fs.move(pending .. ".new", pending)
    local ok, reason = pcall(function()
        for _, name in ipairs({ "startup.lua", "ccpm.lua", "runtime.json" }) do
            local path = paths[name]
            if fs.exists(path) then fs.delete(path) end
            fs.move(transaction .. "/" .. name .. ".new", path)
        end
        fs.delete(pending)
    end)
    if not ok then
        local restored, recoveryError = pcall(recover)
        if not restored then error(tostring(reason) .. "; recovery pending: " .. tostring(recoveryError), 0) end
        error(reason, 0)
    end
    local archived, archiveError = pcall(function()
        if fs.exists("/.ccpm/previous-runtime") then fs.delete("/.ccpm/previous-runtime") end
        fs.makeDir("/.ccpm/previous-runtime")
        for name in pairs(paths) do
            if journal[name] then fs.copy(transaction .. "/" .. name .. ".old", "/.ccpm/previous-runtime/" .. name) end
        end
        if owned("/startup.lua") then
            if not fs.exists("/.ccpm/legacy-startup.lua") then fs.copy("/startup.lua", "/.ccpm/legacy-startup.lua") end
            fs.delete("/startup.lua")
        end
    end)
    if not archived then
        printError("Runtime installed; previous backup incomplete. Originals retained in " .. transaction .. ": " .. tostring(archiveError))
        return
    end
    cleanup()
end

local function uninstall()
    recover()
    for _, path in ipairs({bootHook, recoveryHook, "/startup.lua"}) do
        if owned(path) then fs.delete(path) end
    end
    if owned("/ccpm.lua", "-- ccpm:") then fs.delete("/ccpm.lua") end
    if fs.exists("/.ccpm/runtime.json") then fs.delete("/.ccpm/runtime.json") end
end

if mode == "--installer" then return { install=install, recover=recover, withLock=withLock, uninstall=uninstall } end

local ok, reason = pcall(withLock, recover)
if not ok then printError("ccpm recovery failed: " .. tostring(reason)) return end
if _G.__ccpm_startup_ran then return end
if not fs.exists("/ccpm.lua") then printError("ccpm is missing; run bootstrap again.") return end
_G.__ccpm_startup_ran = true
local ran, result = pcall(shell.run, "/ccpm.lua", "startup")
if not ran then printError("ccpm startup failed: " .. tostring(result))
elseif result == false then printError("ccpm startup did not complete successfully.") end
