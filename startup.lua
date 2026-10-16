-- ccpm runtime recovery and startup.
-- Also used by bootstrap/self-update as a standalone installer library.
local mode = ...
local transaction = "/.ccpm/runtime-update"
local pending = transaction .. "/pending.json"
local hook = "/startup/00-ccpm-recovery.lua"
local runtimeFiles = { "ccpm.lua", "startup.lua" }

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

local function ownsHook()
    local body = readFile(hook)
    local signature = "-- ccpm runtime recovery and startup."
    return body and body:sub(1, #signature) == signature
end

local function cleanup()
    if fs.exists(hook) and ownsHook() then fs.delete(hook) end
    if fs.exists(transaction) then fs.delete(transaction) end
end

local function recover()
    if not fs.exists(pending) then return end
    local journal = textutils.unserializeJSON(assert(readFile(pending)))
    assert(type(journal) == "table", "Invalid ccpm runtime recovery journal")
    -- Copies remain available until the whole rollback finishes, even if
    -- recovery itself is interrupted.
    for _, name in ipairs(runtimeFiles) do
        assert(type(journal[name]) == "boolean", "Invalid ccpm runtime recovery journal")
        if journal[name] then assert(fs.exists(transaction .. "/" .. name .. ".old"), "Missing runtime backup") end
    end
    for _, name in ipairs(runtimeFiles) do
        local path = "/" .. name
        if fs.exists(path) then fs.delete(path) end
        if journal[name] then fs.copy(transaction .. "/" .. name .. ".old", path) end
    end
    fs.delete(pending)
    cleanup()
end

local function install(manager, startup)
    assert(load(manager, "@ccpm.lua", "t", _ENV))
    assert(load(startup, "@startup.lua", "t", _ENV))
    recover()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        error("Cannot install recovery hook: /startup is a file", 0)
    end
    if fs.exists(hook) and not ownsHook() then error("Recovery hook path is already in use: " .. hook, 0) end
    cleanup()
    local bodies = { ["ccpm.lua"] = manager, ["startup.lua"] = startup }
    local journal = {}
    for _, name in ipairs(runtimeFiles) do
        local path = "/" .. name
        if fs.exists(path) and fs.isDir(path) then error("Runtime path is a directory: " .. path, 0) end
        journal[name] = fs.exists(path)
        writeFile(transaction .. "/" .. name .. ".new", bodies[name])
        if journal[name] then fs.copy(path, transaction .. "/" .. name .. ".old") end
    end
    -- CraftOS also runs /startup/* when /startup.lua is missing. Establish
    -- recovery before opening either file's replacement window.
    writeFile(hook, startup)
    writeFile(pending .. ".new", textutils.serializeJSON(journal))
    fs.move(pending .. ".new", pending)
    local ok, reason = pcall(function()
        -- The recovery-aware startup must be active before replacing ccpm.
        for _, name in ipairs({ "startup.lua", "ccpm.lua" }) do
            local path = "/" .. name
            if fs.exists(path) then fs.delete(path) end
            fs.move(transaction .. "/" .. name .. ".new", path)
        end
        fs.delete(pending) -- Commit point: both active files are installed.
    end)
    if not ok then
        local restored, recoveryError = pcall(recover)
        if not restored then error(tostring(reason) .. "; recovery pending: " .. tostring(recoveryError), 0) end
        error(reason, 0)
    end
    cleanup()
end

if mode == "--installer" then return { install = install, recover = recover, withLock = withLock } end

local ok, reason = pcall(withLock, recover)
if not ok then printError("ccpm recovery failed: " .. tostring(reason)) return end
-- A leftover recovery hook and the normal entrypoint may both run.
if _G.__ccpm_startup_ran then return end
if not fs.exists("/ccpm.lua") then
    printError("ccpm is not installed. Run the repository bootstrap command again.")
    return
end
_G.__ccpm_startup_ran = true
local ran, result = pcall(shell.run, "/ccpm.lua", "startup")
if not ran then
    printError("ccpm startup failed: " .. tostring(result))
elseif result == false then
    printError("ccpm startup did not complete successfully.")
end
